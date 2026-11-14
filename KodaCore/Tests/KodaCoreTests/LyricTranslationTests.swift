import Foundation
import Testing
@testable import KodaCore

@Suite struct LyricTranslationTests {
    @Test func earlyTranslationsReassignNearestChoiceToCoverBothLines() {
        let original = [LyricLine(id: 0, time: 1, text: "First"), LyricLine(id: 1, time: 1.6, text: "Second")]
        let translation = LyricTranslationDocument(lines: [.init(time: 0.6, text: "第一句"), .init(time: 1.2, text: "第二句")])
        #expect(translation.aligned(to: original) == [0: "第一句", 1: "第二句"])
        #expect(original.map(\.time) == [1, 1.6])
    }

    @Test func genericRowsStayChronologicalEvenWhenLaterTranslationIsNearer() {
        let original = [LyricLine(id: 0, time: 1, text: "First"), LyricLine(id: 1, time: 1.2, text: "Second")]
        let translation = LyricTranslationDocument(lines: [.init(time: 0.8, text: "第一句"), .init(time: 1.05, text: "第二句")])
        #expect(translation.aligned(to: original) == [0: "第一句", 1: "第二句"])
    }

    @Test func earlyRepeatedStanzasAndMissingLinesKeepTheirOccurrences() {
        let original = [
            LyricLine(id: 0, time: 1, text: "Chorus"), LyricLine(id: 1, time: 1.6, text: "Response"),
            LyricLine(id: 2, time: 5, text: "Missing"),
            LyricLine(id: 3, time: 10, text: "Chorus"), LyricLine(id: 4, time: 10.6, text: "Response")
        ]
        let translation = LyricTranslationDocument(lines: [
            .init(time: 0.6, text: "第一次副歌"), .init(time: 1.2, text: "第一次回應"),
            .init(time: 9.6, text: "第二次副歌"), .init(time: 10.2, text: "第二次回應")
        ])
        #expect(translation.aligned(to: original) == [0: "第一次副歌", 1: "第一次回應", 3: "第二次副歌", 4: "第二次回應"])
    }

    @Test func explicitSingerAndSourceConstraintsSurviveAugmentingPaths() {
        let original = [
            LyricLine(id: 0, time: 1, text: "First lead", voice: .lead),
            LyricLine(id: 1, time: 1, text: "First duet", voice: .duet),
            LyricLine(id: 2, time: 1.6, text: "Second lead", voice: .lead),
            LyricLine(id: 3, time: 1.6, text: "Second duet", voice: .duet)
        ]
        let translation = LyricTranslationDocument(lines: [
            .init(time: 0.6, text: "對唱一", voice: "duet"), .init(time: 0.6, text: "主唱一", voice: "lead"),
            .init(time: 1.2, text: "對唱二", original: "Second duet", voice: "duet"),
            .init(time: 1.2, text: "主唱二", voice: "lead")
        ])
        #expect(translation.aligned(to: original) == [0: "主唱一", 1: "對唱一", 2: "主唱二", 3: "對唱二"])
    }

    @Test func explicitRowIsNeverTakenByAnIncompatibleNearbyLine() {
        let original = [LyricLine(id: 0, time: 1, text: "First"), LyricLine(id: 1, time: 1.2, text: "Second")]
        let translation = LyricTranslationDocument(lines: [.init(time: 1.01, text: "只屬於第二句", original: "Second")])
        #expect(translation.aligned(to: original) == [1: "只屬於第二句"])
        let outside = LyricTranslationDocument(lines: [.init(time: 2, text: "超出時間範圍", original: "First")])
        #expect(outside.aligned(to: original).isEmpty)
    }

    @Test func partialGenericTranslationPrefersTheNearerOriginal() {
        let original = [LyricLine(id: 0, time: 1, text: "Missing"), LyricLine(id: 1, time: 1.4, text: "Translated")]
        let translation = LyricTranslationDocument(lines: [.init(time: 1.3, text: "較接近第二句")])
        #expect(translation.aligned(to: original) == [1: "較接近第二句"])
    }

    @Test func timestampSearchIncludesTheBoundaryWithoutExpandingTolerance() {
        let original = [LyricLine(id: 0, time: 0.8, text: "Original")]
        // 0.8 - 0.5 rounds slightly above 0.3, although abs(0.8 - 0.3) is exactly 0.5.
        let boundary = LyricTranslationDocument(lines: [.init(time: 0.3, text: "邊界內")])
        let outside = LyricTranslationDocument(lines: [.init(time: 0.299_999_9, text: "邊界外")])
        #expect(boundary.aligned(to: original) == [0: "邊界內"])
        #expect(outside.aligned(to: original).isEmpty)
    }

