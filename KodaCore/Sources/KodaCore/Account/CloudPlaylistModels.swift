import Foundation

/// One remote occurrence. The service's setVideoId, not the song's video ID, identifies a removable row.
public struct CloudPlaylistRow: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var song: Song
    public var setVideoID: String?

    public init(id: String, song: Song, setVideoID: String? = nil) {
        self.id = id
        self.song = song
        self.setVideoID = setVideoID
    }
}

public struct CloudPlaylistCapabilities: Codable, Equatable, Sendable {
    public var canAdd: Bool
    public var canRemove: Bool
    public var canRename: Bool
    /// Neither destructive deletion nor reordering is exposed without verified service support.
    public var canDelete: Bool { false }
    public var canReorder: Bool { false }

    public init(canAdd: Bool = false, canRemove: Bool = false, canRename: Bool = false) {
        self.canAdd = canAdd
        self.canRemove = canRemove
        self.canRename = canRename
    }
}

/// Unplayable rows still exist remotely. Retain their identity without inventing
/// playable Song metadata or exposing an unavailable item as a valid audio source.
public struct CloudPlaylistUnavailableRow: Codable, Equatable, Sendable {
    public var setVideoID: String?
    public var videoID: String?

    public init(setVideoID: String? = nil, videoID: String? = nil) {
        self.setVideoID = setVideoID
        self.videoID = videoID
    }
}

public struct CloudPlaylistSnapshot: Codable, Equatable, Sendable {
    public var playlist: PlaylistSummary
    public var rows: [CloudPlaylistRow]
    public var capabilities: CloudPlaylistCapabilities
    public var fetchedAt: Date
    /// Explicitly unavailable service rows, excluded from playback but retained for mutation verification.
    public var unavailableCount: Int
    public var unavailableRows: [CloudPlaylistUnavailableRow]
    public var author: String?
    public var detailLine: String?
    public var description: String?
    public var songs: [Song] { rows.map(\.song) }
    public var id: String { playlist.id }
    public var title: String { playlist.title }
    public var page: PlaylistPage {
        PlaylistPage(playlist: playlist, author: author, detailLine: detailLine,
                     description: description, songs: songs, continuation: nil)
    }

    public init(playlist: PlaylistSummary, rows: [CloudPlaylistRow],
                capabilities: CloudPlaylistCapabilities = .init(), fetchedAt: Date = Date(), unavailableCount: Int = 0,
                unavailableRows: [CloudPlaylistUnavailableRow] = [], author: String? = nil,
                detailLine: String? = nil, description: String? = nil) {
        self.playlist = playlist
        self.rows = rows
        self.capabilities = capabilities
        self.fetchedAt = fetchedAt
        self.unavailableCount = max(unavailableCount, unavailableRows.count)
        self.unavailableRows = unavailableRows
        self.author = author
        self.detailLine = detailLine
        self.description = description
    }

    private enum CodingKeys: String, CodingKey {
        case playlist, rows, capabilities, fetchedAt, unavailableCount, unavailableRows, author, detailLine, description
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        playlist = try values.decode(PlaylistSummary.self, forKey: .playlist)
        rows = try values.decode([CloudPlaylistRow].self, forKey: .rows)
        capabilities = try values.decode(CloudPlaylistCapabilities.self, forKey: .capabilities)
        fetchedAt = try values.decode(Date.self, forKey: .fetchedAt)
        unavailableRows = try values.decodeIfPresent([CloudPlaylistUnavailableRow].self, forKey: .unavailableRows) ?? []
        unavailableCount = max(try values.decodeIfPresent(Int.self, forKey: .unavailableCount) ?? 0, unavailableRows.count)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        detailLine = try values.decodeIfPresent(String.self, forKey: .detailLine)
        description = try values.decodeIfPresent(String.self, forKey: .description)
    }

    var occurrenceIDs: [String] { rows.compactMap(\.setVideoID) + unavailableRows.compactMap(\.setVideoID) }
    var knownVideoIDs: [String] { songs.map(\.id) + unavailableRows.compactMap(\.videoID) }

