import Foundation
import KodaCore
import Observation

/// One coordinator per app, independent of the Now Playing sheet or selected panel.
/// Lookups are shared with the lyrics panel; translation results live in the Core
/// pipeline and its bounded disk cache, rather than in a view's @State.
@MainActor
@Observable
final class LyricsTranslationCoordinator {
    nonisolated struct DownloadRequest: Equatable, Sendable, Identifiable {
        let id: String
        let songID: String
        let source: String
        let target: String
    }

    nonisolated private struct LookupKey: Hashable, Sendable {
        let song: Song
        let sources: [String]
        let custom: [String]
        init(song: Song, sources: [LyricsSource], customSources: [CustomLyricsSource]) {
            self.song = song
            self.sources = sources.map(\.rawValue)
            custom = customSources.filter(\.isEnabled).map { $0.id.uuidString + "|" + $0.urlTemplate }
        }
    }
    private struct PreparedInput {
        let lines: [LyricsTranslationText]
        let input: AutomaticLyricTranslationPipeline.Input
    }

    let versions: LyricsVersions
    private let polish: LyricsPolishing
    @ObservationIgnored private let translationCache: AutomaticLyricTranslationCache
    private var mode: LyricsTranslationMode = .quality
    private var alternate: AlternateTranslation?
    private struct AlternateTranslation {
        let original: LyricsCandidate.Identity
        let songID: String
        let choice: LyricTranslationSelection
        let lines: [Int: String]
    }

    var currentAIMode: LyricsTranslationMode { mode == .pureAI ? .pureAI : .immersive }
    var isAIWorking: Bool {
        [.identifying, .preparing, .summarizing, .generating, .validating, .retrying, .awaitingCancellation]
            .contains(polish.diagnostics.phase)
    }

    private var queueEnded = false
    private var prefetchLimit = 5
    @ObservationIgnored private var cacheCapacityUpdate: Task<Void, Never>?
    @ObservationIgnored private var configuredMegabytes: Int?
    private var hasHeadroom = true
    private var originalReadsAllowed = false
    private var buffered = false
    private var constrained = false
    private var versionBySong: [String: LyricsCandidate] = [:]
    private let pipeline: AutomaticLyricTranslationPipeline
    private var inputs: [String: PreparedInput] = [:]
    @ObservationIgnored private var preparation: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var baseMode: LyricsTranslationMode { mode == .immersive ? .quality : mode }
    private var currentSong: Song?
    private var upcomingSongs: [Song] = []
    private var automaticEnabled = true
    private var showsTranslation = false
    private var foreground = true
    private var expirationSuspended = false
    private var playbackSessionFinished = false
    private(set) var lyricsRevision = 0
    private var downloadAttempt: UInt64 = 0
    private var downloadPolicy = AutomaticLyricDownloadPolicy()
    @ObservationIgnored private var languageCheckTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [LyricsSource] = []
    @ObservationIgnored private var customSources: [CustomLyricsSource] = []
    @ObservationIgnored private var desiredLookups: [String: LookupKey] = [:]
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchGeneration = UUID()
    @ObservationIgnored private var attemptedPrefetch: Set<LookupKey> = []
    @ObservationIgnored private var lookupContext: [LookupKey] = []
    @ObservationIgnored private var backgroundExecutionAllowed = false
    @ObservationIgnored private var backgroundContinuationKey: LookupKey?
    @ObservationIgnored private var currentRetryKey: LookupKey?
    private static let maximumCachedSongs = 200
    private static let maximumOriginalLyricsBytes = 20_000_000
    private static let upcomingCount = 5

    init(client: LyricsClient, directory: URL) {
        versions = LyricsVersions(client: client, cache: directory.deletingLastPathComponent().appending(path: "KodaLyricsCandidates"))
        polish = LyricsPolishing(directory: directory.deletingLastPathComponent().appending(path: "KodaLyricsPolished"))
        let cache = AutomaticLyricTranslationCache(directory: directory)
        translationCache = cache
        pipeline = AutomaticLyricTranslationPipeline(cache: cache, maximumUpcoming: Self.upcomingCount,
                                                     observedEngine: NativeLyricsTranslationEngine.translate)
        versions.onSelection = { [weak self] in self?.selectedVersionChanged($0) }
    }

