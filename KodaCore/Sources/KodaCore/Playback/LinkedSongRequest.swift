/// A shared-link lookup belongs to the transport intent that requested it. Metadata may
/// finish after cancellation, so both its result and its failure must check the revision.
public struct LinkedSongRequest: Sendable, Equatable {
    public enum Selection: Sendable, Equatable {
        case superseded
        case unavailable
        case queue([Song])
    }

    public let songID: String
    public let intentRevision: UInt64

    public init(songID: String, intentRevision: UInt64) {
        self.songID = songID
        self.intentRevision = intentRevision
    }

    public func isCurrent(revision: UInt64, isCancelled: Bool = false) -> Bool {
        !isCancelled && revision == intentRevision
    }

    /// Radio responses can contain only recommendations when the requested song is not
    /// available. Never substitute the first recommendation for the song in the URL.
    public func selection(from songs: [Song], currentRevision: UInt64) -> Selection {
        guard isCurrent(revision: currentRevision) else { return .superseded }
        guard let seed = songs.first(where: { $0.id == songID }) else { return .unavailable }
        return .queue([seed] + songs.filter { $0.id != songID })
    }
}
