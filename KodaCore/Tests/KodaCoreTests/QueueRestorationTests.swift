import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite(.serialized)
struct QueueRestorationTests {
    private func songs(_ count: Int, prefix: String = "collection") -> [Song] {
        (0..<count).map { Song(id: "\(prefix)-\($0)", title: "Song \($0)", artistLine: "Artist", duration: 180) }
    }

    /// Real Player save/recreate boundary, with audio-session activation rejected locally.
    /// No stream is loaded: the saved source must come from PlayQueue, not AVPlayer.items().
    @Test(arguments: [false, true])
    func sixHundredShuffledSongsSurviveColdRestoreAfterMovingPastHistoryLimit(smart: Bool) async throws {
        let suite = "koda.queue-restoration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        player.autoplay = false
        player.audioSessionActivator = { false }
        player.streamLoader = { _, _ in
            Issue.record("Restoring a logical queue must not request audio")
            throw MusicError.signedOut
        }
        player.smartShuffleSettings.enabled = smart
        player.playlistRandomIndex = { $0 - 1 }
        let source = songs(600)
        let started = await player.playPlaylist(source, continuation: nil, shuffled: true).value
        #expect(started)
        #expect(player.current?.id == "collection-599")
        #expect(player.queue.items.count == 600)
        let later = player.queue.items[450].id
        player.jump(to: later)
        player.setRepeat(.all)
        player.seek(to: 42)
        player.persistQueueNow()
        let saved = player.queue
        #expect(saved.currentIndex == 450)
        #expect(saved.items.count == 600)
        #expect(player.loadedItemCount == 0)

        let restored = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
        defer { restored.stop() }
        #expect(restored.queue == saved)
        #expect(restored.queue.current?.id == later)
        #expect(restored.position() == 42)
        #expect(restored.repeatMode == .all)
        #expect(restored.isSmartShuffled == smart)
        #expect(!restored.wantsToPlay)
        #expect(restored.loadedItemCount == 0)
        #expect(Set(restored.queue.items.map(\.song.id)) == Set(source.map(\.id)))
        var nextCycle = restored.queue
        var visited: Set<UUID> = []
        for _ in 0..<600 {
            if let item = nextCycle.advance(automatic: true) { visited.insert(item.id) }
            nextCycle.trimHistory(keeping: Player.historyLimit)
        }
        #expect(visited == Set(saved.items.map(\.id)))
        #expect(nextCycle.items == saved.items)
    }

    @Test func aFiniteCollectionKeepsEveryOccurrenceAcrossRepeatedCycles() throws {
        var queue = PlayQueue()
        var random = SeededGenerator(state: 42)
        queue.replace(with: songs(600), startAt: 599, shuffled: true, using: &random)
        queue.retainCurrentCollection()
        queue.repeatMode = .all
        let original = queue.items
        for _ in 0..<1_250 {
            queue.advance(automatic: true)
            queue.trimHistory(keeping: 100)
        }
        #expect(queue.items == original)
        let restored = try JSONDecoder().decode(PlayQueue.self, from: JSONEncoder().encode(queue))
        #expect(restored == queue)
        queue.setShuffle(false)
        #expect(queue.items.map(\.song.id) == songs(600).map(\.id))
    }

    @Test(arguments: [false, true])
    func aCompleteCollectionEnqueuedIntoAnEmptyPlayerRetainsItsPool(playNext: Bool) async throws {
        let suite = "koda.empty-queue-restoration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        player.autoplay = false
        player.audioSessionActivator = { false }
        player.streamLoader = { _, _ in throw MusicError.signedOut }
        let source = songs(600)
        let started = await player.enqueuePlaylist(source, continuation: nil, playNext: playNext).value
        #expect(started)
        let later = player.queue.items[450].id
        player.jump(to: later)
        player.persistQueueNow()
        #expect(player.queue.items.map(\.song.id) == source.map(\.id))
        #expect(player.loadedItemCount == 0)
        let restored = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
        defer { restored.stop() }
        #expect(restored.queue == player.queue)
        #expect(restored.queue.currentIndex == 450)
        #expect(restored.queue.items.count == 600)
        #expect(restored.loadedItemCount == 0)
    }

    @Test func radioHistoryStaysBoundedOutsideTheRetainedCollection() {
        var queue = PlayQueue()
        queue.replace(with: songs(600))
        queue.retainCurrentCollection()
        let source = queue.items
        queue.append(songs(1_000, prefix: "radio"), protectingOrder: false)
        let current = queue.items[1_450].id
        queue.jump(to: current)
        queue.trimHistory(keeping: 100)
        #expect(queue.current?.id == current)
        #expect(Array(queue.items.prefix(600)) == source)
        #expect(queue.history.filter { $0.song.id.hasPrefix("radio-") }.count == 100)
        #expect(queue.upcoming.count == 149)
        #expect(queue.items.count == 850)
        #expect(queue.peekNext(automatic: true)?.song.id == "radio-851")
    }