    var hasActiveWork: Bool { !playbackSessionFinished && (pipeline.isWorking || versions.searching) }
    var hasCurrentWork: Bool {
        !playbackSessionFinished && !expirationSuspended && (versions.searching || (pipeline.isWorking && pipeline.activeSongID == currentSong?.id))
    }

    /// Called by app-lifetime observation, never by a disposable lyrics view task.
    func update(current: Song?, upcoming: [Song], sources: [LyricsSource], customSources: [CustomLyricsSource],
                automaticEnabled: Bool, showsTranslation: Bool, isForeground: Bool,
                mode: LyricsTranslationMode, prefetchLimit: Int, allowed: Bool, hasHeadroom: Bool,
                constrained: Bool, buffering: Bool) {
        let newMode = self.mode != mode
        if newMode { invalidateLanguageWork(); alternate = nil }
        let budgetChanged = self.prefetchLimit != prefetchLimit || self.hasHeadroom != hasHeadroom
            || self.buffered != buffering || self.constrained != constrained || originalReadsAllowed != allowed
        self.mode = mode
        self.prefetchLimit = prefetchLimit
        self.hasHeadroom = hasHeadroom
        self.buffered = buffering
        self.constrained = constrained
        originalReadsAllowed = allowed
        let becameActive = !foreground && isForeground
        let leavingForeground = foreground && !isForeground
        let changedSong = currentSong?.id != current?.id
        let priorCurrentLookupKey = currentSong.flatMap { desiredLookups[$0.id] }
        let wasPreparing = self.automaticEnabled && self.showsTranslation
        if leavingForeground {
            backgroundContinuationKey = hasCurrentWork && wasPreparing
                ? currentSong.flatMap { desiredLookups[$0.id] } : nil
        }
        if becameActive && !playbackSessionFinished { expirationSuspended = false }
        currentSong = current
        var seen = Set<String>()
        if let current { seen.insert(current.id) }
        upcomingSongs = Array(upcoming.filter { seen.insert($0.id).inserted }.prefix(min(Self.upcomingCount, max(0, prefetchLimit))))
        self.sources = sources
        self.customSources = customSources
        self.automaticEnabled = automaticEnabled
        self.showsTranslation = showsTranslation
        foreground = isForeground
        let songs = current.map { [$0] + upcomingSongs } ?? []
        let context = songs.map { LookupKey(song: $0, sources: sources, customSources: customSources) }
        let changed = context != lookupContext
        if changed {
            let oldDesired = desiredLookups
            desiredLookups = Dictionary(uniqueKeysWithValues: context.map { ($0.song.id, $0) })
            for (id, old) in oldDesired where desiredLookups[id] != old {
                inputs.removeValue(forKey: id)
                preparation.removeValue(forKey: id)?.task.cancel()
                if desiredLookups[id] != nil { versionBySong.removeValue(forKey: id) }
            }
            attemptedPrefetch.formIntersection(Set(context))
            lookupContext = context
        }
        versions.follow(song: current, sources: sources, custom: customSources,
                        allowed: allowed && !expirationSuspended && !playbackSessionFinished && !queueEnded,
                        constrained: constrained || buffering)
        if newMode || changed {
            for candidate in Array(versionBySong.values) where desiredLookups[candidate.songID] != nil {
                install(candidate)
            }
        }
        let prepares = automaticEnabled && showsTranslation && !playbackSessionFinished && !queueEnded
        let currentLookupKey = current.flatMap { desiredLookups[$0.id] }
        if isForeground || !prepares || expirationSuspended || currentLookupKey != backgroundContinuationKey {
            backgroundContinuationKey = nil
        }
        if becameActive || changedSong || currentLookupKey != priorCurrentLookupKey || (!wasPreparing && prepares) {
            currentRetryKey = currentLookupKey
        }
        if !isForeground || !allowed || expirationSuspended || !hasHeadroom || constrained || buffering {
            cancelPrefetch(keepingCurrent: true)
        } else {
            if changed || becameActive || newMode || budgetChanged { cancelPrefetch(keepingCurrent: true) }
            if prefetchTask == nil { startPrefetch(context) }
        }
        if !automaticEnabled { pipeline.suspend() }
        refreshTranslationRequests()
        retryPreparedCurrentIfNeeded()
        trimMemoryInputs()
    }

