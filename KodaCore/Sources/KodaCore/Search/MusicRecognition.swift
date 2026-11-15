import Foundation
import Observation

/// Only catalog metadata is retained. Microphone samples never enter this model.
public struct RecognizedMusic: Hashable, Sendable {
    public var title: String
    public var artist: String
    public var artworkURL: URL?
    public var duration: TimeInterval?

    public init(title: String, artist: String, artworkURL: URL? = nil, duration: TimeInterval? = nil) {
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
    }

    public var searchQuery: String {
        [title, artist].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
    }
}

public enum MusicRecognitionFailure: Error, Equatable, Sendable {
    case unavailable, permissionDenied, audioBusy, interrupted, noMatch, searchFailed, cancelled
}

/// A system permission alert can briefly make the scene inactive. Wait for the
/// foreground instead of treating that alert as dismissal; real backgrounding and
/// cancellation wake every waiter without allowing microphone acquisition.
@MainActor
public final class MusicRecognitionActivityGate {
    public enum State: Equatable, Sendable { case active, inactive, background }
    public private(set) var state: State = .active
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    public init() {}

    public func update(_ state: State) {
        self.state = state
        switch state {
        case .active: resolve(true)
        case .background: resolve(false)
        case .inactive: break
        }
    }

    public func cancelWaiters() { resolve(false) }

    public func waitUntilActive() async -> Bool {
        guard !Task.isCancelled else { return false }
        switch state {
        case .active: return true
        case .background: return false
        case .inactive: break
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                waiters[id] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume(returning: false) }
        }
    }

    private func resolve(_ active: Bool) {
        let pending = Array(waiters.values)
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: active) }
    }
}

public struct MusicCatcherPlaybackLease: Sendable {
    public let profileID: UUID
    public let occurrenceID: UUID?
    public let intentRevision: UInt64
    public let wasPlaying: Bool
    public init(profileID: UUID, occurrenceID: UUID?, intentRevision: UInt64, wasPlaying: Bool) {
        self.profileID = profileID; self.occurrenceID = occurrenceID
        self.intentRevision = intentRevision; self.wasPlaying = wasPlaying
    }
    public func canRestore(profileID: UUID, occurrenceID: UUID?, intentRevision: UInt64,
                           sceneIsActive: Bool, sessionFinished: Bool, otherAudioOwner: Bool) -> Bool {
        wasPlaying && self.occurrenceID != nil && self.profileID == profileID
            && self.occurrenceID == occurrenceID && self.intentRevision == intentRevision
            && sceneIsActive && !sessionFinished && !otherAudioOwner
    }
}

/// The app supplies Apple's microphone recognizer; tests supply a controllable provider.
/// A permission callback may finish after cancel(), so the flow validates its generation
/// before allowing the provider to acquire audio or begin recording.
@MainActor
public protocol MusicRecognitionProviding: AnyObject {
    var isAvailable: Bool { get }
    func requestPermission() async -> Bool
    func recognize() async throws -> RecognizedMusic
    func cancel()
}

@MainActor
@Observable
public final class MusicRecognitionFlow {
    public enum Phase: Equatable, Sendable {
        case idle, authorizing, listening, searching, ready
        case failed(MusicRecognitionFailure)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var recognized: RecognizedMusic?
    public private(set) var candidates: [MusicRecognitionCandidate] = []
    public var isWorking: Bool {
        switch phase {
        case .authorizing, .listening, .searching: true
        default: false
        }
    }

    @ObservationIgnored private var generation: UUID?
    @ObservationIgnored private var provider: (any MusicRecognitionProviding)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var recordingClaimed = false
    @ObservationIgnored private var stoppedRecording: (@MainActor (Bool) -> Void)?

    public init() {}

    /// Start only from a deliberate user action. No candidate is automatically selected,
    /// liked, saved or played. `isCurrent` includes the caller's account/playback intent.
    @discardableResult
    public func start(provider: any MusicRecognitionProviding,
                      isCurrent: @escaping @MainActor () -> Bool,
                      waitUntilActive: @escaping @MainActor () async -> Bool = { true },
                      beforeRecording: @escaping @MainActor () -> Bool,
                      stoppedRecording: @escaping @MainActor (Bool) -> Void,
                      search: @escaping @MainActor (String) async throws -> [Song]) -> Task<Void, Never> {
        cancel(allowPlaybackRestore: false)
        recognized = nil
        candidates = []
        guard provider.isAvailable else {
            phase = .failed(.unavailable)
            return Task {}
        }
        let id = UUID()
        generation = id
        self.provider = provider
        self.stoppedRecording = stoppedRecording
        phase = .authorizing
        let task = Task { [weak self] in
            guard let self else { return }
            let granted = await provider.requestPermission()
            guard self.accepts(id, isCurrent: isCurrent) else {
                self.discardIfCurrent(id)
                return
            }
            guard granted else { self.fail(.permissionDenied, id: id); return }
            guard await waitUntilActive(), self.accepts(id, isCurrent: isCurrent) else {
                self.discardIfCurrent(id)
                return
            }
            guard beforeRecording() else { self.fail(.audioBusy, id: id); return }
            self.recordingClaimed = true
            self.phase = .listening
            do {
                let found = try await provider.recognize()
                guard self.accepts(id, isCurrent: isCurrent) else {
                    self.discardIfCurrent(id)
                    return
                }
                // Stop the microphone before a possibly slow catalog search. Playback
                // restoration is controlled by the caller's retained, current intent.
                self.releaseRecording(allowPlaybackRestore: true)
                guard self.accepts(id, isCurrent: isCurrent) else {
                    self.discardIfCurrent(id)
                    return
                }
                self.recognized = found
                self.phase = .searching
                let songs = try await search(found.searchQuery)
                guard self.accepts(id, isCurrent: isCurrent) else {
                    self.discardIfCurrent(id)
                    return
                }
                self.candidates = MusicCandidateMatcher.rank(songs, for: found)
                self.phase = .ready
                self.finish(id)
            } catch {
                guard self.accepts(id, isCurrent: isCurrent) else {
                    self.discardIfCurrent(id)
                    return
                }
                let failure = error as? MusicRecognitionFailure
                    ?? (self.phase == .searching ? .searchFailed : .unavailable)
                self.fail(failure, id: id)
            }
        }
        self.task = task
        return task
    }

    public func cancel(allowPlaybackRestore: Bool = false) {
        generation = nil
        task?.cancel()
        task = nil
        releaseRecording(allowPlaybackRestore: allowPlaybackRestore)
        provider = nil
        stoppedRecording = nil
        phase = .idle
    }

    public func clear() {
        cancel()
        recognized = nil
        candidates = []
    }

    private func accepts(_ id: UUID, isCurrent: @MainActor () -> Bool) -> Bool {
        generation == id && !Task.isCancelled && isCurrent()
    }

    private func discardIfCurrent(_ id: UUID) {
        guard generation == id else { return }
        cancel(allowPlaybackRestore: false)
    }

    private func releaseRecording(allowPlaybackRestore: Bool) {
        provider?.cancel()
        guard recordingClaimed else { return }
        recordingClaimed = false
        stoppedRecording?(allowPlaybackRestore)
    }

    private func fail(_ failure: MusicRecognitionFailure, id: UUID) {
        guard generation == id else { return }
        releaseRecording(allowPlaybackRestore: failure != .interrupted && failure != .cancelled)
        phase = failure == .cancelled ? .idle : .failed(failure)
        finish(id)
    }

    private func finish(_ id: UUID) {
        guard generation == id else { return }
        generation = nil
        provider = nil
        stoppedRecording = nil
        task = nil
    }
}
