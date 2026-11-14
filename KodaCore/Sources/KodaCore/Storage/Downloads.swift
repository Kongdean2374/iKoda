import Foundation
import Observation

/// Two active transfers, with retry delays outside the active slots. Metadata and bytes are
/// retained by AudioStore using the existing download format and resume from missing ranges.
@MainActor
@Observable
public final class Downloads {
    public enum State: Equatable, Sendable {
        case none, waiting
        case downloading(Double)
        case downloaded
        /// Automatic attempts stopped; the listener can explicitly retry or remove the song.
        case failed
    }

    public struct CollectionRequest: Hashable, Sendable {
        fileprivate let id: UUID
    }

    public private(set) var songs: [Song] = []
    public private(set) var bytes: Int64 = 0
    private var states: [String: State] = [:]

    /// Off, downloads wait for Wi-Fi. Existing sessions must also adopt this restriction.
    public var allowsCellular: Bool {
        didSet {
            guard allowsCellular != oldValue else { return }
            defaults.set(allowsCellular, forKey: Keys.cellular)
            replaceSession()
        }
    }

    @ObservationIgnored public let store: AudioStore
    @ObservationIgnored private let music: YouTubeMusic
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private var queue: [String] = []
    private struct Job: Sendable {
        let token: UUID
        let task: Task<Void, Never>
    }
    @ObservationIgnored private var running: [String: Job] = [:]
    @ObservationIgnored private var retrying: [String: Job] = [:]
    @ObservationIgnored private var failures: [String: Int] = [:]
    @ObservationIgnored private var refreshedURLs: Set<String> = []
    private struct CollectionWork: Sendable {
        let anchors: Set<String>
        var task: Task<Void, Never>?
    }
    @ObservationIgnored private var collections: [UUID: CollectionWork] = [:]
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var validationTask: Task<Void, Never>?
    @ObservationIgnored private var network = NetworkPath.shared.snapshot

    // Deterministic test seams. Production always uses the resolver, URLSession and clock.
    @ObservationIgnored var streamLoader: (@Sendable (String) async throws -> ResolvedStream)?
    @ObservationIgnored var fillLoader: (@Sendable (String, ResolvedStream, URLSession, AudioStore) async throws -> Void)?
    @ObservationIgnored var retrySleep: (@Sendable (Duration) async throws -> Void)?
    @ObservationIgnored var networkSnapshotOverride: NetworkSnapshot? { didSet { pump() } }

    private static let parallel = 2
    static let maximumAttempts = 6
    nonisolated private static let chunk: Int64 = 1 << 20
    private enum Keys { static let cellular = "koda.downloads.cellular" }
    private enum Outcome { case complete, cancelled, retry(Duration), failed, unavailable }

    public init(store: AudioStore, music: YouTubeMusic, defaults: UserDefaults = .standard) {
        self.store = store
        self.music = music
        self.defaults = defaults
        let cellular = defaults.object(forKey: Keys.cellular) as? Bool ?? true
        allowsCellular = cellular
        session = Self.makeSession(allowsCellular: cellular)
        for entry in store.downloads {
            guard let song = entry.song else { continue }
            songs.append(song)
            states[song.id] = entry.isComplete ? .downloaded : .waiting
            if !entry.isComplete { queue.append(song.id) }
        }
        bytes = store.downloadBytes
        networkTask = Task { [weak self] in
            for await snapshot in NetworkPath.shared.updates() {
                guard !Task.isCancelled else { return }
                self?.network = snapshot
                self?.pump()
            }
        }
        pump()
    }

    deinit {
        networkTask?.cancel()
        validationTask?.cancel()
        for job in running.values { job.task.cancel() }
        for job in retrying.values { job.task.cancel() }
        for work in collections.values { work.task?.cancel() }
        session.invalidateAndCancel()
    }

    public func state(of song: Song) -> State { states[song.id] ?? .none }

    /// Observe both the requested collection and transfer state so finishing/removing a
    /// download redraws the offline list, even though AudioStore itself is not observable.
    public var readyOfflineSongs: [Song] {
        let tracked = Set(songs.filter { states[$0.id] != nil }.map(\.id))
        let ready = store.readyOfflineSongs.filter { tracked.contains($0.id) }
        let readyIDs = Set(ready.map(\.id))
        if songs.contains(where: { states[$0.id] == .downloaded && !readyIDs.contains($0.id) }) {
            scheduleValidationRefresh()
        }
        return ready
    }

    /// Storage may have changed while the app was inactive. A validated missing or
    /// truncated download keeps its download intent, but must not stay marked Downloaded.
    /// Reuse the existing scheduler so offline and cellular restrictions still apply.
    public func refreshStoredDownloads() {
        for song in songs where states[song.id] == .downloaded {
            guard let entry = store.entry(song.id), entry.isDownload else {
                remove([song])
                continue
            }
            if !entry.isComplete { refreshInvalidatedDownload(song.id) }
        }
        bytes = store.downloadBytes
    }