    private func selectedVersionChanged(_ candidate: LyricsCandidate?) {
        invalidateLanguageWork()
        alternate = nil
        if let songID = currentSong?.id {
            preparation.removeValue(forKey: songID)?.task.cancel()
            inputs[songID] = nil
            versionBySong[songID] = nil
        }
        if let candidate { install(candidate) }
        lyricsRevision &+= 1
        refreshTranslationRequests()
        if let candidate, let choice = alternateMode(versions.translationSelection) {
            let scope = versions.profileScope
            let selection = versions.translationSelection
            Task { [weak self] in await self?.loadAlternate(candidate, mode: choice, choice: selection, scope: scope) }
        }
        if foreground, hasHeadroom, !buffered, !constrained, prefetchTask == nil { startPrefetch(lookupContext) }
    }

    private func install(_ candidate: LyricsCandidate) {
        let lines: [LyricsTranslationText]
        switch candidate.lyrics {
        case .synced(let rows): lines = rows.map { .init(id: $0.id, text: $0.text) }
        case .plain(let text): lines = LyricsCandidate.plainLines(text).enumerated().map { .init(id: $0.offset, text: $0.element) }
        }
        let previousPlan = versionBySong[candidate.songID]?.id == candidate.id ? inputs[candidate.songID]?.input.plan : nil
        versionBySong[candidate.songID] = candidate
        let rows = lines.map { ChineseLyricTranslationPlan.Row(id: $0.id, text: $0.text) }
        prepare(candidate, lines: lines, rows: rows, plan: previousPlan)
    }

    private func prepare(_ candidate: LyricsCandidate, lines: [LyricsTranslationText],
                         rows: [ChineseLyricTranslationPlan.Row], plan: ChineseLyricTranslationPlan?) {
        let id = candidate.songID
        let token = UUID()
        preparation[id]?.task.cancel()
        let mode = baseMode
        let namespace = candidate.id.cacheNamespace
        inputs[id] = .init(lines: lines, input: .init(songID: id, rows: rows, namespace: namespace, mode: mode, plan: plan))
        preparation[id] = (token, Task(priority: id == currentSong?.id ? .userInitiated : .utility) { [weak self] in
            let plan = if let plan { plan } else { await Self.analyze(rows) }
            guard let self, !Task.isCancelled, self.preparation[id]?.id == token else { return }
            self.inputs[id] = .init(lines: lines, input: .init(songID: id, rows: rows, namespace: namespace, mode: mode, plan: plan))
            if id == self.currentSong?.id { self.adjustPolish(limits: self.polishLimits) }
            guard mode.usesAppleTranslation else { self.preparation[id] = nil; return }
            let routes = await NativeLyricsTranslationEngine.routes(for: plan.fragments, mode: mode)
            guard !Task.isCancelled, self.preparation[id]?.id == token else { return }
            self.inputs[id] = .init(lines: lines, input: .init(songID: id, rows: rows, namespace: namespace,
                                                              mode: mode, plan: plan, routes: routes))
            self.preparation[id] = nil
            self.refreshTranslationRequests()
            self.retryPreparedCurrentIfNeeded()
        })
    }

    @concurrent nonisolated private static func analyze(_ rows: [ChineseLyricTranslationPlan.Row]) async -> ChineseLyricTranslationPlan {
        ChineseLyricTranslationPlan(rows: rows)
    }

    private func preparedBase(_ id: String) -> AutomaticLyricTranslationPipeline.Input? {
        guard let input = inputs[id]?.input, input.routes != nil, input.mode.usesAppleTranslation else { return nil }
        return input
    }

    private func resetPreparation() {
        for work in preparation.values { work.task.cancel() }
        preparation.removeAll()
    }

    func setProfile(_ directory: URL, replacingSession: Bool = false) {
        cancelPrefetch(keepingCurrent: false)
        resetPreparation()
        alternate = nil
        inputs.removeAll()
        versionBySong.removeAll()
        lookupContext = []
        attemptedPrefetch.removeAll()
        currentRetryKey = nil
        versions.setProfile(directory, replacingSession: replacingSession)
        polish.setProfile(directory)
        lyricsRevision &+= 1
        refreshTranslationRequests()
    }

