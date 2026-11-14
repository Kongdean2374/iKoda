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
    private struct LookupWork {
        let token: UUID
        let task: Task<Lyrics?, Never>
    }
    private struct PreparedInput {
        let lines: [LyricsTranslationText]
        let input: AutomaticLyricTranslationPipeline.Input
    }

    @ObservationIgnored private let client: LyricsClient
    private let pipeline: AutomaticLyricTranslationPipeline
    private var inputs: [String: PreparedInput] = [:]
    private var currentSong: Song?
    private var upcomingSongs: [Song] = []
    private var automaticEnabled = true
    private var showsTranslation = false
    private var foreground = true
    private var expirationSuspended = false
    private var currentLookupActive = false
    private(set) var lyricsRevision = 0
    private var downloadAttempt: UInt64 = 0
    private var downloadPolicy = AutomaticLyricDownloadPolicy()
    @ObservationIgnored private var languageCheckTask: Task<Void, Never>?
    @ObservationIgnored private var sources: [LyricsSource] = []
    @ObservationIgnored private var customSources: [CustomLyricsSource] = []
    @ObservationIgnored private var desiredLookups: [String: LookupKey] = [:]
    @ObservationIgnored private var lookupTasks: [LookupKey: LookupWork] = [:]
    @ObservationIgnored private var lookupVersions: [LookupKey: UUID] = [:]
    @ObservationIgnored private var lookupCache: [LookupKey: Lyrics] = [:]
    @ObservationIgnored private var lookupSizes: [LookupKey: Int] = [:]
    @ObservationIgnored private var lookupBytes = 0
    @ObservationIgnored private var lookupOrder: [LookupKey] = []
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var prefetchGeneration = UUID()
    @ObservationIgnored private var prefetchRemaining: [LookupKey] = []
    @ObservationIgnored private var lookupContext: [LookupKey] = []
    @ObservationIgnored private var backgroundExecutionAllowed = false
    @ObservationIgnored private var backgroundContinuationKey: LookupKey?
    @ObservationIgnored private var currentRetryKey: LookupKey?
    private static let maximumCachedSongs = 200
    private static let maximumOriginalLyricsBytes = 20_000_000
    private static let upcomingCount = 5

    init(client: LyricsClient, directory: URL) {
        self.client = client
        pipeline = AutomaticLyricTranslationPipeline(cache: AutomaticLyricTranslationCache(directory: directory),
                                                     maximumUpcoming: Self.upcomingCount,
                                                     engine: NativeLyricsTranslationEngine.translate)
    }

    var hasActiveWork: Bool { pipeline.isWorking || currentLookupActive }
    var hasCurrentWork: Bool {
        !expirationSuspended && (currentLookupActive || (pipeline.isWorking && pipeline.activeSongID == currentSong?.id))
    }

    /// Called by app-lifetime observation, never by a disposable lyrics view task.
    func update(current: Song?, upcoming: [Song], sources: [LyricsSource], customSources: [CustomLyricsSource],
                automaticEnabled: Bool, showsTranslation: Bool, isForeground: Bool) {
        let becameActive = !foreground && isForeground
        let leavingForeground = foreground && !isForeground
        let changedSong = currentSong?.id != current?.id
        let priorCurrentLookupKey = currentSong.flatMap { desiredLookups[$0.id] }
        let wasPreparing = self.automaticEnabled && self.showsTranslation
        if leavingForeground {
            backgroundContinuationKey = hasCurrentWork && wasPreparing
                ? currentSong.flatMap { desiredLookups[$0.id] } : nil
        }
        if becameActive { expirationSuspended = false }
        currentSong = current
        var seen = Set<String>()
        if let current { seen.insert(current.id) }
        upcomingSongs = Array(upcoming.filter { seen.insert($0.id).inserted }.prefix(Self.upcomingCount))
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
            for (id, old) in oldDesired where desiredLookups[id] != old { inputs.removeValue(forKey: id) }
            lookupContext = context
        }
        let prepares = automaticEnabled && showsTranslation
        let currentLookupKey = current.flatMap { desiredLookups[$0.id] }
        if isForeground || !prepares || expirationSuspended || currentLookupKey != backgroundContinuationKey {
            backgroundContinuationKey = nil
        }
        if becameActive || changedSong || currentLookupKey != priorCurrentLookupKey || (!wasPreparing && prepares) {
            currentRetryKey = currentLookupKey
        }
        if !isForeground || !prepares || expirationSuspended {
            cancelPrefetch(keepingCurrent: true)
        } else if changed || becameActive || !wasPreparing {
            // A prefetched B lookup is already useful when A advances to B: keep
            // the work matching the new current key, not the old current ID.
            cancelPrefetch(keepingCurrent: true)
            startPrefetch(context)
        }
        if !automaticEnabled { pipeline.suspend() }
        refreshTranslationRequests()
        retryPreparedCurrentIfNeeded()
        trimMemoryInputs()
    }

    /// A panel and prefetch request for the same metadata share a single lookup. Refresh
    /// cancels that generation and bypasses both this cache and LyricsClient's positive cache.
    func lyrics(for song: Song, sources: [LyricsSource], customSources: [CustomLyricsSource], refresh: Bool = false) async -> Lyrics? {
        let key = LookupKey(song: song, sources: sources, customSources: customSources)
        if !refresh, let cached = lookupCache[key] {
            touchLookup(key)
            registerIfDesired(cached, for: key)
            return cached
        }
        if refresh {
            cancelPrefetch(keepingCurrent: false)
            lookupTasks.removeValue(forKey: key)?.task.cancel()
            lookupCache.removeValue(forKey: key)
            lookupBytes -= lookupSizes.removeValue(forKey: key) ?? 0
        }
        let work: LookupWork
        if let existing = lookupTasks[key] {
            work = existing
        } else {
            let token = UUID()
            let client = client
            let task = Task { await client.lyrics(for: song, sources: sources, customSources: customSources, refresh: refresh) }
            work = LookupWork(token: token, task: task)
            lookupTasks[key] = work
            lookupVersions[key] = token
            updateLookupActivity()
        }
        let value = await work.task.value
        guard lookupVersions[key] == work.token else { return nil }
        // Another waiter may have consumed this same successful single-flight job.
        guard lookupTasks[key]?.token == work.token else { return value }
        lookupTasks.removeValue(forKey: key)
        updateLookupActivity()
        if let value {
            lookupBytes -= lookupSizes[key] ?? 0
            lookupCache[key] = value
            let size = Self.estimatedSize(value)
            lookupSizes[key] = size
            lookupBytes += size
            registerIfDesired(value, for: key)
        }
        touchLookup(key)
        trimLookups()
        if refresh, foreground, automaticEnabled, showsTranslation, !expirationSuspended { startPrefetch(lookupContext) }
        return value
    }

    /// Exact source rows gate reuse, including when a retry finds a different provider.
    func register(songID: String?, lines: [LyricsTranslationText]) {
        guard let songID else { return }
        if inputs[songID]?.lines == lines {
            retryPreparedCurrentIfNeeded()
            return
        }
        inputs[songID] = PreparedInput(lines: lines, input: .init(songID: songID,
            rows: lines.map { .init(id: $0.id, text: $0.text) }))
        refreshTranslationRequests()
        retryPreparedCurrentIfNeeded()
        trimMemoryInputs()
    }

    /// This only reads already registered rows/snapshots; no disk access, network, language
    /// detection or fingerprint hashing occurs in the frame-by-frame lyrics presentation.
    func result(songID: String?, lines: [LyricsTranslationText]) -> AutomaticLyricsResult {
        guard let songID, let prepared = inputs[songID], prepared.lines == lines else { return .init() }
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
        return AutomaticLyricsResult(phase: phase, lines: snapshot.lines, completed: snapshot.completed, total: snapshot.total)
    }

    func retry(songID: String?) {
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
        pipeline.suspend()
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
        lookupCache.removeAll()
        lookupSizes.removeAll()
        lookupBytes = 0
        lookupOrder.removeAll()
        lookupVersions.removeAll()
        let generation = prefetchGeneration
        await client.clearCache()
        lyricsRevision &+= 1
        guard prefetchGeneration == generation, foreground, automaticEnabled, showsTranslation,
              !expirationSuspended else { return }
        startPrefetch(lookupContext)
    }

    var downloadRequest: DownloadRequest? {
        guard foreground, automaticEnabled, showsTranslation, let songID = currentSong?.id,
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
        guard !Task.isCancelled else { cancelLanguageDownload(request); return }
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
                    guard let self, !Task.isCancelled, self.foreground, self.automaticEnabled,
                          self.showsTranslation, self.downloadAttempt == attempt else { return }
                    let ready = await NativeLyricsTranslationEngine.isInstalled(source: request.source, target: request.target)
                    guard !Task.isCancelled, self.foreground, self.downloadAttempt == attempt else { return }
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
        guard let songID = currentSong?.id, let prepared = inputs[songID],
              let needed = pipeline.snapshot(for: prepared.input).languagePair,
              needed.source == pair.source, needed.target == pair.target else { return }
        pipeline.retry(songID: songID)
    }

    private func refreshTranslationRequests() {
        let currentLookupKey = currentSong.flatMap { desiredLookups[$0.id] }
        let mayContinueCurrent = !foreground && backgroundExecutionAllowed && !expirationSuspended
            && backgroundContinuationKey != nil && currentLookupKey == backgroundContinuationKey
        pipeline.setRequests(current: currentSong.flatMap { inputs[$0.id]?.input },
                             upcoming: upcomingSongs.compactMap { inputs[$0.id]?.input },
                             enabled: automaticEnabled && showsTranslation, isForeground: foreground && !expirationSuspended,
                             allowsBackgroundCurrent: mayContinueCurrent)
    }

    /// A failed prefetched record may only become known after its cached lyrics arrive.
    /// Consume one retry per current-song admission, not on every observable update.
    private func retryPreparedCurrentIfNeeded() {
        guard let key = currentRetryKey, currentSong?.id == key.song.id,
              desiredLookups[key.song.id] == key, let prepared = inputs[key.song.id] else { return }
        currentRetryKey = nil
        switch pipeline.snapshot(for: prepared.input).phase {
        case .failed, .paused, .needsLanguage: pipeline.retry(songID: prepared.input.songID)
        default: break
        }
    }

    private func registerIfDesired(_ lyrics: Lyrics, for key: LookupKey) {
        guard desiredLookups[key.song.id] == key else { return }
        let lines: [LyricsTranslationText]
        switch lyrics {
        case .synced(let rows): lines = rows.map { .init(id: $0.id, text: $0.text) }
        case .plain(let text):
            lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n").enumerated().map { .init(id: $0.offset, text: $0.element) }
        }
        register(songID: key.song.id, lines: lines)
    }

    private func startPrefetch(_ context: [LookupKey]) {
        guard foreground, automaticEnabled, showsTranslation, !expirationSuspended,
              let first = context.first else { return }
        let generation = UUID()
        prefetchGeneration = generation
        let sources = sources, custom = customSources
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.lyrics(for: first.song, sources: sources, customSources: custom)
            guard !Task.isCancelled, self.prefetchGeneration == generation, self.foreground else { return }
            // At most two future-song lookups run together. Every provider has its own
            // deadline; only the current song and five future songs are ever prepared.
            self.prefetchRemaining = Array(context.dropFirst())
            // Two structured workers claim the next item on this actor before awaiting
            // its shared lookup. This avoids capturing an inout TaskGroup in a nested
            // actor-isolated closure, while keeping dynamic distribution and the limit.
            async let firstWorker: Void = self.prefetchWorker(generation: generation, sources: sources, customSources: custom)
            async let secondWorker: Void = self.prefetchWorker(generation: generation, sources: sources, customSources: custom)
            _ = await (firstWorker, secondWorker)
        }
    }

    private func prefetchWorker(generation: UUID, sources: [LyricsSource], customSources: [CustomLyricsSource]) async {
        while !Task.isCancelled, prefetchGeneration == generation, foreground,
              automaticEnabled, showsTranslation, !expirationSuspended, !prefetchRemaining.isEmpty {
            let next = prefetchRemaining.removeFirst()
            _ = await lyrics(for: next.song, sources: sources, customSources: customSources)
        }
    }

    private func cancelPrefetch(keepingCurrent: Bool) {
        prefetchGeneration = UUID()
        prefetchRemaining.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        let currentKey = currentSong.flatMap { desiredLookups[$0.id] }
        for (key, work) in Array(lookupTasks) where !keepingCurrent || key != currentKey {
            work.task.cancel()
            lookupTasks.removeValue(forKey: key)
            lookupVersions.removeValue(forKey: key)
        }
        updateLookupActivity()
    }

    private func updateLookupActivity() {
        currentLookupActive = currentSong.flatMap { desiredLookups[$0.id] }.map { lookupTasks[$0] != nil } ?? false
    }

    private func touchLookup(_ key: LookupKey) {
        lookupOrder.removeAll { $0 == key }
        lookupOrder.append(key)
    }
    private func trimLookups() {
        while !lookupOrder.isEmpty && (lookupOrder.count > Self.maximumCachedSongs || lookupBytes > Self.maximumOriginalLyricsBytes) {
            let old = lookupOrder.removeFirst()
            lookupCache.removeValue(forKey: old)
            lookupBytes -= lookupSizes.removeValue(forKey: old) ?? 0
            if lookupTasks[old] == nil { lookupVersions.removeValue(forKey: old) }
        }
    }
    private static func estimatedSize(_ lyrics: Lyrics) -> Int {
        switch lyrics {
        case .plain(let text): text.utf8.count + 128
        case .synced(let rows):
            rows.reduce(0) { total, row in
                total + row.text.utf8.count + 160
                    + row.words.reduce(0) { $0 + $1.text.utf8.count + 80 }
                    + row.background.reduce(0) { $0 + $1.text.utf8.count + 80 }
            }
        }
    }
    private func trimMemoryInputs() {
        guard inputs.count > Self.maximumCachedSongs else { return }
        let protected = Set([currentSong?.id].compactMap { $0 } + upcomingSongs.map(\.id))
        for id in inputs.keys.sorted() where !protected.contains(id) {
            inputs.removeValue(forKey: id)
            if inputs.count <= Self.maximumCachedSongs { break }
        }
    }
}
