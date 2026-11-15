import AVFoundation
import Foundation
import MediaPlayer
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import KodaCore

/// Generated local audio and held continuations exercise real Player ownership boundaries.
/// No service, account, download, wall-clock wait for a timer, or physical audio route is used.
@MainActor
@Suite(.serialized)
struct PlayerSleepSessionTests {
    @MainActor
    private struct Harness {
        let player: Player
        let suite: String
        let defaults: UserDefaults
        let directory: URL
        let wave: URL

        init(count: Int = 600, state: SleepTimerState? = nil, wasPlaying: Bool = true) throws {
            suite = "koda.sleep-player-tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(true, forKey: "koda.playback.resumeOnLaunch")
            if let state { #expect(SleepTimerStore.save(state, defaults: defaults)) }
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            wave = directory.appending(path: "audio.wav")
            try Self.pcm().write(to: wave)
            var queue = PlayQueue()
            queue.replace(with: (0..<count).map {
                Song(id: "sleep-\($0)", title: "Song \($0)", artistLine: "Artist", duration: 120,
                     artwork: Artwork(url: URL(string: "https://example.invalid/cover-\($0).jpg")!))
            })
            queue.retainCurrentCollection()
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue))
            let data = try JSONSerialization.data(withJSONObject: ["queue": object, "position": 42,
                                                                   "wasPlaying": wasPlaying])
            try data.write(to: directory.appending(path: "queue.json"))
            player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
            player.audioSessionActivator = { true }
            player.isMuted = true
            player.autoplay = false
            player.crossfades = false
            player.networkSnapshotOverride = NetworkSnapshot(status: .online, interface: .wifi)
            let local = wave
            player.streamLoader = { song, _ in Self.stream(song.id, url: local) }
        }

        static func stream(_ id: String, url: URL) -> ResolvedStream {
            ResolvedStream(videoId: id, url: url, userAgent: "", itag: 0, contentLength: nil,
                           duration: 120, loudnessDb: nil, expiresAt: nil)
        }

