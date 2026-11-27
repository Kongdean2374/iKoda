import Foundation
import Testing
@testable import KodaCore

@Suite struct ImmersiveLyricsTests {
    @Test func baseCompletionDoesNotReportContextCompletion() {
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .checking) == .preparing)
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .working) == .polishing)
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .partial) == .partial)
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .completed) == .completed)
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .unavailable) == .modelUnavailable)
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .language) == .languageUnsupported)
        #expect(ImmersiveLyricStatus.resolve(base: .partial, polish: .unnecessary) == .fallback)
        #expect(ImmersiveLyricStatus.resolve(base: .ready, polish: .paused) == .paused)
    }

    @Test func individuallyValidRowsSurvivePartialResponseAndOnlyMissingRowsAreRetried() {
        let expected = [0, 1, 2, 3].map { LyricsPolishValidation.Line(id: $0, text: "月光照在玻璃上") }
        let response = [
            LyricsPolishValidation.Line(id: 0, text: "月光照在玻璃上"),
            .init(id: 1, text: "窗上的月光"),
            .init(id: 2, text: "第一份"),
            .init(id: 2, text: "重複識別碼"),
            .init(id: 12, text: "未知的行")
        ]
        let result = LyricPolishBatch.assess(response, expected: expected)
        #expect(result.translations.count == 2)
        #expect(result.changed == 1)
        #expect(result.unchanged == 1)
        #expect(result.missing.map(\.id) == [2, 3])
        #expect(LyricPolishBatch.retryGroups(result.missing).map { $0.map(\.id) } == [[2], [3]])
        let resumed = LyricPolishBatch.assess([.init(id: 2, text: "重新找到路")], expected: Array(result.missing.prefix(1)))
        #expect(resumed.translations[2] == "重新找到路")
        #expect(resumed.missing.isEmpty)
    }

    @Test func contextKeepsUnfinishedSentencesAndVoicesTogether() {
        let original = [
            LyricContextRow(id: 0, text: "I never meant to let", voice: .lead),
            .init(id: 1, text: "the cat out of the bag.", voice: .lead),
            .init(id: 2, text: "What a lovely storm", voice: .duet),
            .init(id: 3, text: "to soak our only map!", voice: .duet),
            .init(id: 4, text: "まだ言わずに", voice: .lead),
            .init(id: 5, text: "窓を閉めた。", voice: .lead),
            .init(id: 6, text: "The bell is ringing.", voice: .together),
            .init(id: 7, text: "The bell is ringing.", voice: .duet)
        ]
        let groups = LyricContextPassages.groups(original, translating: Set(original.map(\.id)))
        #expect(groups.contains { $0.contains(0) && $0.contains(1) && $0.contains(2) && $0.contains(3) })
        #expect(groups.flatMap { $0 }.map { original[$0].id } == Array(0...7))
        #expect(LyricContextPassages.overview(original).rows == original)
        #expect(LyricContextPassages.overview(Array(repeating: original, count: 150).flatMap { $0 }).excerpted)
    }

    @Test func localeAliasesKeepTraditionalScriptAndSupportPrimaryLanguageFallbacks() {
        #expect(LyricTranslationLocale.variants(for: "zh_Hant_TW").contains("zh-Hant"))
        #expect(LyricTranslationLocale.variants(for: "zh_Hant_TW").contains("zh-TW"))
        #expect(!LyricTranslationLocale.variants(for: "zh-Hant-TW").contains("zh-Hans"))
        #expect(LyricTranslationLocale.variants(for: "ja-JP").contains("ja"))
        #expect(LyricTranslationLocale.variants(for: "ko_KR").contains("ko"))
    }

    @Test func newContextCacheKeyLeavesOldRawAndBaseCachesIntact() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = AutomaticLyricTranslationCache(directory: url)
        let rows = [ChineseLyricTranslationPlan.Row(id: 0, text: "An original line")]
        let base = AutomaticLyricTranslationPipeline.cacheKey(.init(songID: "test", rows: rows, namespace: "version", mode: .immersive))
        let old = AutomaticLyricTranslationCache.Key(songID: "test", rows: rows, namespace: "version|immersive|tw-lyric-editor-v1")
        let new = LyricContextPassages.cacheKey(songID: "test", originalNamespace: "version")
        await cache.store(.init(fragments: ["0": "早期語境譯文"], isComplete: true), for: old)
        await cache.store(.init(fragments: ["0:0": "基礎譯文"], isComplete: true), for: base)
        #expect(await cache.entry(for: new) == nil)
        #expect(await cache.entry(for: old)?.fragments["0"] != nil)
        #expect(await cache.entry(for: base)?.fragments["0:0"] == "基礎譯文")
    }

    @Test func compactLayoutIsControlledByPanelAndDisplayPreference() {
        func resolve(_ lyrics: Bool, _ translation: Bool, enabled: Bool = true, portrait: Bool = true, expanded: Bool = false) -> LyricsPlayerChrome {
            .resolve(isPortraitPhone: portrait, lyricsVisible: lyrics, translationVisible: translation,
                     enabled: enabled, controlsExpanded: expanded)
        }
        #expect(resolve(true, true) == .compact)
        #expect(resolve(true, true, expanded: true) == .expanded)
        #expect(resolve(true, false) == .full)
        #expect(resolve(false, true) == .full)
        #expect(resolve(true, true, enabled: false) == .full)
        #expect(resolve(true, true, portrait: false) == .full)
    }

    @Test func playbackTranslationReportsWhereEachDisplayedRowCameFrom() throws {
        let track = try #require(LyricEmbeddedTranslation.collect([(0, "zh-Hans", "窗帘后的微光")]).first)
        #expect(track.convertedToTraditional)
        let result = ResolvedLyricTranslations(selection: .automatic, embedded: [track], prefersProvider: true,
                       imported: [1: "匯入"], base: [0: "系統", 2: "基礎"], contextual: [0: "語境", 2: "改寫"], edits: [2: "手改"])
        #expect(result.origins == [0: .provider(track.id), 1: .imported, 2: .edited])
        let apple = ResolvedLyricTranslations(selection: .appleTranslation, embedded: [track], prefersProvider: true,
                    imported: [0: "匯入"], base: [0: "基礎"], contextual: [0: "語境"], edits: [1: "手改"])
        #expect(apple.origins == [0: .appleTranslation, 1: .edited])
    }

    @Test func declaredPairedLRCKeepsOriginalTimeAxisAndDoesNotGuessUnlabelledPairs() throws {
        let raw = "[00:04.00]When the door opens\n[00:04.00]門開時\n[00:07.00]I will leave\n[00:07.00]我就離開"
        let unlabelled = try #require(Lyrics.parseCandidateFile(raw))
        #expect(unlabelled.translations.isEmpty)
        let parsed = try #require(Lyrics.parseCandidateFile("[translation-language:zh-Hant]\n" + raw))
        #expect(parsed.translations.first?.lines == [0: "門開時", 1: "我就離開"])
        guard case .synced(let original) = parsed.lyrics else { Issue.record("Expected the original LRC"); return }
        #expect(original.map(\.time) == [4, 7])
        #expect(original.map(\.text) == ["When the door opens", "I will leave"])
    }

    @Test func taggedTTMLUsesExactKeysForCoincidentVoices() throws {
        let text = """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
          <head><metadata><itunes:translations><itunes:translation xml:lang="zh-Hans" type="subtitle">
            <itunes:text for="b">窗帘在摇晃</itunes:text>
            <itunes:text for="a">门外没人</itunes:text>
            <itunes:text for="missing">拒絕無對應</itunes:text>
          </itunes:translation></itunes:translations></metadata></head>
          <body><div><p begin="1s" itunes:key="a">Nobody outside.</p>
            <p begin="1s" itunes:key="b">The curtain sways.</p></div></body>
        </tt>
        """
        let parsed = try #require(Lyrics.parseTTMLPayload(text))
        #expect(parsed.lines.map(\.text) == ["Nobody outside.", "The curtain sways."])
        #expect(parsed.translations.first?.lines.count == 2)
        #expect(parsed.translations.first?.lines[0] == "門外沒人")
        #expect(parsed.translations.first?.convertedToTraditional == true)
    }

    @Test func nativeYouLyTranslationsFollowSortedOriginalRows() throws {
        let data = Data(#"""
        {"lyrics":[{"time":5000,"text":"I finally speak","translation":{"lang":"zh-Hant","text":"我終於開口"}},
        {"time":1000,"text":"I keep still","translations":{"zh-Hant":{"text":"我保持沉默"}}}]}
        """#.utf8)
        let result = try #require(Lyrics.parseYouLyPlusPayload(try JSON(data: data)))
        #expect(result.lines.map(\.text) == ["I keep still", "I finally speak"])
        #expect(result.translations.first?.lines == [0: "我保持沉默", 1: "我終於開口"])
    }

    @Test func lrcAPIRealFieldAndTaggedCompanionTranslationAreKept() async throws {
        let body = Data(#"""
        [{"id":"fixture","title":"The Paper Gate","artist":"Fictional Quartet","lrc":"[00:04]A paper gate\n[00:07]Opens at dawn",
          "translations":{"zh-Hant":{"lrc":"[00:04]紙門\n[00:06.95]不使用近似時間\n[00:07]在天明時開啟"}}}]
        """#.utf8)
        let client = LyricsClient(transport: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (body, response)
        })
        let song = Song(id: "lrc-json", title: "The Paper Gate", artistLine: "Fictional Quartet")
        var candidate: LyricsCandidate?
        for await event in client.candidateResults(for: song, sources: [.lrcAPI], customSources: []) {
            candidate = event.candidates.first ?? candidate
        }
        #expect(candidate?.lineCount == 2)
        #expect(candidate?.embeddedTranslations?.first?.lines == [0: "紙門", 1: "在天明時開啟"])
    }

    @Test func sourceChoicePersistsOnlyForItsOriginalVersionAndProfile() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let song = Song(id: "s", title: "The Letter", artistLine: "Fixture")
        let a = try #require(LyricsCandidate.imported(song: song, sourceName: "File", text: "A grey envelope"))
        let b = try #require(LyricsCandidate.imported(song: song, sourceName: "File", text: "A blue envelope"))
        let store = LyricsVersionStore(cache: path.appendingPathComponent("cache"))
        let first = path.appendingPathComponent("profile")
        let other = path.appendingPathComponent("other")
        _ = try await store.selectTranslation(.appleTranslation, for: a, profile: first)
        let opened = await LyricsVersionStore(cache: path.appendingPathComponent("cache")).preference(profile: first, songID: song.id)
        #expect(opened.translationSelections?[a.id.cacheNamespace] == .appleTranslation)
        #expect(opened.translationSelections?[b.id.cacheNamespace] == nil)
        #expect(await store.preference(profile: other, songID: song.id).translationSelections == nil)
    }
}