    func queueDidEnd() {
        queueEnded = true
        cancelPrefetch(keepingCurrent: false)
        polish.stop()
        pipeline.suspend()
        refreshTranslationRequests()
    }

    func playbackRequested() {
        guard queueEnded else { return }
        queueEnded = false
        lookupContext = []
        lyricsRevision &+= 1
    }

    var polishTrigger: AutomaticLyricTranslationPipeline.Snapshot {
        guard let id = currentSong?.id, let prepared = inputs[id] else { return .init() }
        return pipeline.snapshot(for: prepared.input)
    }

    private var polishLimits: Set<LyricWorkLimit> = []

    func adjustPolish(limits: Set<LyricWorkLimit>) {
        polishLimits = expirationSuspended ? limits.union([.background]) : limits
        let wantsAI = mode.usesContextModel || versions.translationSelection == .foundationModels
        var work: LyricsPolishing.Work?
        var upcoming: LyricsPolishing.Work?
        let aiMode: LyricsTranslationMode = mode == .pureAI ? .pureAI : .immersive
        if wantsAI, let song = currentSong, let version = versions.current, let prepared = inputs[song.id],
           let plan = prepared.input.plan {
            work = .init(song: song, candidate: version, rows: prepared.lines, plan: plan, mode: aiMode,
                         base: preparedBase(song.id).map { pipeline.snapshot(for: $0).lines } ?? [:])
            if mode.usesContextModel, hasHeadroom, !constrained, !buffered,
               let next = upcomingSongs.first, let nextVersion = versionBySong[next.id], let nextInput = inputs[next.id],
               let plan = nextInput.input.plan {
                upcoming = .init(song: next, candidate: nextVersion, rows: nextInput.lines, plan: plan, mode: aiMode,
                                 base: preparedBase(next.id).map { pipeline.snapshot(for: $0).lines } ?? [:])
            }
        }
        polish.update(work, upcoming: upcoming, limits: polishLimits,
                      enabled: wantsAI && automaticEnabled && showsTranslation && !queueEnded && !playbackSessionFinished)
    }

    func regenerate(clear: Bool, polishOnly: Bool = false) async {
        guard !playbackSessionFinished, !queueEnded, let id = currentSong?.id, inputs[id] != nil else { return }
        let scope = versions.profileScope
        let version = versions.current?.id
        let requestMode = mode
        if !polishOnly, let base = preparedBase(id) {
            Task {
                guard versions.profileScope == scope, mode == requestMode,
                      versions.current?.id == version, currentSong?.id == id else { return }
                await pipeline.regenerate(base, discardDisk: clear)
            }
        }
        guard (requestMode.usesContextModel || versions.translationSelection == .foundationModels),
              mode == requestMode, versions.profileScope == scope,
              versions.current?.id == version, currentSong?.id == id, !playbackSessionFinished, !queueEnded else { return }
        adjustPolish(limits: polishLimits)
        await polish.regenerate(clear: clear)
    }

    func cachedTranslation(for candidate: LyricsCandidate, mode: LyricsTranslationMode) async -> [Int: String] {
        if mode.usesContextModel { return await polish.cached(candidate, mode: mode) }
        let rows = LyricsPreviewRow.make(candidate.lyrics).map { ChineseLyricTranslationPlan.Row(id: $0.id, text: $0.text) }
        let plan = await Self.analyze(rows)
        let routes = await NativeLyricsTranslationEngine.routes(for: plan.fragments, mode: mode)
        guard !Task.isCancelled else { return [:] }
        let input = AutomaticLyricTranslationPipeline.Input(songID: candidate.songID, rows: rows,
                  namespace: candidate.id.cacheNamespace, mode: mode, plan: plan, routes: routes)
        guard let saved = await translationCache.entry(for: AutomaticLyricTranslationPipeline.cacheKey(input)) else { return [:] }
        return plan.renderedLines(translations: saved.fragments)
    }

