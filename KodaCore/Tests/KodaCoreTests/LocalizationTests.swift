import Foundation
import Testing
@testable import KodaCore

struct LocalizationTests {
    private func bundle(for language: String) throws -> Bundle {
        let path = try #require(KodaLocalization.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    @Test func loadsTaiwanTraditionalChineseFromThePackageBundle() throws {
        let chinese = try bundle(for: "zh-Hant")
        #expect(chinese.localizedString(forKey: "Bass Booster", value: nil, table: nil) == "低音增強")
        #expect(chinese.localizedString(forKey: "This song isn't available", value: nil, table: nil) == "無法播放這首歌曲")
        #expect(chinese.localizedString(forKey: "Listener", value: nil, table: nil) == "聆聽者")
        #expect(Bundle.preferredLocalizations(from: KodaLocalization.bundle.localizations,
                                             forPreferences: ["zh-Hant-TW"]).first == "zh-Hant")
    }

    @Test func preservesTheEnglishDevelopmentLanguage() throws {
        let english = try bundle(for: "en")
        #expect(KodaLocalization.bundle.developmentLocalization == "en")
        #expect(english.localizedString(forKey: "Bass Booster", value: nil, table: nil) == "Bass Booster")
        #expect(Bundle.preferredLocalizations(from: ["en", "zh-Hant"], forPreferences: ["en-US"]).first == "en")
    }

    @Test func preservesExternalErrorTextAndFormatsNumericArguments() throws {
        let chinese = try bundle(for: "zh-Hant")
        let format = chinese.localizedString(forKey: "%@ (Last.fm error %lld)", value: nil, table: nil)
        // External service text is an argument; '%' and Unicode are not interpreted as a format.
        let external = "原始訊息 100% / Artist's title"
        #expect(String(format: format, external, Int64(12345)) == "原始訊息 100% / Artist's title（Last.fm 錯誤 12345）")
        let error = chinese.localizedString(forKey: "Last.fm error %lld.", value: nil, table: nil)
        #expect(String(format: error, Int64(29)) == "Last.fm 錯誤 29。")
    }

    @Test func translatingDisplayNamesDoesNotChangeStoredIdentifiers() throws {
        #expect(ReleaseKind.album.rawValue == "Album")
        #expect(EqualizerPreset.bassBooster.rawValue == "bassBooster")
        #expect(LyricsSource.betterLyrics.rawValue == "betterLyrics")
        let profile = KodaProfile(kind: .device, name: "A listener's own name")
        #expect(profile.displayName == profile.name)
        let encoded = try JSONEncoder().encode(ReleaseKind.album)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"Album\"")
    }

    @MainActor
    @Test func onlyNewBlankPlaylistNamesUseTheLocalizedDefault() throws {
        let library = Library(directory: nil)
        let expected = KodaLocalization.bundle.localizedString(forKey: "New Playlist", value: nil, table: nil)
        #expect(library.createPlaylist(named: " \n ").name == expected)
        #expect(library.createPlaylist(named: "My 新播放清單 100%").name == "My 新播放清單 100%")
        // Even a user-supplied name matching the old English default stays untouched.
        #expect(library.createPlaylist(named: "New Playlist").name == "New Playlist")
        let existing = UserPlaylist(name: "New Playlist")
        let restored = try JSONDecoder().decode(UserPlaylist.self, from: JSONEncoder().encode(existing))
        #expect(restored.name == "New Playlist")
        let chinese = try bundle(for: "zh-Hant")
        #expect(chinese.localizedString(forKey: "New Playlist", value: nil, table: nil) == "新播放清單")
    }

    @Test func bothLanguagesContainEveryCoreKeyAndMatchingFormatArguments() throws {
        func strings(_ language: String) throws -> [String: String] {
            let localized = try bundle(for: language)
            let path = try #require(localized.url(forResource: "Localizable", withExtension: "strings"))
            return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as? [String: String])
        }
        let english = try strings("en")
        let chinese = try strings("zh-Hant")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(chinese.keys))
        let placeholders = try NSRegularExpression(pattern: "%(@|lld)")
        func arguments(_ value: String) -> [String] {
            let ns = value as NSString
            return placeholders.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
        }
        for (key, value) in english {
            #expect(arguments(value) == arguments(chinese[key] ?? ""))
        }
    }
}
