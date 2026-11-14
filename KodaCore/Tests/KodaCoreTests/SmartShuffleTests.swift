import Foundation
import Testing
@testable import KodaCore

@Suite struct SmartShuffleTests {
    private func track(_ id: String, _ artist: String = "Artist") -> Song {
        Song(id: id, title: id, artistLine: artist)
    }

    @Test func seededRankingIsReproducibleAndKeepsEveryOccurrence() {
        let items = (0..<60).map { QueueItem(song: track("s\($0)", "a\($0 % 6)")) }
        var first = SeededGenerator(state: 241), second = SeededGenerator(state: 241)
        let a = SmartShuffle.order(items, settings: .init(), context: .init(), using: &first)
        let b = SmartShuffle.order(items, settings: .init(), context: .init(), using: &second)
        #expect(a == b)
        #expect(Set(a.map(\.id)) == Set(items.map(\.id)))
        #expect(a != items)
        var other = SeededGenerator(state: 242)
        #expect(SmartShuffle.order(items, settings: .init(), context: .init(), using: &other) != a)
    }

    @Test func noSignalsNaturallyUsesOrdinaryShuffle() {
        let items = (0..<15).map { QueueItem(song: track("s\($0)")) }
        var a = SeededGenerator(state: 17), b = SeededGenerator(state: 17)
        #expect(SmartShuffle.order(items, settings: .init(), context: .init(), using: &a) == items.shuffled(using: &b))
    }

    @Test func recentSongsAreDeferredAndDuplicateOccurrencesSpreadOut() {
        let items = (0..<30).map { QueueItem(song: track("s\($0 % 15)", "a\($0 % 5)")) }
        let recent = (0..<7).map { "s\($0)" }
        var smartRecent = 0, plainRecent = 0, smartDuplicates = 0, plainDuplicates = 0
        for seed in 0..<80 {
            var a = SeededGenerator(state: UInt64(seed)), b = SeededGenerator(state: UInt64(seed))
            let ranked = SmartShuffle.order(items, after: track("s0", "a0"), settings: .init(strength: .high),
                                           context: .init(recentSongIDs: recent), using: &a)
            let plain = items.shuffled(using: &b)
            smartRecent += ranked.prefix(5).filter { recent.contains($0.song.id) }.count
            plainRecent += plain.prefix(5).filter { recent.contains($0.song.id) }.count
            smartDuplicates += zip(ranked, ranked.dropFirst()).filter { $0.0.song.id == $0.1.song.id }.count
            plainDuplicates += zip(plain, plain.dropFirst()).filter { $0.0.song.id == $0.1.song.id }.count
        }
        #expect(smartRecent < plainRecent / 2)
        #expect(smartDuplicates < plainDuplicates)
    }

    @Test func respectsArtistLimitWheneverAnAlternativeRemains() {
        let items = (0..<45).map { QueueItem(song: track("s\($0)", "a\($0 % 3)")) }
        for limit in 1...3 {
            var rng = SeededGenerator(state: 89)
            let ranked = SmartShuffle.order(items, settings: .init(artistLimit: limit), context: .init(), using: &rng)
            var run = 0, last: String?
            for (index, item) in ranked.enumerated() {
                let artist = SmartShuffle.artistKey(item.song)
                if run >= limit, ranked[index...].contains(where: { SmartShuffle.artistKey($0.song) != last }) {
                    #expect(artist != last)
                }
                run = artist == last ? run + 1 : 1
                last = artist
            }
        }
    }

    @Test func likedWeightsAndSkipsInfluenceOrderAcrossSeeds() {
        let items = (0..<10).map { QueueItem(song: track("s\($0)")) }
        var likedFirst = 0, skippedFirst = 0
        let context = SmartShuffleContext(skipCounts: ["s1": 15], likedSongIDs: ["s0"])
        for seed in 0..<150 {
            var rng = SeededGenerator(state: UInt64(seed))
            let ranked = SmartShuffle.order(items, settings: .init(likedWeight: 3, strength: .high), context: context, using: &rng)
            if ranked.first?.song.id == "s0" { likedFirst += 1 }
            if ranked.first?.song.id == "s1" { skippedFirst += 1 }
        }
        #expect(likedFirst > 20)
        #expect(skippedFirst < likedFirst / 3)
    }

    @Test func tinyAndSingleArtistQueuesAlwaysFinish() {
        for count in 0...3 {
            let items = (0..<count).map { _ in QueueItem(song: track("same")) }
            var rng = SeededGenerator(state: 1)
            let result = SmartShuffle.order(items, settings: .init(strength: .high), context: .init(recentSongIDs: ["same"]), using: &rng)
            #expect(result.count == count)
            #expect(Set(result.map(\.id)) == Set(items.map(\.id)))
        }
        let items = (0..<100).map { QueueItem(song: track("s\($0)")) }
        var rng = SeededGenerator(state: 3)
        #expect(SmartShuffle.order(items, settings: .init(), context: .init(recentSongIDs: ["s0"]), using: &rng).count == 100)
    }

