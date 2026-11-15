import Foundation
import Testing
@testable import KodaCore

struct FlowQueueTests {
    private func songs(_ count: Int) -> [Song] {
        (0..<count).map { Song(id: "flow-\($0)", title: "Song \($0)", artistLine: "Artist", duration: 180) }
    }

    @Test(arguments: RepeatMode.allCases)
    func flowStartsOnceThroughWithoutChangingTheNextOrdinaryQueuePreference(_ prior: RepeatMode) {
        var queue = PlayQueue()
        queue.repeatMode = prior
        let accepted = queue.replaceFlow(with: songs(3), sourceID: "PL-source")
        #expect(accepted)
        #expect(queue.repeatMode == .off)
        #expect(queue.flowContext?.previousRepeatMode == prior)
        #expect(queue.advance(automatic: true)?.song.id == "flow-1")
        #expect(queue.advance(automatic: true)?.song.id == "flow-2")
        #expect(queue.advance(automatic: true) == nil)
        #expect(queue.current?.song.id == "flow-2")
        queue.replace(with: songs(2))
        #expect(queue.flowContext == nil)
        #expect(queue.repeatMode == prior)
    }

    @Test func sourceRestrictionAndOriginalRepeatPreferenceSurviveEncoding() throws {
        var queue = PlayQueue()
        queue.repeatMode = .all
        queue.replaceFlow(with: songs(600), sourceID: "PL-six-hundred")
        for _ in 0..<550 { queue.advance(automatic: true); queue.trimHistory(keeping: 100) }
        let data = try JSONEncoder().encode(queue)
        var restored = try JSONDecoder().decode(PlayQueue.self, from: data)
        #expect(restored == queue)
        #expect(restored.items.count == 600)
        #expect(restored.flowContext?.sourceID == "PL-six-hundred")
        restored.replace(with: songs(1))
        #expect(restored.repeatMode == .all)
    }

    @Test func oldQueueDecodesAsOrdinaryPlayback() throws {
        var queue = PlayQueue()
        queue.replace(with: songs(2))
        queue.repeatMode = .all
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(queue)) as? [String: Any])
        json.removeValue(forKey: "flowContext")
        let restored = try JSONDecoder().decode(PlayQueue.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.flowContext == nil)
        #expect(restored.repeatMode == .all)
        #expect(restored.items == queue.items)
    }

    @Test func manualQueueEditsKeepTheNoRadioBoundary() {
        var queue = PlayQueue()
        queue.replaceFlow(with: songs(4), sourceID: "PL-original")
        queue.moveUpcoming(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(queue.upcoming.map(\.song.id) == ["flow-3", "flow-1", "flow-2"])
        queue.playNext([Song(id: "manual", title: "Explicit addition", artistLine: "Artist")])
        #expect(queue.upcoming.first?.song.id == "manual")
        let saved = queue.upcoming.map(\.song)
        queue.clearUpcoming()
        queue.restoreClearedUpcoming(saved)
        #expect(queue.upcoming.map(\.song.id) == saved.map(\.id))
        #expect(queue.flowContext?.sourceID == "PL-original")
    }

    @Test func anotherFlowRetainsTheOriginalRepeatPreferenceAndClearRestoresIt() {
        var queue = PlayQueue()
        queue.repeatMode = .one
        queue.replaceFlow(with: songs(4), sourceID: "PL-one")
        // Explicit repeat changes apply to this listening queue only.
        queue.repeatMode = .all
        queue.replaceFlow(with: songs(2), sourceID: "PL-two")
        #expect(queue.repeatMode == .off)
        #expect(queue.flowContext?.previousRepeatMode == .one)
        queue.clear()
        #expect(queue.flowContext == nil)
        #expect(queue.repeatMode == .one)
    }

    @Test func invalidFlowLeavesTheCurrentQueueUntouched() {
        var queue = PlayQueue()
        queue.replace(with: songs(3))
        let before = queue
        let acceptedEmpty = queue.replaceFlow(with: [], sourceID: "PL-one")
        let acceptedBlankSource = queue.replaceFlow(with: songs(2), sourceID: "  ")
        #expect(!acceptedEmpty)
        #expect(!acceptedBlankSource)
        #expect(queue == before)
    }
}

