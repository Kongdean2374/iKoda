import Foundation

/// Small, read-before/write/read-after operations. It never replaces a remote song list.
/// The caller serializes operations with account switching and durably stores every checkpoint.
public enum CloudPlaylistRunner {
    public static func run(
        _ checkpoint: CloudPlaylistCheckpoint,
        transport: any CloudPlaylistTransport,
        validate: @Sendable () async throws -> Void = {},
        didCheckpoint: @Sendable (CloudPlaylistCheckpoint) async throws -> Void = { _ in }
    ) async throws -> CloudPlaylistSnapshot {
        var state = checkpoint
        try validateOperation(state)
        try await check(validate)

        if case .create(let title, _) = state.operation, state.playlistID == nil {
            guard state.pending == nil else { throw CloudPlaylistError.unconfirmedCreation }
            state.pending = .init(kind: .create, title: title)
            try await stage(&state, validate: validate, didCheckpoint: didCheckpoint)
            do {
                let id = try await transport.createEmptyPlaylist(title: title)
                guard !id.isEmpty else { throw CloudPlaylistError.unconfirmedCreation }
                state.playlistID = canonical(id)
                state.pending = nil
                // Even if Cancel/profile-switch happened while the request was in flight,
                // keep the returned ID first. Retrying must never create a second playlist.
                try await save(state, didCheckpoint)
            } catch {
                if definitelyRejected(error) {
                    state.pending = nil
                    try await save(state, didCheckpoint)
                }
                throw error
            }
        }
        guard let playlistID = state.playlistID else { throw CloudPlaylistError.invalidOperation }
        guard !["LM", "WL", "SE"].contains(canonical(playlistID)),
              !canonical(playlistID).hasPrefix("RD"), !canonical(playlistID).hasPrefix("OLAK") else {
            throw CloudPlaylistError.readOnly
        }
        try await check(validate)
        var snapshot = try await transport.readPlaylist(id: playlistID)
        try await check(validate)
        try verifyIdentity(snapshot, expected: playlistID)

        // An earlier process/request might have completed remotely without receiving its
        // response. Only read-back may acknowledge it. In particular, an absent ADD is not
        // proof it will never arrive, so a retry does not blindly send that ADD again.
        if let pending = state.pending {
            guard confirmed(pending, in: snapshot) else {
                throw pending.kind == .create ? CloudPlaylistError.unconfirmedCreation : .unconfirmedWrite
            }
            state.completedCount += pending.consumedCount
            state.pending = nil
            try await save(state, didCheckpoint)
        }
        if state.isComplete { return snapshot }

        switch state.operation {
        case .create(_, let songs), .add(_, let songs):
            while state.completedCount < songs.count {
                try await check(validate)
                let batch = Array(songs.dropFirst(state.completedCount).prefix(50))
                try await requireAddPermission(snapshot, videoIDs: batch.map(\.id), transport: transport, validate: validate)
                var expected = counts(snapshot.knownVideoIDs)
                for song in batch { expected[song.id, default: 0] += 1 }
                let relevant = Set(batch.map(\.id))
                state.pending = .init(kind: .add, videoIDs: batch.map(\.id),
                                      expectedCounts: expected.filter { relevant.contains($0.key) },
                                      consumedCount: batch.count)
                try await stage(&state, validate: validate, didCheckpoint: didCheckpoint)
                try await writeAndVerify(state: &state, snapshot: &snapshot, transport: transport,
                                         validate: validate, didCheckpoint: didCheckpoint) {
                    try await transport.add(playlistID: playlistID, videoIDs: batch.map(\.id))
                }
            }
        case .remove(_, let requested):
            guard snapshot.capabilities.canRemove else { throw CloudPlaylistError.readOnly }
            // Preserve occurrence identity: another device adding the same video does
            // not authorize deleting that new row. Missing selected occurrences are done.
            while state.completedCount < requested.count {
                try await check(validate)
                guard snapshot.capabilities.canRemove else { throw CloudPlaylistError.readOnly }
                let batch = Array(requested.dropFirst(state.completedCount).prefix(50))
                let occurrenceIDs = Set(snapshot.occurrenceIDs)
                var knownVideos = Dictionary(uniqueKeysWithValues: snapshot.rows.compactMap { row in
                    row.setVideoID.map { ($0, row.song.id) }
                })
                for row in snapshot.unavailableRows {
                    if let id = row.setVideoID, let videoID = row.videoID { knownVideos[id] = videoID }
                }
                for row in batch {
                    guard let id = row.setVideoID else { throw CloudPlaylistError.missingOccurrenceID }
                    if let actual = knownVideos[id], actual != row.song.id { throw CloudPlaylistError.externalChange }
                    // A selected row may now be unavailable, not removed. If its
                    // identity disappeared as well, do not claim a no-write success.
                    if !occurrenceIDs.contains(id), !snapshot.confirmsAbsence(of: row) {
                        throw CloudPlaylistError.missingOccurrenceID
                    }
                }
                let present = batch.filter { occurrenceIDs.contains($0.setVideoID!) }
                if present.isEmpty {
                    state.completedCount += batch.count
                    try await save(state, didCheckpoint)
                    continue
                }
                state.pending = .init(kind: .remove, rows: present, consumedCount: batch.count)
                try await stage(&state, validate: validate, didCheckpoint: didCheckpoint)
                try await writeAndVerify(state: &state, snapshot: &snapshot, transport: transport,
                                         validate: validate, didCheckpoint: didCheckpoint) {
                    try await transport.remove(playlistID: playlistID, rows: present)
                }
            }
        case .rename(_, let previous, let title):
            guard snapshot.capabilities.canRename else { throw CloudPlaylistError.readOnly }
            if snapshot.title != title {
                guard snapshot.title == previous else { throw CloudPlaylistError.externalChange }
                state.pending = .init(kind: .rename, title: title)
                try await stage(&state, validate: validate, didCheckpoint: didCheckpoint)
                try await writeAndVerify(state: &state, snapshot: &snapshot, transport: transport,
                                         validate: validate, didCheckpoint: didCheckpoint) {
                    try await transport.rename(playlistID: playlistID, title: title)
                }
            }
        }
        state.isComplete = true
        try await save(state, didCheckpoint)
        try await check(validate)
        return snapshot
    }