    private func scheduleValidationRefresh() {
        guard validationTask == nil else { return }
        // readyOfflineSongs is commonly read by a SwiftUI body. Defer observable
        // mutations, and recheck current intent so a concurrent Remove cannot revive it.
        validationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            validationTask = nil
            refreshStoredDownloads()
        }
    }

    public func state(of songs: [Song]) -> State {
        guard !songs.isEmpty else { return .none }
        var here = 0.0
        var onTheWay = false
        var failed = false
        for song in songs {
            switch state(of: song) {
            case .none: break
            case .waiting: onTheWay = true
            case .downloading(let progress): onTheWay = true; here += progress
            case .downloaded: here += 1
            case .failed: failed = true
            }
        }
        if here >= Double(songs.count) { return .downloaded }
        if onTheWay { return .downloading(here / Double(songs.count)) }
        return failed ? .failed : .none
    }

    public func download(_ songs: [Song]) {
        var seen = Set<String>()
        let fresh = songs.filter { state(of: $0) == .none && seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        store.markDownloaded(fresh)
        for song in fresh { states[song.id] = .waiting }
        self.songs.insert(contentsOf: fresh, at: 0)
        queue += fresh.map(\.id)
        pump()
    }

    /// A delayed playlist result belongs to this explicit download intent. Removing any of
    /// its initial songs, or Remove All, invalidates it even if its old view ignores cancellation.
    public func beginCollection(_ songs: [Song]) -> CollectionRequest {
        let request = CollectionRequest(id: UUID())
        collections[request.id] = CollectionWork(anchors: Set(songs.map(\.id)))
        download(songs)
        return request
    }

    @discardableResult
    public func completeCollection(_ songs: [Song], request: CollectionRequest) -> Bool {
        guard collections.removeValue(forKey: request.id) != nil else { return false }
        download(songs)
        return true
    }

    /// Let Stop/Remove All cancel metadata work owned by another still-visible collection view.
    public func attachCollectionTask(_ task: Task<Void, Never>, request: CollectionRequest) {
        guard collections[request.id] != nil else { task.cancel(); return }
        collections[request.id]?.task = task
    }

    public func cancelCollection(_ request: CollectionRequest) {
        collections.removeValue(forKey: request.id)?.task?.cancel()
    }

    public func retry(_ songs: [Song]) {
        refreshStoredDownloads()
        for song in songs where states[song.id] == .failed {
            failures[song.id] = nil
            refreshedURLs.remove(song.id)
            states[song.id] = .waiting
            enqueue(song.id)
        }
        pump()
    }

    public func remove(_ songs: [Song]) { remove(songs, invalidatingCollections: true) }

    private func remove(_ songs: [Song], invalidatingCollections: Bool) {
        let ids = Set(songs.map(\.id))
        if invalidatingCollections {
            let cancelled = collections.filter { !$0.value.anchors.isDisjoint(with: ids) }.map(\.key)
            for id in cancelled { cancelCollection(CollectionRequest(id: id)) }
        }
        for id in ids {
            cancelJob(id)
            states[id] = nil
            failures[id] = nil
            refreshedURLs.remove(id)
        }
        queue.removeAll { ids.contains($0) }
        self.songs.removeAll { ids.contains($0.id) }
        store.removeDownloads(Array(ids))
        bytes = store.downloadBytes
        pump()
    }

    public func removeAll() {
        for work in collections.values { work.task?.cancel() }
        collections.removeAll()
        remove(songs)
    }

    /// Playback found invalid local audio. Keep the download intent and recover its missing
    /// bytes under the same network policy, rather than leaving a stale Downloaded indicator.
    public func refreshInvalidatedDownload(_ id: String) {
        guard states[id] != nil, store.entry(id)?.isComplete != true else { return }
        cancelJob(id)
        failures[id] = nil
        refreshedURLs.remove(id)
        states[id] = .waiting
        enqueue(id)
        bytes = store.downloadBytes
        pump()
    }

    private func cancelJob(_ id: String) {
        // Remove ownership first: late completion cannot clear a replacement job for this id.
        let active = running.removeValue(forKey: id)
        let waiting = retrying.removeValue(forKey: id)
        active?.task.cancel()
        waiting?.task.cancel()
    }

    private func replaceSession() {
        let previous = session
        session = Self.makeSession(allowsCellular: allowsCellular)
        let interrupted = songs.map(\.id).filter { running[$0] != nil }
        for id in interrupted {
            let job = running.removeValue(forKey: id)
            job?.task.cancel()
            if states[id] != nil { states[id] = .waiting; enqueue(id) }
        }
        // Session configuration is immutable. Even a task currently on Wi-Fi could otherwise
        // migrate to cellular under the old policy. Already written byte ranges are retained.
        previous.invalidateAndCancel()
        pump()
    }

    private var mayUseNetwork: Bool {
        let snapshot = networkSnapshotOverride ?? network
        guard snapshot.status != .offline else { return false }
        if allowsCellular { return true }
        return snapshot.status == .online && [.wifi, .wired, .other].contains(snapshot.interface)
    }

    private func enqueue(_ id: String) {
        guard states[id] != nil, running[id] == nil, retrying[id] == nil, !queue.contains(id) else { return }
        queue.append(id)
    }

    private func pump() {
        while running.count < Self.parallel {
            guard let index = queue.firstIndex(where: { mayUseNetwork || store.entry($0)?.isComplete == true }) else { return }
            let id = queue.remove(at: index)
            guard states[id] != nil, running[id] == nil, retrying[id] == nil,
                  let song = songs.first(where: { $0.id == id }) else { continue }
            let token = UUID()
            let activeSession = session
            let task = Task { [weak self] in
                guard let self else { return }
                let outcome = await fetch(song, token: token, session: activeSession)
                finish(song, token: token, outcome: outcome)
            }
            running[id] = Job(token: token, task: task)
        }
    }

    private func owns(_ id: String, token: UUID) -> Bool {
        !Task.isCancelled && running[id]?.token == token && states[id] != nil
    }

    /// One bounded attempt, never a sleep inside an active transfer slot.
    private func fetch(_ song: Song, token: UUID, session: URLSession) async -> Outcome {
        let id = song.id
        guard owns(id, token: token) else { return .cancelled }
        store.beginUse(id)
        defer { store.endUse(id) }
        if store.entry(id)?.isComplete == true { return .complete }
        do {
            let stream: ResolvedStream
            if let streamLoader { stream = try await streamLoader(id) }
            else { stream = try await music.stream(for: id) }
            guard owns(id, token: token) else { return .cancelled }
            guard stream.contentLength != nil else { throw MusicError.network }
            store.prepare(stream, song: song)
            states[id] = .downloading(progress(id))
            if let fillLoader { try await fillLoader(id, stream, session, store) }
            else {
                try await Self.fill(id, from: stream, session: session, store: store) { [weak self] in
                    guard let self, owns(id, token: token) else { return }
                    states[id] = .downloading(progress(id))
                }
            }
            guard owns(id, token: token) else { return .cancelled }
            guard store.entry(id)?.isComplete == true else { throw MusicError.network }
            return .complete
        } catch {
            guard owns(id, token: token) else { return .cancelled }
            if error is CancellationError { return .failed }
            if let musicError = error as? MusicError, case .unplayable = musicError { return .unavailable }
            failures[id, default: 0] += 1
            guard failures[id, default: 0] < Self.maximumAttempts else { return .failed }
            let refusedURL = (error as? URLError)?.code == .badServerResponse
                || (error as? MusicError) == .badResponse(401) || (error as? MusicError) == .badResponse(403)
                || (error as? AudioStreamResponseError) == .httpStatus(401)
                || (error as? AudioStreamResponseError) == .httpStatus(403)
            if refusedURL, refreshedURLs.insert(id).inserted {
                await music.streamFailed(id)
                guard owns(id, token: token) else { return .cancelled }
                return .retry(.zero)
            }
            guard PlaybackFailureReason.classify(error).isRetryable else { return .failed }
            return .retry(.seconds(min(300, 10 * (1 << (failures[id, default: 1] - 1)))))
        }
    }

    private func finish(_ song: Song, token: UUID, outcome: Outcome) {
        let id = song.id
        guard running[id]?.token == token else { return }
        running[id] = nil
        switch outcome {
        case .complete:
            states[id] = .downloaded
            failures[id] = nil
            refreshedURLs.remove(id)
            bytes = store.downloadBytes
        case .retry(let delay):
            states[id] = .waiting
            scheduleRetry(id, delay: delay)
        case .failed: states[id] = .failed
        case .unavailable: remove([song], invalidatingCollections: false)
        case .cancelled: break
        }
        pump()
    }

    private func scheduleRetry(_ id: String, delay: Duration) {
        if delay == .zero { enqueue(id); return }
        let token = UUID()
        let sleep = retrySleep
        let task = Task { [weak self] in
            do {
                if let sleep { try await sleep(delay) }
                else { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
            } catch { return }
            guard let self, retrying[id]?.token == token else { return }
            retrying[id] = nil
            enqueue(id)
            pump()
        }
        retrying[id] = Job(token: token, task: task)
    }

    private func progress(_ id: String) -> Double {
        guard let entry = store.entry(id), let length = entry.contentLength, length > 0 else { return 0 }
        return min(1, Double(entry.bytes) / Double(length))
    }

    nonisolated private static func fill(_ id: String, from stream: ResolvedStream, session: URLSession, store: AudioStore,
                                         progressed: @MainActor @Sendable () -> Void) async throws {
        while let gap = store.firstGap(id) {
            try Task.checkCancellation()
            let end = min(gap.upperBound, gap.lowerBound + chunk)
            var request = URLRequest(url: stream.url)
            request.setValue("bytes=\(gap.lowerBound)-\(end - 1)", forHTTPHeaderField: "Range")
            request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let length = stream.contentLength else { throw MusicError.network }
            let accepted = try CachingResponse.acceptedRange(response, requested: gap.lowerBound..<end, length: length)
            guard Int64(data.count) == accepted.upperBound - accepted.lowerBound else { throw MusicError.network }
            try store.write(data, at: accepted.lowerBound, for: id)
            await progressed()
        }
    }

    private static func makeSession(allowsCellular: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = allowsCellular
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }
}
