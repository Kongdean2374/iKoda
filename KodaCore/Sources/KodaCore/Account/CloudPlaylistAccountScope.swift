import Foundation

/// Captured when the listener starts an action, before any task is scheduled or
/// receipt is restored. A switch away and back still invalidates the old action.
public struct CloudPlaylistAccountScope: Equatable, Sendable {
    public let profileID: UUID
    public let generation: UInt64

    public init(profileID: UUID, generation: UInt64) {
        self.profileID = profileID
        self.generation = generation
    }

    public func matches(activeProfileID: UUID?, coordinatorProfileID: UUID?, generation: UInt64) -> Bool {
        activeProfileID == profileID && coordinatorProfileID == profileID && self.generation == generation
    }
}
