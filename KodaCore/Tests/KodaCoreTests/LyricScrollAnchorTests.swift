import Testing
@testable import KodaCore

struct LyricScrollAnchorTests {
    typealias Row = LyricScrollAnchor.Row
    private let original = [Row(id: 0, minY: 0, maxY: 60), Row(id: 1, minY: 86, maxY: 146),
                            Row(id: 2, minY: 172, maxY: 232), Row(id: 3, minY: 258, maxY: 318)]

    @Test func wrappedTranslationsAboveTheReadingRowPreserveItsExactPixelPosition() throws {
        let anchor = try #require(LyricScrollAnchor(source: "song", rows: original, offset: 100,
                                                   viewportHeight: 240, preferredRowID: 2))
        let translated = [Row(id: 0, minY: 0, maxY: 104), Row(id: 1, minY: 130, maxY: 246),
                          Row(id: 2, minY: 272, maxY: 372), Row(id: 3, minY: 398, maxY: 510)]
        let offset = try #require(anchor.restoredOffset(source: "song", rows: translated,
            currentOffset: 100, contentHeight: 890, viewportHeight: 240))
        #expect(offset == 200)
        #expect(translated[2].minY - offset == original[2].minY - 100)
        // SwiftUI may have already preserved the same anchor; never compensate twice.
        #expect(anchor.restoredOffset(source: "song", rows: translated, currentOffset: offset,
            contentHeight: 890, viewportHeight: 240) == nil)
    }

    @Test func manualReadingUsesAVisibleRowWhenThePlayingRowIsOffscreen() throws {
        let anchor = try #require(LyricScrollAnchor(source: "song", rows: original, offset: 180,
                                                   viewportHeight: 120, preferredRowID: 0))
        #expect(anchor.rowID == 2)
        let translated = original.map { Row(id: $0.id, minY: $0.minY + 42, maxY: $0.maxY + 42) }
        #expect(anchor.restoredOffset(source: "song", rows: translated, currentOffset: 180,
            contentHeight: 600, viewportHeight: 120) == 222)
    }

    @Test func removingTranslationsPreservesThePositionWithoutReturningToTheCenter() throws {
        let taller = original.map { Row(id: $0.id, minY: $0.minY + 90, maxY: $0.maxY + 90) }
        let anchor = try #require(LyricScrollAnchor(source: "song", rows: taller, offset: 230,
                                                   viewportHeight: 180, preferredRowID: 2))
        #expect(anchor.restoredOffset(source: "song", rows: original, currentOffset: 230,
            contentHeight: 700, viewportHeight: 180) == 140)
    }

    @Test func contentEdgesClampUsingRawOffsetsAndInsets() throws {
        let anchor = try #require(LyricScrollAnchor(source: "song", rows: original, offset: -20,
                                                   viewportHeight: 200, preferredRowID: 0))
        let moved = [Row(id: 0, minY: -100, maxY: -40)]
        #expect(anchor.restoredOffset(source: "song", rows: moved, currentOffset: 0,
            contentHeight: 800, viewportHeight: 200, topInset: 20) == -20)
        let below = [Row(id: 0, minY: 900, maxY: 980)]
        #expect(anchor.restoredOffset(source: "song", rows: below, currentOffset: 0,
            contentHeight: 1_000, viewportHeight: 200, bottomInset: 15) == 815)
    }

    @Test func aNewSongOrMissingRowCannotReuseAnOldAnchor() throws {
        let anchor = try #require(LyricScrollAnchor(source: "first", rows: original, offset: 80,
                                                   viewportHeight: 200, preferredRowID: 2))
        #expect(anchor.restoredOffset(source: "second", rows: original, currentOffset: 80,
            contentHeight: 800, viewportHeight: 200) == nil)
        #expect(anchor.restoredOffset(source: "first", rows: [], currentOffset: 80,
            contentHeight: 800, viewportHeight: 200) == nil)
    }

    @Test func unchangedLayoutAndInvalidGeometryDoNotGenerateScrollCommands() throws {
        let anchor = try #require(LyricScrollAnchor(source: "song", rows: original, offset: 80,
                                                   viewportHeight: 200, preferredRowID: 2))
        #expect(anchor.restoredOffset(source: "song", rows: original, currentOffset: 80,
            contentHeight: 800, viewportHeight: 200) == nil)
        #expect(LyricScrollAnchor(source: "song", rows: original, offset: .nan,
                                 viewportHeight: 200) == nil)
        #expect(LyricScrollAnchor(source: "song", rows: original, offset: 0,
                                 viewportHeight: 0) == nil)
        #expect(anchor.restoredOffset(source: "song", rows: original, currentOffset: .infinity,
            contentHeight: 800, viewportHeight: 200) == nil)
    }
}
