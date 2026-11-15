import Foundation

/// Uses Koda's existing authenticated WEB_REMIX API. This is not an official Google API.
public struct YouTubeCloudPlaylistTransport: CloudPlaylistTransport {
    private let music: YouTubeMusic
    private let validate: @Sendable () async throws -> Void
    private let progress: @Sendable (Int) async -> Void

    public init(music: YouTubeMusic,
                validate: @escaping @Sendable () async throws -> Void = {},
                progress: @escaping @Sendable (Int) async -> Void = { _ in }) {
        self.music = music
        self.validate = validate
        self.progress = progress
    }

    public func readPlaylist(id: String) async throws -> CloudPlaylistSnapshot {
        try await music.cloudPlaylist(id: id, progress: progress, validate: validate)
    }

    public func editablePlaylists(videoIDs: [String]) async throws -> [EditablePlaylist] {
        try await validate()
        try Task.checkCancellation()
        // An empty list used to fall back to every PL-prefixed library item, including
        // other people's saved playlists. That is never an edit-permission proof.
        guard !videoIDs.isEmpty else { return [] }
        let result = try await music.editablePlaylists(for: Array(videoIDs.prefix(50)))
        try await validate()
        try Task.checkCancellation()
        return result
    }

    public func createEmptyPlaylist(title: String) async throws -> String {
        try await validate()
        try Task.checkCancellation()
        // A single request lets the caller durably retain the ID before any song batch.
        // Do not check cancellation AFTER a successful response: the ID must be saved.
        return try await music.createPlaylist(title: title)
    }

    public func add(playlistID: String, videoIDs: [String]) async throws {
        guard (1...50).contains(videoIDs.count) else { throw CloudPlaylistError.invalidOperation }
        try await validate()
        try Task.checkCancellation()
        try await music.addToPlaylist(playlistId: playlistID, videoIds: videoIDs, allowDuplicates: true)
    }

    public func remove(playlistID: String, rows: [CloudPlaylistRow]) async throws {
        guard (1...50).contains(rows.count) else { throw CloudPlaylistError.invalidOperation }
        try await validate()
        try Task.checkCancellation()
        try await music.removePlaylistOccurrences(playlistId: playlistID, rows: rows)
    }

    public func rename(playlistID: String, title: String) async throws {
        try await validate()
        try Task.checkCancellation()
        try await music.renamePlaylist(playlistId: playlistID, title: title)
    }
}

extension YouTubeMusic {
    /// Fresh, complete account data. No PageCache access: explicit refresh and read-back
    /// must not be fulfilled by a stale request finishing after a cache invalidation.
    public func cloudPlaylist(id: String,
                              progress: @Sendable (Int) async -> Void = { _ in },
                              validate: @Sendable () async throws -> Void = {}) async throws -> CloudPlaylistSnapshot {
        let id = String(id.trimmingPrefix("VL"))
        guard !id.isEmpty else { throw CloudPlaylistError.invalidOperation }
        var rows: [CloudPlaylistRow] = []
        var summary: PlaylistSummary?
        var capabilities = CloudPlaylistCapabilities()
        var continuation: String?
        var seen = Set<String>()
        var unavailableCount = 0
        for pageNumber in 0..<200 {
            try Task.checkCancellation()
            try await validate()
            let payload: [String: Any] = if let continuation { ["continuation": continuation] }
                else { ["browseId": "VL" + id] }
            let root = try await api.music("browse", payload, signing: .required)
            try await validate()
            try Task.checkCancellation()
            if pageNumber == 0 {
                guard let page = CloudPlaylistPages.first(root, id: id) else { throw CloudPlaylistError.incompleteResponse }
                summary = page.playlist
                capabilities = page.capabilities
            }
            let parsed = try CloudPlaylistPages.rows(root, startingAt: rows.count)
            let pageRows = parsed.rows
            unavailableCount += parsed.unavailableCount
            guard pageRows.count <= 20_000 - rows.count else {
                throw PlaylistQueueLoader.LoadingError.songLimitExceeded(20_000)
            }
            rows.append(contentsOf: pageRows)
            await progress(rows.count)
            let next = CloudPlaylistPages.continuation(root)
            if let next {
                guard next != continuation, seen.insert(next).inserted else {
                    throw PlaylistQueueLoader.LoadingError.repeatedContinuation
                }
                continuation = next
            } else {
                guard let summary else { throw CloudPlaylistError.incompleteResponse }
                // A duplicate setVideoId would make occurrence-targeted removal ambiguous.
                let occurrenceIDs = rows.compactMap(\.setVideoID)
                guard Set(occurrenceIDs).count == occurrenceIDs.count else { throw CloudPlaylistError.incompleteResponse }
                return CloudPlaylistSnapshot(playlist: summary, rows: rows, capabilities: capabilities,
                                             unavailableCount: unavailableCount)
            }
        }
        throw PlaylistQueueLoader.LoadingError.pageLimitExceeded(200)
    }
}

