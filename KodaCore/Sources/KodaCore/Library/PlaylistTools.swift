import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// An index identifies a particular occurrence, including repeated copies of one video.
/// A selection belongs to an immutable list snapshot, never to the current filtered order.
public struct PlaylistSongSelection: Sendable, Equatable {
    public let count: Int
    public private(set) var selectedIndices: Set<Int> = []
    public init(count: Int) { self.count = max(0, count) }
    public mutating func toggle(_ index: Int) {
        guard (0..<count).contains(index) else { return }
        if !selectedIndices.insert(index).inserted { selectedIndices.remove(index) }
    }
    public mutating func selectAll() { selectedIndices = Set(0..<count) }
    public mutating func clear() { selectedIndices.removeAll(keepingCapacity: true) }
    public func selectedSongs(from songs: [Song]) -> [Song] {
        songs.enumerated().compactMap { selectedIndices.contains($0.offset) ? $0.element : nil }
    }
}

public struct PlaylistSnapshot: Sendable, Equatable {
    public let id: UUID
    public let songs: [Song]
    let profileGeneration: UUID
}

public enum PlaylistEdit: Sendable {
    /// Follows existing Add to Playlist semantics: stable IDs already present are skipped.
    case copy(songs: [Song], to: UUID)
    case move(source: PlaylistSnapshot, indices: Set<Int>, to: UUID)
    case remove(source: PlaylistSnapshot, indices: Set<Int>)
    /// Unlike the legacy single-song API, an explicit merge may retain every occurrence.
    case create(name: String, songs: [Song], excludingExactDuplicates: Bool)
}

public struct PlaylistEditReceipt: Sendable {
    public let playlistID: UUID
    public let affectedCount: Int
    public let undo: PlaylistUndoToken?
}

public struct PlaylistUndoToken: Sendable {
    let id: UUID
    let profileGeneration: UUID
    let before: [UserPlaylist]
    let after: [UserPlaylist]
}

/// An unpublished prepared file is removed even if its owner is cancelled or drops it.
/// The separation also makes the commit boundary independently testable without timing races.
final class PreparedPlaylistEdit: Sendable {
    let version: Int
    let generation: UUID
    let playlists: [UserPlaylist]
    let temporary: URL?
    let destination: URL?
    let receipt: PlaylistEditReceipt
    init(version: Int, generation: UUID, playlists: [UserPlaylist], temporary: URL?, destination: URL?, receipt: PlaylistEditReceipt) {
        self.version = version; self.generation = generation; self.playlists = playlists
        self.temporary = temporary; self.destination = destination; self.receipt = receipt
    }
    deinit { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
}

public enum PlaylistEditError: Error, LocalizedError, Equatable, Sendable {
    case playlistMissing, libraryChanged, wrongProfile, invalidSelection, emptyName, samePlaylist, cannotUndo
    public var errorDescription: String? {
        let key: String
        switch self {
        case .playlistMissing: key = "This local playlist no longer exists."
        case .libraryChanged: key = "The library changed during this operation. Review the updated songs and try again."
        case .wrongProfile: key = "The active profile changed. Open the playlist again."
        case .invalidSelection: key = "Select at least one song from the current playlist."
        case .emptyName: key = "Enter a name for the new playlist."
        case .samePlaylist: key = "Choose a different destination playlist."
        case .cannotUndo: key = "This playlist was reordered or edited after the operation. Undo cannot safely replace those changes."
        }
        return NSLocalizedString(key, bundle: KodaLocalization.bundle, comment: "")
    }
}

public struct PlaylistDuplicateGroup: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case exact, possibleMatch, differentVersions }
    public let id: Int
    public let indices: [Int]
    public let kind: Kind
}

