import Foundation

/// Authorizations can return after their UI has disappeared. Only the current
/// generation may start recording, and only a generation that changed the shared
/// audio session may restore it. The caller serializes transitions on its actor.
public struct VoiceSearchLifecycle: Sendable {
    public struct Generation: Equatable, Sendable {
        fileprivate let id: UUID
    }

    public struct Cleanup: Equatable, Sendable {
        public let restoreAudioSession: Bool
    }

    public private(set) var current: Generation?
    private var ownsAudioSession = false

    public init() {}

    /// Finish and clean up the previous generation before starting another one.
    public mutating func begin() -> Generation {
        precondition(current == nil, "End the previous voice search before starting another")
        let generation = Generation(id: UUID())
        current = generation
        return generation
    }

    public func accepts(_ generation: Generation, taskIsCancelled: Bool = false) -> Bool {
        !taskIsCancelled && current == generation
    }

    /// Call synchronously after successfully changing the audio session category.
    /// A failed category change has not acquired the session and must not deactivate it.
    @discardableResult
    public mutating func acquiredAudioSession(for generation: Generation) -> Bool {
        guard accepts(generation) else { return false }
        ownsAudioSession = true
        return true
    }

    /// Nil means stale work: it must not touch any resources belonging to a new search.
    /// A cleanup with false ownership may clear local state, but not shared playback.
    public mutating func end(_ generation: Generation) -> Cleanup? {
        guard accepts(generation) else { return nil }
        let cleanup = Cleanup(restoreAudioSession: ownsAudioSession)
        current = nil
        ownsAudioSession = false
        return cleanup
    }
}
