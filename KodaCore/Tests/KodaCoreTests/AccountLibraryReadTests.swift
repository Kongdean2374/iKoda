import Foundation
import Testing
@testable import KodaCore

private let accountKinds: [LibraryChange.Kind] = [.liked, .album, .playlist, .artist]

private func libraryRow(_ kind: LibraryChange.Kind, id: String) -> [String: Any] {
    let title: [String: Any] = ["runs": [["text": "Item " + id]]]
    if kind == .liked {
        return ["musicResponsiveListItemRenderer": [
            "playlistItemData": ["videoId": id],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": title]]],
        ]]
    }
    let browseID: String = switch kind {
    case .album: "MPRE" + id
    case .playlist: "VLPL" + id
    case .artist: "UC" + id
    case .liked: id
    }
    if kind == .artist {
        return ["musicResponsiveListItemRenderer": [
            "navigationEndpoint": ["browseEndpoint": ["browseId": browseID]],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": title]]],
        ]]
    }
    return ["musicTwoRowItemRenderer": ["title": title,
        "navigationEndpoint": ["browseEndpoint": ["browseId": browseID]]]]
}

private func libraryPage(_ kind: LibraryChange.Kind, ids: [String], next: String? = nil,
                         continuationPage: Bool = false, extra: [[String: Any]] = []) throws -> Data {
    let shelf = kind == .liked || kind == .artist
    let key = shelf ? (continuationPage ? "musicShelfContinuation" : "musicShelfRenderer")
        : (continuationPage ? "gridContinuation" : "gridRenderer")
    var contents = ids.map { libraryRow(kind, id: $0) } + extra
    if let next { contents.append(["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": next]]]]) }
    return try JSONSerialization.data(withJSONObject: [key: [shelf ? "contents" : "items": contents]])
}

private final class AccountReadScript: @unchecked Sendable {
    enum Response: Sendable { case data(Data), networkFailure }
    private let lock = NSLock()
    private var responses: [Response]
    private var calls = 0

    init(_ responses: [Response]) { self.responses = responses }
    func next() -> Response {
        lock.withLock {
            calls += 1
            return responses.isEmpty ? .networkFailure : responses.removeFirst()
        }
    }
    var count: Int { lock.withLock { calls } }
}

/// Intercepts every request from this test's URLSession. No actual YouTube request
/// or account credential is used. Each visitor ID routes to a separate test script.
private final class AccountReadProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scripts: [String: AccountReadScript] = [:]
    static func install(_ script: AccountReadScript, id: String) { lock.withLock { scripts[id] = script } }
    static func remove(_ id: String) { lock.withLock { scripts[id] = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Goog-Visitor-Id"),
              let script = Self.lock.withLock({ Self.scripts[id] }),
              let url = request.url, url.path == "/youtubei/v1/browse" else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch script.next() {
        case .data(let data):
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .networkFailure:
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        }
    }
    override func stopLoading() {}
}

private struct AccountReadHarness: Sendable {
    let api: InnerTube
    let script: AccountReadScript
    let session: URLSession
    let suite: String

