import Foundation
import Testing
@testable import KodaCore

/// These tests exercise the real Player intent boundary while metadata requests are held.
/// Audio is deliberately rejected locally, so no network or playback device is required.
@MainActor
@Suite(.serialized)
struct PlayerPlaylistLoadingTests {
    private actor Pages {
        typealias Page = PlaylistQueueLoader.Page
        private var pending: [String: CheckedContinuation<Page, any Error>] = [:]
        private var calls: [String] = []

        func load(_ cursor: String) async throws -> Page {
            calls.append(cursor)
            // Deliberately ignores cancellation: Player must reject a stale result itself.
            return try await withCheckedThrowingContinuation { pending[cursor] = $0 }
        }

        func complete(_ cursor: String, songs: [Song], next: String?) {
            pending.removeValue(forKey: cursor)?.resume(returning: Page(songs: songs, continuation: next))
        }

        func fail(_ cursor: String) { pending.removeValue(forKey: cursor)?.resume(throwing: MusicError.network) }
        func requests() -> [String] { calls }
    }

    @MainActor
    private struct Harness {
        let player: Player
        let suite: String
        let defaults: UserDefaults
        let directory: URL

        init(restoringPlayback: Bool = false) throws {
            suite = "koda.playlist-player-tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(restoringPlayback, forKey: "koda.playback.resumeOnLaunch")
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var old = PlayQueue()
            old.replace(with: (0..<3).map { Song(id: "old-\($0)", title: "Old \($0)", artistLine: "Artist", duration: 200) })
            let queueJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old))
            let snapshot = try JSONSerialization.data(withJSONObject: ["queue": queueJSON, "position": 42,
                                                                       "wasPlaying": restoringPlayback])
            try snapshot.write(to: directory.appending(path: "queue.json"))
            player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
            player.autoplay = false
            player.crossfades = false
            player.streamLoader = { _, _ in throw MusicError.signedOut }
        }

        func cleanUp() {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func songs(_ range: Range<Int>) -> [Song] {
        range.map { Song(id: "song-\($0)", title: "Song \($0)", artistLine: "Artist \($0 % 20)", duration: 180) }
    }

    private func waitForRequest(_ cursor: String, pages: Pages, count: Int = 1) async throws {
        for _ in 0..<200 {
            let calls = await pages.requests()
            if calls.filter({ $0 == cursor }).count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let calls = await pages.requests()
        #expect(calls.filter { $0 == cursor }.count >= count, "Expected the controlled metadata request to start")
        throw CancellationError()
    }

    @Test(arguments: [false, true])
    func allSixHundredSongsAreEligibleBeforeEitherShuffleStarts(smart: Bool) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let player = h.player
        let oldQueue = player.queue
        let engine = player.engineIdentifier
        let pages = Pages()
        player.playlistPageLoader = { try await pages.load($0) }
        player.smartShuffleSettings.enabled = smart
        var randomPoolSizes: [Int] = []
        player.playlistRandomIndex = { count in randomPoolSizes.append(count); return count - 1 }
        var audioRequests = 0
        player.streamLoader = { _, _ in audioRequests += 1; throw MusicError.signedOut }

        let task = player.playPlaylist(songs(0..<200), continuation: "page-2", shuffled: true, sourceID: "large")
        try await waitForRequest("page-2", pages: pages)
        #expect(player.queue == oldQueue)
        #expect(player.position() == 42)
        #expect(player.engineIdentifier == engine)
        #expect(audioRequests == 0)
        #expect(randomPoolSizes.isEmpty)
        #expect(player.playlistLoadingCount == 200)
        await pages.complete("page-2", songs: songs(200..<400), next: "page-3")
        try await waitForRequest("page-3", pages: pages)
        #expect(player.playlistLoadingCount == 400)
        #expect(player.queue == oldQueue)
        #expect(audioRequests == 0)
        await pages.complete("page-3", songs: songs(400..<600), next: nil)
        let started = await task.value
        #expect(started)
        #expect(randomPoolSizes == [600])
        #expect(player.current?.id == "song-599")
        #expect(player.queue.items.count == 600)
        #expect(Set(player.queue.items.map(\.song.id)) == Set(songs(0..<600).map(\.id)))
        #expect(player.upcoming.count == 599)
        #expect(player.isSmartShuffled == smart)
        #expect(player.playlistLoadingCount == nil)
        #expect(player.playlistLoadingSourceID == nil)
    }

    @Test func originalRowIndexIsAppliedOnlyAfterTheCompleteSourceArrives() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let task = h.player.playPlaylist(songs(0..<200), continuation: "rest", startAt: 512)
        try await waitForRequest("rest", pages: pages)
        await pages.complete("rest", songs: songs(200..<600), next: nil)
        let started = await task.value
        #expect(started)
        #expect(h.player.current?.id == "song-512")
        // A finite source keeps its full repeat/shuffle pool, even when playback starts
        // well past the bounded history used for continuing radio recommendations.
        #expect(h.player.queue.items.map(\.song.id) == songs(0..<600).map(\.id))
        #expect(h.player.queue.currentIndex == 512)
        #expect(!h.player.isShuffled)
    }

    @Test func failedLaterPageKeepsOldQueueAndRetryDoesNotDuplicateAcceptedPages() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let oldQueue = h.player.queue
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let task = h.player.playPlaylist(songs(0..<200), continuation: "second", sourceID: "retry")
        try await waitForRequest("second", pages: pages)
        await pages.complete("second", songs: songs(200..<400), next: "third")
        try await waitForRequest("third", pages: pages)
        await pages.fail("third")
        let started = await task.value
        #expect(!started)
        #expect(h.player.queue == oldQueue)
        #expect(h.player.position() == 42)
        #expect(!h.player.wantsToPlay)
        #expect(h.player.playlistLoadingCount == 400)
        #expect(h.player.playlistLoadingError != nil)
        #expect(h.player.playlistLoadCanRetry)
        let retry = h.player.retryPlaylistLoading()
        try await waitForRequest("third", pages: pages, count: 2)
        await pages.complete("third", songs: songs(400..<600), next: nil)
        let retried = await retry.value
        let calls = await pages.requests()
        #expect(retried)
        #expect(calls == ["second", "third", "third"])
        #expect(h.player.queue.items.map(\.song.id) == songs(0..<600).map(\.id))
        #expect(h.player.playlistLoadingError == nil)
    }

    @Test func newerPlaylistWinsEvenWhenTheOldFetcherIgnoresCancellation() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let old = h.player.playPlaylist(songs(0..<10), continuation: "old", sourceID: "old")
        try await waitForRequest("old", pages: pages)
        let replacement = h.player.playPlaylist(songs(100..<110), continuation: "new", sourceID: "new")
        try await waitForRequest("new", pages: pages)
        await pages.complete("old", songs: songs(10..<20), next: nil)
        let oldStarted = await old.value
        #expect(!oldStarted)
        #expect(h.player.current?.id == "old-0")
        #expect(h.player.playlistLoadingSourceID == "new")
        await pages.complete("new", songs: songs(110..<120), next: nil)
        let newStarted = await replacement.value
        #expect(newStarted)
        #expect(h.player.queue.items.map(\.song.id) == songs(100..<120).map(\.id))
    }

    @Test(arguments: ["cancel", "stop", "pause", "resume", "seek", "play", "append", "next", "move", "remove", "clear", "shuffle", "advance", "previous", "jump", "repeat"])
    func explicitIntentPreventsLatePlaylistCommit(action: String) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let task = h.player.playPlaylist(songs(0..<200), continuation: "held")
        try await waitForRequest("held", pages: pages)
        switch action {
        case "cancel": h.player.cancelPlaylistLoading()
        case "stop": h.player.stop()
        case "pause": h.player.pause()
        case "resume": h.player.resume()
        case "seek": h.player.seek(to: 90)
        case "play": h.player.play(songs(800..<803))
        case "append": h.player.addToQueue(songs(800..<803))
        case "next": h.player.playNext(songs(800..<803))
        case "move": h.player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        case "remove":
            let id = try #require(h.player.upcoming.first?.id)
            h.player.remove(id)
        case "clear": h.player.clearUpcoming()
        case "shuffle": h.player.setShuffle(true)
        case "advance": h.player.next()
        case "previous": h.player.previous()
        case "jump":
            let id = try #require(h.player.upcoming.first?.id)
            h.player.jump(to: id)
        case "repeat": h.player.setRepeat(.all)
        default: Issue.record("Unhandled test action")
        }
        let intended = h.player.queue
        #expect(h.player.playlistLoadingCount == nil)
        await pages.complete("held", songs: songs(200..<600), next: nil)
        let started = await task.value
        #expect(!started)
        #expect(h.player.queue == intended)
        #expect(h.player.playlistLoadingError == nil)
    }

    @Test func firstPageIsOwnedByTheSameGenerationAndRepeatCommitsWithTheQueue() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistFirstPageLoader = { try await pages.load($0) }
        h.player.playlistPageLoader = { try await pages.load($0) }
        let obsolete = h.player.playPlaylist(id: "obsolete", repeatMode: .all)
        try await waitForRequest("obsolete", pages: pages)
        let replacement = h.player.playPlaylist(id: "current", repeatMode: .one)
        try await waitForRequest("current", pages: pages)
        await pages.complete("obsolete", songs: songs(0..<50), next: nil)
        let obsoleteStarted = await obsolete.value
        #expect(!obsoleteStarted)
        #expect(h.player.repeatMode == .off)
        await pages.complete("current", songs: songs(100..<200), next: "tail")
        try await waitForRequest("tail", pages: pages)
        #expect(h.player.repeatMode == .off)
        await pages.complete("tail", songs: songs(200..<300), next: nil)
        let started = await replacement.value
        #expect(started)
        #expect(h.player.repeatMode == .one)
        #expect(h.player.queue.items.map(\.song.id) == songs(100..<300).map(\.id))
    }

    @Test(arguments: [false, true])
    func enqueueInstallsTheWholeSourceWithoutChangingCurrentOrManualOrder(playNext: Bool) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let current = h.player.queue.current
        let task = h.player.enqueuePlaylist(songs(0..<200), continuation: "tail", playNext: playNext)
        try await waitForRequest("tail", pages: pages)
        #expect(h.player.queue.items.count == 3)
        await pages.complete("tail", songs: songs(200..<600), next: nil)
        let enqueued = await task.value
        let expected = playNext ? songs(0..<600).map(\.id) + ["old-1", "old-2"] : ["old-1", "old-2"] + songs(0..<600).map(\.id)
        #expect(enqueued)
        #expect(h.player.queue.current == current)
        #expect(h.player.upcoming.map(\.song.id) == expected)
        #expect(h.player.position() == 42)
        #expect(!h.player.wantsToPlay)
    }

    @Test func cancellingTheReturnedTaskClearsStatusAndRejectsUncooperativeFetch() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let before = h.player.queue
        let task = h.player.playPlaylist(songs(0..<200), continuation: "held")
        try await waitForRequest("held", pages: pages)
        task.cancel()
        for _ in 0..<100 where h.player.playlistLoadingCount != nil { await Task.yield() }
        #expect(h.player.playlistLoadingCount == nil)
        await pages.complete("held", songs: songs(200..<600), next: nil)
        let started = await task.value
        #expect(!started)
        #expect(h.player.queue == before)
    }

    @Test func completeLocalPlaylistRemainsImmediateAndUsesItsEntireRandomPool() throws {
        let h = try Harness()
        defer { h.cleanUp() }
        var pool = 0
        h.player.playlistRandomIndex = { pool = $0; return $0 - 1 }
        h.player.playPlaylist(songs(0..<600), continuation: nil, shuffled: true)
        #expect(pool == 600)
        #expect(h.player.current?.id == "song-599")
        #expect(h.player.queue.items.count == 600)
        #expect(h.player.playlistLoadingCount == nil)
    }

    @Test func overLimitCompletedSourceFailsExplicitlyInsteadOfBypassingPreparationSafety() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let before = h.player.queue
        let result = await h.player.playPlaylist(songs(0..<20_001), continuation: nil).value
        #expect(!result)
        #expect(h.player.queue == before)
        #expect(h.player.playlistLoadingError != nil)
        #expect(!h.player.playlistLoadCanRetry)
    }

    @Test func previouslyBrowsedContinuationCycleDoesNotStartATruncatedQueue() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let before = h.player.queue
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let task = h.player.playPlaylist(songs(0..<400), continuation: "third", completedPageTokens: ["second"])
        try await waitForRequest("third", pages: pages)
        await pages.complete("third", songs: songs(400..<600), next: "second")
        let result = await task.value
        #expect(!result)
        #expect(h.player.queue == before)
        #expect(h.player.playlistLoadingCount == 400)
        #expect(h.player.playlistLoadingError != nil)
        #expect(!h.player.playlistLoadCanRetry)
    }

    @Test func restoredPlaybackDoesNotStartAfterTheSceneLeavesForeground() async throws {
        let h = try Harness(restoringPlayback: true)
        defer { h.cleanUp() }
        var loads = 0
        h.player.streamLoader = { _, _ in loads += 1; throw MusicError.signedOut }
        let offline = NetworkSnapshot(status: .offline, interface: .unknown)
        let online = NetworkSnapshot(status: .online, interface: .wifi)
        h.player.networkSnapshotOverride = offline
        h.player.applicationBecameActive()
        #expect(h.player.phase == .idle)
        #expect(!h.player.wantsToPlay)
        h.player.applicationBecameInactive()
        h.player.networkSnapshotOverride = online
        h.player.networkChanged(online)
        await Task.yield()
        #expect(loads == 0)
        #expect(h.player.phase == .idle)
        #expect(!h.player.wantsToPlay)
        // Foregrounding again is still allowed to honor the saved opt-in intention.
        h.player.applicationBecameActive()
        #expect(h.player.wantsToPlay)
        for _ in 0..<100 where loads == 0 { await Task.yield() }
        #expect(loads == 1)
    }

    @Test func goingOfflineBeforeARetryFiresDoesNotConsumeAnAttempt() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let original = h.player.queue.current
        let online = NetworkSnapshot(status: .online, interface: .wifi)
        let offline = NetworkSnapshot(status: .offline, interface: .unknown)
        h.player.networkSnapshotOverride = online
        var loads = 0
        h.player.streamLoader = { _, _ in
            loads += 1
            throw loads == 1 ? MusicError.network : MusicError.signedOut
        }
        h.player.resume()
        for _ in 0..<100 {
            if h.player.diagnosticEvents.contains(where: { $0.kind == .retryScheduled }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(loads == 1)
        h.player.networkSnapshotOverride = offline
        h.player.networkChanged(offline)
        for _ in 0..<300 {
            if h.player.diagnosticEvents.contains(where: { $0.kind == .waitingForNetwork }) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(loads == 1)
        #expect(h.player.audioInformation.retryAttempt == 0)
        #expect(!h.player.diagnosticEvents.contains(where: { $0.kind == .retryStarted }))
        #expect(h.player.queue.current == original)
        #expect(h.player.position() == 42)
        h.player.networkSnapshotOverride = online
        h.player.networkChanged(online)
        for _ in 0..<300 where loads < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(loads == 2)
        #expect(h.player.audioInformation.retryAttempt == 1)
        let started = h.player.diagnosticEvents.filter { $0.kind == .retryStarted }
        #expect(started.count == 1)
        #expect(started.first?.attempt == 1)
        #expect(h.player.queue.current == original)
    }

    @Test func automaticOldQueueExhaustionDoesNotCancelPreparingTheNextPlaylist() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        let task = h.player.playPlaylist(songs(0..<200), continuation: "tail")
        try await waitForRequest("tail", pages: pages)
        h.player.extendWithRadio(thenAdvance: true) // Autoplay is off: natural exhaustion pauses the old queue.
        #expect(h.player.playlistLoadingCount == 200)
        #expect(!h.player.wantsToPlay)
        await pages.complete("tail", songs: songs(200..<600), next: nil)
        let started = await task.value
        #expect(started)
        #expect(h.player.queue.items.count == 600)
    }

    @Test func radioPrefetchUpgradesToAdvanceWhenTheLastSongEnds() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.autoplay = true
        h.player.streamLoader = { _, _ in throw CancellationError() }
        h.player.radioLoader = { try await pages.load($0).songs }
        h.player.play(songs(0..<1))
        h.player.extendWithRadio(thenAdvance: false)
        try await waitForRequest("song-0", pages: pages)
        h.player.extendWithRadio(thenAdvance: true)
        await pages.complete("song-0", songs: songs(0..<10), next: nil)
        for _ in 0..<200 where h.player.current?.id == "song-0" { await Task.yield() }
        let requests = await pages.requests()
        #expect(requests == ["song-0"])
        #expect(h.player.current?.id == "song-1")
        #expect(h.player.wantsToPlay)
        #expect(h.player.queue.items.count == 10)
    }

    @Test(arguments: ["pause", "new-selection", "pause-resume"])
    func delayedRadioCallbacksCannotOverrideLaterPlaybackIntent(action: String) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.autoplay = true
        h.player.streamLoader = { _, _ in throw CancellationError() }
        h.player.radioLoader = { try await pages.load($0).songs }
        h.player.play(songs(0..<1))
        h.player.extendWithRadio(thenAdvance: true)
        try await waitForRequest("song-0", pages: pages)
        switch action {
        case "pause": h.player.pause()
        case "new-selection": h.player.play(songs(100..<103))
        case "pause-resume": h.player.pause(); h.player.resume()
        default: Issue.record("Unhandled test action")
        }
        let intendedQueue = h.player.queue
        let intendedPlaying = h.player.wantsToPlay
        if action == "pause" { await pages.complete("song-0", songs: songs(0..<10), next: nil) }
        else { await pages.fail("song-0") }
        for _ in 0..<100 { await Task.yield() }
        #expect(h.player.queue == intendedQueue)
        #expect(h.player.wantsToPlay == intendedPlaying)
    }

    @Test func explicitMusicIntentIsPublishedBeforeMetadataOrAudioCanStart() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pages = Pages()
        h.player.playlistPageLoader = { try await pages.load($0) }
        var intents = 0
        var audio = 0
        h.player.onPlaybackRequested = { intents += 1 }
        h.player.streamLoader = { _, _ in audio += 1; throw CancellationError() }
        let task = h.player.playPlaylist(songs(0..<200), continuation: "tail")
        #expect(intents == 1)
        #expect(audio == 0)
        try await waitForRequest("tail", pages: pages)
        h.player.pause()
        #expect(intents == 1)
        await pages.complete("tail", songs: songs(200..<600), next: nil)
        let obsolete = await task.value
        #expect(!obsolete)
        h.player.play(songs(700..<701))
        #expect(intents == 2)
    }
}