        static func pcm() -> Data {
            let bytes = 120 * 8_000 * 2
            var data = Data()
            func text(_ value: String) { data.append(contentsOf: value.utf8) }
            func u16(_ value: UInt16) {
                var number = value.littleEndian
                Swift.withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
            }
            func u32(_ value: UInt32) {
                var number = value.littleEndian
                Swift.withUnsafeBytes(of: &number) { data.append(contentsOf: $0) }
            }
            text("RIFF"); u32(UInt32(36 + bytes)); text("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(8_000); u32(16_000); u16(2); u16(16)
            text("data"); u32(UInt32(bytes)); data.append(Data(count: bytes))
            return data
        }

        func saved() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "queue.json"))) as? [String: Any])
        }

        func cleanup() {
            player.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(description)")
        throw CancellationError()
    }

    private func expired(_ action: SleepTimerAction = .finishPlaybackSession) throws -> SleepTimerState {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 1, action: action, at: Date().addingTimeInterval(-120))
        return policy.state
    }

    @Test func finishKeepsAllSixHundredOccurrencesAndSavesInactivePosition() throws {
        let h = try Harness()
        defer { h.cleanup() }
        let before = h.player.queue
        var callbackCount = 0
        var deactivations = 0
        h.player.onPlaybackSessionFinished = {
            #expect(h.player.isPlaybackSessionFinished)
            #expect(!h.player.wantsToPlay)
            #expect(h.player.loadedItemCount == 0)
            callbackCount += 1
        }
        h.player.canDeactivateAudioSession = { true }
        h.player.audioSessionDeactivator = { deactivations += 1 }
        h.player.finishPlaybackSession()
        #expect(h.player.queue == before)
        #expect(h.player.queue.items.count == 600)
        #expect(h.player.position() == 42)
        #expect(h.player.timeAnchor.rate == 0)
        #expect(h.player.phase == .idle)
        #expect(h.player.loadedItemCount == 0)
        #expect(!h.player.isBuffering)
        #expect(try h.saved()["wasPlaying"] as? Bool == false)
        #expect(try h.saved()["position"] as? Double == 42)
        #expect(SleepTimerStore.load(defaults: h.defaults).completion?.action == .finishPlaybackSession)
        h.player.finishPlaybackSession()
        #expect(callbackCount == 1)
        #expect(deactivations == 1)
    }

    @Test func expiredColdLaunchNeverPublishesOrResumesThePreviouslyActiveQueue() throws {
        let h = try Harness(state: expired())
        defer { h.cleanup() }
        let before = h.player.queue
        var activations = 0
        h.player.audioSessionActivator = { activations += 1; return true }
        h.player.applicationBecameActive()
        h.player.networkChanged(NetworkSnapshot(status: .online, interface: .cellular))
        h.player.handleMediaServicesReset()
        #expect(h.player.isPlaybackSessionFinished)
        #expect(h.player.sleepTimerState.plan == nil)
        #expect(h.player.queue == before)
        #expect(h.player.position() == 42)
        #expect(activations == 0)
        #expect(!h.player.wantsToPlay)
        #expect(h.player.loadedItemCount == 0)
        #expect(try h.saved()["wasPlaying"] as? Bool == false)
    }

    @Test func completionTombstoneWinsOverAnOlderActiveQueueSnapshot() throws {
        var policy = SleepTimerPolicy()
        policy.recordCompletion(action: .finishPlaybackSession, at: Date())
        let h = try Harness(state: policy.state, wasPlaying: true)
        defer { h.cleanup() }
        h.player.cancelSleepTimer()
        h.player.resumePlaybackOnLaunch = true
        h.player.applicationBecameActive()
        #expect(h.player.isPlaybackSessionFinished)
        #expect(!h.player.wantsToPlay)
        #expect(h.player.loadedItemCount == 0)
        #expect(h.player.sleepTimerState.completion != nil)
    }

    @Test func anExpiredPauseTimerSuppressesLaunchResumeWithoutFinishingTheSession() throws {
        let h = try Harness(state: expired(.pause))
        defer { h.cleanup() }
        var activations = 0
        h.player.audioSessionActivator = { activations += 1; return true }
        h.player.applicationBecameActive()
        #expect(!h.player.isPlaybackSessionFinished)
        #expect(!h.player.wantsToPlay)
        #expect(activations == 0)
        #expect(h.player.position() == 42)
        #expect(h.player.sleepTimerState.completion?.action == .pause)
    }

    @Test func explicitResumeReopensTheSameOccurrenceAtItsSavedPosition() async throws {
        let h = try Harness(count: 2, state: expired())
        defer { h.cleanup() }
        let occurrence = h.player.queue.current?.id
        var callbackSawOpenSession = false
        h.player.onPlaybackRequested = { callbackSawOpenSession = !h.player.isPlaybackSessionFinished }
        h.player.resume()
        try await waitFor("restored local item") { h.player.currentPlayerItem?.status == .readyToPlay && h.player.phase == .ready }
        #expect(callbackSawOpenSession)
        #expect(!h.player.isPlaybackSessionFinished)
        #expect(h.player.sleepTimerState.completion == nil)
        #expect(h.player.queue.current?.id == occurrence)
        #expect(h.player.position() >= 41 && h.player.position() < 48)
        #expect(h.player.wantsToPlay)
    }

    @Test func ordinaryPauseAndPauseTimerKeepTheReadyItem() async throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        h.player.resume()
        try await waitFor("ready local item") { h.player.currentPlayerItem?.status == .readyToPlay }
        let original = h.player.currentPlayerItem
        h.player.pause()
        #expect(h.player.currentPlayerItem === original)
        #expect(!h.player.isPlaybackSessionFinished)
        h.player.resume()
        h.player.setSleepTimerAction(.pause)
        try h.player.scheduleSleepTimer(minutes: 1)
        let deadline = try #require(h.player.sleepTimerState.deadline)
        #expect(h.player.evaluateSleepTimer(at: deadline))
        #expect(h.player.currentPlayerItem === original)
        #expect(!h.player.wantsToPlay)
        #expect(!h.player.isPlaybackSessionFinished)
        #expect(h.player.sleepTimerState.completion?.action == .pause)
    }

    @Test func finishReleasesMainAndStandbyAndDoesNotDeactivateAnotherOwner() async throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        h.player.crossfades = true
        h.player.resume()
        try await waitFor("standby item") { h.player.standbyPlayer?.currentItem?.status == .readyToPlay }
        let queue = h.player.queue
        var deactivations = 0
        h.player.canDeactivateAudioSession = { false } // MV/PiP or a recording owns it.
        h.player.audioSessionDeactivator = { deactivations += 1 }
        h.player.finishPlaybackSession()
        #expect(deactivations == 0)
        #expect(h.player.loadedItemCount == 0)
        #expect(h.player.standbyPlayer == nil)
        #expect(!h.player.isFadingOut)
        #expect(h.player.currentPlayerItem == nil)
        #expect(h.player.queue == queue)
    }

    @Test func delayedStreamCannotInstallAnItemAfterFinishing() async throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        var pending: CheckedContinuation<ResolvedStream, any Error>?
        h.player.streamLoader = { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 } // Deliberately ignores cancellation.
        }
        h.player.resume()
        try await waitFor("held stream request") { pending != nil }
        h.player.finishPlaybackSession()
        let queue = h.player.queue
        pending?.resume(returning: Harness.stream("sleep-0", url: h.wave))
        pending = nil
        for _ in 0..<30 { await Task.yield() }
        #expect(h.player.isPlaybackSessionFinished)
        #expect(h.player.currentPlayerItem == nil)
        #expect(h.player.loadedItemCount == 0)
        #expect(h.player.queue == queue)
        #expect(h.player.position() == 42)
    }

    @Test func staleCountdownRevisionCannotFinishAnExtendedTimer() throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        try h.player.scheduleSleepTimer(minutes: 1)
        let old = try #require(h.player.sleepTimerState.plan)
        try h.player.extendSleepTimer(minutes: 10)
        #expect(!h.player.evaluateSleepTimer(at: Date().addingTimeInterval(120), revision: old.revision))
        #expect(h.player.sleepTimerState.plan?.revision != old.revision)
        #expect(!h.player.isPlaybackSessionFinished)
        h.player.cancelSleepTimer()
        #expect(!h.player.evaluateSleepTimer(at: Date().addingTimeInterval(1_000)))
    }

    @Test func songEndFinishesBeforeAdvancingEvenWithRepeatOneAndStandby() async throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        h.player.setRepeat(.one)
        h.player.crossfades = true
        h.player.resume()
        try await waitFor("playing local item") { h.player.currentPlayerItem?.status == .readyToPlay && h.player.phase == .ready }
        let occurrence = try #require(h.player.queue.current?.id)
        try h.player.scheduleSleepTimerAtEndOfSong()
        let item = try #require(h.player.currentPlayerItem)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
        #expect(h.player.isPlaybackSessionFinished)
        #expect(h.player.queue.current?.id == occurrence)
        #expect(h.player.repeatMode == .one)
        #expect(h.player.loadedItemCount == 0)
        #expect(h.player.sleepTimerState.plan == nil)
    }

    @Test func selectingAnotherOccurrenceCancelsOnlyTheSongEndTimer() async throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        h.player.resume()
        try await waitFor("current item") { h.player.currentPlayerItem?.status == .readyToPlay && h.player.phase == .ready }
        let oldItem = try #require(h.player.currentPlayerItem)
        try h.player.scheduleSleepTimerAtEndOfSong()
        h.player.next()
        #expect(h.player.sleepTimerState.plan == nil)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: oldItem)
        #expect(!h.player.isPlaybackSessionFinished)
        #expect(h.player.current?.id == "sleep-1")
    }

    @Test func networkChangesDuringFinishedSessionAreAvailableToExplicitResume() throws {
        let h = try Harness(count: 2)
        defer { h.cleanup() }
        h.player.networkSnapshotOverride = nil
        h.player.networkChanged(NetworkSnapshot(status: .offline, interface: .unknown))
        h.player.finishPlaybackSession()
        h.player.networkChanged(NetworkSnapshot(status: .online, interface: .wifi))
        h.player.audioSessionActivator = { false } // Observe latest network without starting hardware.
        h.player.resume()
        #expect(h.player.audioInformation.network.status == .online)
        #expect(h.player.audioInformation.network.interface == .wifi)
        #expect(!h.player.isPlaybackSessionFinished)
    }

    @Test func aFutureTimerIsRearmedWhenACompletedSessionIsRestored() throws {
        var policy = SleepTimerPolicy()
        policy.recordCompletion(action: .finishPlaybackSession, at: Date())
        try policy.start(minutes: 30, action: .finishPlaybackSession, at: Date())
        let h = try Harness(count: 2, state: policy.state)
        defer { h.cleanup() }
        #expect(h.player.isPlaybackSessionFinished)
        #expect(h.player.sleepTimerState.isActive)
        #expect(h.player.hasScheduledSleepTimer)
        h.player.cancelSleepTimer()
        #expect(!h.player.hasScheduledSleepTimer)
        #expect(h.player.isPlaybackSessionFinished)
    }

    @Test func mediaResetWhileFinishedDefersRebuildUntilManualPlayback() async throws {
        let h = try Harness(count: 2, state: expired())
        defer { h.cleanup() }
        let oldEngine = h.player.engineIdentifier
        h.player.handleMediaServicesReset()
        #expect(h.player.engineIdentifier == oldEngine)
        #expect(!h.player.wantsToPlay)
        h.player.resume()
        #expect(h.player.engineIdentifier != oldEngine)
        try await waitFor("rebuilt local player") { h.player.currentPlayerItem?.status == .readyToPlay && h.player.phase == .ready }
        #expect(h.player.wantsToPlay)
        #expect(h.player.current?.id == "sleep-0")
    }

    @Test func lateArtworkCompletionCannotPublishAfterSessionFinishes() async throws {
        let h = try Harness(count: 1)
        defer { h.cleanup() }
        var gate: CheckedContinuation<Void, Never>?
        var completed = false
        var returnedArtwork: MPMediaItemArtwork?
        h.player.artworkLoader = { _ in
            await withCheckedContinuation { gate = $0 }
            completed = true
            #if canImport(UIKit)
            let artworkImage = UIImage()
            #else
            let artworkImage = NSImage(size: NSSize(width: 1, height: 1))
            #endif
            let artwork = MPMediaItemArtwork(boundsSize: CGSize(width: 1, height: 1)) { _ in artworkImage }
            returnedArtwork = artwork
            return artwork
        }
        h.player.resume()
        try await waitFor("held artwork") { gate != nil }
        h.player.finishPlaybackSession()
        gate?.resume()
        gate = nil
        try await waitFor("late artwork completion") { completed }
        #expect(h.player.isPlaybackSessionFinished)
        #expect(!h.player.wantsToPlay)
        let lateArtwork = try #require(returnedArtwork)
        let published = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        // Other serialized Player suites can still run concurrently with this suite.
        // Assert this request's identity, without assuming global Now Playing stays empty.
        #expect(published !== lateArtwork)
    }
}
