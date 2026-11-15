import Foundation
import Testing
@testable import KodaCore

private func catalogJSON(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }
private func catalogPlaylist(_ id: String, title: String? = nil) -> PlaylistSummary {
    .init(id: id, title: title ?? id)
}

private actor CatalogPageFixture {
    let pages: [String: CloudPlaylistCatalogPage]
    let failure: String?
    let cancellation: Bool
    let failureError: MusicError
    private(set) var calls: [String] = []

    init(pages: [String: CloudPlaylistCatalogPage], failure: String? = nil, cancellation: Bool = false,
         failureError: MusicError = .network) {
        self.pages = pages
        self.failure = failure
        self.cancellation = cancellation
        self.failureError = failureError
    }

    func fetch(_ cursor: String?) throws -> CloudPlaylistCatalogPage {
        let key = cursor ?? "first"
        calls.append(key)
        if key == failure {
            if cancellation { throw CancellationError() }
            throw failureError
        }
        guard let page = pages[key] else { throw MusicError.badResponse(500) }
        return page
    }
}

@Suite struct CloudPlaylistCompatibilityTests {
    // Reduced service shapes, not a capture of the user's account. Title navigation
    // follows sigma67/ytmusicapi parsers/browsing.py parse_playlist. Container/control
    // shapes also appear in TeamPiped/rustypipe testfiles/music_userdata/saved_playlists.json
    // and nick42d/youtui ytmapi-rs/test_json/get_library_playlists.json.
    @Test func titleLinkedCloudCardIsNotRejectedAsAnUnknownPlaylist() throws {
        let value = try catalogJSON(#"{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"Travel","navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLtravel"}}}]},"subtitle":{"runs":[{"text":"Owner","navigationEndpoint":{"browseEndpoint":{"browseId":"UCowner"}}}]}}}]}}"#)
        let strict = try AccountPages.completeLibraryItems(value)
        #expect(strict.count == 1)
        guard case .playlist(let playlist) = strict[0] else { Issue.record("Expected a playlist"); return }
        #expect(playlist.id == "PLtravel")
        #expect(playlist.title == "Travel")
        let display = AccountPages.playlistCatalogPage(value)
        #expect(display.playlists == [playlist])
        #expect(display.issues.isEmpty)
    }

    @Test func titleLinkedListRowKeepsItsPlaylistIdentity() throws {
        let value = try catalogJSON(#"{"musicShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Evening","navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLnight"}}}]}}},{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Owner","navigationEndpoint":{"browseEndpoint":{"browseId":"UCowner"}}}]}}}]}}]}}"#)
        #expect(try AccountPages.completeLibraryItems(value).count == 1)
        #expect(AccountPages.playlistCatalogPage(value).playlists.map(\.id) == ["PLnight"])
    }

    @Test func conflictingTitleLinksDoNotInventAPlaylistIdentity() throws {
        let value = try catalogJSON(#"{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"One","navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLone"}}},{"text":"Two","navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLtwo"}}}]}}}]}}"#)
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(value) }
        #expect(AccountPages.playlistCatalogPage(value).playlists.isEmpty)
        #expect(AccountPages.playlistCatalogPage(value).issues == [.unrecognizedEntries(1)])
    }

    @Test func newPlaylistTitleCommandIsAControlRatherThanAMissingPlaylist() throws {
        let value = try catalogJSON(#"{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"runs":[{"text":"New playlist","navigationEndpoint":{"createPlaylistEndpoint":{}}}]}}}]}}"#)
        #expect(try AccountPages.completeLibraryItems(value).isEmpty)
        #expect(AccountPages.playlistCatalogPage(value).issues.isEmpty)
    }

    @Test func unknownCardRetainsKnownIDsForDisplayButCannotAuthorizeAFullReplace() throws {
        let value = try catalogJSON(#"{"gridRenderer":{"items":[{"unknownPlaylistRenderer":{"id":"PLunknown"}},{"musicTwoRowItemRenderer":{"title":{"simpleText":"Known"},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLknown"}}}},{"continuationItemRenderer":{"continuationEndpoint":{"continuationCommand":{"token":"next"}}}}]}}"#)
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(value) }
        let page = AccountPages.playlistCatalogPage(value)
        #expect(page.playlists.map(\.id) == ["PLknown"])
        #expect(page.continuation == "next")
        #expect(page.issues == [.unrecognizedEntries(1)])
    }

    @Test func unknownOrMalformedPageIsNotACompleteEmptyDirectory() throws {
        for text in [#"{"messageRenderer":{"text":{"simpleText":"Sign in"}}}"#,
                     #"{"gridRenderer":{}}"#, #"{"gridContinuation":{"items":null}}"#] {
            let page = AccountPages.playlistCatalogPage(try catalogJSON(text))
            #expect(page.playlists.isEmpty)
            #expect(page.issues.contains(.unrecognizedPage))
        }
    }

    @Test func sectionReloadTokenDoesNotBecomeAnotherPlaylistPage() throws {
        // rustypipe's saved_playlists fixture uses this exact outer response family.
        // The outer reload token changes sort/filter state; it is not pagination.
        let value = try catalogJSON(#"{"continuationContents":{"sectionListContinuation":{"contents":[{"gridRenderer":{"items":[]}}],"continuations":[{"reloadContinuationData":{"continuation":"reload"}}]}}}"#)
        let page = AccountPages.playlistCatalogPage(value)
        #expect(page.issues.isEmpty)
        #expect(page.continuation == nil)
        #expect(try AccountPages.completeLibraryItems(value).isEmpty)
    }

    @Test func malformedNextTokenRetainsReadableCardsWithoutClaimingCompleteness() throws {
        let value = try catalogJSON(#"{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"simpleText":"Known"},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLknown"}}}}],"continuations":[{"nextContinuationData":{}}]}}"#)
        let page = AccountPages.playlistCatalogPage(value)
        #expect(page.playlists.map(\.id) == ["PLknown"])
        #expect(page.issues == [.invalidContinuation])
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(value) }
    }

    @Test func partialPageStillLoadsEveryKnownFollowingPageOnce() async throws {
        let fixture = CatalogPageFixture(pages: [
            "first": .init(playlists: [catalogPlaylist("a")], continuation: "two", issues: [.unrecognizedEntries(1)]),
            "two": .init(playlists: [catalogPlaylist("b")], continuation: "three"),
            "three": .init(playlists: [catalogPlaylist("c")], continuation: nil),
        ])
        let result = try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) }
        #expect(result.playlists.map(\.id) == ["a", "b", "c"])
        #expect(!result.isComplete)
        #expect(result.displayMessage != nil)
        #expect(await fixture.calls == ["first", "two", "three"])
    }

    @Test func laterNetworkFailureKeepsKnownCardsAsExplicitlyPartial() async throws {
        let fixture = CatalogPageFixture(pages: ["first": .init(playlists: [catalogPlaylist("a")], continuation: "two")], failure: "two")
        let result = try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) }
        #expect(result.playlists.map(\.id) == ["a"])
        #expect(result.issues == [.pageRequestFailed])
        #expect(await fixture.calls == ["first", "two"])
    }

