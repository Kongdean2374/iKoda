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

    @Test func unsupportedSecondaryLanguageDoesNotRemoveOverviewContext() {
        let primary = Evidence("en", confidence: 0.92)
        #expect(LyricAISummaryPolicy.primaryIsUsable(primary, supported: ["en": true, "id": false]))
        #expect(!LyricAISummaryPolicy.primaryIsUsable(primary, supported: ["en": false, "id": true]))
        #expect(LyricAISummaryPolicy.primaryIsUsable(Evidence("id", confidence: 0.32), supported: ["id": false]))
    }

    @Test func pureModelPayloadOmitsAllReferencesEvenWhenProvidedByCaller() throws {
        let rows = [LyricContextRow(id: 3, text: "I didn't let the cat"), .init(id: 4, text: "out of the bag.")]
        for mode in [LyricsTranslationMode.pureAI, .immersive] {
            let request = LyricAIRequest(mode: mode, title: "A Lantern", artist: "Original Fixture", overview: nil,
                  context: rows, requested: [3, 4], base: [3: "不應傳入純 AI 資料"])
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            #expect((json["references"] != nil) == (mode == .immersive))
            #expect(json["requested"] as? [Int] == [3, 4])
            #expect((json["context"] as? [[String: Any]])?.compactMap { $0["text"] as? String } == rows.map(\.text))
        }
        let pure = LyricContextPassages.cacheKey(songID: "song", originalNamespace: "version", mode: .pureAI)
        let immersive = LyricContextPassages.cacheKey(songID: "song", originalNamespace: "version", mode: .immersive)
        #expect(pure != immersive)
        #expect(ImmersiveLyricStatus.resolve(base: .translating, polish: .working) == .polishing)
        #expect(ImmersiveLyricStatus.resolve(base: .unavailable, polish: .completed) == .completed)
    }

    @MainActor @Test func pureWorkDoesNotAdmitAnyAppleTranslationJob() async {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = AutomaticLyricTranslationPipeline(cache: .init(directory: url)) { _, _ in
            Issue.record("Pure AI must not call Apple Translation")
            return .unavailable
        }
        let pure = AutomaticLyricTranslationPipeline.Input(songID: "pure", rows: [.init(id: 0, text: "The lantern goes out")], mode: .pureAI)
        service.setRequests(current: pure, upcoming: [pure], enabled: true, isForeground: true)
        #expect(!service.isWorking)
        #expect(service.snapshot(for: pure).phase == .idle)
    }

    @Test func onlyCompatibleRefrainsShareAContextKey() {
        let rows = [
            LyricContextRow(id: 0, text: "Carry the lantern", voice: .lead),
            .init(id: 1, text: "Hold it close", voice: .lead),
            .init(id: 2, text: "Until the morning", voice: .lead),
            .init(id: 3, text: "Carry the lantern", voice: .lead),
            .init(id: 4, text: "Hold it close", voice: .lead),
            .init(id: 5, text: "Until the morning", voice: .lead),
            .init(id: 6, text: "My father's letter", voice: .lead),
            .init(id: 7, text: "Hold it close", voice: .lead),
            .init(id: 8, text: "Before it disappears", voice: .lead)
        ]
        #expect(LyricContextPassages.repeatContext(rows, at: 1, language: "en") == LyricContextPassages.repeatContext(rows, at: 4, language: "en"))
        #expect(LyricContextPassages.repeatContext(rows, at: 1, language: "en") != LyricContextPassages.repeatContext(rows, at: 7, language: "en"))
        var spoken = rows
        spoken[4] = .init(id: 4, text: rows[4].text, voice: .duet)
        #expect(LyricContextPassages.repeatContext(spoken, at: 1, language: "en") != LyricContextPassages.repeatContext(spoken, at: 4, language: "en"))
    }

    @Test func validationRejectsUnorderedRowsAndCantoneseGrammarButKeepsValidOutput() {
        let expected = (0..<5).map { LyricsPolishValidation.Line(id: $0, text: "A lantern in the valley") }
        let reply = [
            LyricsPolishValidation.Line(id: 0, text: "山谷裡的一盞燈"),
            .init(id: 2, text: "小路盡頭的光"), .init(id: 1, text: "遲到的回覆"),
            .init(id: 3, text: "我哋喺度睇到一盞燈"), .init(id: 4, text: "翻譯結果：山谷的燈")
        ]
        let assessed = LyricPolishBatch.assess(reply, expected: expected)
        #expect(assessed.translations.keys.sorted() == [0, 2])
        #expect(assessed.missing.map(\.id) == [1, 3, 4])
        #expect(LyricAIRetry.permits(.invalidOutput))
        #expect(LyricAIRetry.permits(.timeout))
        #expect(!LyricAIRetry.permits(.refused))
        #expect(!LyricAIRetry.permits(.language))
    }

    @Test func modelDeadlineReportsTimeOutAndCancelsTheCooperativeChild() async {
        let events = DeadlineEvents()
        do {
            _ = try await LyricModelDeadline.run(for: .milliseconds(15), onTimeout: { await events.markTimeout() }) {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { await events.markCancellation(); throw error }
                return true
            }
            Issue.record("Expected a bounded timeout")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        #expect(await events.timedOut)
        #expect(await events.cancelled)
    }

    @Test func preservedTranslationsSurviveClearingTheLRUAndRemainProfileScoped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appending(path: "profile-a")
        let anotherProfile = root.appending(path: "profile-b")
        let cache = AutomaticLyricTranslationCache(directory: root.appending(path: "cache"))
        let store = PreservedLyricTranslationStore()
        let song = Song(id: "fiction", title: "Lanterns", artistLine: "Fixture")
        let version = LyricsCandidate(song: song, source: "fixture", sourceName: "Fixture", metadata: .init(), lyrics: .plain("The gate will open"))
        let revised = LyricsCandidate(song: song, source: "fixture", sourceName: "Fixture", metadata: .init(), lyrics: .plain("The gate will close"))
        let record = PreservedLyricTranslationStore.Record(candidate: version, mode: .pureAI, target: "zh-Hant-TW",
            languages: ["en"], lines: [0: "那扇門會打開"], edits: [0: "門就要開了"], isComplete: true)
        let key = LyricContextPassages.cacheKey(songID: song.id, originalNamespace: version.id.cacheNamespace, mode: .pureAI)
        await cache.store(.init(fragments: ["0": "那扇門會打開"], isComplete: true), for: key)
        try await store.save(record, for: version, profile: profile)
        await cache.clear()
        #expect(await cache.entry(for: key) == nil)
        let reopened = PreservedLyricTranslationStore()
        #expect(try await reopened.read(version, mode: .pureAI, profile: profile) == record)
        #expect(try await reopened.read(version, mode: .immersive, profile: profile) == nil)
        #expect(try await reopened.read(version, mode: .pureAI, profile: anotherProfile) == nil)
        #expect(try await reopened.read(revised, mode: .pureAI, profile: profile) == nil)
        #expect(try await reopened.usage(profile: profile) > 0)
        try await store.remove(version, mode: .pureAI, profile: profile)
        #expect(try await reopened.read(version, mode: .pureAI, profile: profile) == nil)
    }
}

private actor DeadlineEvents {
    private(set) var timedOut = false
    private(set) var cancelled = false
    func markTimeout() { timedOut = true }
    func markCancellation() { cancelled = true }
}