    func selectTranslation(_ choice: LyricTranslationSelection) async {
        guard let candidate = versions.current else { return }
        let scope = versions.profileScope
        await versions.selectTranslation(choice)
        guard versions.profileScope == scope, versions.current?.id == candidate.id,
              versions.translationSelection == choice else { return }
        alternate = nil
        if let mode = alternateMode(choice) { await loadAlternate(candidate, mode: mode, choice: choice, scope: scope) }
    }

    private func alternateMode(_ choice: LyricTranslationSelection) -> LyricsTranslationMode? {
        switch choice {
        case .quickApple: .quick
        case .qualityApple: .quality
        case .immersiveAI: .immersive
        case .pureAI: .pureAI
        default: nil
        }
    }

    private func loadAlternate(_ candidate: LyricsCandidate, mode: LyricsTranslationMode, choice: LyricTranslationSelection,
                               scope: UUID) async {
        let lines = await cachedTranslation(for: candidate, mode: mode)
        guard !Task.isCancelled, versions.profileScope == scope, versions.current?.id == candidate.id,
              versions.translationSelection == choice else { return }
        alternate = .init(original: candidate.id, songID: candidate.songID, choice: choice, lines: lines)
    }

    func resumeFailedContext() {
        guard !playbackSessionFinished, !queueEnded else { return }
        polish.resumeFailed()
    }

    func regenerateContext(_ rows: Set<Int>, for candidate: LyricsCandidate, scope: UUID) async {
        guard !playbackSessionFinished, !queueEnded, scope == versions.profileScope,
              versions.current?.id == candidate.id, polish.version == candidate.id, polish.songID == candidate.songID else { return }
        await polish.regenerate(clear: false, rows: rows)
    }

    func retainAI(_ candidate: LyricsCandidate) async throws {
        guard candidate.id == versions.current?.id, candidate.songID == versions.current?.songID else { throw CancellationError() }
        try await polish.retain(candidate, mode: currentAIMode, edits: versions.edits(for: candidate))
    }

    func retainedAI(_ candidate: LyricsCandidate, mode: LyricsTranslationMode) async throws -> PreservedLyricTranslationStore.Record? {
        try await polish.retained(candidate, mode: mode)
    }

    func forgetAI(_ candidate: LyricsCandidate, mode: LyricsTranslationMode) async throws {
        try await polish.forget(candidate, mode: mode)
    }

    func retainedAIUsage() async throws -> Int { try await polish.retainedUsage() }

    func setCacheCapacity(megabytes: Int) {
        guard configuredMegabytes != megabytes else { return }
        configuredMegabytes = megabytes
        let previous = cacheCapacityUpdate
        cacheCapacityUpdate = Task { [versions, translationCache, polish] in
            await previous?.value
            let total = min(250, max(25, megabytes)) * 1_000_000
            await versions.store.setCapacity(total * 2 / 5)
            await translationCache.setCapacity(total * 2 / 5)
            await polish.setCapacity(total / 5)
        }
    }

    func cacheUsage() async -> Int {
        await cacheCapacityUpdate?.value
        let originals = await versions.store.usage()
        let translated = await translationCache.byteCount()
        let polished = await polish.usage()
        return originals + translated + polished
    }

