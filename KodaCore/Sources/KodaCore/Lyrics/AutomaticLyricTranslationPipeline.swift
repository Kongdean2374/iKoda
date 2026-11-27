import Foundation
import Observation

/// App-owned, bounded translation work. Presentation visibility never owns a session or
/// clears its results. The injected engine handles platform language models; this type
/// owns cache reuse, cancellation generations and current-song priority.
@MainActor
@Observable
public final class AutomaticLyricTranslationPipeline {
    nonisolated public struct Input: Equatable, Sendable {
        public let songID: String
        public let rows: [ChineseLyricTranslationPlan.Row]
        public let namespace: String?
        public let mode: LyricsTranslationMode
        public init(songID: String, rows: [ChineseLyricTranslationPlan.Row],
                    namespace: String? = nil, mode: LyricsTranslationMode = .quick) {
            self.songID = songID
            self.rows = rows
            self.namespace = namespace
            self.mode = mode
        }
    }

    nonisolated public enum Phase: Equatable, Sendable {
        case idle, preparing, translating, ready, needsLanguage, unavailable, failed, paused
    }

    nonisolated public struct LanguagePair: Equatable, Sendable {
        public let source: String
        public let target: String
        public init(source: String, target: String) { self.source = source; self.target = target }
    }

    nonisolated public struct Snapshot: Equatable, Sendable {
        public var phase: Phase
        public var lines: [Int: String]
        /// Progress counts source fragments, including repeated occurrences.
        public var completed: Int
        public var total: Int
        public var languagePair: LanguagePair?
        public var usedCompatibility = false
        public var sourceRows = 0
        public var completedRows = 0
        public var semanticRows: Set<Int> = []
        public var cacheUse: LyricCacheUse = .unchecked
        public var cacheSeconds: TimeInterval?
        public var planningSeconds: TimeInterval?
        public var translationSeconds: TimeInterval?
        public var apple = AppleLyricDiagnostics()
        public init(phase: Phase = .idle, lines: [Int: String] = [:], completed: Int = 0,
                    total: Int = 0, languagePair: LanguagePair? = nil) {
            self.phase = phase
            self.lines = lines
            self.completed = completed
            self.total = total
            self.languagePair = languagePair
        }
    }

    nonisolated public enum Outcome: Equatable, Sendable {
        case complete, compatible, needsLanguage(LanguagePair), unavailable
    }
    public typealias Publish = @Sendable ([String: String]) async -> Void
    public typealias ContextEngine = @Sendable (Input, [ChineseLyricTranslationPlan.Fragment], @escaping Publish) async throws -> Outcome
    public typealias Report = @Sendable (AppleLyricDiagnostics) async -> Void
    public typealias ObservedEngine = @Sendable (Input, [ChineseLyricTranslationPlan.Fragment], @escaping Publish, @escaping Report) async throws -> Outcome
    public typealias Engine = @Sendable ([ChineseLyricTranslationPlan.Fragment], @escaping Publish) async throws -> Outcome

    public private(set) var isWorking = false
    public private(set) var activeSongID: String?
    private var published: [AutomaticLyricTranslationCache.Key: Snapshot] = [:]

    private typealias Key = AutomaticLyricTranslationCache.Key
    private struct Record {
        var input: Input
        var plan: ChineseLyricTranslationPlan?
        var fragments: [String: String] = [:]
        var loadedCache = false
        var usedCompatibility = false
        var cacheUse: LyricCacheUse = .unchecked
        var cacheSeconds: TimeInterval?
        var planningSeconds: TimeInterval?
        var engineStarted: ContinuousClock.Instant?
        var translationSeconds: TimeInterval?
        var apple = AppleLyricDiagnostics()
        var lastUsed: UInt64
    }
    private struct Active {
        let key: Key
        let token: UUID
        var cancelled = false
    }

