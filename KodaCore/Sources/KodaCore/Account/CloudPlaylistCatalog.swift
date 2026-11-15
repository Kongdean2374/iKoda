import Foundation

/// Display diagnostics, never permission evidence or proof that a remote item was removed.
public enum CloudPlaylistCatalogIssue: Codable, Equatable, Sendable {
    case unrecognizedPage
    case unrecognizedEntries(Int)
    case invalidContinuation
    case repeatedContinuation
    case pageLimitReached
    case playlistLimitReached
    case pageRequestFailed
}

/// A directory for browsing. Only a complete result may replace an authoritative
/// cache; partial results may contribute known remote IDs without deleting old ones.
public struct CloudPlaylistCatalogResult: Sendable, Equatable {
    public var playlists: [PlaylistSummary]
    public var issues: [CloudPlaylistCatalogIssue]
    public var fetchedAt: Date
    public var isComplete: Bool { issues.isEmpty }

    public init(playlists: [PlaylistSummary], issues: [CloudPlaylistCatalogIssue] = [], fetchedAt: Date = Date()) {
        self.playlists = playlists
        self.issues = issues
        self.fetchedAt = fetchedAt
    }

    public var displayMessage: String? {
        guard !isComplete else { return nil }
        return NSLocalizedString("Some cloud playlists could not be loaded. Your existing playlists have been kept. Refresh to try again.",
                                 bundle: KodaLocalization.bundle, comment: "")
    }

    /// Keeps stale-but-known cards on a partial refresh, while updating metadata for
    /// IDs successfully read this time. Callers must not treat this merge as synced.
    public func mergingForDisplay(previous: [PlaylistSummary]) -> [PlaylistSummary] {
        let values = isComplete ? playlists : playlists + previous
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

struct CloudPlaylistCatalogPage: Sendable {
    var playlists: [PlaylistSummary]
    var continuation: String?
    var issues: [CloudPlaylistCatalogIssue] = []
}

enum CloudPlaylistCatalogLoader {
    struct Limits: Sendable {
        var maxPages = 80
        var maxPlaylists = 5_000
    }

    /// One traversal, even when an unfamiliar control/card is encountered. Known
    /// cursors are followed; a late failure returns what was read with partial status.
    static func load(limits: Limits = .init(),
                     fetch: @Sendable (String?) async throws -> CloudPlaylistCatalogPage) async throws -> CloudPlaylistCatalogResult {
        var playlists: [PlaylistSummary] = []
        var knownIDs = Set<String>()
        var issues: [CloudPlaylistCatalogIssue] = []
        var cursor: String?
        var seenCursors = Set<String>()
        guard limits.maxPages > 0, limits.maxPlaylists > 0 else {
            return .init(playlists: [], issues: [.pageLimitReached])
        }
        for pageNumber in 0..<limits.maxPages {
            try Task.checkCancellation()
            let page: CloudPlaylistCatalogPage
            do { page = try await fetch(cursor) }
            catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if let musicError = error as? MusicError, case .signedOut = musicError { throw error }
                guard pageNumber > 0 else { throw error }
                issues.append(.pageRequestFailed)
                return .init(playlists: playlists, issues: issues)
            }
            try Task.checkCancellation()
            issues += page.issues
            for playlist in page.playlists where knownIDs.insert(playlist.id).inserted {
                guard playlists.count < limits.maxPlaylists else {
                    issues.append(.playlistLimitReached)
                    return .init(playlists: playlists, issues: issues)
                }
                playlists.append(playlist)
            }
            guard let next = page.continuation else { return .init(playlists: playlists, issues: issues) }
            guard next != cursor, seenCursors.insert(next).inserted else {
                issues.append(.repeatedContinuation)
                return .init(playlists: playlists, issues: issues)
            }
            cursor = next
        }
        issues.append(.pageLimitReached)
        return .init(playlists: playlists, issues: issues)
    }
}
