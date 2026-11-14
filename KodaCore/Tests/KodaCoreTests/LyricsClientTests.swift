import Foundation
import Testing
@testable import KodaCore

private actor LyricsProviderStub {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private var handler: Handler
    private var requests: [URLRequest] = []

    init(_ handler: @escaping Handler) { self.handler = handler }

    func replace(_ handler: @escaping Handler) { self.handler = handler }

    func response(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let (status, data) = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    func seen() -> [URLRequest] { requests }
}

private func lyricParameters(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, new in new })
}

private func lyricRecord(title: String = "Song", artist: String = "Artist", lyric: String = "Line",
                         duration: Double = 200) -> [String: Any] {
    ["trackName": title, "artistName": artist, "duration": duration, "syncedLyrics": "[00:01.00]\(lyric)"]
}

private actor HeldLyricsProvider {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var first: CheckedContinuation<Data, Never>?
    private let old: Data
    private let fresh: Data

    init() throws {
        old = try JSONSerialization.data(withJSONObject: lyricRecord(lyric: "Old"))
        fresh = try JSONSerialization.data(withJSONObject: lyricRecord(lyric: "Fresh"))
    }

    func response(_ request: URLRequest) async -> (Data, URLResponse) {
        count += 1
        let data: Data
        if count == 1 {
            data = await withCheckedContinuation { continuation in
                first = continuation
                waiters.forEach { $0.resume() }
                waiters = []
            }
        } else { data = fresh }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func waitForFirst() async {
        if first != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func releaseFirst() { first?.resume(returning: old); first = nil }
    func requests() -> Int { count }
}

struct LyricsClientTests {
    private func song(title: String = "Song", artist: String = "Artist", id: String = "test-song") -> Song {
        Song(id: id, title: title, artistLine: artist, duration: 200)
    }

    @Test func rawLRCBodyKeepsWordTimingsAndWrappedJSONIsNotParsedAsRawLRC() throws {
        let text = "\u{FEFF}[00:01.00]<00:01.00>One <00:01.50>two\n[00:03.00]Three"
        let raw = try #require(LyricsClient.decodeWrapped(Data(text.utf8)))
        guard case .synced(let lines) = raw else { Issue.record("Expected timed raw LRC"); return }
        #expect(lines.map(\.text) == ["One two", "Three"])
        #expect(lines[0].words.map(\.start) == [1, 1.5])
        let wrapped = try JSONSerialization.data(withJSONObject: ["lyrics": text])
        #expect(LyricsClient.decodeWrapped(wrapped) == raw)
    }

    @Test(arguments: ["Service temporarily unavailable", "<html><body>Error</body></html>", "{\"error\":\"not found\"}"])
    func providerErrorBodiesAreNotLyrics(_ body: String) {
        #expect(LyricsClient.decodeWrapped(Data(body.utf8)) == nil)
    }

    @Test func normalizedSearchFindsLyricsWithoutAcceptingAnUnrelatedFirstResult() async throws {
        let stub = LyricsProviderStub { request in
            let fields = lyricParameters(request)
            if request.url?.path == "/api/get" { return (404, Data()) }
            if fields["track_name"] == "Song", fields["artist_name"] == "Artist" {
                let records = [lyricRecord(title: "Other Song", lyric: "Wrong title"),
                               lyricRecord(artist: "Someone Else", lyric: "Wrong artist"),
                               lyricRecord(lyric: "Right song")]
                return (200, try JSONSerialization.data(withJSONObject: records))
            }
            return (200, Data("[]".utf8))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let input = song(title: "Song (Official Music Video)", artist: "Artist - Topic")
        let found = await client.lyrics(for: input, sources: [.lrclib])
        #expect(found == .synced(Lyrics.parseLRC("[00:01.00]Right song")))
        let requests = await stub.seen()
        #expect(requests.contains { lyricParameters($0)["track_name"] == "Song" })
        #expect(input.title == "Song (Official Music Video)")
        #expect(input.artistLine == "Artist - Topic")
    }

    @Test func bilingualArtistCreditCanReachTheChineseCatalogueName() async throws {
        let stub = LyricsProviderStub { request in
            let fields = lyricParameters(request)
            guard request.url?.path == "/api/search", fields["artist_name"] == "南征北战" else {
                return (404, Data())
            }
            return (200, try JSONSerialization.data(withJSONObject: [lyricRecord(title: "最美的期待", artist: "南征北战")]))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let found = await client.lyrics(for: song(title: "最美的期待", artist: "南征北戰 NZBZ"), sources: [.lrclib])
        #expect(found != nil)
        let requests = await stub.seen()
        #expect(requests.contains { lyricParameters($0)["artist_name"] == "南征北战" })
        #expect(requests.count <= 8)
    }

    @Test func freeTextFallbackStillValidatesTheOriginalSongIdentity() async throws {
        let stub = LyricsProviderStub { request in
            guard lyricParameters(request)["q"] != nil else { return (404, Data()) }
            return (200, try JSONSerialization.data(withJSONObject: [lyricRecord(title: "Song (Live)"), lyricRecord(lyric: "Studio")]))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let found = await client.lyrics(for: song(), sources: [.lrclib])
        #expect(found == .synced(Lyrics.parseLRC("[00:01.00]Studio")))
    }

    @Test func missesAreNotCachedAndExplicitRefreshReplacesTheSuccessfulCachedAnswer() async throws {
        let stub = LyricsProviderStub { _ in (503, Data()) }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let initial = await client.lyrics(for: song(), sources: [.lrclib])
        #expect(initial == nil)
        await stub.replace { _ in (200, try JSONSerialization.data(withJSONObject: lyricRecord(lyric: "First"))) }
        let first = await client.lyrics(for: song(), sources: [.lrclib])
        #expect(first == .synced(Lyrics.parseLRC("[00:01.00]First")))
        let beforeCache = await stub.seen().count
        await stub.replace { _ in (200, try JSONSerialization.data(withJSONObject: lyricRecord(lyric: "Refreshed"))) }
        let cached = await client.lyrics(for: song(), sources: [.lrclib])
        #expect(cached == first)
        #expect(await stub.seen().count == beforeCache)
        let refreshed = await client.lyrics(for: song(), sources: [.lrclib], refresh: true)
        #expect(refreshed == .synced(Lyrics.parseLRC("[00:01.00]Refreshed")))
        #expect(await stub.seen().count > beforeCache)
    }

    @Test func correctedMetadataForTheSameVideoIDDoesNotReuseOldLyrics() async throws {
        let stub = LyricsProviderStub { request in
            let title = lyricParameters(request)["track_name"] ?? ""
            return (200, try JSONSerialization.data(withJSONObject: lyricRecord(title: title, lyric: title)))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let first = await client.lyrics(for: song(title: "Old title"), sources: [.lrclib])
        let corrected = await client.lyrics(for: song(title: "Correct title"), sources: [.lrclib])
        #expect(first != corrected)
        #expect(corrected == .synced(Lyrics.parseLRC("[00:01.00]Correct title")))
        #expect(await stub.seen().count == 2)
    }

    @Test func disabledAndRepeatedSourcesDoNotCreateExtraRequests() async {
        let stub = LyricsProviderStub { _ in (404, Data()) }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let disabled = await client.lyrics(for: song(), sources: [])
        #expect(disabled == nil)
        #expect(await stub.seen().isEmpty)
        _ = await client.lyrics(for: song(), sources: [.lrclib, .lrclib])
        #expect(await stub.seen().count == 3) // exact, field search, free-text search
    }

    @Test func lateOldLookupCannotOverwriteARefreshAfterTheCacheWasCleared() async throws {
        let stub = try HeldLyricsProvider()
        let client = LyricsClient(transport: { await stub.response($0) })
        let input = song()
        let old = Task { await client.lyrics(for: input, sources: [.lrclib]) }
        await stub.waitForFirst()
        await client.clearCache()
        let fresh = await client.lyrics(for: input, sources: [.lrclib], refresh: true)
        await stub.releaseFirst()
        _ = await old.value
        let cached = await client.lyrics(for: input, sources: [.lrclib])
        #expect(cached == fresh)
        #expect(cached == .synced(Lyrics.parseLRC("[00:01.00]Fresh")))
        #expect(await stub.requests() == 2)
    }

    @Test func cancelledLookupCannotReturnOrCacheALateProviderAnswer() async throws {
        let stub = try HeldLyricsProvider()
        let client = LyricsClient(transport: { await stub.response($0) })
        let input = song()
        let pending = Task { await client.lyrics(for: input, sources: [.lrclib]) }
        await stub.waitForFirst()
        pending.cancel()
        await stub.releaseFirst()
        let cancelled = await pending.value
        #expect(cancelled == nil)
        let fresh = await client.lyrics(for: input, sources: [.lrclib])
        #expect(fresh == .synced(Lyrics.parseLRC("[00:01.00]Fresh")))
        #expect(await stub.requests() == 2)
    }

    @Test func lyricsOVHUsesEncodedPathSegmentsAndReadsItsDocumentedResponse() async throws {
        let stub = LyricsProviderStub { request in
            #expect(request.url?.host == "api.lyrics.ovh")
            #expect(request.url?.absoluteString.contains("A%2FB") == true)
            #expect(request.url?.absoluteString.contains("Song%3F") == true)
            #expect(request.url?.query == nil)
            return (200, try JSONSerialization.data(withJSONObject: ["lyrics": "A plain line\nAnother line"]))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let found = await client.lyrics(for: song(title: "Song?", artist: "A/B"), sources: [.lyricsOVH])
        #expect(found == .plain("A plain line\nAnother line"))
        #expect(await stub.seen().count == 1)
    }

    @Test func lrcAPIRejectsUnrelatedRecordsAndKeepsOriginalTiming() async throws {
        let stub = LyricsProviderStub { request in
            #expect(request.url?.host == "api.lrc.cx")
            #expect(request.url?.path == "/jsonapi")
            let records = [["title": "Other Song", "artist": "Artist", "lyrics": "[00:01.00]Wrong"],
                           ["title": "Song", "artist": "Artist", "lyrics": "[00:01.25]First\n[00:02.75]Second"]]
            return (200, try JSONSerialization.data(withJSONObject: records))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let found = await client.lyrics(for: song(), sources: [.lrcAPI])
        #expect(found == .synced(Lyrics.parseLRC("[00:01.25]First\n[00:02.75]Second")))
        #expect(await stub.seen().count == 1)
    }

    @Test func linkedPrimaryArtistDoesNotHideTheKnownFullCollaboratorCredit() async throws {
        let stub = LyricsProviderStub { request in
            guard lyricParameters(request)["artist_name"] == "Artist A & Artist B" else { return (404, Data()) }
            return (200, try JSONSerialization.data(withJSONObject: [lyricRecord(artist: "Artist A & Artist B", lyric: "Duet")]))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let input = Song(id: "duet", title: "Song", artistLine: "Artist A & Artist B",
                         artists: [ArtistRef(id: "a", name: "Artist A"), ArtistRef(id: "b", name: "Artist B")], duration: 200)
        let found = await client.lyrics(for: input, sources: [.lrclib])
        #expect(found == .synced(Lyrics.parseLRC("[00:01.00]Duet")))
    }

    @Test func customOnlyLookupPreservesTemplateQueryAndHonorsDisabledSources() async throws {
        let disabled = CustomLyricsSource(name: "Disabled", urlTemplate: "https://disabled.example/lyrics?title={title}", isEnabled: false)
        let source = CustomLyricsSource(name: "My source", urlTemplate: "https://lyrics.example/get?track={title}&artist={artist}&format=lrc")
        let stub = LyricsProviderStub { request in
            #expect(request.url?.host == "lyrics.example")
            #expect(lyricParameters(request)["track"] == "Song? & More")
            #expect(lyricParameters(request)["artist"] == "A/B")
            #expect(lyricParameters(request)["format"] == "lrc")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(!request.httpShouldHandleCookies)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            return (200, Data("[00:01.00]User source".utf8))
        }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let found = await client.lyrics(for: song(title: "Song? & More", artist: "A/B"), sources: [], customSources: [disabled, source])
        #expect(found == .synced(Lyrics.parseLRC("[00:01.00]User source")))
        #expect(await stub.seen().count == 1)
    }

    @Test func aChangedCustomEndpointDoesNotReuseAnEarlierEndpointsCachedLyrics() async {
        let id = UUID()
        let first = CustomLyricsSource(id: id, name: "Source", urlTemplate: "https://one.example/{title}")
        let second = CustomLyricsSource(id: id, name: "Source", urlTemplate: "https://two.example/{title}")
        let stub = LyricsProviderStub { request in (200, Data("[00:01.00]\(request.url!.host!)".utf8)) }
        let client = LyricsClient(transport: { try await stub.response($0) })
        let old = await client.lyrics(for: song(), sources: [], customSources: [first])
        let new = await client.lyrics(for: song(), sources: [], customSources: [second])
        #expect(old != new)
        #expect(new == .synced(Lyrics.parseLRC("[00:01.00]two.example")))
        #expect(await stub.seen().count == 2)
    }
}