    private static func writeAndVerify(
        state: inout CloudPlaylistCheckpoint, snapshot: inout CloudPlaylistSnapshot,
        transport: any CloudPlaylistTransport,
        validate: @Sendable () async throws -> Void,
        didCheckpoint: @Sendable (CloudPlaylistCheckpoint) async throws -> Void,
        write: () async throws -> Void
    ) async throws {
        do { try await write() }
        catch {
            if definitelyRejected(error) {
                state.pending = nil
                try await save(state, didCheckpoint)
            }
            // Retain the possibly-sent batch. A user retry checks it before any write.
            throw error
        }
        try await check(validate)
        guard let playlistID = state.playlistID else { throw CloudPlaylistError.invalidOperation }
        let fresh = try await transport.readPlaylist(id: playlistID)
        try await check(validate)
        try verifyIdentity(fresh, expected: playlistID)
        guard let pending = state.pending, confirmed(pending, in: fresh) else {
            throw CloudPlaylistError.unconfirmedWrite
        }
        snapshot = fresh
        state.completedCount += pending.consumedCount
        state.pending = nil
        try await save(state, didCheckpoint)
    }

    private static func requireAddPermission(_ snapshot: CloudPlaylistSnapshot, videoIDs: [String],
                                             transport: any CloudPlaylistTransport,
                                             validate: @Sendable () async throws -> Void) async throws {
        if snapshot.capabilities.canAdd { return }
        try await check(validate)
        let permitted = try await transport.editablePlaylists(videoIDs: videoIDs)
        try await check(validate)
        guard permitted.contains(where: { canonical($0.id) == canonical(snapshot.id) }) else {
            throw CloudPlaylistError.readOnly
        }
    }