public enum PlaylistTools {
    /// Stable first-source order. Only a nonempty stable ID permits automatic exclusion.
    public static func merge(_ sources: [[Song]], excludingExactDuplicates: Bool,
                             progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [Song] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let total = sources.reduce(0) { $0 + $1.count }
            var songs: [Song] = []; songs.reserveCapacity(total)
            var seen = Set<String>(); var processed = 0
            for source in sources {
                for song in source {
                    if processed.isMultiple(of: 128) { try Task.checkCancellation(); progress?(processed, total) }
                    if !excludingExactDuplicates || song.id.isEmpty || seen.insert(song.id).inserted { songs.append(song) }
                    processed += 1
                }
            }
            try Task.checkCancellation(); progress?(total, total)
            return songs
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Suggestions never remove songs. Metadata-only matches deliberately remain uncertain.
    public static func duplicateGroups(in songs: [Song]) async throws -> [PlaylistDuplicateGroup] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { try analyze(songs) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func analyze(_ songs: [Song]) throws -> [PlaylistDuplicateGroup] {
        struct Metadata {
            let index: Int
            let album: String
            let duration: TimeInterval?
            let version: String
        }
        var byID: [String: [Int]] = [:]
        var byTitleAndArtist: [String: [Metadata]] = [:]
        for (index, song) in songs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            if !song.id.isEmpty { byID[song.id, default: []].append(index) }
            let artist = normalized(song.artistLine)
            let (title, version) = titleAndVersion(song.title)
            guard !title.isEmpty, !artist.isEmpty else { continue }
            let duration = song.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            byTitleAndArtist[title + "\u{1F}" + artist, default: []].append(
                Metadata(index: index, album: normalized(song.album?.title ?? ""), duration: duration, version: version))
        }
        var results: [PlaylistDuplicateGroup] = []
        for indices in byID.values where indices.count > 1 {
            results.append(PlaylistDuplicateGroup(id: indices[0] * 3, indices: indices, kind: .exact))
        }
        for entries in byTitleAndArtist.values where entries.count > 1 {
            try Task.checkCancellation()
            // Multiple copies of one ID are already accounted for by the exact group.
            guard Set(entries.map { songs[$0.index].id }).count > 1 else { continue }
            if Set(entries.map(\.version)).count > 1 || entries.contains(where: { !$0.version.isEmpty }) {
                let indices = entries.map(\.index).sorted()
                results.append(PlaylistDuplicateGroup(id: indices[0] * 3 + 2, indices: indices, kind: .differentVersions))
                continue
            }
            // Album and a narrow duration window are supporting evidence, not an identity.
            // Partitioning avoids quadratic comparisons for large same-title collections.
            let albums = Dictionary(grouping: entries, by: \.album)
            for bucket in albums.values {
                let timed = bucket.filter { $0.duration != nil }.sorted { $0.duration! < $1.duration! }
                var cluster: [Metadata] = []
                func appendCluster() {
                    guard cluster.count > 1, Set(cluster.map { songs[$0.index].id }).count > 1 else { return }
                    let indices = cluster.map(\.index).sorted()
                    results.append(PlaylistDuplicateGroup(id: indices[0] * 3 + 1, indices: indices, kind: .possibleMatch))
                }
                for entry in timed {
                    if let first = cluster.first, entry.duration! - first.duration! > 2 { appendCluster(); cluster = [] }
                    cluster.append(entry)
                }
                appendCluster()
            }
        }
        return results.sorted { $0.id < $1.id }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func titleAndVersion(_ text: String) -> (String, String) {
        let lower = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let markers = ["live", "remix", "cover", "instrumental", "acoustic", "karaoke", "sped up", "slowed", "remaster",
                       "現場", "现场", "演唱會", "演唱会", "翻唱", "伴奏", "純音樂", "纯音乐", "混音"]
        let versions = markers.filter { marker in
            guard lower.contains(marker) else { return false }
            if marker.unicodeScalars.contains(where: { $0.value > 127 }) { return lower.contains(marker) }
            return lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b", options: .regularExpression) != nil
        }
        var base = lower
        // Remove bracketed edition labels only when there is an explicit version marker.
        if !versions.isEmpty {
            base = base.replacingOccurrences(of: #"[\(\[（【][^\)\]）】]*[\)\]）】]"#, with: "", options: .regularExpression)
            for marker in versions {
                if marker.unicodeScalars.contains(where: { $0.value > 127 }) {
                    base = base.replacingOccurrences(of: marker, with: "")
                } else {
                    base = base.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: marker) + "\\b",
                                                     with: "", options: .regularExpression)
                }
            }
        }
        return (normalized(base), versions.sorted().joined(separator: ","))
    }
}

/// Preparing the full JSON is deliberately outside SaveClock's lock and off MainActor.
/// Only rename is serialized with publication; stale writers can never overwrite a commit.
enum PreparedLibraryFile {
    static func prepare(_ data: Data, for destination: URL) throws -> URL {
        let temp = destination.deletingLastPathComponent().appending(path: ".koda-library-\(UUID().uuidString).tmp")
        do { try data.write(to: temp, options: .withoutOverwriting); return temp }
        catch { try? FileManager.default.removeItem(at: temp); throw error }
    }

    static func publish(_ temp: URL, to destination: URL) throws {
        guard rename(temp.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
