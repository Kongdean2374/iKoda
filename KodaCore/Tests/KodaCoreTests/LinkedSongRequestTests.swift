import Foundation
import Testing
@testable import KodaCore

/// A lookup that deliberately finishes even when its caller has changed playback intent.
private actor LinkedSongLookupGate {
    private var response: [Song]?
    private var waiting: [CheckedContinuation<[Song], Never>] = []

    func load() async -> [Song] {
        if let response { return response }
        return await withCheckedContinuation { waiting.append($0) }
    }

    func complete(_ songs: [Song]) {
        response = songs
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume(returning: songs) }
    }
}

@MainActor
@Suite(.serialized)
struct LinkedSongRequestTests {
    private func song(_ id: String) -> Song {
        Song(id: id, title: id, artistLine: "Artist", duration: 180)
    }

    @MainActor
    private struct Harness {
        let player: Player
        let suite: String
        let defaults: UserDefaults
        let directory: URL

        init() throws {
            suite = "koda.link-request-tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "koda.playback.resumeOnLaunch")
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var queue = PlayQueue()
            queue.replace(with: (0..<3).map { Song(id: "old-\($0)", title: "Old \($0)", artistLine: "Artist", duration: 180) })
            let queueJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue))
            try JSONSerialization.data(withJSONObject: ["queue": queueJSON, "position": 42, "wasPlaying": false])
                .write(to: directory.appending(path: "queue.json"))
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

    @Test func exactLinkedSongLeadsWithoutSubstitutingAnotherRadioResult() {
        let request = LinkedSongRequest(songID: "linked", intentRevision: 4)
        let recommended = song("recommendation")
        let linked = song("linked")
        let selection = request.selection(from: [recommended, linked, linked, recommended], currentRevision: 4)
        #expect(selection == .queue([linked, recommended, recommended]))
        #expect(request.selection(from: [recommended], currentRevision: 4) == .unavailable)
        #expect(request.selection(from: [], currentRevision: 4) == .unavailable)
    }

    @Test func supersededLookupCannotReportMissingSongOrReplaceQueue() {
        let request = LinkedSongRequest(songID: "linked", intentRevision: 4)
        #expect(request.selection(from: [song("linked")], currentRevision: 5) == .superseded)
        #expect(request.selection(from: [], currentRevision: 5) == .superseded)
        #expect(!request.isCurrent(revision: 5)) // The same check gates network failures.
    }

    @Test(arguments: ["play", "next", "pause", "previous", "stop", "seek", "new-link", "new-playlist"])
    func realTransportIntentRejectsHeldLinkLookup(action: String) async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let player = h.player
        let request = LinkedSongRequest(songID: "linked", intentRevision: player.beginExternalPlaybackRequest())
        let gate = LinkedSongLookupGate()
        let pending = Task {
            let songs = await gate.load()
            let selection = request.selection(from: songs, currentRevision: player.playbackIntentRevision)
            if case .queue(let accepted) = selection { player.play(accepted) }
            return selection
        }
        switch action {
        case "play": player.play([song("new-choice")])
        case "next": player.next()
        case "pause": player.pause()
        case "previous": player.previous()
        case "stop": player.stop()
        case "seek": player.seek(to: 12)
        case "new-link": _ = player.beginExternalPlaybackRequest()
        default: player.playPlaylist([song("new-playlist")], continuation: nil)
        }
        let expectedQueue = player.queue
        await gate.complete([song("linked"), song("recommendation")])
        let selection = await pending.value
        #expect(selection == .superseded)
        #expect(player.queue == expectedQueue)
        #expect(!request.isCurrent(revision: player.playbackIntentRevision))
    }

    @Test func unavailableLinkedSongPreservesCurrentQueueAndPosition() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let player = h.player
        let previous = player.queue
        let position = player.position()
        var requests = 0
        player.onPlaybackRequested = { requests += 1 }
        let request = LinkedSongRequest(songID: "linked", intentRevision: player.beginExternalPlaybackRequest())
        let gate = LinkedSongLookupGate()
        let pending = Task {
            let songs = await gate.load()
            return request.selection(from: songs, currentRevision: player.playbackIntentRevision)
        }
        await gate.complete([song("different-video")])
        let result = await pending.value
        #expect(result == .unavailable)
        #expect(player.queue == previous)
        #expect(player.position() == position)
        #expect(requests == 1)
    }

    @Test func canceledLookupCannotReturnAfterNavigatingOrSwitchingAwayAndBack() async {
        let request = LinkedSongRequest(songID: "linked", intentRevision: 4)
        let gate = LinkedSongLookupGate()
        let pending = Task {
            let songs = await gate.load()
            guard request.isCurrent(revision: 4, isCancelled: Task.isCancelled) else {
                return LinkedSongRequest.Selection.superseded
            }
            return request.selection(from: songs, currentRevision: 4)
        }
        // Profile/navigation cancellation does not alter the music queue or its revision.
        // Even if the profile ID later matches again, this request stays canceled.
        pending.cancel()
        await gate.complete([song("linked")])
        let result = await pending.value
        #expect(result == .superseded)
    }
}
