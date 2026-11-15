import Foundation
import Testing
@testable import KodaCore

@Suite struct PlaylistToolsTests {
    private func song(_ id: String, _ title: String = "Song", artist: String = "Artist", album: String = "Album", duration: Double? = 180) -> Song {
        Song(id: id, title: title, artistLine: artist, album: AlbumRef(id: "album", title: album), duration: duration)
    }

    @Test func selectionTracksOccurrencesAndRejectsInvalidIndices() {
        let songs = [song("a"), song("a"), song("b")]
        var selection = PlaylistSongSelection(count: songs.count)
        selection.toggle(1); selection.toggle(-1); selection.toggle(3)
        #expect(selection.selectedIndices == [1])
        #expect(selection.selectedSongs(from: songs) == [songs[1]])
        selection.selectAll()
        #expect(selection.selectedIndices == [0, 1, 2])
        selection.toggle(1)
        #expect(selection.selectedIndices == [0, 2])
        selection.clear()
        #expect(selection.selectedIndices.isEmpty)
    }

    @Test func emptySelectionAndLargeSelectionAreBounded() {
        var empty = PlaylistSongSelection(count: -1); empty.selectAll()
        #expect(empty.selectedIndices.isEmpty)
        var large = PlaylistSongSelection(count: 10_000); large.selectAll()
        #expect(large.selectedIndices.count == 10_000)
        large.clear()
        #expect(large.selectedIndices.isEmpty)
    }

    @Test func mergePreservesSourceOrderWithOptionalStableIDExclusion() async throws {
        let a = song("a"), b = song("b"), c = song("c")
        let all = try await PlaylistTools.merge([[a, b], [b, c, a]], excludingExactDuplicates: false)
        let unique = try await PlaylistTools.merge([[a, b], [b, c, a]], excludingExactDuplicates: true)
        #expect(all.map(\.id) == ["a", "b", "b", "c", "a"])
        #expect(unique.map(\.id) == ["a", "b", "c"])
    }

    @Test func emptyIDsAreNeverExcludedAutomatically() async throws {
        let anonymous = song("")
        let merged = try await PlaylistTools.merge([[anonymous, anonymous]], excludingExactDuplicates: true)
        #expect(merged.count == 2)
        let groups = try await PlaylistTools.duplicateGroups(in: [anonymous, anonymous])
        #expect(!groups.contains { $0.kind == .exact })
    }

    @Test func stableIDIsTheOnlyExactDuplicateSignal() async throws {
        let groups = try await PlaylistTools.duplicateGroups(in: [song("a"), song("a", "Retitled"), song("b"), song("c")])
        #expect(groups.contains { $0.kind == .exact && $0.indices == [0, 1] })
        #expect(groups.contains { $0.kind == .possibleMatch && $0.indices == [0, 2, 3] })
    }

    @Test(arguments: ["Live", "Remix", "Cover", "Instrumental", "Acoustic", "現場", "伴奏"])
    func versionsAreSuggestionsAndNeverExact(_ edition: String) async throws {
        let groups = try await PlaylistTools.duplicateGroups(in: [song("a"), song("b", "Song (\(edition))")])
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .differentVersions)
    }

    @Test func metadataNormalizationDoesNotMergeDifferentArtistsAlbumsOrLengths() async throws {
        let groups = try await PlaylistTools.duplicateGroups(in: [
            song("a", "ＳＯＮＧ"), song("b", "song", artist: "artist", duration: 181),
            song("other-artist", artist: "Someone Else"), song("other-album", album: "Other"), song("long", duration: 250)
        ])
        #expect(groups.map(\.indices) == [[0, 1]])
        #expect(groups.first?.kind == .possibleMatch)
    }

    @Test func missingMetadataCannotProveADuplicate() async throws {
        let groups = try await PlaylistTools.duplicateGroups(in: [song("a", duration: nil), song("b", duration: nil), song("c", artist: "")])
        #expect(groups.isEmpty)
    }

    @Test func mergeCancellationStopsBeforeReturningAnIncompletePlaylist() async throws {
        let source = (0..<20_000).map { song("\($0)") }
        let task = Task { try await PlaylistTools.merge([source, source], excludingExactDuplicates: false) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled merge returned songs") }
        catch is CancellationError {}
    }

    @Test func largeMergeDoesNotLoseOrReorderSongs() async throws {
        let source = (0..<5_000).map { song("\($0)") }
        let result = try await PlaylistTools.merge([source, source], excludingExactDuplicates: true)
        #expect(result == source)
    }
}

