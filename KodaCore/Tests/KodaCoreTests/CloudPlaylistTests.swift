import Foundation
import Testing
@testable import KodaCore

private func cloudSong(_ id: String) -> Song {
    Song(id: id, title: "Song \(id)", artistLine: "Artist", duration: 180)
}

private func cloudRow(_ id: String, occurrence: String) -> CloudPlaylistRow {
    CloudPlaylistRow(id: occurrence, song: cloudSong(id), setVideoID: occurrence)
}

private actor CloudFixture: CloudPlaylistTransport {
    var snapshot: CloudPlaylistSnapshot
    var permitted: [EditablePlaylist] = []
    var createFailsAfterCommit = false
    var addFailureNumber: Int?
    var addCommitsBeforeFailure = true
    var ignoreWrites = false
    var readFailures = 0
    var createHook: (@Sendable () async -> Void)?
    private(set) var creates = 0
    private(set) var adds: [[String]] = []
    private(set) var removals: [[String]] = []
    private(set) var renames: [String] = []
    private(set) var reads = 0
    private(set) var permissionQueries = 0

    init(rows: [CloudPlaylistRow] = [], owned: Bool = true, title: String = "Original") {
        snapshot = .init(playlist: .init(id: "PLtest", title: title), rows: rows,
                         capabilities: .init(canAdd: owned, canRemove: owned, canRename: owned))
    }
    func configureCreateFailure() { createFailsAfterCommit = true }
    func configureAddFailure(_ number: Int, commits: Bool = true) { addFailureNumber = number; addCommitsBeforeFailure = commits }
    func configureIgnoredWrites() { ignoreWrites = true }
    func configurePermissions() { permitted = [.init(id: "PLtest", title: "Original")] }
    func onCreate(_ hook: @escaping @Sendable () async -> Void) { createHook = hook }
    func failReadOnce() { readFailures = 1 }

    func readPlaylist(id: String) throws -> CloudPlaylistSnapshot {
        reads += 1
        if readFailures > 0 { readFailures -= 1; throw MusicError.network }
        return snapshot
    }
    func editablePlaylists(videoIDs: [String]) -> [EditablePlaylist] { permissionQueries += 1; return permitted }
    func createEmptyPlaylist(title: String) async throws -> String {
        creates += 1
        snapshot.playlist.title = title
        snapshot.rows = []
        if let createHook { await createHook() }
        if createFailsAfterCommit { throw MusicError.network }
        return snapshot.id
    }
    func add(playlistID: String, videoIDs: [String]) throws {
        adds.append(videoIDs)
        let fails = adds.count == addFailureNumber
        if !ignoreWrites, !fails || addCommitsBeforeFailure {
            for id in videoIDs { snapshot.rows.append(cloudRow(id, occurrence: "set-\(snapshot.rows.count)-\(id)")) }
        }
        if fails { throw MusicError.network }
    }
    func remove(playlistID: String, rows: [CloudPlaylistRow]) {
        let ids = rows.compactMap(\.setVideoID)
        removals.append(ids)
        if !ignoreWrites { snapshot.rows.removeAll { ids.contains($0.setVideoID ?? "") } }
    }
    func rename(playlistID: String, title: String) {
        renames.append(title)
        if !ignoreWrites { snapshot.playlist.title = title }
    }
}

private actor CloudReceiptFixture {
    private(set) var saved: [CloudPlaylistCheckpoint] = []
    var fail = false
    var onPending: (@Sendable () async -> Void)?
    func record(_ state: CloudPlaylistCheckpoint) async throws {
        if fail { throw CocoaError(.fileWriteOutOfSpace) }
        saved.append(state)
        if state.pending != nil, let onPending { await onPending() }
    }
    func failWrites() { fail = true }
    func whenPending(_ hook: @escaping @Sendable () async -> Void) { onPending = hook }
    var latest: CloudPlaylistCheckpoint? { saved.last }
}

private actor CloudValidationGate {
    var valid = true
    func invalidate() { valid = false }
    func validate() throws { if !valid { throw CancellationError() } }
}

@Suite struct CloudPlaylistMutationTests {
    private func run(_ operation: CloudPlaylistOperation, _ transport: CloudFixture,
                     _ receipts: CloudReceiptFixture = .init()) async throws -> CloudPlaylistSnapshot {
        try await CloudPlaylistRunner.run(.init(operation: operation), transport: transport,
                                          didCheckpoint: { try await receipts.record($0) })
    }