    @Test func manualEditsPersistWithoutResurrectingRemovedSourceSongs() throws {
        var queue = PlayQueue()
        queue.replace(with: songs(600))
        queue.retainCurrentCollection()
        let removed = queue.items[300]
        let didRemove = queue.remove(removed.id)
        #expect(didRemove)
        queue.playNext(songs(2, prefix: "manual"))
        queue.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let manual = Array(queue.upcoming.prefix(2))
        var restored = try JSONDecoder().decode(PlayQueue.self, from: JSONEncoder().encode(queue))
        #expect(Array(restored.upcoming.prefix(2)) == manual)
        #expect(!restored.items.contains { $0.id == removed.id })
        restored.clearUpcoming()
        restored.append(songs(300, prefix: "radio"), protectingOrder: false)
        let radioCurrent = restored.items[250].id
        restored.jump(to: radioCurrent)
        restored.trimHistory(keeping: 100)
        #expect(restored.items.filter { $0.song.id.hasPrefix("collection-") }.count == 1)
        #expect(!restored.items.contains { $0.id == removed.id })
        #expect(restored.history.filter { $0.song.id.hasPrefix("radio-") }.count == 100)
        #expect(restored.current?.id == radioCurrent)
    }

    @Test func aLegacySnapshotRetainsOnlyItsKnownPoolAndBoundsFutureRadioHistory() throws {
        var queue = PlayQueue()
        queue.replace(with: songs(600), startAt: 450)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        json.removeValue(forKey: "retainedCollectionOccurrenceIDs")
        var restored = try JSONDecoder().decode(PlayQueue.self, from: JSONSerialization.data(withJSONObject: json))
        let current = restored.current
        let upcoming = Array(restored.upcoming)
        restored.trimHistory(keeping: 100)
        #expect(restored.current == current)
        #expect(Array(restored.upcoming) == upcoming)
        #expect(restored.items == queue.items)
        #expect(restored.history.count == 450)
        restored.append(songs(1_000, prefix: "new-radio"), protectingOrder: false)
        let radioCurrent = restored.items[1_450].id
        restored.jump(to: radioCurrent)
        restored.trimHistory(keeping: 100)
        #expect(Array(restored.items.prefix(600)) == queue.items)
        #expect(restored.history.filter { $0.song.id.hasPrefix("new-radio-") }.count == 100)
        #expect(restored.items.count == 850)
    }

    @Test func anExplicitEmptyRetentionSetDoesNotMigrateAsALegacyCollection() throws {
        var queue = PlayQueue()
        queue.replace(with: songs(600, prefix: "radio"), startAt: 450)
        let data = try JSONEncoder().encode(queue)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["retainedCollectionOccurrenceIDs"] as? [String])?.isEmpty == true)
        var restored = try JSONDecoder().decode(PlayQueue.self, from: data)
        let current = restored.current
        let upcoming = Array(restored.upcoming)
        restored.trimHistory(keeping: 100)
        #expect(restored.current == current)
        #expect(Array(restored.upcoming) == upcoming)
        #expect(restored.history.count == 100)
        #expect(restored.items.count == 250)
    }

    @Test func aLegacyPlayerFileRestoresAllSixHundredKnownSongsWithoutFetchingMetadata() throws {
        let suite = "koda.legacy-queue-restoration." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        var queue = PlayQueue()
        queue.replace(with: songs(600), startAt: 450)
        var queueJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        queueJSON.removeValue(forKey: "retainedCollectionOccurrenceIDs")
        let data = try JSONSerialization.data(withJSONObject: ["queue": queueJSON, "position": 42])
        try data.write(to: directory.appending(path: "queue.json"))
        let restored = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
        defer { restored.stop() }
        #expect(restored.queue.items == queue.items)
        #expect(restored.queue.currentIndex == 450)
        #expect(restored.position() == 42)
        #expect(restored.loadedItemCount == 0)
        #expect(!restored.wantsToPlay)
    }

    @Test func anOversizedLegacySnapshotDoesNotCreateUnboundedRetention() throws {
        var queue = PlayQueue()
        queue.replace(with: songs(PlayQueue.maximumRetainedCollectionCount + 1), startAt: 450)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        json.removeValue(forKey: "retainedCollectionOccurrenceIDs")
        var restored = try JSONDecoder().decode(PlayQueue.self, from: JSONSerialization.data(withJSONObject: json))
        restored.trimHistory(keeping: 100)
        #expect(restored.history.count == 100)
        #expect(restored.current?.song.id == "collection-450")
    }

    @Test func retentionIsBoundedAndResetWhenAnotherCollectionReplacesIt() {
        var queue = PlayQueue()
        queue.replace(with: songs(600), startAt: 450)
        queue.retainCurrentCollection()
        queue.replace(with: songs(300, prefix: "radio"), startAt: 250)
        queue.trimHistory(keeping: 100)
        #expect(queue.items.count == 150)
        #expect(queue.current?.song.id == "radio-250")
        queue.replace(with: songs(PlayQueue.maximumRetainedCollectionCount + 1), startAt: 250)
        queue.retainCurrentCollection()
        queue.trimHistory(keeping: 100)
        #expect(queue.history.count == 100)
        #expect(queue.items.count == PlayQueue.maximumRetainedCollectionCount + 1 - 150)
    }
}