    @Test func firstPageNetworkFailureStillPropagates() async throws {
        let fixture = CatalogPageFixture(pages: [:], failure: "first")
        await #expect(throws: MusicError.network) { try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) } }
    }

    @Test func cancellationNeverPublishesAnOldPartialResult() async throws {
        let fixture = CatalogPageFixture(pages: ["first": .init(playlists: [catalogPlaylist("a")], continuation: "two")], failure: "two", cancellation: true)
        await #expect(throws: CancellationError.self) { try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) } }
    }

    @Test func expiredAuthorizationIsNotConvertedIntoSuccessWithPartialCards() async throws {
        let fixture = CatalogPageFixture(pages: ["first": .init(playlists: [catalogPlaylist("a")], continuation: "two")],
                                         failure: "two", failureError: .signedOut)
        await #expect(throws: MusicError.signedOut) { try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) } }
    }

    @Test func catalogCompatibilityDoesNotRelaxSongReadbackRequirements() throws {
        let tracks = try catalogJSON(#"{"musicPlaylistShelfRenderer":{"contents":[{"musicResponsiveListItemRenderer":{"playlistItemData":{"videoId":"a","playlistSetVideoId":"set-a"},"flexColumns":[{"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"Track"}]}}}]}},{"unknownTrackRenderer":{"videoId":"b"}}]}}"#)
        #expect(throws: CloudPlaylistError.incompleteResponse) { try CloudPlaylistPages.rows(tracks, startingAt: 0) }
        let catalog = try catalogJSON(#"{"gridRenderer":{"items":[{"musicTwoRowItemRenderer":{"title":{"simpleText":"Known"},"navigationEndpoint":{"browseEndpoint":{"browseId":"VLPLknown"}}}}]}}"#)
        #expect(AccountPages.playlistCatalogPage(catalog).playlists.count == 1)
        #expect(throws: CloudPlaylistError.incompleteResponse) { try CloudPlaylistPages.rows(catalog, startingAt: 0) }
    }

    @Test func repeatedCursorStopsWithoutDiscardingTheDirectory() async throws {
        let fixture = CatalogPageFixture(pages: [
            "first": .init(playlists: [catalogPlaylist("a")], continuation: "two"),
            "two": .init(playlists: [catalogPlaylist("b")], continuation: "two"),
        ])
        let result = try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) }
        #expect(result.playlists.map(\.id) == ["a", "b"])
        #expect(result.issues == [.repeatedContinuation])
        #expect(await fixture.calls.count == 2)
    }