@MainActor
@Suite struct PlaylistTransactionTests {
    private func song(_ id: String) -> Song { Song(id: id, title: id, artistLine: "Artist") }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "playlist-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func mergedOccurrencesSurviveRelaunchWithoutChangingLegacyAdd() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        let a = song("a"), b = song("b")
        let receipt = try await library.applyPlaylistEdit(.create(name: "Merged", songs: [a, b, a], excludingExactDuplicates: false))
        #expect(Library(directory: dir).userPlaylist(receipt.playlistID)?.songs.map(\.id) == ["a", "b", "a"])
        let old = library.createPlaylist(named: "Legacy", songs: [a, a])
        #expect(old.songs.count == 1)
        let added = library.add([a], toPlaylist: old.id)
        #expect(added == 0)
    }

    @Test func copyAndMoveAreLocalOnlyAndPersistAsOneChange() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        let source = library.createPlaylist(named: "Source", songs: [song("a"), song("b"), song("c")])
        let target = library.createPlaylist(named: "Target", songs: [song("c")])
        var cloudWrites = 0
        library.onChange = { _ in cloudWrites += 1 }
        let copy = try await library.applyPlaylistEdit(.copy(songs: [song("c"), song("d"), song("d")], to: target.id))
        #expect(copy.affectedCount == 1)
        let snapshot = try #require(library.playlistSnapshot(source.id))
        let move = try await library.applyPlaylistEdit(.move(source: snapshot, indices: [0, 2], to: target.id))
        #expect(move.affectedCount == 2)
        let reopened = Library(directory: dir)
        #expect(reopened.userPlaylist(source.id)?.songs.map(\.id) == ["b"])
        #expect(reopened.userPlaylist(target.id)?.songs.map(\.id) == ["c", "d", "a"])
        #expect(cloudWrites == 0)
    }

    @Test func removalTargetsOneOccurrenceAndUndoPreservesLaterAppends() async throws {
        let library = Library(directory: nil)
        let created = try await library.applyPlaylistEdit(.create(name: "Repeated", songs: [song("a"), song("b"), song("a")], excludingExactDuplicates: false))
        let snapshot = try #require(library.playlistSnapshot(created.playlistID))
        let removed = try await library.applyPlaylistEdit(.remove(source: snapshot, indices: [2]))
        #expect(library.userPlaylist(created.playlistID)?.songs.map(\.id) == ["a", "b"])
        library.add([song("new")], toPlaylist: created.playlistID)
        let undo = try #require(removed.undo)
        try await library.undoPlaylistEdit(undo)
        #expect(library.userPlaylist(created.playlistID)?.songs.map(\.id) == ["a", "b", "a", "new"])
        await #expect(throws: PlaylistEditError.cannotUndo) { try await library.undoPlaylistEdit(undo) }
    }

    @Test func moveUndoRestoresBothListsWithoutDiscardingNewSongs() async throws {
        let library = Library(directory: nil)
        let source = library.createPlaylist(named: "Source", songs: [song("a"), song("b")])
        let target = library.createPlaylist(named: "Target", songs: [song("c")])
        let snapshot = try #require(library.playlistSnapshot(source.id))
        let receipt = try await library.applyPlaylistEdit(.move(source: snapshot, indices: [0], to: target.id))
        library.add([song("later-source")], toPlaylist: source.id)
        library.add([song("later-target")], toPlaylist: target.id)
        try await library.undoPlaylistEdit(#require(receipt.undo))
        #expect(library.userPlaylist(source.id)?.songs.map(\.id) == ["a", "b", "later-source"])
        #expect(library.userPlaylist(target.id)?.songs.map(\.id) == ["c", "later-target"])
    }

    @Test func undoRejectsLaterReorderingWithoutOverwritingIt() async throws {
        let library = Library(directory: nil)
        let playlist = library.createPlaylist(named: "P", songs: [song("a"), song("b"), song("c")])
        let snapshot = try #require(library.playlistSnapshot(playlist.id))
        let receipt = try await library.applyPlaylistEdit(.remove(source: snapshot, indices: [0]))
        library.moveSongs(fromOffsets: [0], toOffset: 2, inPlaylist: playlist.id)
        let current = library.userPlaylist(playlist.id)?.songs
        await #expect(throws: PlaylistEditError.cannotUndo) { try await library.undoPlaylistEdit(#require(receipt.undo)) }
        #expect(library.userPlaylist(playlist.id)?.songs == current)
    }

    @Test func staleSourceAndMissingDestinationDoNotDeleteAnything() async throws {
        let library = Library(directory: nil)
        let source = library.createPlaylist(named: "P", songs: [song("a"), song("b")])
        let snapshot = try #require(library.playlistSnapshot(source.id))
        library.add([song("new")], toPlaylist: source.id)
        await #expect(throws: PlaylistEditError.libraryChanged) { try await library.applyPlaylistEdit(.remove(source: snapshot, indices: [0])) }
        let current = try #require(library.playlistSnapshot(source.id))
        await #expect(throws: PlaylistEditError.playlistMissing) { try await library.applyPlaylistEdit(.move(source: current, indices: [0], to: UUID())) }
        #expect(library.userPlaylist(source.id)?.songs.map(\.id) == ["a", "b", "new"])
    }

    @Test func mergeValidatesEveryLocalSourceBeforeCreatingAnything() async throws {
        let library = Library(directory: nil)
        let source = library.createPlaylist(named: "P", songs: [song("a")])
        let snapshot = try #require(library.playlistSnapshot(source.id))
        library.deletePlaylist(source.id)
        await #expect(throws: PlaylistEditError.playlistMissing) {
            try await library.applyPlaylistEdit(.create(name: "Merged", songs: snapshot.songs, excludingExactDuplicates: false), validating: [snapshot])
        }
        #expect(library.userPlaylists.isEmpty)
    }

    @Test func profileChangeInvalidatesOldSelectionsAndUndo() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: nil)
        let source = library.createPlaylist(named: "P", songs: [song("a"), song("b")])
        let snapshot = try #require(library.playlistSnapshot(source.id))
        let receipt = try await library.applyPlaylistEdit(.remove(source: snapshot, indices: [0]))
        library.open(directory: dir)
        await #expect(throws: PlaylistEditError.wrongProfile) { try await library.applyPlaylistEdit(.remove(source: snapshot, indices: [0])) }
        await #expect(throws: PlaylistEditError.wrongProfile) { try await library.undoPlaylistEdit(#require(receipt.undo)) }
        #expect(library.userPlaylists.isEmpty)
    }

    @Test func failedDiskWriteKeepsBothListsUnchanged() async throws {
        let parent = try directory(); defer { try? FileManager.default.removeItem(at: parent) }
        let notDirectory = parent.appending(path: "file")
        try Data("not a directory".utf8).write(to: notDirectory)
        let library = Library(directory: notDirectory)
        let source = library.createPlaylist(named: "Source", songs: [song("a")])
        let target = library.createPlaylist(named: "Target")
        let snapshot = try #require(library.playlistSnapshot(source.id))
        do {
            _ = try await library.applyPlaylistEdit(.move(source: snapshot, indices: [0], to: target.id))
            Issue.record("An unwritable transaction succeeded")
        } catch { #expect(!(error is PlaylistEditError)) }
        #expect(library.userPlaylist(source.id)?.songs.map(\.id) == ["a"])
        #expect(library.userPlaylist(target.id)?.songs.isEmpty == true)
    }

    @Test func cancellationBeforeCommitDoesNotPublishPartialChanges() async throws {
        let library = Library(directory: nil)
        let task = Task { try await library.applyPlaylistEdit(.create(name: "Cancelled", songs: [song("a")], excludingExactDuplicates: false)) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled transaction succeeded") }
        catch is CancellationError {}
        #expect(library.userPlaylists.isEmpty)
    }

    @Test func oldLibraryFilesStillDecodeAndCanBeManaged() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"liked":[],"userPlaylists":[]}"#.utf8).write(to: dir.appending(path: "library.json"))
        let library = Library(directory: dir)
        let receipt = try await library.applyPlaylistEdit(.create(name: "New", songs: [song("a")], excludingExactDuplicates: true))
        #expect(Library(directory: dir).userPlaylist(receipt.playlistID)?.songs.count == 1)
    }

    @Test func oldPreparedSaveCannotOverwriteNewTransactionOrFlush() throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "library.json"), clock = SaveClock()
        let oldVersion = clock.next()
        let oldFile = try PreparedLibraryFile.prepare(Data("old".utf8), for: file)
        defer { try? FileManager.default.removeItem(at: oldFile) }
        let newFile = try PreparedLibraryFile.prepare(Data("transaction".utf8), for: file)
        let committed = try clock.commit(oldVersion, advancing: true) { try PreparedLibraryFile.publish(newFile, to: file) }
        let stale = try clock.commit(oldVersion) { try PreparedLibraryFile.publish(oldFile, to: file) }
        #expect(committed && !stale)
        #expect(try String(contentsOf: file, encoding: .utf8) == "transaction")
        let flushVersion = clock.next()
        let flushed = try PreparedLibraryFile.prepare(Data("flush".utf8), for: file)
        try clock.commit(flushVersion) { try PreparedLibraryFile.publish(flushed, to: file) }
        let stillStale = try clock.commit(oldVersion) { try PreparedLibraryFile.publish(oldFile, to: file) }
        #expect(!stillStale)
        #expect(try String(contentsOf: file, encoding: .utf8) == "flush")
    }

    @Test func listeningAddedDuringPreparationCannotBeLostAtCommit() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        let current = song("playing")
        let prepared = try await library.preparePlaylistEdit(.create(name: "Pending", songs: [current], excludingExactDuplicates: false))
        library.addListening(12, to: current)
        #expect(throws: PlaylistEditError.libraryChanged) { try library.commitPlaylistEdit(prepared) }
        #expect(library.userPlaylists.isEmpty)
        library.flush()
        #expect(Library(directory: dir).songStats[current.id]?.seconds == 12)
    }

    @Test func inMemoryEditsAlsoInvalidatePreparedTransactions() async throws {
        let library = Library(directory: nil)
        let source = library.createPlaylist(named: "Original", songs: [song("a")])
        let prepared = try await library.preparePlaylistEdit(.copy(songs: [song("pending")], to: source.id))
        library.add([song("newer")], toPlaylist: source.id)
        #expect(throws: PlaylistEditError.libraryChanged) { try library.commitPlaylistEdit(prepared) }
        #expect(library.userPlaylist(source.id)?.songs.map(\.id) == ["a", "newer"])
    }

    @Test func profileSwitchBetweenPreparationAndPublicationCannotWriteNewProfile() async throws {
        let first = try directory(), second = try directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let library = Library(directory: first)
        let prepared = try await library.preparePlaylistEdit(.create(name: "Pending", songs: [song("a")], excludingExactDuplicates: false))
        library.open(directory: second)
        #expect(throws: PlaylistEditError.wrongProfile) { try library.commitPlaylistEdit(prepared) }
        #expect(library.userPlaylists.isEmpty)
        #expect(Library(directory: first).userPlaylists.isEmpty)
        #expect(Library(directory: second).userPlaylists.isEmpty)
    }

    @Test func cancellationAfterEncodingStillPreventsPublication() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        let prepared = try await library.preparePlaylistEdit(.create(name: "Pending", songs: [song("a")], excludingExactDuplicates: false))
        let task = Task { try library.commitPlaylistEdit(prepared) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled prepared change was published") }
        catch is CancellationError {}
        #expect(library.userPlaylists.isEmpty)
        #expect(Library(directory: dir).userPlaylists.isEmpty)
    }

    @Test func unpublishedTemporaryFilesAreRemovedWhenPreparationIsDiscarded() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        var prepared: PreparedPlaylistEdit? = try await library.preparePlaylistEdit(.create(name: "Pending", songs: [song("a")], excludingExactDuplicates: false))
        let path = try #require(prepared?.temporary?.path)
        #expect(FileManager.default.fileExists(atPath: path))
        prepared = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func failedAtomicPublicationDoesNotChangeMemory() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let library = Library(directory: dir)
        let prepared = try await library.preparePlaylistEdit(.create(name: "Pending", songs: [song("a")], excludingExactDuplicates: false))
        try FileManager.default.createDirectory(at: dir.appending(path: "library.json"), withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try library.commitPlaylistEdit(prepared) }
        #expect(library.userPlaylists.isEmpty)
    }

    @Test func onlyRecentUndoTokensRemainUsable() async throws {
        let library = Library(directory: nil)
        let playlist = library.createPlaylist(named: "P")
        var first: PlaylistUndoToken?
        for index in 0..<65 {
            let result = try await library.applyPlaylistEdit(.copy(songs: [song("\(index)")], to: playlist.id))
            if index == 0 { first = result.undo }
        }
        let token = try #require(first)
        await #expect(throws: PlaylistEditError.cannotUndo) { try await library.undoPlaylistEdit(token) }
        #expect(library.userPlaylist(playlist.id)?.songs.count == 65)
    }
}
