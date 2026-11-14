import Foundation
import Testing
@testable import KodaCore

struct CustomLyricsSourceTests {
    private func source(_ template: String) -> CustomLyricsSource {
        CustomLyricsSource(name: "My lyrics server", urlTemplate: template)
    }

    @Test func queryValuesCannotInjectParametersOrChangeTheHost() throws {
        let server = source("https://lyrics.example/find?title={title}&artist={artist}&album={album}&duration={duration}&mode=lrc")
        let title = "最美的期待 & admin=true#fragment"
        let artist = "南征北战 NZBZ / Someone?"
        let album = "100% Love + More"
        let url = try server.requestURL(title: title, artist: artist, album: album, duration: 237.4)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "lyrics.example")
        #expect(components.fragment == nil)
        let items = try #require(components.queryItems)
        #expect(items.map(\.name) == ["title", "artist", "album", "duration", "mode"])
        #expect(items.map(\.value) == [title, artist, album, "237", "lrc"])
        #expect(!url.absoluteString.contains("& admin="))
    }

    @Test func metadataCannotEscapeItsPathSegmentAndRepeatedTokensKeepTheirValues() throws {
        let server = source("https://lyrics.example/lyrics/{artist}/{title}?copy={title}&artist={artist}")
        let url = try server.requestURL(title: "100% Love?#", artist: "AC/DC & More", album: nil, duration: nil)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/lyrics/AC%2FDC%20%26%20More/100%25%20Love%3F%23")
        #expect(components.queryItems == [URLQueryItem(name: "copy", value: "100% Love?#"),
                                         URLQueryItem(name: "artist", value: "AC/DC & More")])
        #expect(components.host == "lyrics.example")
    }

    @Test func metadataContainingPlaceholderTextIsNotExpandedAgain() throws {
        let server = source("https://lyrics.example/{title}?artist={artist}&album={album}")
        let url = try server.requestURL(title: "{artist}", artist: "Real Artist", album: "{title}", duration: nil)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/%7Bartist%7D")
        #expect(components.queryItems == [URLQueryItem(name: "artist", value: "Real Artist"),
                                         URLQueryItem(name: "album", value: "{title}")])
    }

    @Test func unicodeTemplateLiteralsAndMultipleMetadataTokensRemainIntact() throws {
        let server = source("https://lyrics.example/歌詞/{title}?來源=測試&artist={artist}")
        let url = try server.requestURL(title: "最美的期待", artist: "南征北战 NZBZ", album: nil, duration: nil)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/歌詞/最美的期待")
        #expect(components.queryItems == [URLQueryItem(name: "來源", value: "測試"),
                                         URLQueryItem(name: "artist", value: "南征北战 NZBZ")])
    }

    @Test func literalPercentEscapesAreNotDoubledWhenTheTemplateAlsoContainsUnicode() throws {
        let server = source("https://lyrics.example/歌詞/{title}?來源=A%26B&artist={artist}")
        let url = try server.requestURL(title: "100% Love", artist: "歌手 & Band", album: nil, duration: nil)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/歌詞/100% Love")
        #expect(components.queryItems == [URLQueryItem(name: "來源", value: "A&B"),
                                         URLQueryItem(name: "artist", value: "歌手 & Band")])
    }

    @Test(arguments: [Double.nan, Double.infinity, -1, 0])
    func absentOrInvalidDurationIsEmptyInsteadOfInventingAValue(duration: Double) throws {
        let server = source("https://lyrics.example/?title={title}&album={album}&duration={duration}")
        let url = try server.requestURL(title: "Song", artist: "Artist", album: nil, duration: duration)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "title", value: "Song"),
                                         URLQueryItem(name: "album", value: ""),
                                         URLQueryItem(name: "duration", value: "")])
    }

    @Test(arguments: [
        "http://lyrics.example/?title={title}",
        "file:///lyrics/{title}",
        "https://user:password@lyrics.example/?title={title}",
        "https://lyrics.example/?title={title}#result",
        "https://{artist}.example/?title={title}",
        "https://lyrics.example:{duration}/?title={title}",
        "https:///lyrics/{title}",
        "https://lyrics.example/\n?title={title}",
        "https://lyrics.example/%?title={title}",
        "https://lyrics.example/%2?title={title}",
        "https://lyrics.example/%GG?title={title}"
    ])
    func rejectsUnsafeOrNonHTTPSDestinations(template: String) {
        #expect(throws: (any Error).self) { try source(template).validated() }
    }

    @Test(arguments: [
        "https://lyrics.example/?title={unknown}",
        "https://lyrics.example/?title={title",
        "https://lyrics.example/?title={{title}}",
        "https://lyrics.example/?title={}",
        "https://lyrics.example/?title={Title}",
        "https://lyrics.example/?title={title}}"
    ])
    func rejectsUnknownOrMalformedPlaceholders(template: String) {
        #expect(throws: CustomLyricsSource.ValidationError.invalidPlaceholder) { try source(template).validated() }
    }

    @Test func metadataPlaceholderIsRequiredAndErrorsDoNotExposeTheEndpoint() {
        let server = source("https://lyrics.example/?api_key=private-value&album={album}")
        #expect(throws: CustomLyricsSource.ValidationError.missingMetadataPlaceholder) { try server.validated() }
        do {
            _ = try server.validated()
        } catch {
            #expect(!error.localizedDescription.contains("private-value"))
            #expect(!error.localizedDescription.contains("lyrics.example"))
        }
    }

    @Test func validationTrimsUserInputAndPreservesIdentityAndEnablementAcrossPersistence() throws {
        let original = CustomLyricsSource(name: "  我的歌詞  ", urlTemplate: "  https://lyrics.example/?title={title}  ", isEnabled: false)
        let valid = try original.validated()
        #expect(valid.name == "我的歌詞")
        #expect(valid.urlTemplate == "https://lyrics.example/?title={title}")
        #expect(valid.id == original.id)
        #expect(!valid.isEnabled)
        let restored = try JSONDecoder().decode(CustomLyricsSource.self, from: JSONEncoder().encode(valid))
        #expect(restored == valid)
    }

    @Test func oversizedNamesTemplatesAndExpandedRequestsAreRejected() throws {
        let empty = CustomLyricsSource(name: " \n ", urlTemplate: "https://lyrics.example/?title={title}")
        let longName = CustomLyricsSource(name: String(repeating: "a", count: 81), urlTemplate: "https://lyrics.example/?title={title}")
        #expect(throws: CustomLyricsSource.ValidationError.invalidName) { try empty.validated() }
        #expect(throws: CustomLyricsSource.ValidationError.invalidName) { try longName.validated() }
        let longTemplate = source("https://lyrics.example/?title={title}&padding=" + String(repeating: "a", count: 4_096))
        #expect(throws: CustomLyricsSource.ValidationError.urlTooLong) { try longTemplate.validated() }
        let server = source("https://lyrics.example/?title={title}")
        #expect(throws: CustomLyricsSource.ValidationError.urlTooLong) {
            try server.requestURL(title: String(repeating: "歌", count: 2_000), artist: "Artist", album: nil, duration: nil)
        }
    }
}