    @Test func freshSmartCollectionIncludesSongsBeforeTappedIndexAndRestoresOriginalOrder() {
        let source = (0..<20).map { track("s\($0)", "a\($0 % 4)") }
        var queue = PlayQueue()
        var rng = SeededGenerator(state: 63)
        queue.replaceSmart(with: source, startAt: 12, settings: .init(), context: .init(), using: &rng)
        #expect(queue.current?.song.id == "s12")
        #expect(queue.history.isEmpty)
        #expect(queue.upcoming.count == 19)
        #expect(Set(queue.upcoming.map(\.song.id)) == Set(source.map(\.id)).subtracting(["s12"]))
        let tapped = queue.current
        queue.setSmartShuffle(false, settings: .init(), context: .init(), using: &rng)
        #expect(queue.items.map(\.song.id) == source.map(\.id))
        #expect(queue.current == tapped)
    }

    @Test func manualInsertAppendAndDraggingStayFixed() {
        var queue = PlayQueue()
        queue.replace(with: (0..<20).map { track("s\($0)", "a\($0 % 4)") }, startAt: 2)
        let current = queue.current, history = Array(queue.history)
        queue.playNext([track("manual-next"), track("manual-next-2")])
        queue.append([track("manual-last")])
        var rng = SeededGenerator(state: 19)
        queue.setSmartShuffle(true, settings: .init(), context: .init(), using: &rng)
        #expect(queue.current == current)
        #expect(Array(queue.history) == history)
        #expect(queue.upcoming.prefix(2).map(\.song.id) == ["manual-next", "manual-next-2"])
        #expect(queue.upcoming.last?.song.id == "manual-last")
        queue.moveUpcoming(fromOffsets: [3], toOffset: 0)
        let arranged = Array(queue.upcoming)
        queue.setSmartShuffle(false, settings: .init(), context: .init(), using: &rng)
        #expect(Array(queue.upcoming) == arranged)
        queue.setSmartShuffle(true, settings: .init(), context: .init(), using: &rng)
        #expect(Array(queue.upcoming) == arranged)
    }

    @Test func smartOrderDoesNotChangeRepeatOrPreviousAndCanReturnToOrdinaryShuffle() {
        var queue = PlayQueue()
        queue.replace(with: (0..<10).map { track("s\($0)", "a\($0 % 2)") })
        queue.repeatMode = .one
        var rng = SeededGenerator(state: 72)
        queue.setSmartShuffle(true, settings: .init(), context: .init(), using: &rng)
        let first = queue.current
        #expect(queue.advance(automatic: true) == first)
        let next = queue.advance(automatic: false)
        #expect(next != first)
        #expect(queue.retreat() == first)
        queue.setShuffle(true, using: &rng)
        #expect(queue.isShuffled)
        #expect(!queue.isSmartShuffled)
        queue.setShuffle(false, using: &rng)
        #expect(queue.items.map(\.song.id) == (0..<10).map { "s\($0)" })
        queue.repeatMode = .all
        _ = queue.jump(to: queue.items.last!.id)
        #expect(queue.advance(automatic: true) == queue.items.first)
    }

    @Test func savedSmartQueueKeepsManualProtectionAndLegacyDataStillDecodes() throws {
        var queue = PlayQueue()
        queue.replace(with: (0..<10).map { track("s\($0)", "a\($0 % 2)") }, startAt: 2)
        queue.playNext([track("placed")])
        queue.setSmartShuffle(true, settings: .init(), context: .init())
        let data = try JSONEncoder().encode(queue)
        var restored = try JSONDecoder().decode(PlayQueue.self, from: data)
        #expect(restored == queue)
        restored.setSmartShuffle(false, settings: .init(), context: .init())
        #expect(restored.upcoming.first?.song.id == "placed")
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "isSmartShuffled")
        legacy.removeValue(forKey: "protectedUpcoming")
        let decoded = try JSONDecoder().decode(PlayQueue.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.items == queue.items)
        #expect(decoded.current == queue.current)
        #expect(!decoded.isSmartShuffled)
    }

    @Test func corruptSavedIndexesAndDuplicateIDsCannotCrashQueueAccess() throws {
        var queue = PlayQueue()
        queue.replace(with: [track("a"), track("b")])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        json["currentIndex"] = 999
        var items = try #require(json["items"] as? [[String: Any]])
        items[1]["id"] = items[0]["id"]
        json["items"] = items
        var restored = try JSONDecoder().decode(PlayQueue.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.current?.song.id == "b")
        #expect(Set(restored.items.map(\.id)).count == 2)
        restored.trimHistory(keeping: -1)
        #expect(restored.current?.song.id == "b")
    }

    @Test func settingsMigrateAndBoundedHistoryRoundTrips() throws {
        let defaults = try JSONDecoder().decode(SmartShuffleSettings.self, from: Data("{}".utf8))
        #expect(defaults == SmartShuffleSettings())
        let invalid = SmartShuffleSettings(recentWindow: 500, artistLimit: 0, likedWeight: .nan).validated
        #expect(invalid.recentWindow == 50 && invalid.artistLimit == 1 && invalid.likedWeight == 1.5)
        var history = SmartShuffleHistory()
        for n in 0..<600 {
            history.recordPlay(track("s\(n)"))
            if n % 2 == 0 { history.recordSkip(track("s\(n)")) }
        }
        #expect(history.eventCount == SmartShuffleHistory.eventLimit)
        #expect(history.context().recentSongIDs.count == 50)
        let restored = try JSONDecoder().decode(SmartShuffleHistory.self, from: JSONEncoder().encode(history))
        #expect(restored == history)
        #expect(restored.context().skipCounts.values.reduce(0, +) > 0)
        history.clear()
        #expect(history.context().recentSongIDs.isEmpty)
    }
}