    /// This only reads already registered rows/snapshots; no disk access, network, language
    /// detection or fingerprint hashing occurs in the frame-by-frame lyrics presentation.
    func result(songID: String?, lines: [LyricsTranslationText], imported: [Int: String] = [:],
                importsEnabled: Bool = true) -> AutomaticLyricsResult {
        let current = versions.current
        let currentVersion = current?.songID == songID ? current : nil
        let selection = currentVersion == nil ? .automatic : versions.translationSelection
        let isImmersive = mode.usesContextModel || selection == .foundationModels
        guard let songID, let prepared = inputs[songID], prepared.lines == lines else {
            return .init(phase: playbackSessionFinished ? .paused : .idle, playbackSessionFinished: playbackSessionFinished,
                         immersiveStatus: isImmersive ? .preparing : nil,
                         originalReady: currentVersion != nil, originalSearching: versions.searching, limits: polishLimits)
        }
        let snapshot = pipeline.snapshot(for: prepared.input)
        let phase: AutomaticLyricsResult.Phase
        let baseStage: ImmersiveLyricStatus.Base
        switch snapshot.phase {
        case .idle: (phase, baseStage) = (.idle, .preparing)
        case .preparing: (phase, baseStage) = (.preparing, .preparing)
        case .translating: (phase, baseStage) = (.translating, .translating)
        case .ready: (phase, baseStage) = (.ready, .ready)
        case .needsLanguage: (phase, baseStage) = (.needsLanguage, snapshot.lines.isEmpty ? .unavailable : .partial)
        case .unavailable: (phase, baseStage) = (.unavailable, snapshot.lines.isEmpty ? .unavailable : .partial)
        case .failed: (phase, baseStage) = (.failed, snapshot.lines.isEmpty ? .unavailable : .partial)
        case .paused: (phase, baseStage) = (.paused, .preparing)
        }

        let workMatches = currentVersion != nil && polish.version == currentVersion?.id && polish.mode == currentAIMode && polish.songID == songID
        let contextual = automaticEnabled && isImmersive && workMatches ? polish.lines : [:]
        let pure = mode == .pureAI
        let preferred = currentVersion.map {
            $0.id.source == "local" || [.high, .medium].contains($0.match.confidence)
                || versions.assessments[$0.id]?.content == .verified
        } ?? false
        let selectedMode = alternateMode(selection)
        let activeLines: [Int: String]
        if selectedMode == baseMode, !pure { activeLines = snapshot.lines }
        else if selectedMode == currentAIMode, workMatches { activeLines = contextual }
        else if let alternate, alternate.songID == songID, alternate.original == currentVersion?.id, alternate.choice == selection {
            activeLines = alternate.lines
        } else { activeLines = [:] }
        let resolved = ResolvedLyricTranslations(selection: selection, embedded: currentVersion?.embeddedTranslations ?? [],
                        prefersProvider: preferred, imported: importsEnabled ? imported : [:],
                        base: automaticEnabled && !pure ? snapshot.lines : [:], contextual: contextual,
                        contextualOrigin: pure ? .pureAI : .foundationModels,
                        edits: currentVersion.map { versions.edits(for: $0) } ?? [:], selectedLines: activeLines)
        let polishStatus: ImmersiveLyricStatus.Polish = workMatches ? polish.status : .idle
        let immersive = isImmersive ? ImmersiveLyricStatus.resolve(base: pure ? .ready : baseStage, polish: polishStatus) : nil
        let status = snapshot.usedCompatibility ? String(localized: "Using Compatible Translation") : nil
        return AutomaticLyricsResult(phase: playbackSessionFinished && phase != .ready ? .paused : phase,
            lines: resolved.lines, completed: snapshot.completed, total: snapshot.total,
            playbackSessionFinished: playbackSessionFinished, strategyStatus: status,
            immersiveStatus: immersive, baseDiagnostics: snapshot, polishDiagnostics: workMatches ? polish.diagnostics : .init(),
            originalReady: currentVersion != nil, originalSearching: versions.searching,
            originalLookupSeconds: versions.originalLookupSeconds, originalCacheUse: versions.originalCacheUse,
            origins: resolved.origins, selectedSource: selection, limits: polishLimits,
            languageProfile: prepared.input.plan?.languageProfile,
            skippedRows: prepared.input.plan.map { lines.count - $0.semanticRows.count } ?? 0)
    }

    func legacyContextualLines(for candidate: LyricsCandidate) async -> [Int: String] {
        await polish.legacy(candidate)
    }

    func contextualLines(for candidate: LyricsCandidate) -> [Int: String] {
        polish.version == candidate.id && polish.songID == candidate.songID ? polish.lines : [:]
    }

    private func invalidateLanguageWork() {
        languageCheckTask?.cancel()
        languageCheckTask = nil
        downloadAttempt &+= 1
        downloadPolicy = AutomaticLyricDownloadPolicy()
    }

    func retry(songID: String?) {
        guard !playbackSessionFinished else { return }
        if foreground { expirationSuspended = false }
        languageCheckTask?.cancel()
        downloadAttempt &+= 1
        let pair = songID.flatMap { inputs[$0]?.input }.flatMap { pipeline.snapshot(for: $0).languagePair }
            .map { AutomaticLyricDownloadPolicy.Pair(source: $0.source, target: $0.target) }
        downloadPolicy.retry(pair)
        pipeline.retry(songID: songID)
    }