    @ObservationIgnored private let cache: AutomaticLyricTranslationCache
    @ObservationIgnored private let engine: ObservedEngine
    /// Internal asynchronous seam for persistence-order tests. Production always uses
    /// the serialized cache actor; the writer never blocks an executor with a semaphore.
    @ObservationIgnored var checkpointWriter: @Sendable (AutomaticLyricTranslationCache.Key, AutomaticLyricTranslationCache.Entry) async -> Void
    @ObservationIgnored private let detectLanguage: @Sendable (String) -> String?
    @ObservationIgnored private let maximumUpcoming: Int
    @ObservationIgnored private let maximumSnapshots: Int
    @ObservationIgnored private var records: [Key: Record] = [:]
    @ObservationIgnored private var memo: [String: (input: Input, key: Key)] = [:]
    @ObservationIgnored private var currentKey: Key?
    @ObservationIgnored private var upcomingKeys: [Key] = []
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var foreground = true
    /// An explicit platform execution allowance, bound to this exact source content.
    /// It never authorizes speculative work or follows a later song automatically.
    @ObservationIgnored private var backgroundCurrentKey: Key?
    @ObservationIgnored private var suspended = false
    /// A deliberate end of listening is stronger than background suspension. Scene
    /// changes and language-download replies cannot reopen this execution gate.
    @ObservationIgnored private var playbackSessionFinished = false
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var active: Active?
    @ObservationIgnored private var retryAfterFinish: Key?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var refreshing: [Key: UUID] = [:]
    @ObservationIgnored private var dirty: Set<Key> = []
    @ObservationIgnored private var checkpointDelay: Task<Void, Never>?
    @ObservationIgnored private var persistence: Task<Void, Never>?

    public convenience init(cache: AutomaticLyricTranslationCache, maximumUpcoming: Int = 5,
                maximumSnapshots: Int = 200,
                detectLanguage: @escaping @Sendable (String) -> String? = { LyricsRomanizer.language(of: [$0]) },
                engine: @escaping Engine) {
        self.init(cache: cache, maximumUpcoming: maximumUpcoming, maximumSnapshots: maximumSnapshots,
                  detectLanguage: detectLanguage, contextualEngine: { _, fragments, publish in
            try await engine(fragments, publish)
        })
    }

    public convenience init(cache: AutomaticLyricTranslationCache, maximumUpcoming: Int = 5,
                maximumSnapshots: Int = 200,
                detectLanguage: @escaping @Sendable (String) -> String? = { LyricsRomanizer.language(of: [$0]) },
                contextualEngine: @escaping ContextEngine) {
        self.init(cache: cache, maximumUpcoming: maximumUpcoming, maximumSnapshots: maximumSnapshots,
                  detectLanguage: detectLanguage, observedEngine: { input, fragments, publish, _ in
            try await contextualEngine(input, fragments, publish)
        })
    }

    public init(cache: AutomaticLyricTranslationCache, maximumUpcoming: Int = 5,
                maximumSnapshots: Int = 200,
                detectLanguage: @escaping @Sendable (String) -> String? = { LyricsRomanizer.language(of: [$0]) },
                observedEngine: @escaping ObservedEngine) {
        self.cache = cache
        self.maximumUpcoming = min(20, max(0, maximumUpcoming))
        self.maximumSnapshots = max(21, maximumSnapshots)
        self.detectLanguage = detectLanguage
        self.engine = observedEngine
        checkpointWriter = { key, entry in await cache.store(entry, for: key) }
    }

    /// Turning display off stops speculative starts, but a running current-song job may
    /// finish. Returning to this content reuses its memory/disk result without invalidation.
    public func setRequests(current: Input?, upcoming: [Input], enabled: Bool, isForeground: Bool,
                            allowsBackgroundCurrent: Bool = false) {
        self.enabled = enabled
        foreground = isForeground
        if isForeground && !playbackSessionFinished { suspended = false }
        currentKey = current.map(ensureRecord)
        backgroundCurrentKey = allowsBackgroundCurrent ? currentKey : nil
        var seen = Set<Key>()
        if let currentKey { seen.insert(currentKey) }
        upcomingKeys = upcoming.prefix(maximumUpcoming).compactMap { input in
            let key = ensureRecord(input)
            return seen.insert(key).inserted ? key : nil
        }
        if let active {
            if currentKey == nil || (active.key != currentKey &&
                (!enabled || !isForeground || !upcomingKeys.contains(active.key) || currentNeedsWork)) {
                cancelActive()
            }
        }
        trimMemory()
        schedule()
    }

    /// O(1) after comparing the already registered rows; no hashing or planning on every
    /// lyric animation frame. Unknown/mismatched content never sees a previous provider's text.
    public func snapshot(for input: Input) -> Snapshot {
        guard let remembered = memo[input.songID], remembered.input == input else { return Snapshot() }
        return published[remembered.key] ?? Snapshot()
    }

