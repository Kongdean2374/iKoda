import Foundation
import Testing
@testable import KodaCore

struct ChineseLyricTranslationPlanTests {
    typealias Row = ChineseLyricTranslationPlan.Row

    @Test func chineseOnlyUsesLocalScriptConversionWithoutSemanticRequests() {
        let rows = [Row(id: 0, text: "我有一个梦"), Row(id: 1, text: "像雨后彩虹")]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { _ in "zh-Hans" })
        #expect(plan.fragments.isEmpty)
        #expect(plan.renderedLines(translations: [:]) == [0: "我有一個夢", 1: "像雨後彩虹"])
        #expect(rows[0].text == "我有一个梦")
    }

    @Test func alreadyTraditionalRowsDoNotCreateDuplicateAutomaticTextOrUnavailableNotices() {
        let rows = [Row(id: 0, text: "我有一個夢"), Row(id: 1, text: "像雨后彩虹")]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { _ in "zh-Hant" })
        #expect(plan.fragments.isEmpty)
        #expect(!plan.hasUnrecognizedText)
        #expect(plan.renderedLines(translations: [:]) == [1: "像雨後彩虹"])
        let original = LyricTranslationPresentation(mode: .translation, enabled: true,
                                                    translation: plan.renderedLines(translations: [:])[0])
        #expect(original.showsOriginal)
    }

    @Test func unknownForeignLettersNeedNoticeButURLsAndNumbersDoNot() {
        let unknown = ChineseLyricTranslationPlan(rows: [Row(id: 0, text: "unidentified phrase")], detectLanguage: { _ in nil })
        #expect(unknown.fragments.isEmpty)
        #expect(unknown.hasUnrecognizedText)
        #expect(unknown.renderedLines(translations: [:]).isEmpty)
        let literal = ChineseLyricTranslationPlan(rows: [Row(id: 0, text: "https://example.com/音乐"), Row(id: 1, text: "123 456")],
                                                 detectLanguage: { _ in nil })
        #expect(literal.fragments.isEmpty)
        #expect(!literal.hasUnrecognizedText)
        #expect(literal.renderedLines(translations: [:]).isEmpty)
    }

    @Test func unknownInlineForeignPhraseAlsoNeedsNoticeWithoutDuplicatingTraditionalText() {
        let row = Row(id: 0, text: "我想說 qzxv 永遠")
        let plan = ChineseLyricTranslationPlan(rows: [row], detectLanguage: { $0 == row.text ? "zh-Hant" : nil })
        #expect(plan.hasUnrecognizedText)
        #expect(plan.fragments.isEmpty)
        #expect(plan.renderedLines(translations: [:]).isEmpty)
    }

    @Test func aChineseSongStillRequestsCompleteEnglishJapaneseAndKoreanRows() {
        let rows = [
            Row(id: 0, text: "我有一个梦"), Row(id: 1, text: "I will always love you"),
            Row(id: 2, text: "未来へ行こう"), Row(id: 3, text: "우리 함께 노래해")
        ]
        let languages = ["我有一个梦": "zh-Hans", "I will always love you": "en", "未来へ行こう": "ja", "우리 함께 노래해": "ko"]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { languages[$0] })
        #expect(plan.fragments.map(\.language) == ["en", "ja", "ko"])
        #expect(plan.fragments.map(\.lineID) == [1, 2, 3])
        #expect(plan.fragments[1].text == "未来へ行こう") // Never preconvert Japanese 未来 to 未來.
        let responses = [plan.fragments[0].id: "我會永遠愛你", plan.fragments[1].id: "一起走向未來", plan.fragments[2].id: "我們一起歌唱"]
        #expect(plan.renderedLines(translations: responses) == [0: "我有一個夢", 1: "我會永遠愛你", 2: "一起走向未來", 3: "我們一起歌唱"])
    }

    @Test func inlineEnglishPhraseIsDetectedAsOneRequestAndReassembledInPlace() {
        let row = Row(id: 12, text: "我想说 I love you 永远")
        let languages = [row.text: "zh-Hans", "I love you": "en"]
        let plan = ChineseLyricTranslationPlan(rows: [row], detectLanguage: { languages[$0] })
        #expect(plan.fragments.count == 1)
        #expect(plan.fragments[0].text == "I love you")
        #expect(plan.fragments[0].language == "en")
        #expect(plan.renderedLines(translations: [plan.fragments[0].id: "我愛你"]) == [12: "我想說 我愛你 永遠"])
        #expect(plan.renderedLines(translations: [:]) == [12: "我想說 I love you 永遠"])
        #expect(row.text == "我想说 I love you 永远")
    }

    @Test func latinFragmentsDoNotAssumeEnglishAndCanGroupWithOtherLanguages() {
        let rows = [Row(id: 0, text: "我说 Bonjour tout le monde 再见"), Row(id: 1, text: "永远 I love you")]
        let languages = [rows[0].text: "zh-Hans", rows[1].text: "zh-Hans", "Bonjour tout le monde": "fr", "I love you": "en"]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { languages[$0] })
        let groups = Dictionary(grouping: plan.fragments, by: \.language)
        #expect(Set(groups.keys) == ["fr", "en"])
        #expect(groups["fr"]?.first?.text == "Bonjour tout le monde")
        #expect(groups["en"]?.first?.text == "I love you")
    }

    @Test func inlineJapaneseHanStaysWithKanaAndKoreanWordsKeepTheirPhrase() {
        let rows = [Row(id: 1, text: "我说 未来へ行こう 永远"), Row(id: 2, text: "我说 안녕 우리 永远")]
        let languages = [rows[0].text: "zh-Hans", rows[1].text: "zh-Hans", "未来へ行こう": "ja", "안녕 우리": "ko"]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { languages[$0] })
        #expect(plan.fragments.map(\.text) == ["未来へ行こう", "안녕 우리"])
        #expect(plan.fragments.map(\.language) == ["ja", "ko"])
        let translated = [plan.fragments[0].id: "走向未來", plan.fragments[1].id: "我們你好"]
        #expect(plan.renderedLines(translations: translated) == [1: "我說 走向未來 永遠", 2: "我說 我們你好 永遠"])
    }

    @Test func unsupportedForeignRowsFallBackToOriginalAndPartialMixedRowsKeepSourceFragments() {
        let rows = [Row(id: 0, text: "I love you"), Row(id: 1, text: "我说 I love you 再见"), Row(id: 2, text: "неизвестно")]
        let languages = [rows[0].text: "en", rows[1].text: "zh-Hans"]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { languages[$0] })
        #expect(plan.renderedLines(translations: [:]) == [1: "我說 I love you 再見"])
        #expect(plan.renderedLines(translations: ["0:0": " \n ", "unknown:0": "錯誤回應"]) == [1: "我說 I love you 再見"])
        let presentation = LyricTranslationPresentation(mode: .translation, enabled: true,
                                                       translation: plan.renderedLines(translations: [:])[0])
        #expect(presentation.showsOriginal)
    }

    @Test func urlAndNumberOnlyRowsDoNotBecomeTranslationRequests() {
        let rows = [Row(id: 0, text: "https://example.com/音乐?q=hello"), Row(id: 1, text: "123 456"), Row(id: 2, text: " \n "),
                    Row(id: 3, text: "我说 https://example.com/音乐 再见")]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { text in text.hasPrefix("我说") ? "zh-Hans" : "en" })
        #expect(plan.fragments.isEmpty)
        #expect(plan.renderedLines(translations: [:]) == [3: "我說 https://example.com/音乐 再見"])
    }

    @Test func duplicateSourceIDsCannotCrashOrMixResponsesAcrossOccurrences() {
        let rows = [Row(id: 5, text: "I love you"), Row(id: 5, text: "Discard duplicate"), Row(id: 9, text: "I love you")]
        let plan = ChineseLyricTranslationPlan(rows: rows, detectLanguage: { _ in "en" })
        #expect(plan.fragments.count == 2)
        #expect(Set(plan.fragments.map(\.id)).count == 2)
        #expect(plan.fragments.map(\.lineID) == [5, 9])
        let first = plan.fragments[0], second = plan.fragments[1]
        #expect(plan.renderedLines(translations: [first.id: "第一次", second.id: "第二次"]) == [5: "第一次", 9: "第二次"])
    }

    @Test func originalWordTimesAndSingerRowsAreNotModifiedByPlanning() {
        let lines = [
            LyricLine(id: 0, time: 1, text: "我说 I love you", words: [.init(text: "我说", start: 1, end: 2)],
                      background: [.init(text: "love", start: 2, end: 3)], end: 4, voice: .lead),
            LyricLine(id: 1, time: 1, text: "I love you", end: 4, voice: .duet)
        ]
        let snapshot = lines
        let plan = ChineseLyricTranslationPlan(rows: lines.map { Row(id: $0.id, text: $0.text) },
                                               detectLanguage: { $0.hasPrefix("我说") ? "zh-Hans" : "en" })
        #expect(plan.fragments.map(\.lineID) == [0, 1])
        _ = plan.renderedLines(translations: ["0:0": "我愛你", "1:0": "我愛你"])
        #expect(lines == snapshot)
        #expect(lines[0].words[0].start == 1)
        #expect(lines[0].background[0].start == 2)
        #expect(lines[1].voice == .duet)
    }
}