    @Test func maximumCoverageAgreesWithExhaustiveSmallMatchings() {
        // The oracle enumerates every matching rather than repeating the augmenting-path
        // implementation. A fixed generator exercises sparse/dense and source/voice constraints.
        var seed: UInt64 = 0x4B4F4441
        func random(_ upper: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            return Int((seed >> 32) % UInt64(upper))
        }
        for _ in 0..<120 {
            let original = (0..<6).map { index in
                LyricLine(id: index, time: Double(random(20)) / 10, text: "Source \(index)", voice: random(2) == 0 ? .lead : .duet)
            }
            let translated = (0..<5).map { index in
                LyricTranslationDocument.Line(time: Double(random(20)) / 10, text: "譯文 \(index)",
                    original: random(3) == 0 ? original[random(original.count)].text : nil,
                    voice: random(3) == 0 ? (random(2) == 0 ? "lead" : "duet") : nil)
            }
            func compatible(_ source: Int, _ candidate: Int) -> Bool {
                let a = original[source], b = translated[candidate]
                return abs(a.time - b.time) <= 0.5 && (b.original == nil || b.original == a.text)
                    && (b.voice == nil || b.voice == (a.voice == .duet ? "duet" : "lead"))
            }
            func exhaustive(_ source: Int, _ used: Set<Int>) -> Int {
                if source == original.count { return 0 }
                var best = exhaustive(source + 1, used)
                for candidate in translated.indices where !used.contains(candidate) && compatible(source, candidate) {
                    best = max(best, 1 + exhaustive(source + 1, used.union([candidate])))
                }
                return best
            }
            let found = LyricTranslationDocument(lines: translated).aligned(to: original)
            #expect(found.count == exhaustive(0, []))
            #expect(Set(found.values).count == found.count)
            for (source, text) in found {
                let candidate = translated.firstIndex { $0.text == text }!
                #expect(compatible(source, candidate))
            }
        }
    }

    @Test func fiveThousandEarlyRowsUseAnIterativeLongAugmentingPath() {
        let original = (0..<5_000).map { LyricLine(id: $0, time: 1 + Double($0) * 0.6, text: "Source \($0)") }
        let translated = original.map { LyricTranslationDocument.Line(time: $0.time - 0.4, text: "譯文 \($0.id)") }
        let found = LyricTranslationDocument(lines: translated).aligned(to: original)
        #expect(found.count == 5_000)
        #expect(found[0] == "譯文 0")
        #expect(found[4_999] == "譯文 4999")
    }

    @Test func denseDeficientGroupDoesNotReuseRowsOrSearchItRepeatedly() {
        let original = (0..<5_000).map { LyricLine(id: $0, time: 1, text: "Source \($0)") }
        var translated = (0..<200).map { LyricTranslationDocument.Line(time: 1, text: "譯文 \($0)") }
        // An unmatched translation elsewhere prevents the all-candidates-used shortcut;
        // the exhausted simultaneous group must remain closed for the remaining 4,800 rows.
        translated.append(.init(time: 20, text: "其他時間"))
        let found = LyricTranslationDocument(lines: translated).aligned(to: original)
        #expect(found.count == 200)
        #expect(Set(found.values).count == 200)
        #expect(found[0] == "譯文 0")
        #expect(found[200] == nil)
    }


    @Test func bilingualLRCMatchesRepeatedOccurrencesByTime() throws {
        let original = Lyrics.parseLRC("[00:10.00]Hello\n[00:20.00]Bridge\n[00:30.00]Hello")
        let translation = try LyricTranslationDocument.parse(Data("""
        [00:10.00]Hello
        [00:10.00]你好
        [00:30.00]Hello
        [00:30.00]再次你好
        """.utf8))
        let aligned = translation.aligned(to: original)
        #expect(aligned == [0: "你好", 2: "再次你好"])
        #expect(aligned[1] == nil)
    }

    @Test func repeatedLRCStampsProduceSeparateTranslationOccurrences() throws {
        let original = Lyrics.parseLRC("[00:10.00][00:30.00]Chorus")
        let translation = try LyricTranslationDocument.parse(Data("[00:10.00][00:30.00]副歌".utf8))
        #expect(translation.aligned(to: original) == [0: "副歌", 1: "副歌"])
    }