    /// A missing visible row is not proof of removal: it may have become unavailable.
    /// Unknown rows only block confirmation when they could be the selected song.
    func confirmsAbsence(of selected: CloudPlaylistRow) -> Bool {
        guard let id = selected.setVideoID, !occurrenceIDs.contains(id),
              unavailableCount <= unavailableRows.count else { return false }
        guard !rows.contains(where: { $0.setVideoID == nil && $0.song.id == selected.song.id }) else { return false }
        return !unavailableRows.contains {
            $0.setVideoID == nil && ($0.videoID == nil || $0.videoID == selected.song.id)
        }
    }
}

/// Every read is fresh and complete. Implementations must never return a truncated page as a snapshot.
public protocol CloudPlaylistTransport: Sendable {
    func readPlaylist(id: String) async throws -> CloudPlaylistSnapshot
    func editablePlaylists(videoIDs: [String]) async throws -> [EditablePlaylist]
    func createEmptyPlaylist(title: String) async throws -> String
    func add(playlistID: String, videoIDs: [String]) async throws
    func remove(playlistID: String, rows: [CloudPlaylistRow]) async throws
    func rename(playlistID: String, title: String) async throws
}

public enum CloudPlaylistOperation: Codable, Equatable, Sendable {
    case create(title: String, songs: [Song])
    case add(playlistID: String, songs: [Song])
    case remove(playlistID: String, rows: [CloudPlaylistRow])
    case rename(playlistID: String, previousTitle: String, title: String)

    public var playlistID: String? {
        switch self {
        case .create: nil
        case .add(let id, _), .remove(let id, _), .rename(let id, _, _): id
        }
    }
}

/// Persist before sending a write. If the process dies, this record forces a read-back, not a blind replay.
public struct CloudPlaylistPendingBatch: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case create, add, remove, rename }
    public var kind: Kind
    public var videoIDs: [String]
    public var rows: [CloudPlaylistRow]
    public var expectedCounts: [String: Int]
    public var title: String?
    public var consumedCount: Int

    public init(kind: Kind, videoIDs: [String] = [], rows: [CloudPlaylistRow] = [],
                expectedCounts: [String: Int] = [:], title: String? = nil, consumedCount: Int = 0) {
        self.kind = kind
        self.videoIDs = videoIDs
        self.rows = rows
        self.expectedCounts = expectedCounts
        self.title = title
        self.consumedCount = consumedCount
    }
}

public struct CloudPlaylistCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var operation: CloudPlaylistOperation
    public var playlistID: String?
    public var completedCount: Int
    public var pending: CloudPlaylistPendingBatch?
    public var isComplete: Bool
    public var updatedAt: Date

    public init(id: UUID = UUID(), operation: CloudPlaylistOperation) {
        self.id = id
        self.operation = operation
        self.playlistID = operation.playlistID
        self.completedCount = 0
        self.pending = nil
        self.isComplete = false
        self.updatedAt = Date()
    }
}

public enum CloudPlaylistError: Error, Equatable, Sendable, LocalizedError {
    case readOnly, unsupported, missingOccurrenceID, externalChange, incompleteResponse
    case unconfirmedWrite, unconfirmedCreation, invalidOperation

    public var errorDescription: String? {
        let key: String = switch self {
        case .readOnly: "This playlist is read-only for this account."
        case .unsupported: "YouTube Music does not currently provide a verified way to perform this operation."
        case .missingOccurrenceID: "YouTube Music did not provide the row identifiers needed to safely remove these songs."
        case .externalChange: "This playlist changed on another device. Refresh it before trying again."
        case .incompleteResponse: "The complete cloud playlist could not be verified. No partial result was accepted."
        case .unconfirmedWrite: "The cloud change is not confirmed yet. Check again before making another change."
        case .unconfirmedCreation: "YouTube Music may have created this playlist. Refresh your playlists before creating another one."
        case .invalidOperation: "The cloud playlist operation is invalid. Refresh and try again."
        }
        return NSLocalizedString(key, bundle: KodaLocalization.bundle, comment: "")
    }
}