    func suspendForBackgroundExpiration() {
        expirationSuspended = true
        backgroundContinuationKey = nil
        cancelPrefetch(keepingCurrent: false)
        polish.stop()
        pipeline.suspend()
    }

    /// Only Player's explicit session boundary may change this gate. Background/active
    /// notifications and translation toggles keep the completed listening session closed.
    func setPlaybackSessionFinished(_ finished: Bool) {
        guard playbackSessionFinished != finished else { return }
        playbackSessionFinished = finished
        pipeline.setPlaybackSessionFinished(finished)
        if finished {
            polish.stop()
            backgroundContinuationKey = nil
            currentRetryKey = nil
            languageCheckTask?.cancel()
            languageCheckTask = nil
            downloadAttempt &+= 1
            cancelPrefetch(keepingCurrent: false)
        } else {
            expirationSuspended = false
            // Force one normal foreground reconciliation even if song and settings are
            // unchanged. Stored results remain available and only missing work resumes.
            lookupContext = []
            currentRetryKey = currentSong.flatMap { desiredLookups[$0.id] }
            lyricsRevision &+= 1
        }
    }

    func flush() async { await pipeline.flush() }

    /// The scene owner supplies this only after UIKit grants a valid finite assertion.
    /// Permission alone never starts work for a newly selected background song.
    func setBackgroundExecutionAllowed(_ allowed: Bool) {
        guard backgroundExecutionAllowed != allowed else { return }
        backgroundExecutionAllowed = allowed
        if !allowed { backgroundContinuationKey = nil }
        refreshTranslationRequests()
    }

    /// Source-cache clearing does not discard content-keyed automatic translations.
    func clearLyricsCache() async {
        cancelPrefetch(keepingCurrent: false)
        await versions.clearCatalogueCache()
        if originalReadsAllowed && !queueEnded && !playbackSessionFinished { versions.search(force: true) }
    }

    var downloadRequest: DownloadRequest? {
        guard mode.usesAppleTranslation, !playbackSessionFinished, foreground, automaticEnabled, showsTranslation, let songID = currentSong?.id,
              let prepared = inputs[songID] else { return nil }
        let snapshot = pipeline.snapshot(for: prepared.input)
        guard snapshot.phase == .needsLanguage, let pair = snapshot.languagePair else { return nil }
        let id = "\(songID)|\(pair.source)|\(pair.target)|\(downloadAttempt)"
        guard downloadPolicy.allows(.init(source: pair.source, target: pair.target), requestID: id) else { return nil }
        return DownloadRequest(id: id, songID: songID, source: pair.source, target: pair.target)
    }

    func beginLanguageDownload(_ request: DownloadRequest) -> Bool {
        guard downloadRequest == request else { return false }
        return downloadPolicy.begin(.init(source: request.source, target: request.target), requestID: request.id)
    }

    func finishLanguageDownload(_ request: DownloadRequest, installed: Bool) {
        guard !Task.isCancelled, !playbackSessionFinished, downloadRequest == request else { cancelLanguageDownload(request); return }
        let pair = AutomaticLyricDownloadPolicy.Pair(source: request.source, target: request.target)
        guard downloadPolicy.finish(pair, requestID: request.id, installed: installed) else { return }
        // A failed/cancelled foreground prompt is not remounted indefinitely. Retry is
        // explicit and belongs to the language pair, including after skipping a song.
        if installed {
            retryCurrentLanguage(pair)
        } else {
            // Apple's preparation may finish while another download is still running.
            // Check local installation state briefly without retaining the UI session or
            // repeatedly presenting a download dialog. A later foreground entry can retry.
            languageCheckTask?.cancel()
            let attempt = downloadAttempt
            languageCheckTask = Task { [weak self] in
                for _ in 0..<10 {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, !Task.isCancelled, !self.playbackSessionFinished, self.foreground, self.automaticEnabled,
                          self.showsTranslation, self.downloadAttempt == attempt else { return }
                    let ready = await NativeLyricsTranslationEngine.isInstalled(source: request.source, target: request.target)
                    guard !Task.isCancelled, !self.playbackSessionFinished, self.foreground, self.downloadAttempt == attempt else { return }
                    if ready {
                        self.retryCurrentLanguage(pair)
                        return
                    }
                }
            }
        }
    }