    public func retry(songID: String?) {
        guard !playbackSessionFinished else { return }
        guard let songID, let key = memo[songID]?.key else { return }
        if key == active?.key {
            // A model-download reply can arrive while this terminal result is still
            // checkpointing. Queue its retry instead of losing that foreground action.
            if let phase = published[key]?.phase,
               phase == .needsLanguage || phase == .unavailable || phase == .failed {
                retryAfterFinish = key
            }
            return
        }
        if var snapshot = published[key], snapshot.phase != .ready {
            snapshot.phase = .paused
            snapshot.languagePair = nil
            published[key] = snapshot
        }
        if foreground { suspended = false }
        if key == currentKey, let active, active.key != key { cancelActive() }
        schedule()
    }

    /// A background-time expiration cancels work without deleting partial translations.
    /// Foreground setRequests resumes only missing fragments after the old engine exits.
    public func suspend() {
        suspended = true
        backgroundCurrentKey = nil
        cancelActive()
        checkpointNow()
    }

    public func setPlaybackSessionFinished(_ finished: Bool) {
        guard playbackSessionFinished != finished else { return }
        playbackSessionFinished = finished
        if finished { suspend() }
        // Resumption waits for the owner to provide the current song and scene state.
        // It must not briefly restart a previously selected song here.
    }

    /// Wait for all currently pending writes. New progress arriving while this waits is
    /// included in another pass, so callers can checkpoint before a background deadline.
    public func flush() async {
        repeat {
            checkpointNow()
            let waiting = persistence
            await waiting?.value
        } while !dirty.isEmpty
    }

    private var currentNeedsWork: Bool {
        guard let currentKey else { return false }
        return needsWork(currentKey)
    }

    private func needsWork(_ key: Key) -> Bool {
        guard refreshing[key] == nil else { return false }
        return switch published[key]?.phase ?? .idle {
        case .idle, .paused: true
        case .preparing, .translating: active?.key != key
        case .ready, .needsLanguage, .unavailable, .failed: false
        }
    }

    public nonisolated static func cacheKey(_ input: Input) -> AutomaticLyricTranslationCache.Key {
        let namespace = input.namespace.map { $0 + "|" + input.mode.rawValue + "|apple-translation-v2" }
        return .init(songID: input.songID, rows: input.rows, namespace: namespace)
    }

    public func regenerate(_ input: Input, discardDisk: Bool) async {
        let key = Self.cacheKey(input)
        let token = UUID()
        refreshing[key] = token
        defer {
            if refreshing[key] == token {
                refreshing[key] = nil
                schedule()
            }
        }
        if active?.key == key { cancelActive(); await task?.value }
        await flush()
        guard refreshing[key] == token, currentKey == key, !playbackSessionFinished else { return }
        if discardDisk { await cache.discard(key) }
        guard refreshing[key] == token, currentKey == key, !playbackSessionFinished, var record = records[key] else { return }
        record.fragments = [:]
        record.loadedCache = true
        record.apple = .init()
        record.usedCompatibility = false
        record.cacheUse = .miss
        record.cacheSeconds = nil
        record.translationSeconds = nil
        records[key] = record
        if var snapshot = published[key] {
            snapshot.phase = .paused
            snapshot.languagePair = nil
            if discardDisk { snapshot.lines = [:]; snapshot.completed = 0 }
            snapshot.usedCompatibility = false
            snapshot.apple = .init()
            snapshot.cacheUse = .miss
            snapshot.cacheSeconds = nil
            snapshot.translationSeconds = nil
            snapshot.completedRows = 0
            published[key] = snapshot
        }
    }

    private func ensureRecord(_ input: Input) -> Key {
        let key: Key
        if let remembered = memo[input.songID], remembered.input == input {
            key = remembered.key
        } else {
            key = Self.cacheKey(input)
            memo[input.songID] = (input, key)
        }
        sequence &+= 1
        if records[key] == nil { records[key] = Record(input: input, lastUsed: sequence) }
        else { records[key]?.lastUsed = sequence }
        return key
    }