    init(_ responses: [AccountReadScript.Response]) async {
        suite = "account-read-test-" + UUID().uuidString
        script = AccountReadScript(responses)
        AccountReadProtocol.install(script, id: suite)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountReadProtocol.self]
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        UserDefaults(suiteName: suite)?.set(suite, forKey: "koda.visitorData")
        let identity = VisitorIdentity(session: session, suite: suite)
        let accounts = AccountSessions()
        await accounts.activate(.init(profileID: UUID(), cookies: .init(header: "SAPISID=test-only")))
        api = InnerTube(session: session, identity: identity, accounts: accounts)
    }

    func close() {
        session.invalidateAndCancel()
        AccountReadProtocol.remove(suite)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AccountLibraryReadTests {
    @Test(arguments: accountKinds)
    func everyCollectionRequiresAllPagesBeforeReturning(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([
            .data(try libraryPage(kind, ids: ["a"], next: "page-two")),
            .data(try libraryPage(kind, ids: ["b", "a"], continuationPage: true)),
        ])
        defer { harness.close() }
        let items = try await harness.api.accountLibraryItems(kind)
        #expect(items.map(\.title) == ["Item a", "Item b"])
        #expect(harness.script.count == 2)
    }

    @Test(arguments: accountKinds)
    func laterPageFailureNeverReturnsAPrefix(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: ["a"], next: "next")), .networkFailure])
        defer { harness.close() }
        await #expect(throws: MusicError.network) { try await harness.api.accountLibraryItems(kind) }
        #expect(harness.script.count == 2)
    }

    @Test(arguments: accountKinds)
    func repeatedCursorCannotBecomeACompleteLibrary(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([
            .data(try libraryPage(kind, ids: ["a"], next: "same")),
            .data(try libraryPage(kind, ids: ["b"], next: "same", continuationPage: true)),
        ])
        defer { harness.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await harness.api.accountLibraryItems(kind) }
        #expect(harness.script.count == 2)
    }

    @Test(arguments: accountKinds)
    func reachingTheItemCapWithMorePagesStillThrows(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: ["a"], next: "next"))])
        defer { harness.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await harness.api.accountLibraryItems(kind, limit: 1) }
        #expect(harness.script.count == 1)
    }

    @Test(arguments: accountKinds)
    func oversizedFinalPageCannotBeSilentlyPrefixed(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: ["a", "b"]))])
        defer { harness.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await harness.api.accountLibraryItems(kind, limit: 1) }
    }

    @Test(arguments: accountKinds)
    func exactlyFullFinalPageIsStillComplete(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: ["a"]))])
        defer { harness.close() }
        #expect(try await harness.api.accountLibraryItems(kind, limit: 1).count == 1)
    }

    @Test(arguments: accountKinds)
    func pageBudgetCannotSilentlyDropUnreadPages(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([
            .data(try libraryPage(kind, ids: ["a"], next: "two")),
            .data(try libraryPage(kind, ids: ["b"], next: "three", continuationPage: true)),
        ])
        defer { harness.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await harness.api.accountLibraryItems(kind, maxPages: 2) }
        #expect(harness.script.count == 2)
    }

    @Test(arguments: accountKinds)
    func missingContainerOrUnreadableEntityCannotMeanEmpty(_ kind: LibraryChange.Kind) async throws {
        let missing = await AccountReadHarness([.data(Data(#"{"responseContext":{}}"#.utf8))])
        defer { missing.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await missing.api.accountLibraryItems(kind) }
        let malformed = await AccountReadHarness([.data(try libraryPage(kind, ids: [], extra: [["musicResponsiveListItemRenderer": ["playlistItemData": [:]]]]))])
        defer { malformed.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await malformed.api.accountLibraryItems(kind) }
    }

    @Test(arguments: accountKinds)
    func wrongKnownEntityTypeCannotBeDiscardedByCompactMap(_ kind: LibraryChange.Kind) async throws {
        let wrong: LibraryChange.Kind = kind == .album ? .playlist : .album
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: [], extra: [libraryRow(wrong, id: "wrong")]))])
        defer { harness.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await harness.api.accountLibraryItems(kind) }
    }

    @Test(arguments: accountKinds)
    func explicitEmptyShelfIsAValidCompleteResult(_ kind: LibraryChange.Kind) async throws {
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: []))])
        defer { harness.close() }
        #expect(try await harness.api.accountLibraryItems(kind).isEmpty)
    }

    @Test func actualDefaultPageBudgetRejectsAnUnfinishedEightyPageRead() async throws {
        let responses = try (0..<80).map { AccountReadScript.Response.data(try libraryPage(.album, ids: [String($0)], next: "page-\($0)", continuationPage: $0 > 0)) }
        let harness = await AccountReadHarness(responses)
        defer { harness.close() }
        await #expect(throws: AccountLibraryReadError.incompleteResponse) { try await harness.api.accountLibraryItems(.album) }
        #expect(harness.script.count == 80)
    }

    @Test func explicitlyCancelledReadDoesNotPublishEvenAnEmptyFirstPage() async throws {
        let harness = await AccountReadHarness([.data(try libraryPage(.liked, ids: []))])
        defer { harness.close() }
        let task = Task { () throws -> [MusicItem] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await harness.api.accountLibraryItems(.liked)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(harness.script.count == 0)
    }

    @MainActor
    @Test(arguments: accountKinds)
    func failedAuthoritativeReadLeavesEveryCollectionAndMirrorUntouched(_ kind: LibraryChange.Kind) async throws {
        let library = Library(directory: nil)
        let original = AccountLibrary(liked: [.init(id: "song", title: "Song", artistLine: "Artist")],
            albums: [.init(id: "MPREalbum", title: "Album", artistLine: "Artist")],
            playlists: [.init(id: "PLplaylist", title: "Playlist")], artists: [.init(id: "UCartist", name: "Artist")])
        var mirror = AccountMirror()
        library.reconcile(with: original, mirror: &mirror)
        mirror.queue(.liked(original.liked[0], true))
        let before = mirror
        let harness = await AccountReadHarness([.data(try libraryPage(kind, ids: ["new"], next: "next")), .networkFailure])
        defer { harness.close() }
        do {
            _ = try await harness.api.accountLibraryItems(kind)
            Issue.record("An incomplete collection was accepted for reconciliation")
            library.reconcile(with: .init(), mirror: &mirror)
        } catch {
            #expect(error as? MusicError == .network)
        }
        #expect(library.liked == original.liked)
        #expect(library.albums == original.albums)
        #expect(library.playlists == original.playlists)
        #expect(library.artists == original.artists)
        #expect(mirror == before)
    }
}