    static func confirmed(_ batch: CloudPlaylistPendingBatch, in snapshot: CloudPlaylistSnapshot) -> Bool {
        switch batch.kind {
        case .create: return false // An unknown remote ID cannot be recovered by matching names.
        case .add:
            let actual = counts(snapshot.knownVideoIDs)
            return !batch.expectedCounts.isEmpty && batch.expectedCounts.allSatisfy { actual[$0.key, default: 0] >= $0.value }
        case .remove:
            return !batch.rows.isEmpty && batch.rows.allSatisfy { snapshot.confirmsAbsence(of: $0) }
        case .rename: return snapshot.title == batch.title
        }
    }

    private static func validateOperation(_ state: CloudPlaylistCheckpoint) throws {
        guard state.completedCount >= 0 else { throw CloudPlaylistError.invalidOperation }
        guard !state.isComplete || (state.pending == nil && state.playlistID != nil) else { throw CloudPlaylistError.invalidOperation }
        switch state.operation {
        case .create(let title, let songs):
            guard validTitle(title), validSongs(songs), state.completedCount <= songs.count,
                  !state.isComplete || state.completedCount == songs.count else { throw CloudPlaylistError.invalidOperation }
        case .add(let id, let songs):
            guard !canonical(id).isEmpty, !songs.isEmpty, validSongs(songs), state.completedCount <= songs.count,
                  !state.isComplete || state.completedCount == songs.count else { throw CloudPlaylistError.invalidOperation }
        case .remove(let id, let rows):
            guard !canonical(id).isEmpty, !rows.isEmpty, rows.count <= 20_000,
                  state.completedCount <= rows.count, !state.isComplete || state.completedCount == rows.count else { throw CloudPlaylistError.invalidOperation }
            guard rows.allSatisfy({ $0.setVideoID?.isEmpty == false }),
                  Set(rows.compactMap(\.setVideoID)).count == rows.count else { throw CloudPlaylistError.missingOccurrenceID }
        case .rename(let id, _, let title):
            guard !canonical(id).isEmpty, validTitle(title) else { throw CloudPlaylistError.invalidOperation }
        }
        if let id = state.playlistID, let expected = state.operation.playlistID,
           canonical(id) != canonical(expected) { throw CloudPlaylistError.invalidOperation }
        if let pending = state.pending, pending.consumedCount < 0 || pending.consumedCount > 50 {
            throw CloudPlaylistError.invalidOperation
        }
    }

    private static func validTitle(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 150
    }
    private static func validSongs(_ songs: [Song]) -> Bool { songs.count <= 20_000 && songs.allSatisfy { !$0.id.isEmpty } }
    private static func canonical(_ id: String) -> String { String(id.trimmingPrefix("VL")) }
    private static func counts(_ ids: [String]) -> [String: Int] {
        ids.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
    private static func verifyIdentity(_ snapshot: CloudPlaylistSnapshot, expected: String) throws {
        guard canonical(snapshot.id) == canonical(expected) else { throw CloudPlaylistError.incompleteResponse }
        let ids = snapshot.occurrenceIDs
        guard Set(ids).count == ids.count else { throw CloudPlaylistError.incompleteResponse }
    }
    private static func check(_ validate: @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
    }
    private static func save(_ state: CloudPlaylistCheckpoint,
                             _ didCheckpoint: @Sendable (CloudPlaylistCheckpoint) async throws -> Void) async throws {
        var copy = state
        copy.updatedAt = Date()
        try await didCheckpoint(copy)
    }
    private static func stage(_ state: inout CloudPlaylistCheckpoint,
                              validate: @Sendable () async throws -> Void,
                              didCheckpoint: @Sendable (CloudPlaylistCheckpoint) async throws -> Void) async throws {
        try await save(state, didCheckpoint)
        do { try await check(validate) }
        catch {
            // A cancellation/profile switch while the journal was saving is known to
            // precede the request. Do not label a never-sent operation as ambiguous.
            state.pending = nil
            try await save(state, didCheckpoint)
            throw error
        }
    }
    private static func definitelyRejected(_ error: Error) -> Bool {
        guard let error = error as? MusicError else { return false }
        return switch error {
        case .signedOut: true
        case .badResponse(let status): [400, 401, 403, 404].contains(status)
        default: false
        }
    }
}