    @Test func createKeepsReturnedIDAndResumesAfterAnAmbiguousSecondBatch() async throws {
        let api = CloudFixture()
        let journal = CloudReceiptFixture()
        await api.configureAddFailure(2)
        let songs = (0..<125).map { cloudSong("v\($0)") }
        await #expect(throws: MusicError.network) { try await run(.create(title: "New", songs: songs), api, journal) }
        let saved = try #require(await journal.latest)
        #expect(saved.playlistID == "PLtest")
        #expect(saved.completedCount == 50)
        #expect(saved.pending?.videoIDs.count == 50)
        let result = try await CloudPlaylistRunner.run(saved, transport: api, didCheckpoint: { try await journal.record($0) })
        #expect(result.songs.map(\.id) == songs.map(\.id))
        #expect(await api.creates == 1)
        #expect(await api.adds.map(\.count) == [50, 50, 25])
        #expect(await journal.latest?.isComplete == true)
    }

    @Test func unknownCreateResponseNeverRetriesByMatchingPlaylistName() async throws {
        let api = CloudFixture()
        let journal = CloudReceiptFixture()
        await api.configureCreateFailure()
        await #expect(throws: MusicError.network) { try await run(.create(title: "New", songs: []), api, journal) }
        let saved = try #require(await journal.latest)
        #expect(saved.pending?.kind == .create)
        #expect(saved.playlistID == nil)
        await #expect(throws: CloudPlaylistError.unconfirmedCreation) {
            try await CloudPlaylistRunner.run(saved, transport: api)
        }
        #expect(await api.creates == 1)
    }

    @Test func returnedCreateIDIsSavedEvenIfTheProfileChangesDuringTheRequest() async throws {
        let api = CloudFixture()
        let gate = CloudValidationGate()
        let journal = CloudReceiptFixture()
        await api.onCreate { await gate.invalidate() }
        await #expect(throws: CancellationError.self) {
            try await CloudPlaylistRunner.run(.init(operation: .create(title: "New", songs: [cloudSong("a")])),
                transport: api, validate: { try await gate.validate() }, didCheckpoint: { try await journal.record($0) })
        }
        #expect(await journal.latest?.playlistID == "PLtest")
        #expect(await journal.latest?.pending == nil)
        #expect(await api.adds.isEmpty)
    }

    @Test func cancellationWhileSavingTheJournalPreventsTheWrite() async throws {
        let api = CloudFixture()
        let gate = CloudValidationGate()
        let journal = CloudReceiptFixture()
        await journal.whenPending { await gate.invalidate() }
        await #expect(throws: CancellationError.self) {
            try await CloudPlaylistRunner.run(.init(operation: .add(playlistID: "PLtest", songs: [cloudSong("a")])),
                transport: api, validate: { try await gate.validate() }, didCheckpoint: { try await journal.record($0) })
        }
        #expect(await api.adds.isEmpty)
        #expect(await journal.latest?.pending == nil)
    }

    @Test func journalFailureCannotSendAnUnrecoverableMutation() async throws {
        let api = CloudFixture()
        let journal = CloudReceiptFixture()
        await journal.failWrites()
        await #expect(throws: CocoaError.self) { try await run(.create(title: "New", songs: []), api, journal) }
        #expect(await api.creates == 0)
    }

    @Test func anUnconfirmedAddIsCheckedWithoutBeingSentTwice() async throws {
        let api = CloudFixture()
        let journal = CloudReceiptFixture()
        await api.configureAddFailure(1, commits: false)
        await #expect(throws: MusicError.network) { try await run(.add(playlistID: "PLtest", songs: [cloudSong("a")]), api, journal) }
        let saved = try #require(await journal.latest)
        await #expect(throws: CloudPlaylistError.unconfirmedWrite) { try await CloudPlaylistRunner.run(saved, transport: api) }
        #expect(await api.adds.count == 1)
        #expect(await api.snapshot.rows.isEmpty)
    }

    @Test func httpSuccessWithoutTheObservedChangeIsNotReportedAsSynced() async throws {
        let api = CloudFixture()
        let journal = CloudReceiptFixture()
        await api.configureIgnoredWrites()
        await #expect(throws: CloudPlaylistError.unconfirmedWrite) {
            try await run(.add(playlistID: "PLtest", songs: [cloudSong("a")]), api, journal)
        }
        #expect(await journal.latest?.isComplete == false)
        #expect(await journal.latest?.pending?.kind == .add)
    }

    @Test func readOnlyPlaylistDoesNotReceiveWritesBasedOnItsPLPrefix() async throws {
        let api = CloudFixture(owned: false)
        await #expect(throws: CloudPlaylistError.readOnly) { try await run(.add(playlistID: "PLtest", songs: [cloudSong("a")]), api) }
        #expect(await api.adds.isEmpty)
        #expect(await api.permissionQueries == 1)
    }

    @Test func serverProvidedAddPermissionDoesNotGrantRenameOrRemove() async throws {
        let api = CloudFixture(owned: false)
        await api.configurePermissions()
        _ = try await run(.add(playlistID: "PLtest", songs: [cloudSong("a")]), api)
        await #expect(throws: CloudPlaylistError.readOnly) { try await run(.rename(playlistID: "PLtest", previousTitle: "Original", title: "New"), api) }
        #expect(await api.renames.isEmpty)
    }

    @Test func removingOneOccurrencePreservesNewCopiesOfTheSameSong() async throws {
        let old = cloudRow("a", occurrence: "original")
        let addedElsewhere = cloudRow("a", occurrence: "new-on-another-device")
        let api = CloudFixture(rows: [old, cloudRow("b", occurrence: "b"), addedElsewhere])
        let result = try await run(.remove(playlistID: "PLtest", rows: [old]), api)
        #expect(result.rows.map(\.id) == ["b", "new-on-another-device"])
        #expect(await api.removals == [["original"]])
    }

    @Test func missingSelectedOccurrenceDoesNotDeleteAnAlternativeCopy() async throws {
        let api = CloudFixture(rows: [cloudRow("a", occurrence: "different")])
        let result = try await run(.remove(playlistID: "PLtest", rows: [cloudRow("a", occurrence: "gone")]), api)
        #expect(result.rows.map(\.id) == ["different"])
        #expect(await api.removals.isEmpty)
    }

    @Test func missingOccurrenceIDNeverFallsBackToVideoIDRemoval() async throws {
        let row = CloudPlaylistRow(id: "position:0", song: cloudSong("a"))
        let api = CloudFixture(rows: [row])
        await #expect(throws: CloudPlaylistError.missingOccurrenceID) { try await run(.remove(playlistID: "PLtest", rows: [row]), api) }
        #expect(await api.removals.isEmpty)
    }

    @Test func externalRenameIsNotOverwrittenWithAnOldCachedTitle() async throws {
        let api = CloudFixture(title: "Changed elsewhere")
        await #expect(throws: CloudPlaylistError.externalChange) {
            try await run(.rename(playlistID: "PLtest", previousTitle: "Original", title: "My rename"), api)
        }
        #expect(await api.renames.isEmpty)
    }

    @Test func renameIsVerifiedByReadingTheNewRemoteTitle() async throws {
        let api = CloudFixture()
        let result = try await run(.rename(playlistID: "PLtest", previousTitle: "Original", title: "New"), api)
        #expect(result.title == "New")
        #expect(await api.reads == 2)
    }

    @Test func explicitDuplicateOccurrencesInAMergeArePreserved() async throws {
        let api = CloudFixture()
        let result = try await run(.create(title: "Merged", songs: [cloudSong("a"), cloudSong("a"), cloudSong("b")]), api)
        #expect(result.songs.map(\.id) == ["a", "a", "b"])
        #expect(Set(result.rows.compactMap(\.setVideoID)).count == 3)
    }

    @Test func readFailureDoesNotSendAnyWrite() async throws {
        let api = CloudFixture()
        await api.failReadOnce()
        await #expect(throws: MusicError.network) { try await run(.add(playlistID: "PLtest", songs: [cloudSong("a")]), api) }
        #expect(await api.adds.isEmpty)
    }

    @Test func receiptRoundTripPreservesPartialOperationIdentity() throws {
        var receipt = CloudPlaylistCheckpoint(operation: .create(title: "Name", songs: [cloudSong("a")]))
        receipt.playlistID = "PLcreated"
        receipt.pending = .init(kind: .add, videoIDs: ["a"], expectedCounts: ["a": 1], consumedCount: 1)
        #expect(try JSONDecoder().decode(CloudPlaylistCheckpoint.self, from: JSONEncoder().encode(receipt)) == receipt)
    }

    @Test func specialCollectionsCannotBeEditedAsOrdinaryPlaylists() async throws {
        let api = CloudFixture()
        await #expect(throws: CloudPlaylistError.readOnly) {
            try await run(.add(playlistID: "LM", songs: [cloudSong("a")]), api)
        }
        #expect(await api.adds.isEmpty)
    }

    @Test func corruptCompletedCreationWithoutRemoteIDCannotCreateAgain() async throws {
        let api = CloudFixture()
        var saved = CloudPlaylistCheckpoint(operation: .create(title: "New", songs: []))
        saved.isComplete = true
        await #expect(throws: CloudPlaylistError.invalidOperation) {
            try await CloudPlaylistRunner.run(saved, transport: api)
        }
        #expect(await api.creates == 0)
    }
}