    @Test func timestampsHaveBoundedToleranceAndNoPositionalGuessing() {
        let original = Lyrics.parseLRC("[00:10.00]First\n[00:20.00]Second\n[00:30.00]Third")
        let translation = LyricTranslationDocument(lines: [.init(time: 10.3, text: "第一句"), .init(time: 21, text: "第二句")])
        #expect(translation.aligned(to: original) == [0: "第一句"])
    }

    @Test func simultaneousSingersUseSourceAndVoiceAndDoNotReuseRows() throws {
        let original = [
            LyricLine(id: 0, time: 10, text: "Lead", voice: .lead),
            LyricLine(id: 1, time: 10, text: "Duet", voice: .duet),
            LyricLine(id: 2, time: 20, text: "Together", voice: .together)
        ]
        let translation = LyricTranslationDocument(lines: [
            .init(time: 10, text: "對唱", original: "Duet", voice: "duet"),
            .init(time: 10, text: "主唱", original: "Lead", voice: "lead"),
            .init(time: 20, text: "合唱", voice: "together")
        ])
        let decoded = try LyricTranslationDocument.parse(JSONEncoder().encode(translation))
        #expect(decoded.aligned(to: original) == [0: "主唱", 1: "對唱", 2: "合唱"])
        let one = LyricTranslationDocument(lines: [.init(time: 10, text: "一行譯文")])
        #expect(one.aligned(to: original).count == 1)
    }

    @Test func allDisplayModesKeepTheOriginalTimelineAndFallbackForMissingLines() {
        let words = [LyricWord(text: "Hello", start: 10, end: 11)]
        let background = [LyricWord(text: "echo", start: 10.5, end: 11.5)]
        let original = [LyricLine(id: 7, time: 10, text: "Hello", words: words, background: background, end: 12, voice: .duet)]
        let before = original
        let translation = LyricTranslationDocument(lines: [.init(time: 10, text: "你好")])
        for mode in LyricsDisplayMode.allCases {
            let presentation = LyricTranslationPresentation(mode: mode, enabled: true, translation: translation.aligned(to: original)[7])
            #expect(presentation.showsOriginal == (mode != .translation))
            #expect(presentation.translation == (mode == .original ? nil : "你好"))
            #expect(LyricTranslationPresentation(mode: mode, enabled: true, translation: nil).showsOriginal)
            #expect(LyricTranslationPresentation(mode: mode, enabled: false, translation: "你好").showsOriginal)
            #expect(original == before)
            #expect(Lyrics.index(of: 10.8, in: original) == 0)
        }
    }

    @Test func rejectsInvalidOversizedOrUnknownDocuments() {
        #expect(throws: LyricTranslationDocument.ImportError.self) { try LyricTranslationDocument.parse(Data("No timestamps".utf8)) }
        #expect(throws: LyricTranslationDocument.ImportError.self) { try LyricTranslationDocument.parse(Data(repeating: 65, count: 1_000_001)) }
        #expect(throws: LyricTranslationDocument.ImportError.self) { try LyricTranslationDocument(lines: [.init(time: -1, text: "壞資料")]).validated() }
        #expect(throws: LyricTranslationDocument.ImportError.self) { try LyricTranslationDocument(lines: [.init(time: 10, text: "譯文")], version: 2).validated() }
        #expect(throws: LyricTranslationDocument.ImportError.self) { try LyricTranslationDocument(lines: [.init(time: 10, text: "译文")], language: "zh-Hans").validated() }
        #expect(throws: LyricTranslationDocument.ImportError.self) { try LyricTranslationDocument(lines: [.init(time: 10, text: "譯文", voice: "invalid")]).validated() }
    }

    @Test func cacheSurvivesReopeningAndRemovalWithoutTouchingLyrics() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = LyricTranslationDocument(lines: [.init(time: 10, text: "你好")])
        let store = LyricTranslationStore(directory: directory)
        try await store.save(document, for: "song/../untrusted-id")
        let reopened = LyricTranslationStore(directory: directory)
        #expect(await reopened.document(for: "song/../untrusted-id") == document)
        #expect(await reopened.document(for: "other-song") == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 1)
        try await reopened.remove(for: "song/../untrusted-id")
        #expect(await reopened.document(for: "song/../untrusted-id") == nil)
    }

    @Test func cacheIsBoundedAndCorruptFilesDoNotBreakPlayback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricTranslationStore(directory: directory, maximumDocuments: 2)
        let document = LyricTranslationDocument(lines: [.init(time: 10, text: "你好")])
        for number in 0..<4 { try await store.save(document, for: String(number)) }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files { try Data("broken".utf8).write(to: file) }
        for number in 0..<4 { #expect(await store.document(for: String(number)) == nil) }
    }
}
