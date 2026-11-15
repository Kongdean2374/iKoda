import Foundation
import Testing
@testable import KodaCore

@Suite struct CloudPlaylistJournalTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-journal-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func knownCreationIDAndUnconfirmedBatchSurviveANewJournal() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receipt = CloudPlaylistCheckpoint(operation: .create(title: "Night", songs: [Song(id: "a", title: "A", artistLine: "X")]))
        receipt.playlistID = "PLremote"
        receipt.pending = .init(kind: .add, videoIDs: ["a"], expectedCounts: ["a": 1], consumedCount: 1)
        try await CloudPlaylistJournal().save(receipt, in: directory)
        #expect(try await CloudPlaylistJournal().load(in: directory) == receipt)
    }

    @Test func anUnknownCreationOutcomeIsNotDroppedAtRelaunch() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var receipt = CloudPlaylistCheckpoint(operation: .create(title: "Night", songs: []))
        receipt.pending = .init(kind: .create, title: "Night")
        try await CloudPlaylistJournal().save(receipt, in: directory)
        let restored = try await CloudPlaylistJournal().load(in: directory)
        #expect(restored?.playlistID == nil)
        #expect(restored?.pending?.kind == .create)
    }

    @Test func malformedReceiptBlocksInsteadOfPretendingNoOperationExists() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appending(path: "cloud-playlist-operation.json"))
        await #expect(throws: CloudPlaylistJournal.Failure.unreadableReceipt) {
            try await CloudPlaylistJournal().load(in: directory)
        }
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "cloud-playlist-operation.json").path))
    }

    @Test func dismissalCannotEraseANewerOperation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CloudPlaylistJournal()
        let old = CloudPlaylistCheckpoint(operation: .create(title: "Old", songs: []))
        let newer = CloudPlaylistCheckpoint(operation: .create(title: "New", songs: []))
        try await journal.save(old, in: directory)
        try await journal.save(newer, in: directory)
        try await journal.archive(id: old.id, in: directory)
        #expect(try await journal.load(in: directory) == newer)
    }

    @Test func archiveRetainsTheReceiptAsABackup() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CloudPlaylistJournal()
        var receipt = CloudPlaylistCheckpoint(operation: .create(title: "Saved", songs: []))
        receipt.playlistID = "PLsaved"
        receipt.isComplete = true
        try await journal.save(receipt, in: directory)
        try await journal.archive(id: receipt.id, in: directory)
        #expect(try await journal.load(in: directory) == nil)
        let backup = try String(contentsOf: directory.appending(path: "cloud-playlist-operation-backup.json"), encoding: .utf8)
        #expect(backup.contains("PLsaved"))
    }

    @Test func profilesNeverShareReceiptsOrCatalogs() async throws {
        let first = try directory(), second = try directory()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let journal = CloudPlaylistJournal()
        let receipt = CloudPlaylistCheckpoint(operation: .create(title: "Private", songs: []))
        try await journal.save(receipt, in: first)
        try await journal.saveCatalog(.init(playlists: [.init(id: "PLone", title: "One")], fetchedAt: Date()), session: UUID(), revision: 1, in: first)
        #expect(try await journal.load(in: second) == nil)
        #expect(await journal.loadCatalog(in: second) == nil)
        #expect(await journal.loadCatalog(in: first)?.playlists.map(\.id) == ["PLone"])
    }

    @Test func receiptWriteFailureIsReportedBeforeAnyCallerMayWriteRemotely() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = parent.appending(path: "not-a-directory")
        try Data().write(to: file)
        let receipt = CloudPlaylistCheckpoint(operation: .create(title: "No Write", songs: []))
        await #expect(throws: CloudPlaylistJournal.Failure.storageUnavailable) {
            try await CloudPlaylistJournal().save(receipt, in: file)
        }
    }

    @Test func anOlderCatalogTaskArrivingLateCannotOverwriteANewerRead() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CloudPlaylistJournal(), session = UUID()
        try await journal.saveCatalog(.init(playlists: [.init(id: "PLnew", title: "New")], fetchedAt: Date()),
                                      session: session, revision: 2, in: directory)
        try await journal.saveCatalog(.init(playlists: [.init(id: "PLold", title: "Old")], fetchedAt: Date()),
                                      session: session, revision: 1, in: directory)
        #expect(await journal.loadCatalog(in: directory)?.playlists.map(\.id) == ["PLnew"])
    }
}

@MainActor @Suite struct CloudPlaylistCatalogTests {
    @Test func remoteRenameRefreshesMetadataWithoutDroppingLocalBookmarks() {
        let library = Library(directory: nil)
        library.toggleSave(PlaylistSummary(id: "PLremote", title: "Old"))
        library.toggleSave(PlaylistSummary(id: "PLbookmark", title: "Local bookmark"))
        library.applyCloudPlaylistCatalog([.init(id: "PLremote", title: "Renamed")], previousCloudIDs: ["PLremote"])
        #expect(library.playlists.first?.title == "Renamed")
        #expect(library.playlists.map(\.id) == ["PLremote", "PLbookmark"])
    }

    @Test func onlyPreviouslyKnownCloudEntriesDisappearAndNoWriteIsQueued() {
        let library = Library(directory: nil)
        library.toggleSave(PlaylistSummary(id: "PLgone", title: "Gone"))
        library.toggleSave(PlaylistSummary(id: "PLlocal", title: "Local"))
        var changes = 0
        library.onChange = { _ in changes += 1 }
        library.applyCloudPlaylistCatalog([], previousCloudIDs: ["PLgone"])
        #expect(library.playlists.map(\.id) == ["PLlocal"])
        #expect(changes == 0)
    }

    @Test func authoritativeCloudCatalogNeverChangesLegacyLocalPlaylists() {
        let library = Library(directory: nil)
        let song = Song(id: "local-song", title: "Local", artistLine: "Artist")
        let original = library.createPlaylist(named: "Legacy", songs: [song, song])
        library.applyCloudPlaylistCatalog([.init(id: "PLcloud", title: "Cloud")], previousCloudIDs: [])
        #expect(library.userPlaylists == [original])
        library.applyCloudPlaylistCatalog([], previousCloudIDs: ["PLcloud"])
        #expect(library.userPlaylists == [original])
    }

    @Test func cloudMetadataRefreshCannotUndoAnUnsentUnsaveAfterReconcile() {
        let library = Library(directory: nil)
        let playlist = PlaylistSummary(id: "PLpending", title: "Still remote")
        library.toggleSave(playlist)
        library.toggleSave(playlist)
        var mirror = AccountMirror()
        mirror.playlists = [playlist.id]
        mirror.queue(.playlist(playlist, false))
        let remote = AccountLibrary(playlists: [playlist])
        library.reconcile(with: remote, mirror: &mirror)
        #expect(!library.isSaved(playlist: playlist.id))
        library.applyCloudPlaylistCatalog(remote.playlists, previousCloudIDs: [playlist.id], pending: mirror.pending)
        #expect(!library.isSaved(playlist: playlist.id))
        #expect(mirror.pending == [.playlist(playlist, false)])
    }

    @Test func forcedCloudRefreshPreservesAnUnsentSaveMissingRemotely() {
        let library = Library(directory: nil)
        let playlist = PlaylistSummary(id: "PLpending", title: "Saved offline")
        library.toggleSave(playlist)
        var mirror = AccountMirror()
        mirror.queue(.playlist(playlist, true))
        library.applyCloudPlaylistCatalog([], previousCloudIDs: [playlist.id], pending: mirror.pending)
        #expect(library.playlists == [playlist])
        #expect(mirror.pending == [.playlist(playlist, true)])
    }
}
