import Foundation
import Testing
@testable import KodaCore

@Suite struct CarPlayLyricsTimingTests {
    private let lines = [
        LyricLine(id: 0, time: 3, text: "First sung line", end: 5),
        LyricLine(id: 1, time: 7, text: "Second sung line", end: 10),
        LyricLine(id: 2, time: 11, text: "First sung line"),
    ]

    @Test func delayMovesOriginalAndTranslationAsOneLine() {
        let translations = [0: "第一句", 1: "第二句"]
        let early = CarPlayLyricsTiming.sample(at: 2.5, offset: -0.5, in: lines)
        let late = CarPlayLyricsTiming.sample(at: 3.4, offset: 0.5, in: lines)
        #expect(early.line.flatMap { translations[$0.id] } == "第一句")
        #expect(early.nextPosition == 4.5)
        #expect(late.line == nil)
        #expect(late.nextPosition == 3.5)
        #expect(CarPlayLyricsTiming.sample(at: 3.5, offset: 0.5, in: lines).line?.id == 0)
    }

    @Test func gapsAndSeeksUseTheActualPlayhead() {
        #expect(CarPlayLyricsTiming.sample(at: 12, offset: 0, in: lines).line?.id == 2)
        #expect(CarPlayLyricsTiming.sample(at: 8, offset: 0, in: lines).line?.id == 1)
        let gap = CarPlayLyricsTiming.sample(at: 5.1, offset: 0, in: lines)
        #expect(gap.line == nil)
        #expect(gap.nextPosition == 7)
        #expect(CarPlayLyricsTiming.sample(at: 0, offset: 0, in: lines).line == nil)
    }

    @Test func noLinesAndInvalidOffsetsAreSafe() {
        #expect(CarPlayLyricsTiming.sample(at: 32, offset: 1, in: []).line == nil)
        #expect(CarPlayLyricsTiming.sample(at: .infinity, offset: 0, in: lines).nextPosition == nil)
        #expect(CarPlayLyricsTiming.normalizedOffset(.nan) == 0)
        #expect(CarPlayLyricsTiming.normalizedOffset(-10.6) == -10)
        #expect(CarPlayLyricsTiming.normalizedOffset(100) == 10)
        #expect(CarPlayLyricsTiming.normalizedOffset(1.16) == 1.2)
    }

    @Test @MainActor func delayPersistsPerTrackAndProfileWithoutChangingPhoneTiming() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "koda-carplay-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "one")
        let second = root.appending(path: "two")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let library = Library(directory: first)
        library.setLyricsOffset(-0.8, for: "song")
        library.setCarPlayLyricsOffset(1.1, for: "song")
        library.setCarPlayLyricsOffset(-4.5, for: "other")
        library.flush()

        let reopened = Library(directory: first)
        #expect(reopened.carPlayLyricsOffset(for: "song") == 1.1)
        #expect(reopened.carPlayLyricsOffset(for: "other") == -4.5)
        #expect(reopened.lyricsOffset(for: "song") == -0.8)
        reopened.open(directory: second)
        #expect(reopened.carPlayLyricsOffset(for: "song") == 0)
        reopened.setCarPlayLyricsOffset(2.2, for: "song")
        reopened.open(directory: first)
        #expect(reopened.carPlayLyricsOffset(for: "song") == 1.1)
        reopened.setCarPlayLyricsOffset(0, for: "song")
        reopened.flush()
        #expect(Library(directory: first).carPlayLyricsOffset(for: "song") == 0)
        #expect(Library(directory: first).lyricsOffset(for: "song") == -0.8)
    }

    @Test @MainActor func previousLibrarySnapshotStillDecodes() throws {
        let previous = Data(#"{"lyricsOffsets":{"song":1.2}}"#.utf8)
        let snapshot = try JSONDecoder().decode(Library.Snapshot.self, from: previous)
        #expect(snapshot.lyricsOffsets["song"] == 1.2)
        #expect(snapshot.carPlayLyricsOffsets.isEmpty)
    }
}
