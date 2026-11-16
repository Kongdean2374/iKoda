#if DEBUG
import Foundation
import KodaCore

/// A deterministic service boundary for the real cloud coordinator and views. A
/// successful write changes the remote snapshot; the production runner still has
/// to read it back before the UI may report success. No cookies/network are used.
actor UITestCloudTransport: CloudPlaylistTransport {
    private var snapshots: [String: CloudPlaylistSnapshot]
    private let songs: [String: Song]
    private var sequence = 0
    private var failFirstReadAfterAdd: Bool
    private var failNextRead = false
    private let beforeRename: (@Sendable () async throws -> Void)?

    init(snapshots: [CloudPlaylistSnapshot], songs: [Song], failFirstReadAfterAdd: Bool = false,
         beforeRename: (@Sendable () async throws -> Void)? = nil) {
        self.failFirstReadAfterAdd = failFirstReadAfterAdd
        self.beforeRename = beforeRename
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        self.songs = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
    }

    func readPlaylist(id: String) async throws -> CloudPlaylistSnapshot {
        if failNextRead {
            failNextRead = false
            throw URLError(.timedOut)
        }
        guard let value = snapshots[id] else { throw CloudPlaylistError.invalidOperation }
        return value
    }

    func editablePlaylists(videoIDs: [String]) async throws -> [EditablePlaylist] {
        snapshots.values.filter { $0.capabilities.canAdd }
            .sorted { $0.id < $1.id }
            .map { EditablePlaylist(id: $0.id, title: $0.title) }
    }

    func createEmptyPlaylist(title: String) async throws -> String {
        sequence += 1
        let id = "PLui-created-\(sequence)"
        snapshots[id] = CloudPlaylistSnapshot(playlist: .init(id: id, title: title), rows: [],
            capabilities: .init(canAdd: true, canRemove: true, canRename: true))
        return id
    }

    func add(playlistID: String, videoIDs: [String]) async throws {
        guard var value = snapshots[playlistID], value.capabilities.canAdd else { throw CloudPlaylistError.readOnly }
        for id in videoIDs {
            guard let song = songs[id] else { throw CloudPlaylistError.invalidOperation }
            sequence += 1
            let occurrence = "ui-row-\(sequence)"
            value.rows.append(.init(id: occurrence, song: song, setVideoID: occurrence))
        }
        snapshots[playlistID] = value
        if failFirstReadAfterAdd {
            failFirstReadAfterAdd = false
            failNextRead = true
        }
    }

    func remove(playlistID: String, rows: [CloudPlaylistRow]) async throws {
        guard var value = snapshots[playlistID], value.capabilities.canRemove else { throw CloudPlaylistError.readOnly }
        let ids = Set(rows.compactMap(\.setVideoID))
        guard ids.count == rows.count else { throw CloudPlaylistError.missingOccurrenceID }
        value.rows.removeAll { row in row.setVideoID.map { ids.contains($0) } ?? false }
        snapshots[playlistID] = value
    }

    func rename(playlistID: String, title: String) async throws {
        try await beforeRename?()
        guard var value = snapshots[playlistID], value.capabilities.canRename else { throw CloudPlaylistError.readOnly }
        value.playlist.title = title
        snapshots[playlistID] = value
    }
}

/// Tests choose a result or a suspended recognition. This exercises the real
/// permission/cancellation/result state machine without claiming Shazam success.
@MainActor
final class UITestMusicRecognizer: MusicRecognitionProviding {
    enum Scenario { case match(RecognizedMusic), noMatch, waiting, denied }
    let isAvailable = true
    private let scenario: Scenario
    private var continuation: CheckedContinuation<RecognizedMusic, any Error>?

    init(_ scenario: Scenario) { self.scenario = scenario }
    func requestPermission() async -> Bool {
        if case .denied = scenario { return false }
        return true
    }

    func recognize() async throws -> RecognizedMusic {
        switch scenario {
        case .match(let value): return value
        case .noMatch: throw MusicRecognitionFailure.noMatch
        case .denied: throw MusicRecognitionFailure.permissionDenied
        case .waiting:
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
    }

    func cancel() {
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: MusicRecognitionFailure.cancelled)
    }
}
#endif
