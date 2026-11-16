import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite struct AccountMirrorTests {
    let a = Song(id: "a", title: "A", artistLine: "X")
    let b = Song(id: "b", title: "B", artistLine: "X")
    let c = Song(id: "c", title: "C", artistLine: "X")

    @Test func theFirstSyncBringsTheAccountInAndKeepsWhatIsOnlyHere() {
        let library = Library(directory: nil)
        library.toggleLike(c)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        #expect(library.liked.map(\.id) == ["a", "b", "c"])
        #expect(mirror.liked == ["a", "b"])
    }

    @Test func somethingRemovedOnTheAccountLeavesHereToo() {
        let library = Library(directory: nil)
        library.toggleLike(c)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b], albums: [AlbumSummary(id: "MPRE1", title: "Al", artistLine: "X")]), mirror: &mirror)
        // Unliked and unsaved on another device.
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror)
        #expect(library.liked.map(\.id) == ["a", "c"])
        #expect(library.albums.isEmpty)
    }

    @Test func anUnlikeNotYetSentIsntLikedAgain() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        library.toggleLike(a)
        mirror.queue(.liked(a, false))
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        #expect(library.liked.map(\.id) == ["b"])
    }

    @Test func aLikeNotYetSentIsntDropped() {
        let library = Library(directory: nil)
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a, b]), mirror: &mirror)
        // Unliked elsewhere, then liked again here while offline.
        mirror.queue(.liked(b, true))
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror)
        #expect(library.isLiked(b))
    }

    @Test func aNewerChangeReplacesTheOlderOne() {
        var mirror = AccountMirror()
        mirror.queue(.liked(a, true))
        mirror.queue(.liked(b, true))
        mirror.queue(.liked(a, false))
        #expect(mirror.pending == [.liked(b, true), .liked(a, false)])
        // An older send finishing doesn't clear the newer change.
        mirror.sent(.liked(a, true))
        #expect(mirror.pending == [.liked(b, true), .liked(a, false)])
        mirror.sent(.liked(a, false))
        #expect(mirror.pending == [.liked(b, true)])
    }

    @Test func survivesARoundTrip() throws {
        var mirror = AccountMirror()
        mirror.liked = ["a"]
        mirror.queue(.album(AlbumSummary(id: "MPRE1", title: "Al", artistLine: "X"), true))
        let data = try JSONEncoder().encode(mirror)
        #expect(try JSONDecoder().decode(AccountMirror.self, from: data) == mirror)
        #expect(try JSONDecoder().decode(AccountMirror.self, from: Data("{}".utf8)) == AccountMirror())
    }

    @Test func mergingDoesNotTellOnChange() {
        let library = Library(directory: nil)
        var told: [LibraryChange] = []
        library.onChange = { told.append($0) }
        var mirror = AccountMirror()
        library.reconcile(with: AccountLibrary(liked: [a]), mirror: &mirror)
        library.reconcile(with: AccountLibrary(), mirror: &mirror)
        #expect(told.isEmpty)
        library.toggleLike(b)
        #expect(told == [.liked(b, true)])
    }

    private func allCollections(_ suffix: String) -> AccountLibrary {
        .init(liked: [.init(id: "song-" + suffix, title: suffix, artistLine: "Artist")],
              albums: [.init(id: "MPRE" + suffix, title: suffix, artistLine: "Artist")],
              playlists: [.init(id: "PL" + suffix, title: suffix)],
              artists: [.init(id: "UC" + suffix, name: suffix)])
    }

    @Test func confirmedCloudRemovalsStillApplyToAllFourCollections() {
        let library = Library(directory: nil)
        let remote = allCollections("remote"), local = allCollections("local")
        library.toggleLike(local.liked[0])
        library.toggleSave(local.albums[0])
        library.toggleSave(local.playlists[0])
        library.toggleSave(local.artists[0])
        var mirror = AccountMirror()
        library.reconcile(with: remote, mirror: &mirror)
        library.reconcile(with: .init(), mirror: &mirror)
        #expect(library.liked == local.liked)
        #expect(library.albums == local.albums)
        #expect(library.playlists == local.playlists)
        #expect(library.artists == local.artists)
        #expect(mirror == AccountMirror())
    }

    @Test func pendingOfflineAddsProtectAllFourCollectionsFromConfirmedRemoteAbsence() {
        let library = Library(directory: nil)
        let remote = allCollections("remote")
        var mirror = AccountMirror()
        library.reconcile(with: remote, mirror: &mirror)
        let changes: [LibraryChange] = [.liked(remote.liked[0], true), .album(remote.albums[0], true),
                                        .playlist(remote.playlists[0], true), .artist(remote.artists[0], true)]
        changes.forEach { mirror.queue($0) }
        library.reconcile(with: .init(), mirror: &mirror)
        #expect(library.liked == remote.liked)
        #expect(library.albums == remote.albums)
        #expect(library.playlists == remote.playlists)
        #expect(library.artists == remote.artists)
        #expect(mirror.pending == changes)
    }

    @Test func pendingOfflineRemovalsAreNotUndoneByACompleteCloudSnapshot() {
        let library = Library(directory: nil)
        let remote = allCollections("remote")
        var mirror = AccountMirror()
        library.reconcile(with: remote, mirror: &mirror)
        library.toggleLike(remote.liked[0])
        library.toggleSave(remote.albums[0])
        library.toggleSave(remote.playlists[0])
        library.toggleSave(remote.artists[0])
        let changes: [LibraryChange] = [.liked(remote.liked[0], false), .album(remote.albums[0], false),
                                        .playlist(remote.playlists[0], false), .artist(remote.artists[0], false)]
        changes.forEach { mirror.queue($0) }
        library.reconcile(with: remote, mirror: &mirror)
        #expect(library.liked.isEmpty && library.albums.isEmpty && library.playlists.isEmpty && library.artists.isEmpty)
        #expect(mirror.pending == changes)
    }
}

