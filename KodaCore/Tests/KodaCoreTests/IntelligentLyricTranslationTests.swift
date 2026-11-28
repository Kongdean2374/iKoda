import Foundation
import Testing
@testable import KodaCore

@Suite struct IntelligentLyricTranslationTests {
    typealias Row = ChineseLyricTranslationPlan.Row
    typealias Evidence = LyricLanguageProfile.Evidence
    typealias Route = AppleLyricDiagnostics.LanguageRoute

    @Test func shortLatinGuessesAndVocalizationsCannotOverrideTheSong() {
        let texts = [
            "I will carry the lantern until we make it home",
            "Only you", "Doo, da, la, na", "Not yet",
            "Orion", "Let me carry the lantern until the long night ends",
            "Oh, please don't leave!", "…", "   "
        ]
        let plan = ChineseLyricTranslationPlan(rows: texts.enumerated().map { .init(id: $0, text: $1) },
            languageEvidence: { text in
                switch text {
                case "Only you": .init("id", confidence: 0.92)
                case "Not yet", "Orion": .init("pt", confidence: 0.92)
                default: .init("en", confidence: 0.95)
                }
            })
        #expect(plan.languageProfile.primary?.language == "en")
        #expect(plan.languageProfile.corrected == 3)
        #expect(plan.languageProfile.vocalizations == [2])
        #expect(plan.languageProfile.noTranslation == [2, 7, 8])
        #expect(Set(plan.fragments.map(\.language)) == ["en"])
        #expect(plan.fragments.map(\.lineID).contains(6))
        #expect(!plan.hasUnrecognizedText)
    }

    @Test func trustsScriptAndSustainedLanguageSwitches() {
        let lines = ["I keep the door open while the street goes dark", "La pluie traverse encore la ville",
                     "Nous suivons la lueur qui nous ramène", "月がまだ空にある", "함께 길을 걸어요",
                     "我還在等 I will carry the lantern"]
        let plan = ChineseLyricTranslationPlan(rows: lines.enumerated().map { .init(id: $0, text: $1) },
            languageEvidence: { text in
                if text.hasPrefix("La pluie") || text.hasPrefix("Nous") { .init("fr", confidence: 0.95) }
                else if text == "我還在等 I will carry the lantern" { .init("zh", confidence: 0.96) }
                else { .init("en", confidence: 0.90) }
            })
        #expect(Set(plan.fragments.map(\.language)) == ["en", "fr", "ja", "ko"])
        #expect(plan.fragments.last?.text == "I will carry the lantern")
    }

    @Test func prioritizesConfirmedTaiwanPairAndDistinguishesHongKongFallback() {
        let hk = Route(source: "en", target: "zh-HK", support: .available, strategy: .highFidelity)
        let tw = Route(source: "en", target: "zh-Hant-TW", support: .download, strategy: .lowLatency)
        let unsupported = Route(source: "en", target: "zh-TW", support: .unsupported, strategy: .standard)
        let standard = Route(source: "en", target: "zh-Hans", support: .available, strategy: .standard)
        #expect(LyricChineseTarget.choose([hk, unsupported, tw], prefersQuality: true) == tw)
        #expect(LyricChineseTarget.choose([hk, unsupported], prefersQuality: true)?.target == "zh-HK")
        #expect(LyricChineseTarget.choose([hk, standard], prefersQuality: true) == standard)
        let input = AutomaticLyricTranslationPipeline.Input(songID: "fixture", rows: [.init(id: 0, text: "Into the blue")], namespace: "identified", mode: .quality, routes: [tw])
        let fallback = AutomaticLyricTranslationPipeline.Input(songID: input.songID, rows: input.rows, namespace: "identified", mode: .quality, routes: [hk])
        #expect(AutomaticLyricTranslationPipeline.cacheKey(input) != AutomaticLyricTranslationPipeline.cacheKey(fallback))
    }
}