@Suite struct AccountLibraryIntegrityParserTests {
    @Test func competingContinuationChainsCannotProveCompleteness() throws {
        let legacyA: [String: Any] = ["nextContinuationData": ["continuation": "A"]]
        let legacyB: [String: Any] = ["nextContinuationData": ["continuation": "B"]]
        let modernB: [String: Any] = ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "B"]]]]
        let values: [[String: Any]] = [
            ["gridRenderer": ["items": [], "continuations": [legacyA, legacyB]]],
            ["gridRenderer": ["items": [modernB], "continuations": [legacyA]]],
            ["contents": [["gridRenderer": ["items": [], "continuations": [legacyA]]],
                          ["gridRenderer": ["items": [], "continuations": [legacyB]]]]],
        ]
        for value in values {
            let root = JSON(value)
            #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root, expectedKind: .playlist) }
            let display = AccountPages.playlistCatalogPage(root)
            #expect(display.issues.contains(.invalidContinuation))
            #expect(!CloudPlaylistCatalogResult(playlists: display.playlists, issues: display.issues).isComplete)
        }
    }

    @Test func duplicateRepresentationOfOneCursorIsNotASecondChain() throws {
        let root = JSON(["gridRenderer": ["items": [["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "A"]]]]],
                                         "continuations": [["nextContinuationData": ["continuation": "A"]]]]])
        #expect(try AccountPages.completeLibraryItems(root, expectedKind: .playlist).isEmpty)
        #expect(try AccountPages.completeLibraryContinuation(root) == "A")
    }

    @Test(arguments: accountKinds)
    func malformedTokenDoesNotLookLikeTheLastPage(_ kind: LibraryChange.Kind) throws {
        let values: [[String: Any]] = [
            ["gridRenderer": ["items": [], "continuations": [["nextContinuationData": [:]]]]],
            ["gridRenderer": ["items": [["continuationItemRenderer": ["continuationEndpoint": [:]]]]]],
            ["gridRenderer": ["items": [], "continuations": "invalid"]],
            ["gridRenderer": ["items": [], "continuations": NSNull()]],
        ]
        for value in values {
            #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(JSON(value), expectedKind: kind) }
        }
    }

    @Test func playlistDisplayWrongKindCannotReachTheDeletionCapableCatalogPath() throws {
        let root = JSON(["gridRenderer": ["items": [libraryRow(.album, id: "a"), libraryRow(.playlist, id: "p")]]])
        let page = AccountPages.playlistCatalogPage(root)
        #expect(page.playlists.map(\.id) == ["PLp"])
        #expect(page.issues == [.unrecognizedEntries(1)])
        let result = CloudPlaylistCatalogResult(playlists: page.playlists, issues: page.issues)
        #expect(!result.isComplete)
        #expect(result.mergingForDisplay(previous: [.init(id: "PLold", title: "Old")]).map(\.id) == ["PLp", "PLold"])
    }

    @Test(arguments: accountKinds)
    func malformedContainerBesideGoodContentStillFails(_ kind: LibraryChange.Kind) throws {
        let parsed = try JSON(data: libraryPage(kind, ids: ["a"]))
        let good = try #require(parsed.raw as? [String: Any])
        let root = JSON(["contents": [good, ["gridRenderer": ["items": "invalid"]]]])
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root, expectedKind: kind) }
    }

    @Test func aValidArrayCannotHideAnotherMalformedCollectionField() throws {
        let invalidFields: [Any] = [NSNull(), ["unknownRenderer": ["id": "lost"]], "invalid"]
        for invalid in invalidFields {
            let root = JSON(["gridRenderer": ["items": [libraryRow(.playlist, id: "known")], "contents": invalid]])
            #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root, expectedKind: .playlist) }
            let display = AccountPages.playlistCatalogPage(root)
            #expect(display.playlists.map(\.id) == ["PLknown"])
            #expect(display.issues.contains(.unrecognizedPage))
            let result = CloudPlaylistCatalogResult(playlists: display.playlists, issues: display.issues)
            #expect(!result.isComplete)
            #expect(result.mergingForDisplay(previous: [.init(id: "PLold", title: "Old")]).count == 2)
        }
    }

    @Test func knownContainerWithWrongValueTypeCannotDisappearBesideAnEmptyShelf() throws {
        let invalidWrappers: [Any] = [NSNull(), "invalid", [] as [Any]]
        for invalid in invalidWrappers {
            let root = JSON(["contents": [["gridRenderer": ["items": []]], ["musicShelfRenderer": invalid]]])
            #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root, expectedKind: .playlist) }
            let page = AccountPages.playlistCatalogPage(root)
            #expect(page.issues.contains(.unrecognizedPage))
            let result = CloudPlaylistCatalogResult(playlists: page.playlists, issues: page.issues)
            #expect(!result.isComplete)
            #expect(result.mergingForDisplay(previous: [.init(id: "PLold", title: "Old")]).map(\.id) == ["PLold"])
        }
    }

    @Test func aBrowsePrefixWithoutAPlaylistIDCannotAuthorizeRemoteDeletion() throws {
        let root = JSON(["gridRenderer": ["items": [["musicTwoRowItemRenderer": [
            "title": ["simpleText": "Broken identity"],
            "navigationEndpoint": ["browseEndpoint": ["browseId": "VL"]],
        ]]]]])
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root, expectedKind: .playlist) }
        let page = AccountPages.playlistCatalogPage(root)
        #expect(page.playlists.isEmpty)
        #expect(page.issues == [.unrecognizedEntries(1)])
        #expect(!CloudPlaylistCatalogResult(playlists: page.playlists, issues: page.issues).isComplete)
    }

    @Test func realShuffleControlRequiresEndpointAndIconEvidence() throws {
        var shuffle: [String: Any] = [
            "navigationEndpoint": ["watchPlaylistEndpoint": ["playlistId": "MLCT"]],
            "thumbnail": ["musicIconBadgeRenderer": ["icon": ["iconType": "MUSIC_SHUFFLE"]]],
            "flexColumns": [["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "隨機播放全部"]]]]]],
        ]
        func root(_ row: [String: Any]) -> JSON {
            JSON(["musicShelfRenderer": ["contents": [["musicResponsiveListItemRenderer": row], libraryRow(.liked, id: "a")]]])
        }
        #expect(try AccountPages.completeLibraryItems(root(shuffle), expectedKind: .liked).map(\.title) == ["Item a"])
        shuffle["navigationEndpoint"] = nil
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root(shuffle), expectedKind: .liked) }
        shuffle["navigationEndpoint"] = ["watchPlaylistEndpoint": ["playlistId": "MLCT"]]
        shuffle["thumbnail"] = nil
        #expect(throws: CloudPlaylistError.incompleteResponse) { try AccountPages.completeLibraryItems(root(shuffle), expectedKind: .liked) }
    }

    @Test func onlyTextSayingShuffleCannotHideAMalformedSong() throws {
        // The original reduced liked-songs fixture intentionally omitted the real
        // control's endpoint/icon. Tolerant browsing can skip it, authoritative
        // reconciliation cannot infer safety from its English label.
        #expect(throws: CloudPlaylistError.incompleteResponse) {
            try AccountPages.completeLibraryItems(fixture("liked-songs"), expectedKind: .liked)
        }
    }

    @Test func existingLikedSongFixtureWithVerifiedControlMetadataLoadsNormally() throws {
        var shelf = try #require(fixture("liked-songs").first("musicShelfRenderer").raw as? [String: Any])
        var contents = try #require(shelf["contents"] as? [[String: Any]])
        var control = try #require(contents[0]["musicResponsiveListItemRenderer"] as? [String: Any])
        // These fields are present in the public rustypipe saved_tracks fixture;
        // the old reduced Koda fixture retained only its display text.
        control["navigationEndpoint"] = ["watchPlaylistEndpoint": ["playlistId": "MLCT"]]
        control["thumbnail"] = ["musicIconBadgeRenderer": ["icon": ["iconType": "MUSIC_SHUFFLE"]]]
        contents[0] = ["musicResponsiveListItemRenderer": control]
        shelf["contents"] = contents
        let root = JSON(["musicShelfRenderer": shelf])
        #expect(try AccountPages.completeLibraryItems(root, expectedKind: .liked).count == 3)
        #expect(try AccountPages.completeLibraryContinuation(root) == "LIKED-2")
        #expect(try AccountPages.completeLibraryItems(fixture("liked-songs-continuation"), expectedKind: .liked).count == 3)
    }

    @Test func existingAlbumArtistAndPlaylistFixturesKeepTheirKnownShapes() throws {
        #expect(try AccountPages.completeLibraryItems(fixture("library-albums"), expectedKind: .album).count == 2)
        #expect(try AccountPages.completeLibraryItems(fixture("library-albums-continuation"), expectedKind: .album).count == 2)
        #expect(try AccountPages.completeLibraryItems(fixture("library-artists"), expectedKind: .artist).count >= 2)
        #expect(try AccountPages.completeLibraryItems(fixture("library-playlists"), expectedKind: .playlist).count == 4)
        #expect(try AccountPages.completeLibraryContinuation(fixture("library-albums")) == "ALBUMS-2")
        #expect(try AccountPages.completeLibraryContinuation(fixture("library-playlists")) == nil)
    }
}
