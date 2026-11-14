import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite(.serialized)
struct QueueUndoTests {
    private func tracks(_ ids: [String]) -> [Song] {
        ids.map { Song(id: $0, title: $0, artistLine: "Artist", duration: 200) }
    }

    @Test func restoringClearedSongsKeepsLaterManualAdditionsInOrder() {
        var queue = PlayQueue()
        queue.replace(with: tracks(["A", "B", "C"]))
        let current = queue.current
        let cleared = queue.upcoming.map(\.song)
        queue.clearUpcoming()
        queue.append(tracks(["D", "E"]))
        let additions = Array(queue.upcoming)
        queue.restoreClearedUpcoming(cleared)
        #expect(queue.current == current)
        #expect(queue.upcoming.map(\.song.id) == ["B", "C", "D", "E"])
        #expect(Array(queue.upcoming.suffix(2)) == additions)
    }

    @Test func equalSongIDsRemainSeparateRestoredAndNewOccurrences() {
        var queue = PlayQueue()
        queue.replace(with: tracks(["A", "B", "C"]))
        let cleared = queue.upcoming.map(\.song)
        queue.clearUpcoming()
        queue.append(tracks(["B", "C", "B"]))
        let additions = Array(queue.upcoming)
        queue.restoreClearedUpcoming(cleared)
        #expect(queue.upcoming.map(\.song.id) == ["B", "C", "B", "C", "B"])
        #expect(Array(queue.upcoming.suffix(3)) == additions)
        #expect(Set(queue.items.map(\.id)).count == queue.items.count)
    }

    @Test func restoringAfterCurrentChangesKeepsCurrentHistoryAndRepeat() {
        var queue = PlayQueue()
        queue.replace(with: tracks(["A", "B", "C"]))
        queue.repeatMode = .all
        let cleared = queue.upcoming.map(\.song)
        queue.clearUpcoming()
        queue.append(tracks(["D", "E"]))
        queue.advance(automatic: false)
        let current = queue.current
        let history = Array(queue.history)
        queue.restoreClearedUpcoming(cleared)
        #expect(queue.current == current)
        #expect(queue.current?.song.id == "D")
        #expect(Array(queue.history) == history)
        #expect(queue.upcoming.map(\.song.id) == ["B", "C", "E"])
        #expect(queue.repeatMode == .all)
    }

    @Test func restoredManualOrderRemainsProtectedAcrossSmartShuffleAndPersistence() throws {
        var queue = PlayQueue()
        queue.replace(with: tracks(["A", "B", "C"]))
        var random = SeededGenerator(state: 42)
        queue.setSmartShuffle(true, settings: .init(), context: .init(), using: &random)
        let cleared = queue.upcoming.map(\.song)
        queue.clearUpcoming()
        queue.append(tracks(["D", "E"]))
        queue.append(tracks(["radio-1", "radio-2"]), protectingOrder: false)
        queue.restoreClearedUpcoming(cleared)
        let protectedPrefix = Array(queue.upcoming.prefix(4))
        #expect(protectedPrefix.map(\.song.id) == cleared.map(\.id) + ["D", "E"])
        var restored = try JSONDecoder().decode(PlayQueue.self, from: JSONEncoder().encode(queue))
        restored.setSmartShuffle(false, settings: .init(), context: .init(), using: &random)
        restored.setSmartShuffle(true, settings: .init(), context: .init(), using: &random)
        #expect(Array(restored.upcoming.prefix(4)) == protectedPrefix)
        #expect(Set(restored.items.map(\.id)) == Set(queue.items.map(\.id)))
        #expect(restored.current == queue.current)
    }

    @Test func restoringAnEmptySnapshotDoesNotChangeTheQueue() {
        var queue = PlayQueue()
        queue.replace(with: tracks(["A", "D", "E"]))
        let before = queue
        queue.restoreClearedUpcoming([])
        #expect(queue == before)
    }

    @Test func playerUndoPreservesPausedPositionAndEngineWhileMergingNewSongs() throws {
        let suite = "koda.queue-undo-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var saved = PlayQueue()
        saved.replace(with: tracks(["A", "B", "C"]))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        let snapshot = try JSONSerialization.data(withJSONObject: ["queue": encoded, "position": 42])
        try snapshot.write(to: directory.appending(path: "queue.json"))
        let player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
        defer {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        player.autoplay = false
        player.streamLoader = { _, _ in throw MusicError.signedOut }
        let current = player.queue.current
        let engine = player.engineIdentifier
        let phase = player.phase
        let cleared = player.upcoming.map(\.song)
        player.clearUpcoming()
        player.addToQueue(tracks(["D", "E"]))
        let additions = player.upcoming
        player.restoreClearedUpcoming(cleared)
        #expect(player.upcoming.map(\.song.id) == ["B", "C", "D", "E"])
        #expect(Array(player.upcoming.suffix(2)) == additions)
        #expect(player.queue.current == current)
        #expect(player.engineIdentifier == engine)
        #expect(player.phase == phase)
        #expect(player.position() == 42)
        #expect(!player.wantsToPlay)
    }
}