enum CloudPlaylistPages {
    static func first(_ root: JSON, id: String) -> CloudPlaylistSnapshot? {
        guard let page = Pages.playlist(root, id: id) else { return nil }
        // This explicit renderer is the authenticated service's editor header. A PL
        // prefix, title, author name, or saved-library membership is not permission.
        let editor = root.first("musicEditablePlaylistDetailHeaderRenderer")
        let special = ["LM", "WL", "SE"].contains(id) || id.hasPrefix("RD") || id.hasPrefix("OLAK")
        let owned = editor.exists && !special
        return .init(playlist: page.playlist, rows: [],
                     capabilities: .init(canAdd: owned, canRemove: owned, canRename: owned))
    }

    struct RowPage {
        var rows: [CloudPlaylistRow]
        var unavailableCount: Int
    }

    static func rows(_ root: JSON, startingAt offset: Int) throws -> RowPage {
        let containers = root.objects("musicPlaylistShelfRenderer")
            + root.objects("musicPlaylistShelfContinuation") + root.objects("appendContinuationItemsAction")
        guard !containers.isEmpty,
              containers.allSatisfy({ $0["contents"].raw is [Any] || $0["continuationItems"].raw is [Any] }) else {
            throw CloudPlaylistError.incompleteResponse
        }
        var unavailable = 0
        var rows: [CloudPlaylistRow] = []
        for entry in containers.flatMap({ $0["contents"].array + $0["continuationItems"].array }) {
                let row = entry["musicResponsiveListItemRenderer"]
                if !row.exists {
                    guard entry["continuationItemRenderer"].exists else { throw CloudPlaylistError.incompleteResponse }
                    continue
                }
                if row["isAvailable"].bool == false || row["musicItemRendererDisplayPolicy"].string == "MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT" {
                    unavailable += 1
                    continue
                }
                guard let song = Rows.song(listRow: row) else { throw CloudPlaylistError.incompleteResponse }
                let setID = row["playlistItemData"]["playlistSetVideoId"].nonEmpty
                    ?? row["playlistItemData"]["setVideoId"].nonEmpty
                    ?? row.objects("playlistEditEndpoint").flatMap { $0["actions"].array }
                        .first(where: { $0["action"].string == "ACTION_REMOVE_VIDEO" })?["setVideoId"].nonEmpty
                rows.append(CloudPlaylistRow(id: setID ?? "row:\(offset + rows.count):\(song.id)", song: song, setVideoID: setID))
        }
        return RowPage(rows: rows, unavailableCount: unavailable)
    }

    static func continuation(_ root: JSON) -> String? {
        let scopes = root.objects("musicPlaylistShelfRenderer")
            + root.objects("musicPlaylistShelfContinuation") + root.objects("appendContinuationItemsAction")
        for scope in scopes {
            if let token = scope.objects("continuationCommand").first?["token"].nonEmpty { return token }
            if let token = scope.objects("nextContinuationData").first?["continuation"].nonEmpty { return token }
        }
        return nil
    }
}
