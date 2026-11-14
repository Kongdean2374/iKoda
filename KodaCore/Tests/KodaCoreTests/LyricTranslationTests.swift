import Foundation
import Testing
@testable import KodaCore

@Suite struct LyricTranslationTests {
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