    private func schedule() {
        // Active work remains the sole engine until cancellation has actually completed.
        guard active == nil, enabled, !suspended, !playbackSessionFinished, let currentKey else { return }
        let next: Key?
        if foreground {
            next = needsWork(currentKey) ? currentKey : upcomingKeys.first(where: needsWork)
        } else {
            guard backgroundCurrentKey == currentKey, needsWork(currentKey) else { return }
            next = currentKey
        }
        guard let next, records[next] != nil else { return }
        let token = UUID()
        active = Active(key: next, token: token)
        activeSongID = records[next]?.input.songID
        isWorking = true
        var value = published[next] ?? Snapshot()
        value.phase = .preparing
        value.languagePair = nil
        published[next] = value
        task = Task { [weak self] in
            guard let self else { return }
            await run(key: next, token: token)
            await finish(key: next, token: token)
        }
    }

    private func run(key: Key, token: UUID) async {
        guard var record = records[key] else { return }
        if record.plan == nil {
            let planningStarted = ContinuousClock.now
            let rows = record.input.rows
            let detector = detectLanguage
            let plan = await Task.detached(priority: .utility) {
                ChineseLyricTranslationPlan(rows: rows, detectLanguage: detector)
            }.value
            guard accepts(key: key, token: token) else { return }
            record.plan = plan
            record.planningSeconds = planningStarted.duration(to: .now).lyricSeconds
            records[key] = record
        }
        guard let plan = record.plan else { return }
        let allowed = Set(plan.fragments.map(\.id))
        if !record.loadedCache {
            let cacheStarted = ContinuousClock.now
            let saved = await cache.entry(for: key)
            guard accepts(key: key, token: token) else { return }
            record.fragments = saved?.fragments.filter { allowed.contains($0.key) && Self.hasText($0.value) } ?? [:]
            record.loadedCache = true
            record.usedCompatibility = saved?.usedCompatibility ?? false
            if let report = saved?.appleDiagnostics { record.apple = report }
            else { record.apple.usedCompatibility = saved?.usedCompatibility }
            record.cacheUse = saved.map { $0.isComplete ? ($0.appleDiagnostics == nil ? .legacy : .hit) : .partial } ?? .miss
            record.cacheSeconds = cacheStarted.duration(to: .now).lyricSeconds
            records[key] = record
        }
        let missing = plan.fragments.filter { record.fragments[$0.id] == nil }
        publishSnapshot(key: key, phase: missing.isEmpty ? (plan.hasUnrecognizedText ? .unavailable : .ready) : .translating)
        guard !missing.isEmpty else {
            dirty.insert(key)
            return
        }
        records[key]?.engineStarted = .now
        do {
            let outcome = try await engine(record.input, missing, { [weak self] fragments in
                await self?.receive(fragments, key: key, token: token)
            }, { [weak self] report in
                await self?.receiveDiagnostics(report, key: key, token: token)
            })
            guard accepts(key: key, token: token) else { return }
            stopEngineClock(key)
            switch outcome {
            case .complete, .compatible:
                records[key]?.usedCompatibility = (records[key]?.apple.usedCompatibility ?? false) || outcome == .compatible
                let complete = records[key]?.fragments.count == plan.fragments.count
                publishSnapshot(key: key, phase: complete && !plan.hasUnrecognizedText ? .ready : .unavailable)
            case .needsLanguage(let pair):
                publishSnapshot(key: key, phase: .needsLanguage, pair: pair)
            case .unavailable:
                publishSnapshot(key: key, phase: .unavailable)
            }
        } catch {
            guard accepts(key: key, token: token) else { return }
            stopEngineClock(key)
            if records[key]?.apple.lastError == nil { records[key]?.apple.lastError = .translation }
            publishSnapshot(key: key, phase: .failed)
        }
        dirty.insert(key)
    }

    private func stopEngineClock(_ key: Key) {
        guard let started = records[key]?.engineStarted else { return }
        let duration = started.duration(to: .now).lyricSeconds
        records[key]?.translationSeconds = (records[key]?.translationSeconds ?? 0) + duration
        records[key]?.engineStarted = nil
    }

    private func receiveDiagnostics(_ report: AppleLyricDiagnostics, key: Key, token: UUID) {
        guard accepts(key: key, token: token), var record = records[key] else { return }
        var merged = report
        merged.strategies.formUnion(record.apple.strategies)
        let names = Set(report.languages.map(\.source))
        merged.languages += record.apple.languages.filter { !names.contains($0.source) }
        if record.apple.usedCompatibility == true { merged.usedCompatibility = true }
        if merged.lastError == nil { merged.lastError = record.apple.lastError }
        record.apple = merged
        if let used = merged.usedCompatibility { record.usedCompatibility = used }
        records[key] = record
        publishSnapshot(key: key, phase: .translating)
    }