    @Test func pageLimitReturnsPartialProgressRatherThanAnApparentlyFullList() async throws {
        let fixture = CatalogPageFixture(pages: ["first": .init(playlists: [catalogPlaylist("a")], continuation: "two")])
        let result = try await CloudPlaylistCatalogLoader.load(limits: .init(maxPages: 1, maxPlaylists: 100)) { try await fixture.fetch($0) }
        #expect(result.playlists.map(\.id) == ["a"])
        #expect(result.issues == [.pageLimitReached])
    }

    @Test func playlistLimitDoesNotPretendThatRemainingCardsWereDeleted() async throws {
        let fixture = CatalogPageFixture(pages: ["first": .init(playlists: [catalogPlaylist("a"), catalogPlaylist("b")], continuation: nil)])
        let result = try await CloudPlaylistCatalogLoader.load(limits: .init(maxPages: 10, maxPlaylists: 1)) { try await fixture.fetch($0) }
        #expect(result.playlists.map(\.id) == ["a"])
        #expect(result.issues == [.playlistLimitReached])
    }

    @Test func partialDirectoryDoesNotRemoveEntriesFromTheCompleteCache() {
        let previous = [catalogPlaylist("a", title: "Old title"), catalogPlaylist("b")]
        let result = CloudPlaylistCatalogResult(playlists: [catalogPlaylist("a", title: "New title"), catalogPlaylist("c")], issues: [.unrecognizedEntries(1)])
        let display = result.mergingForDisplay(previous: previous)
        #expect(display.map(\.id) == ["a", "c", "b"])
        #expect(display.first?.title == "New title")
        #expect(previous.first?.title == "Old title")
        #expect(!result.isComplete)
    }

    @Test func confirmedEmptyDirectoryCanReplaceTheOldCache() async throws {
        let fixture = CatalogPageFixture(pages: ["first": .init(playlists: [], continuation: nil)])
        let result = try await CloudPlaylistCatalogLoader.load { try await fixture.fetch($0) }
        #expect(result.isComplete)
        #expect(result.mergingForDisplay(previous: [catalogPlaylist("old")]).isEmpty)
        #expect(result.displayMessage == nil)
    }
}
