import Foundation
import Testing
@testable import KodaCore

struct TraditionalChineseLyricsTests {
    @Test(arguments: ["zh", "zh-Hans", "zh-Hant", "zh-Hant-TW", "zh_CN", "ZH_hant_tw", " zh-Hans "])
    func chineseLanguageDetectionAcceptsExplicitLanguageIdentifiers(_ language: String) {
        #expect(TraditionalChineseLyrics.isChinese(language: language))
    }

    @Test(arguments: ["", "ja", "ko", "en", "zho", "zhang", "-zh", "jv-Hant"])
    func chineseLanguageDetectionDoesNotMistakeOtherLanguagesForChinese(_ language: String) {
        #expect(!TraditionalChineseLyrics.isChinese(language: language))
        #expect(!TraditionalChineseLyrics.isChinese(language: nil))
    }

    @Test func localScriptConversionPreservesBreaksWhitespaceAndNonChineseText() {
        let simplified = "  音乐让我们相遇\n听见风的声音\tHello 123!  "
        #expect(TraditionalChineseLyrics.convert(simplified) == "  音樂讓我們相遇\n聽見風的聲音\tHello 123!  ")
        #expect(TraditionalChineseLyrics.convert("音樂與期待") == "音樂與期待")
        #expect(TraditionalChineseLyrics.convert("") == "")
    }

    @Test func conversionKeepsRepeatedDuetLinesSeparateAndLeavesOriginalTimingUntouched() {
        let word = LyricWord(text: "音乐", start: 1.2, end: 1.8, spaceAfter: false)
        let backing = LyricWord(text: "回声", start: 1.4, end: 2.1)
        let lines = [
            LyricLine(id: 10, time: 1.2, text: "音乐让我们相遇", words: [word], background: [backing], end: 2.4, voice: .lead),
            LyricLine(id: 11, time: 1.2, text: "音乐让我们相遇", end: 2.5, voice: .duet),
            LyricLine(id: 25, time: 8.5, text: "音乐让我们相遇", end: 10, voice: .together),
            LyricLine(id: 26, time: 11, text: " \n\t ")
        ]
        let original = lines
        let translated = TraditionalChineseLyrics.convertedLines(lines)
        #expect(translated == [10: "音樂讓我們相遇", 11: "音樂讓我們相遇", 25: "音樂讓我們相遇"])
        #expect(lines == original)
        #expect(lines[0].words == [word])
        #expect(lines[0].background == [backing])
        #expect(lines.map(\.time) == [1.2, 1.2, 8.5, 11])
        #expect(lines.map(\.voice) == [.lead, .duet, .together, .lead])
    }

    @Test func partialImportOverridesOnlyAvailableLinesAndPreservesTheirFormatting() {
        let automatic = [1: "自動一", 2: "自動二", 3: "自動三", 4: "\n  "]
        let imported = [1: " 匯入一\n第二行 ", 2: " \n\t ", 5: "匯入五"]
        let result = TraditionalChineseLyrics.merged(automatic: automatic, imported: imported, importsEnabled: true)
        #expect(result == [1: " 匯入一\n第二行 ", 2: "自動二", 3: "自動三", 5: "匯入五"])
        #expect(automatic[1] == "自動一")
        #expect(imported[2] == " \n\t ")
    }

    @Test func disablingImportsUsesAutomaticResultsAndMissingResultsStayAbsent() {
        let result = TraditionalChineseLyrics.merged(automatic: [1: "自動一", 2: "\n"],
                                                     imported: [1: "匯入一", 3: "匯入三"], importsEnabled: false)
        #expect(result == [1: "自動一"])
        #expect(TraditionalChineseLyrics.merged(automatic: [:], imported: [:], importsEnabled: true).isEmpty)
    }

    @Test func automaticAndImportedResultsShareDisplayModesWithoutInventingTiming() {
        let results = TraditionalChineseLyrics.merged(automatic: [0: "自動譯文"], imported: [1: "匯入譯文"], importsEnabled: true)
        for text in results.values {
            let original = LyricTranslationPresentation(mode: .original, enabled: true, translation: text)
            #expect(original.showsOriginal)
            #expect(original.translation == nil)
            let translated = LyricTranslationPresentation(mode: .translation, enabled: true, translation: text)
            #expect(!translated.showsOriginal)
            #expect(translated.translation == text)
            let bilingual = LyricTranslationPresentation(mode: .bilingual, enabled: true, translation: text)
            #expect(bilingual.showsOriginal)
            #expect(bilingual.translation == text)
        }
        let missing = LyricTranslationPresentation(mode: .translation, enabled: true, translation: results[2])
        #expect(missing.showsOriginal)
        #expect(missing.translation == nil)
        let off = LyricTranslationPresentation(mode: .translation, enabled: false, translation: results[0])
        #expect(off.showsOriginal)
        #expect(off.translation == nil)
    }
}
