import Foundation
import Testing
@testable import KodaCore

private actor PlaylistPagesFixture {
    enum Failure: Error { case transient, unexpectedRequest }
    private var pages: [String: PlaylistQueueLoader.Page]
    private var failures: Set<String>
    private(set) var requests: [String] = []
    private(set) var checkpoints: [PlaylistQueueLoader.Checkpoint] = []

    init(_ pages: [String: PlaylistQueueLoader.Page], failOnce: Set<String> = []) {
        self.pages = pages
        failures = failOnce
    }

    func fetch(_ token: String) throws -> PlaylistQueueLoader.Page {
        requests.append(token)
        if failures.remove(token) != nil { throw Failure.transient }
        guard let page = pages[token] else { throw Failure.unexpectedRequest }
        return page
    }

    func record(_ checkpoint: PlaylistQueueLoader.Checkpoint) { checkpoints.append(checkpoint) }
    var latest: PlaylistQueueLoader.Checkpoint { checkpoints.last ?? .init() }
}

@Suite struct PlaylistQueueLoaderTests {
    private func tracks(_ range: Range<Int>) -> [Song] {
        range.map { Song(id: "s\($0)", title: "Track \($0)", artistLine: "Artist \($0 % 7)") }
    }

    private func load(_ fixture: PlaylistPagesFixture, from checkpoint: PlaylistQueueLoader.Checkpoint = .init(),
                      limits: PlaylistQueueLoader.Limits = .init()) async throws -> PlaylistQueueLoader.Checkpoint {
        try await PlaylistQueueLoader.load(from: checkpoint, limits: limits,
            fetchFirst: { try await fixture.fetch("first") },
            fetchMore: { try await fixture.fetch($0) },
            didLoadPage: { await fixture.record($0) })
    }