@Suite struct CloudPlaylistParsingTests {
    private func root(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
    private func row(_ id: String = "same", setID: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["videoId": id]
        if let setID { data["playlistSetVideoId"] = setID }
        return ["musicResponsiveListItemRenderer": [
            "playlistItemData": data,
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Track", "navigationEndpoint": ["watchEndpoint": ["videoId": id]]]]]]]],
        ]]
    }

    @Test func parsingRetainsDuplicateVideoIDsWithDifferentRemoteOccurrenceIDs() throws {
        let json = JSON(["contents": ["musicPlaylistShelfRenderer": ["contents": [row(setID: "one"), row(setID: "two")]]]])
        let result = try CloudPlaylistPages.rows(json, startingAt: 0)
        #expect(result.rows.map(\.song.id) == ["same", "same"])
        #expect(result.rows.compactMap(\.setVideoID) == ["one", "two"])
    }

    @Test func unknownContinuationShapeCannotPretendThePlaylistIsComplete() throws {
        let malformed = try root(#"{"responseContext":{}}"#)
        #expect(throws: CloudPlaylistError.incompleteResponse) { try CloudPlaylistPages.rows(malformed, startingAt: 50) }
    }

    @Test func malformedResponsiveRowCannotDisappearSilently() throws {
        let malformed = try root(#"{"musicPlaylistShelfContinuation":{"contents":[{"musicResponsiveListItemRenderer":{"playlistItemData":{}}}]}}"#)
        #expect(throws: CloudPlaylistError.incompleteResponse) { try CloudPlaylistPages.rows(malformed, startingAt: 0) }
    }

    @Test func explicitlyUnavailableRowsAreCountedSeparately() throws {
        let value = try root(#"{"musicPlaylistShelfContinuation":{"contents":[{"musicResponsiveListItemRenderer":{"musicItemRendererDisplayPolicy":"MUSIC_ITEM_RENDERER_DISPLAY_POLICY_GREY_OUT"}}]}}"#)
        let result = try CloudPlaylistPages.rows(value, startingAt: 0)
        #expect(result.rows.isEmpty)
        #expect(result.unavailableCount == 1)
    }

    @Test func missingSetIDStillAllowsReadOnlyPlayback() throws {
        let value = JSON(["musicPlaylistShelfRenderer": ["contents": [row("a")]]])
        let result = try CloudPlaylistPages.rows(value, startingAt: 50)
        #expect(result.rows.first?.song.id == "a")
        #expect(result.rows.first?.setVideoID == nil)
        #expect(result.rows.first?.id == "row:50:a")
    }

    @Test func onlyAnExplicitEditorHeaderGrantsMutationCapabilities() throws {
        let ordinary = try root(#"{"header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Mine?"}]}}}}"#)
        #expect(CloudPlaylistPages.first(ordinary, id: "PLmine")?.capabilities.canRename == false)
        let editable = try root(#"{"header":{"musicEditablePlaylistDetailHeaderRenderer":{"header":{"musicResponsiveHeaderRenderer":{"title":{"runs":[{"text":"Mine"}]}}}}}}"#)
        #expect(CloudPlaylistPages.first(editable, id: "PLmine")?.capabilities.canRename == true)
        #expect(CloudPlaylistPages.first(editable, id: "LM")?.capabilities.canRemove == false)
    }

    @Test func explicitEmptyShelfIsAValidCompletePage() throws {
        let value = try root(#"{"musicPlaylistShelfContinuation":{"contents":[]}}"#)
        #expect(try CloudPlaylistPages.rows(value, startingAt: 0).rows.isEmpty)
        #expect(CloudPlaylistPages.continuation(value) == nil)
    }
}