    func cancelLanguageDownload(_ request: DownloadRequest) {
        let pair = AutomaticLyricDownloadPolicy.Pair(source: request.source, target: request.target)
        guard downloadPolicy.cancelHost(pair, requestID: request.id) else { return }
        // A replacement host might already have tried this request while the old host
        // still held its claim. Give the now-free request a new identity so it can run.
        downloadAttempt &+= 1
    }

    private func retryCurrentLanguage(_ pair: AutomaticLyricDownloadPolicy.Pair) {
        guard !playbackSessionFinished, let songID = currentSong?.id, let prepared = inputs[songID],
              let needed = pipeline.snapshot(for: prepared.input).languagePair,
              needed.source == pair.source, needed.target == pair.target else { return }
        if let candidate = versions.current, candidate.songID == songID { install(candidate) }
    }

    private func refreshTranslationRequests() {
        let currentLookupKey = currentSong.flatMap { desiredLookups[$0.id] }
        let mayContinueCurrent = !playbackSessionFinished && !foreground && backgroundExecutionAllowed && !expirationSuspended
            && backgroundContinuationKey != nil && currentLookupKey == backgroundContinuationKey
        pipeline.setRequests(current: currentSong.flatMap { preparedBase($0.id) },
                             upcoming: (hasHeadroom && !buffered && !constrained ? upcomingSongs : []).compactMap { preparedBase($0.id) },
                             enabled: mode.usesAppleTranslation && automaticEnabled && showsTranslation && !playbackSessionFinished && !queueEnded,
                             isForeground: foreground && !expirationSuspended && !playbackSessionFinished,
                             allowsBackgroundCurrent: mayContinueCurrent)
    }

    /// A failed prefetched record may only become known after its cached lyrics arrive.
    /// Consume one retry per current-song admission, not on every observable update.
    private func retryPreparedCurrentIfNeeded() {
        guard !playbackSessionFinished, let key = currentRetryKey, currentSong?.id == key.song.id,
              desiredLookups[key.song.id] == key, let prepared = inputs[key.song.id] else { return }
        currentRetryKey = nil
        switch pipeline.snapshot(for: prepared.input).phase {
        case .failed, .paused, .needsLanguage: pipeline.retry(songID: prepared.input.songID)
        default: break
        }
    }

    private func startPrefetch(_ context: [LookupKey]) {
        guard !playbackSessionFinished, !queueEnded, foreground, !expirationSuspended,
              originalReadsAllowed, hasHeadroom, !buffered, !constrained,
              !versions.searching || versions.current != nil else { return }
        let lookups = context.dropFirst().filter { versionBySong[$0.song.id] == nil && !attemptedPrefetch.contains($0) }
        guard !lookups.isEmpty else { return }
        let generation = UUID()
        prefetchGeneration = generation
        let sources = sources, custom = customSources
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for next in lookups {
                guard !Task.isCancelled, self.prefetchGeneration == generation, self.foreground else { return }
                let version = await self.versions.preparedVersion(.init(song: next.song, sources: sources, custom: custom))
                guard !Task.isCancelled, self.prefetchGeneration == generation, self.desiredLookups[next.song.id] == next else { return }
                self.attemptedPrefetch.insert(next)
                if let version {
                    self.install(version)
                    self.refreshTranslationRequests()
                }
            }
            if self.prefetchGeneration == generation { self.prefetchTask = nil }
        }
    }

    private func cancelPrefetch(keepingCurrent: Bool) {
        prefetchGeneration = UUID()
        prefetchTask?.cancel()
        prefetchTask = nil
        if !keepingCurrent { versions.suspend() }
    }

    private func trimMemoryInputs() {
        guard inputs.count > Self.maximumCachedSongs else { return }
        let protected = Set([currentSong?.id].compactMap { $0 } + upcomingSongs.map(\.id))
        for id in Array(inputs.keys).sorted() where !protected.contains(id) {
            inputs.removeValue(forKey: id)
            versionBySong[id] = nil
            if inputs.count <= Self.maximumCachedSongs { break }
        }
    }
}