    @Test func collectsOverFiveHundredWithoutViewportCallbacksInSourceOrder() async throws {
        let fixture = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<100), continuation: "a"),
            "a": .init(songs: tracks(100..<350), continuation: "b"),
            "b": .init(songs: tracks(350..<700), continuation: "c"),
            "c": .init(songs: tracks(700..<1200), continuation: nil)
        ])
        let result = try await load(fixture)
        #expect(result.isComplete)
        #expect(result.pagesLoaded == 4)
        #expect(result.songs == tracks(0..<1200))
        #expect(await fixture.requests == ["first", "a", "b", "c"])
        #expect(await fixture.checkpoints.map(\.songs.count) == [100, 350, 700, 1200])
    }

    @Test func duplicateOccurrencesAndEmptyContinuationPagesArePreserved() async throws {
        let first = tracks(0..<1)
        let fixture = PlaylistPagesFixture([
            "first": .init(songs: first, continuation: "empty"),
            "empty": .init(songs: [], continuation: "last"),
            "last": .init(songs: first + tracks(1..<2), continuation: nil)
        ])
        let result = try await load(fixture)
        #expect(result.songs.map(\.id) == ["s0", "s0", "s1"])
        #expect(result.pagesLoaded == 3)
        #expect(await fixture.requests == ["first", "empty", "last"])
    }

    @Test func retryResumesFailedCursorWithoutRefetchingOrDuplicatingEarlierPages() async throws {
        let fixture = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<200), continuation: "a"),
            "a": .init(songs: tracks(200..<400), continuation: "b"),
            "b": .init(songs: tracks(400..<650), continuation: nil)
        ], failOnce: ["b"])
        await #expect(throws: PlaylistPagesFixture.Failure.self) { try await load(fixture) }
        let saved = await fixture.latest
        #expect(saved.songs == tracks(0..<400))
        #expect(saved.continuation == "b")
        #expect(saved.pagesLoaded == 2)
        let retried = try await load(fixture, from: saved)
        #expect(retried.songs == tracks(0..<650))
        #expect(retried.isComplete)
        #expect(await fixture.requests == ["first", "a", "b", "b"])
    }

    @Test func repeatedCursorAndLongerCyclesFailWithoutCommittingInvalidPage() async throws {
        let direct = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<1), continuation: "a"),
            "a": .init(songs: tracks(1..<2), continuation: "a")
        ])
        await #expect(throws: PlaylistQueueLoader.LoadingError.repeatedContinuation) { try await load(direct) }
        #expect(await direct.requests == ["first", "a"])
        #expect(await direct.latest.songs == tracks(0..<1))
        let cycle = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<1), continuation: "a"),
            "a": .init(songs: tracks(1..<2), continuation: "b"),
            "b": .init(songs: tracks(2..<3), continuation: "a")
        ])
        await #expect(throws: PlaylistQueueLoader.LoadingError.repeatedContinuation) { try await load(cycle) }
        #expect(await cycle.requests == ["first", "a", "b"])
        #expect(await cycle.latest.songs == tracks(0..<2))
    }

    @Test func pageAndSongSafetyLimitsFailExplicitlyRatherThanTruncate() async throws {
        let pageLimited = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<1), continuation: "a"),
            "a": .init(songs: [], continuation: "b"),
            "b": .init(songs: tracks(1..<2), continuation: nil)
        ])
        await #expect(throws: PlaylistQueueLoader.LoadingError.pageLimitExceeded(2)) {
            try await load(pageLimited, limits: .init(maxPages: 2))
        }
        #expect(await pageLimited.requests == ["first", "a"])
        #expect(await pageLimited.latest.isComplete == false)
        let songLimited = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<2), continuation: "a"),
            "a": .init(songs: tracks(2..<4), continuation: nil)
        ])
        await #expect(throws: PlaylistQueueLoader.LoadingError.songLimitExceeded(3)) {
            try await load(songLimited, limits: .init(maxSongs: 3))
        }
        #expect(await songLimited.latest.songs == tracks(0..<2))
        #expect(await songLimited.latest.continuation == "a")
    }

    @Test func cancellationBeforeFetchAndAfterPageBoundaryNeverReturnsPartialSuccess() async throws {
        let fixture = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<100), continuation: "a"),
            "a": .init(songs: tracks(100..<200), continuation: nil)
        ])
        let before = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await load(fixture)
        }
        await #expect(throws: CancellationError.self) { try await before.value }
        #expect(await fixture.requests.isEmpty)
        let during = Task {
            try await PlaylistQueueLoader.load(
                fetchFirst: { try await fixture.fetch("first") },
                fetchMore: { try await fixture.fetch($0) },
                didLoadPage: { checkpoint in
                    await fixture.record(checkpoint)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        await #expect(throws: CancellationError.self) { try await during.value }
        #expect(await fixture.requests == ["first"])
        #expect(await fixture.latest.songs.count == 100)
        let completed = try await load(fixture, from: await fixture.latest)
        #expect(completed.songs.count == 200)
        #expect(await fixture.requests == ["first", "a"])
    }

    @Test func networkCancellationIsPropagatedAsTaskCancellation() async throws {
        let fixture = PlaylistPagesFixture(["first": .init(songs: tracks(0..<1), continuation: "a")])
        let task = Task {
            try await PlaylistQueueLoader.load(
                fetchFirst: { try await fixture.fetch("first") },
                fetchMore: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.cancelled)
                }, didLoadPage: { await fixture.record($0) })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.latest.songs == tracks(0..<1))
        #expect(await fixture.latest.continuation == "a")
    }

    @Test func orderedPrefixAndCompletedCheckpointDoNotRequestTheFirstPageAgain() async throws {
        let prefix = PlaylistQueueLoader.Checkpoint(firstPage: .init(songs: tracks(0..<200), continuation: "next"))
        let fixture = PlaylistPagesFixture([
            "next": .init(songs: tracks(200..<400), continuation: "last"),
            "last": .init(songs: tracks(400..<600), continuation: nil)
        ])
        let result = try await load(fixture, from: prefix)
        #expect(result.songs == tracks(0..<600))
        #expect(result.pagesLoaded == 3)
        #expect(await fixture.requests == ["next", "last"])
        let completeAgain = try await load(fixture, from: result)
        #expect(completeAgain.songs == result.songs)
        #expect(await fixture.requests == ["next", "last"])
        await #expect(throws: PlaylistQueueLoader.LoadingError.songLimitExceeded(100)) {
            try await load(fixture, from: prefix, limits: .init(maxSongs: 100))
        }
    }

    @Test func browsedPrefixRetainsKnownCursorHistoryAndPageBudget() async throws {
        let prefix = PlaylistQueueLoader.Checkpoint(
            firstPage: .init(songs: tracks(0..<400), continuation: "third"),
            completedTokens: ["second"])
        #expect(prefix.pagesLoaded == 2)
        let fixture = PlaylistPagesFixture([
            "third": .init(songs: tracks(400..<600), continuation: "second")
        ])
        await #expect(throws: PlaylistQueueLoader.LoadingError.pageLimitExceeded(2)) {
            try await load(fixture, from: prefix, limits: .init(maxPages: 2))
        }
        #expect(await fixture.requests.isEmpty)
        await #expect(throws: PlaylistQueueLoader.LoadingError.repeatedContinuation) {
            try await load(fixture, from: prefix)
        }
        #expect(await fixture.requests == ["third"])
        #expect(await fixture.checkpoints.isEmpty)
        #expect(prefix.songs == tracks(0..<400))
    }

    @Test func allCollectionOccurrencesAreEligibleForInitialOrdinaryAndSmartShuffle() async throws {
        let fixture = PlaylistPagesFixture([
            "first": .init(songs: tracks(0..<100), continuation: "rest"),
            "rest": .init(songs: tracks(100..<850), continuation: nil)
        ])
        let source = try await load(fixture).songs
        var selectedLaterPage = false
        for seed in 0..<20 {
            var rng = SeededGenerator(state: UInt64(seed))
            let start = Int.random(in: 0..<source.count, using: &rng)
            selectedLaterPage = selectedLaterPage || start >= 100
            var plain = PlayQueue()
            plain.replace(with: source, startAt: start, shuffled: true, using: &rng)
            #expect(plain.current?.song == source[start])
            #expect(plain.items.count == 850)
            #expect(Set(plain.items.map(\.song.id)) == Set(source.map(\.id)))
            var smart = PlayQueue()
            smart.replaceSmart(with: source, startAt: start, settings: .init(), context: .init(), using: &rng)
            #expect(smart.current?.song == source[start])
            #expect(smart.items.count == 850)
            #expect(smart.upcoming.count == 849)
            #expect(Set(smart.items.map(\.song.id)) == Set(source.map(\.id)))
        }
        #expect(selectedLaterPage)
    }

    @Test func invalidLimitsAndEmptyCollectionAreHandledWithoutGuessing() async throws {
        let fixture = PlaylistPagesFixture(["first": .init(songs: [], continuation: nil)])
        await #expect(throws: PlaylistQueueLoader.LoadingError.invalidLimits) {
            try await load(fixture, limits: .init(maxPages: 0))
        }
        #expect(await fixture.requests.isEmpty)
        let empty = try await load(fixture)
        #expect(empty.isComplete)
        #expect(empty.songs.isEmpty)
    }
}