@MainActor
@Suite(.serialized)
struct PlayerFlowTests {
    private actor Counter {
        private var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    @MainActor
    private struct Harness {
        let player: Player
        let defaults: UserDefaults
        let suite: String
        let directory: URL

        init() throws {
            suite = "koda.flow.tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
            player.audioSessionActivator = { false }
            player.streamLoader = { _, _ in
                Issue.record("Flow intent checks must never need a real audio stream")
                throw MusicError.signedOut
            }
        }

        func cleanup() {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var songs: [Song] {
        (0..<3).map { Song(id: "flow-\($0)", title: "Song \($0)", artistLine: "Artist", duration: 180) }
    }

    @Test(arguments: ["pause", "seek", "clear", "finish", "replace", "shuffle"])
    func newerUserIntentRejectsAnOlderPreparedFlow(_ action: String) throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.player.play(songs)
        let preparedAt = h.player.playbackIntentRevision
        switch action {
        case "pause": h.player.pause()
        case "seek": h.player.seek(to: 30)
        case "clear": h.player.clearUpcoming()
        case "finish": h.player.finishPlaybackSession()
        case "replace": h.player.play([songs[2]])
        default: h.player.setShuffle(true)
        }
        let expected = h.player.queue
        #expect(!h.player.playFlow(songs, sourceID: "PL-source", expectedIntentRevision: preparedAt))
        #expect(h.player.queue == expected)
        #expect(h.player.flowSourceID == nil)
    }

    @Test func sleepCompletionRejectsThePreviouslyPreparedFlow() throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.player.play(songs)
        try h.player.scheduleSleepTimer(minutes: 1)
        let token = h.player.playbackIntentRevision
        #expect(h.player.evaluateSleepTimer(at: try #require(h.player.sleepTimerState.deadline)))
        #expect(!h.player.playFlow(songs, sourceID: "PL-source", expectedIntentRevision: token))
        #expect(h.player.isPlaybackSessionFinished)
        #expect(!h.player.wantsToPlay)
    }

    @Test func flowEndNeverRequestsRadioAndKeepsGlobalAutoplay() async throws {
        let h = try Harness()
        defer { h.cleanup() }
        let radioRequests = Counter()
        h.player.radioLoader = { _ in await radioRequests.increment(); return [] }
        h.player.autoplay = true
        h.player.setRepeat(.all)
        let token = h.player.playbackIntentRevision
        #expect(h.player.playFlow([songs[0]], sourceID: "PL-source", expectedIntentRevision: token))
        #expect(h.player.repeatMode == .off)
        h.player.extendWithRadio(thenAdvance: false, explicitlyRequested: true)
        h.player.next()
        await Task.yield()
        #expect(await radioRequests.value() == 0)
        #expect(!h.player.wantsToPlay)
        #expect(h.player.autoplay)
        #expect(h.player.queue.items.map(\.song.id) == ["flow-0"])
        h.player.play(songs)
        #expect(h.player.repeatMode == .all)
        #expect(h.player.flowSourceID == nil)
    }

    @Test func flowPolicyRestoresThroughTheRealPlayerSnapshot() throws {
        let h = try Harness()
        defer { h.cleanup() }
        h.player.setRepeat(.one)
        #expect(h.player.playFlow(songs, sourceID: "PL-source"))
        h.player.seek(to: 42)
        h.player.persistQueueNow()
        let restored = Player(music: YouTubeMusic(defaultsSuite: h.suite), storageDirectory: h.directory, defaults: h.defaults)
        defer { restored.stop() }
        #expect(restored.flowSourceID == "PL-source")
        #expect(restored.repeatMode == .off)
        #expect(restored.position() == 42)
        #expect(restored.queue.items == h.player.queue.items)
        restored.audioSessionActivator = { false }
        restored.play(songs)
        #expect(restored.repeatMode == .one)
    }
}