    private func receive(_ fragments: [String: String], key: Key, token: UUID) {
        guard accepts(key: key, token: token), var record = records[key], let plan = record.plan else { return }
        let allowed = Set(plan.fragments.map(\.id))
        for (id, text) in fragments where allowed.contains(id) && Self.hasText(text) { record.fragments[id] = text }
        records[key] = record
        publishSnapshot(key: key, phase: .translating)
        dirty.insert(key)
        if checkpointDelay == nil {
            checkpointDelay = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                self?.checkpointNow()
            }
        }
    }

    private func publishSnapshot(key: Key, phase: Phase, pair: LanguagePair? = nil) {
        guard let record = records[key], let plan = record.plan else { return }
        let rendered = plan.renderedLines(translations: record.fragments)
        let lines = phase == .ready ? rendered : (published[key]?.lines ?? [:]).merging(rendered) { _, new in new }
        var next = Snapshot(phase: phase, lines: lines,
                            completed: record.fragments.count, total: plan.fragments.count, languagePair: pair)
        next.usedCompatibility = record.usedCompatibility
        let rows = plan.rowProgress(translations: record.fragments)
        next.sourceRows = rows.total
        next.completedRows = rows.completed
        next.semanticRows = plan.semanticRows
        next.cacheUse = record.cacheUse
        next.cacheSeconds = record.cacheSeconds
        next.planningSeconds = record.planningSeconds
        next.translationSeconds = record.engineStarted.map { $0.duration(to: .now).lyricSeconds + (record.translationSeconds ?? 0) } ?? record.translationSeconds
        next.apple = record.apple
        if published[key] != next { published[key] = next }
    }

    private func accepts(key: Key, token: UUID) -> Bool {
        !Task.isCancelled && active?.key == key && active?.token == token && active?.cancelled == false
    }

    private func cancelActive() {
        guard let running = active, !running.cancelled else { return }
        active?.cancelled = true
        stopEngineClock(running.key)
        task?.cancel()
        if var snapshot = published[running.key] {
            snapshot.phase = .paused
            snapshot.languagePair = nil
            snapshot.translationSeconds = records[running.key]?.translationSeconds
            published[running.key] = snapshot
        }
        checkpointNow()
    }

    private func finish(key: Key, token: UUID) async {
        guard active?.token == token else { return }
        // Keep the current work/budget alive until its final checkpoint is durable.
        // Ready text can appear immediately; only execution ownership waits for disk.
        await flush()
        guard active?.token == token else { return }
        active = nil
        task = nil
        isWorking = false
        activeSongID = nil
        if retryAfterFinish == key {
            retryAfterFinish = nil
            if var snapshot = published[key], snapshot.phase != .ready {
                snapshot.phase = .paused
                snapshot.languagePair = nil
                published[key] = snapshot
            }
        }
        schedule()
    }

    private func checkpointNow() {
        checkpointDelay?.cancel()
        checkpointDelay = nil
        guard !dirty.isEmpty else { return }
        let entries = dirty.compactMap { key -> (Key, AutomaticLyricTranslationCache.Entry)? in
            guard let record = records[key], let plan = record.plan else { return nil }
            return (key, .init(fragments: record.fragments,
                              isComplete: record.fragments.count == plan.fragments.count && !plan.hasUnrecognizedText,
                              usedCompatibility: record.apple.usedCompatibility ?? (record.usedCompatibility ? true : nil),
                              appleDiagnostics: record.apple == .init() ? nil : record.apple))
        }
        dirty.removeAll()
        let previous = persistence
        let writer = checkpointWriter
        persistence = Task {
            await previous?.value
            for (key, entry) in entries { await writer(key, entry) }
        }
    }

    private func trimMemory() {
        guard records.count > maximumSnapshots else { return }
        let protected = Set(upcomingKeys + [currentKey, active?.key].compactMap { $0 })
        let candidates = records.filter { !protected.contains($0.key) }.sorted { $0.value.lastUsed < $1.value.lastUsed }
        checkpointNow()
        for (key, record) in candidates.prefix(records.count - maximumSnapshots) {
            records.removeValue(forKey: key)
            published.removeValue(forKey: key)
            if memo[record.input.songID]?.key == key { memo.removeValue(forKey: record.input.songID) }
        }
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
