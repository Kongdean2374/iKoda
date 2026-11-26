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
                                                     contextualEngine: NativeLyricsTranslationEngine.translate)
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
        if newMode { invalidateLanguageWork() }
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
        if let songID = currentSong?.id {
            inputs[songID] = nil
            versionBySong[songID] = nil
        }
        if let candidate { install(candidate) }
        lyricsRevision &+= 1
        refreshTranslationRequests()
        if foreground, hasHeadroom, !buffered, !constrained, prefetchTask == nil { startPrefetch(lookupContext) }
    }

    private func install(_ candidate: LyricsCandidate) {
        let lines: [LyricsTranslationText]
        switch candidate.lyrics {
        case .synced(let rows): lines = rows.map { .init(id: $0.id, text: $0.text) }
        case .plain(let text): lines = LyricsCandidate.plainLines(text).enumerated().map { .init(id: $0.offset, text: $0.element) }
        }
        versionBySong[candidate.songID] = candidate
        inputs[candidate.songID] = PreparedInput(lines: lines, input: .init(songID: candidate.songID,
            rows: lines.map { .init(id: $0.id, text: $0.text) }, namespace: candidate.id.cacheNamespace, mode: mode))
    }

    func setProfile(_ directory: URL) {
        cancelPrefetch(keepingCurrent: false)
        inputs.removeAll()
        versionBySong.removeAll()
        lookupContext = []
        attemptedPrefetch.removeAll()
        currentRetryKey = nil
        versions.setProfile(directory)
        polish.stop()
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

    func adjustPolish(allowed: Bool) {
        let snapshot = polishTrigger
        let upcoming: LyricsPolishing.Work?
        if mode == .immersive, hasHeadroom, !constrained, !buffered,
           let song = upcomingSongs.first, let version = versionBySong[song.id], let prepared = inputs[song.id] {
            let next = pipeline.snapshot(for: prepared.input)
            upcoming = next.phase == .ready
                ? .init(song: song, candidate: version, rows: prepared.lines, base: next.lines, completed: true)
                : nil
        } else { upcoming = nil }
        polish.update(song: currentSong, candidate: versions.current,
                      rows: currentSong.flatMap { inputs[$0.id]?.lines } ?? [], base: snapshot.lines,
                      complete: snapshot.phase == .ready, upcoming: upcoming, allowed: allowed && !expirationSuspended,
                      enabled: mode == .immersive && automaticEnabled && showsTranslation && !queueEnded && !playbackSessionFinished)
    }

    func regenerate(clear: Bool, polishOnly: Bool = false) async {
        guard !playbackSessionFinished, !queueEnded, let id = currentSong?.id, let input = inputs[id]?.input else { return }
        let scope = versions.profileScope
        let version = versions.current?.id
        let requestMode = mode
        if !polishOnly { await pipeline.regenerate(input, discardDisk: clear) }
        guard requestMode == .immersive, mode == requestMode, versions.profileScope == scope,
              versions.current?.id == version, currentSong?.id == id, !playbackSessionFinished, !queueEnded else { return }
        await polish.regenerate(clear: clear)
    }

    func cachedTranslation(for candidate: LyricsCandidate, mode: LyricsTranslationMode) async -> [Int: String] {
        let rows = LyricsPreviewRow.make(candidate.lyrics).map { ChineseLyricTranslationPlan.Row(id: $0.id, text: $0.text) }
        let input = AutomaticLyricTranslationPipeline.Input(songID: candidate.songID, rows: rows,
                  namespace: candidate.id.cacheNamespace, mode: mode)
        let saved = await translationCache.entry(for: AutomaticLyricTranslationPipeline.cacheKey(input))
        let polished = mode == .immersive ? await polish.cached(candidate, rows: rows) : [:]
        guard let saved else { return polished }
        let base = await Task.detached(priority: .utility) {
            ChineseLyricTranslationPlan(rows: rows).renderedLines(translations: saved.fragments)
        }.value
        return base.merging(polished) { _, newer in newer }
    }

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
    func result(songID: String?, lines: [LyricsTranslationText]) -> AutomaticLyricsResult {
        guard let songID, let prepared = inputs[songID], prepared.lines == lines else {
            return .init(phase: playbackSessionFinished ? .paused : .idle, playbackSessionFinished: playbackSessionFinished)
        }
        let snapshot = pipeline.snapshot(for: prepared.input)
        let phase: AutomaticLyricsResult.Phase
        switch snapshot.phase {
        case .idle: phase = .idle
        case .preparing: phase = .preparing
        case .translating: phase = .translating
        case .ready: phase = .ready
        case .needsLanguage: phase = .needsLanguage
        case .unavailable: phase = .unavailable
        case .failed: phase = .failed
        case .paused: phase = .paused
        }
        let version = versionBySong[songID]
        var resultLines = snapshot.lines
        if mode == .immersive, polish.version == version?.id { resultLines.merge(polish.lines) { _, new in new } }
        if let version { resultLines.merge(versions.edits(for: version)) { _, new in new } }
        let label = strategyStatus(phase: phase, compatibility: snapshot.usedCompatibility)
        return AutomaticLyricsResult(phase: playbackSessionFinished && phase != .ready ? .paused : phase,
            lines: resultLines, completed: snapshot.completed, total: snapshot.total,
            playbackSessionFinished: playbackSessionFinished, strategyStatus: label)
    }

    private func strategyStatus(phase: AutomaticLyricsResult.Phase, compatibility: Bool) -> String? {
        if mode == .immersive {
            switch polish.status {
            case .checking: return String(localized: "Checking On-Device Model…")
            case .working: return String(localized: "Polishing Lyrics in Context…")
            case .complete: return String(localized: "Context Polish Complete")
            case .partial where phase == .ready: return String(localized: "Context Polish Partially Complete")
            case .unavailable, .language, .failed: return String(localized: "Context Polish Unavailable · Showing Base Translation")
            case .paused: return String(localized: "Context Polish Paused")
            default: break
            }
        }
        if compatibility { return String(localized: "Using Compatible Translation") }
        if phase == .translating {
            return mode == .quick ? String(localized: "Quick Translation…") : String(localized: "High Fidelity Requested…")
        }
        return nil
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
        guard !playbackSessionFinished, foreground, automaticEnabled, showsTranslation, let songID = currentSong?.id,
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
            pipeline.retry(songID: request.songID)
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
                        self.pipeline.retry(songID: request.songID)
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
        pipeline.retry(songID: songID)
    }

    private func refreshTranslationRequests() {
        let currentLookupKey = currentSong.flatMap { desiredLookups[$0.id] }
        let mayContinueCurrent = !playbackSessionFinished && !foreground && backgroundExecutionAllowed && !expirationSuspended
            && backgroundContinuationKey != nil && currentLookupKey == backgroundContinuationKey
        pipeline.setRequests(current: currentSong.flatMap { inputs[$0.id]?.input },
                             upcoming: (hasHeadroom && !buffered && !constrained ? upcomingSongs : []).compactMap { inputs[$0.id]?.input },
                             enabled: automaticEnabled && showsTranslation && !playbackSessionFinished && !queueEnded,
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
