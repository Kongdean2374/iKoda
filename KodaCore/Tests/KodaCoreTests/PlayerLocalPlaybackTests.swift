import AVFoundation
import Foundation
import Testing
@testable import KodaCore

/// Real AVPlayerItems backed by generated local PCM files. No service requests, account,
/// audio output device or physical iPhone is required for these handover/state regressions.
@MainActor
@Suite(.serialized)
struct PlayerLocalPlaybackTests {
    @MainActor
    private struct Harness {
        let player: Player
        let directory: URL
        let defaults: UserDefaults
        let suite: String
        let short: URL
        let long: URL
        let songs = [Song(id: "short", title: "Short", artistLine: "Artist", duration: 120),
                     Song(id: "long", title: "Long", artistLine: "Artist", duration: 360)]

        init(savedPosition: Double? = nil) throws {
            suite = "koda.local-player-tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            short = directory.appending(path: "short.wav")
            long = directory.appending(path: "long.wav")
            try Self.wave(seconds: 120).write(to: short)
            try Self.wave(seconds: 360).write(to: long)
            if let savedPosition {
                var queue = PlayQueue()
                queue.replace(with: songs)
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(queue))
                let snapshot = try JSONSerialization.data(withJSONObject: ["queue": object, "position": savedPosition])
                try snapshot.write(to: directory.appending(path: "queue.json"))
            }
            player = Player(music: YouTubeMusic(defaultsSuite: suite), storageDirectory: directory, defaults: defaults)
            player.audioSessionActivator = { true }
            player.isMuted = true
            player.autoplay = false
            player.crossfades = false
            player.networkSnapshotOverride = NetworkSnapshot(status: .online, interface: .wifi)
            let shortURL = short, longURL = long
            player.streamLoader = { song, _ in
                Self.stream(song.id, url: song.id == "short" ? shortURL : longURL, duration: song.duration)
            }
        }

        static func stream(_ id: String, url: URL, duration: Double?) -> ResolvedStream {
            ResolvedStream(videoId: id, url: url, userAgent: "", itag: 0, contentLength: nil,
                           duration: duration, loudnessDb: nil, expiresAt: nil)
        }

        static func wave(seconds: Int) -> Data {
            let sampleRate = 8_000
            let count = seconds * sampleRate * 2
            var data = Data()
            func text(_ value: String) { data.append(contentsOf: value.utf8) }
            func u16(_ value: UInt16) {
                var little = value.littleEndian
                Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            func u32(_ value: UInt32) {
                var little = value.littleEndian
                Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            text("RIFF"); u32(UInt32(36 + count)); text("WAVEfmt "); u32(16)
            u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
            text("data"); u32(UInt32(count)); data.append(Data(count: count))
            return data
        }

        func cleanUp() {
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

    @Test func manualNextPublishesThePreloadedItemsOwnDuration() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.player.play(h.songs)
        try await waitFor("two local items") { h.player.loadedItemCount == 2 && h.player.currentPlayerItem?.status == .readyToPlay }
        let oldItem = h.player.currentPlayerItem
        #expect(h.player.duration == 120)
        h.player.next()
        try await waitFor("the actual second AVPlayerItem") { h.player.currentPlayerItem !== oldItem && h.player.current?.id == "long" }
        #expect(h.player.duration == 360)
        #expect(h.player.position() < 2)
        #expect(h.player.queue.currentIndex == 1)
    }

    @Test func manualNextRewindsAStandbyParkedAtAnAutoMixEntryPoint() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.player.crossfades = true
        h.player.play(h.songs)
        try await waitFor("standby PCM item") { h.player.standbyPlayer?.currentItem?.status == .readyToPlay }
        let standby = try #require(h.player.standbyPlayer)
        let incomingItem = try #require(standby.currentItem)
        // Reproduce the real seek performed by planAutoMix, without requiring music analysis.
        let parked = await standby.seek(to: CMTime(seconds: 45, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(parked)
        #expect(abs(standby.currentTime().seconds - 45) < 0.1)
        h.player.next()
        try await waitFor("rewound standby handover") { h.player.currentPlayerItem === incomingItem }
        #expect(h.player.current?.id == "long")
        #expect(incomingItem.currentTime().seconds < 2)
        #expect(h.player.position() < 2)
        #expect(h.player.duration == 360)
    }

    @Test func resumeReusesAReadyPausedItemButReloadsAFailedPausedItem() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        var loads = 0
        let good = h.short
        let bad = h.directory.appending(path: "invalid.m4a")
        try Data("This is not an audio file.".utf8).write(to: bad)
        h.player.streamLoader = { song, _ in
            loads += 1
            return Harness.stream(song.id, url: loads == 1 ? bad : good, duration: song.duration)
        }
        h.player.play([h.songs[0]])
        h.player.pause() // Pause before the asynchronous stream is installed and fails.
        try await waitFor("paused failed AVPlayerItem") { h.player.phase == .ready && h.player.currentPlayerItem?.status == .failed }
        let occurrence = h.player.queue.current?.id
        let failed = h.player.currentPlayerItem
        #expect(!h.player.wantsToPlay)
        h.player.resume()
        try await waitFor("fresh local replacement") { loads == 2 && h.player.currentPlayerItem?.status == .readyToPlay }
        #expect(h.player.currentPlayerItem !== failed)
        #expect(h.player.queue.current?.id == occurrence)
        h.player.pause()
        let ready = h.player.currentPlayerItem
        h.player.resume()
        for _ in 0..<50 { await Task.yield() }
        #expect(loads == 2)
        #expect(h.player.currentPlayerItem === ready)
    }

    @Test func failedAudioSessionActivationDoesNotForceAudioOrDiscardTheQueue() async throws {
        let h = try Harness(savedPosition: 42)
        defer { h.cleanUp() }
        let before = h.player.queue
        var loads = 0
        let good = h.short
        h.player.streamLoader = { song, _ in loads += 1; return Harness.stream(song.id, url: good, duration: song.duration) }
        h.player.audioSessionActivator = { false }
        h.player.resume()
        #expect(!h.player.wantsToPlay)
        #expect(loads == 0)
        #expect(h.player.position() == 42)
        #expect(h.player.queue == before)
        h.player.audioSessionActivator = { true }
        h.player.resume()
        try await waitFor("playback after activation succeeds") { h.player.currentPlayerItem?.status == .readyToPlay }
        #expect(h.player.queue.current?.id == before.current?.id)
        #expect(h.player.position() >= 42 && h.player.position() < 44)
    }

    @Test(arguments: [false, true])
    func confirmedBadLocalAudioIsReplacedOnceWithoutChangingOccurrenceOrPosition(initiallyOffline: Bool) async throws {
        let h = try Harness(savedPosition: 42)
        defer { h.cleanUp() }
        let store = AudioStore(directory: h.directory.appending(path: "cache"))
        let bad = Data("This is not a playable M4A file.".utf8)
        let declaration = ResolvedStream(videoId: "short", url: URL(string: "https://example.invalid/audio")!, userAgent: "",
                                         itag: 140, contentLength: Int64(bad.count), duration: 120, loudnessDb: nil, expiresAt: nil)
        store.markDownloaded([h.songs[0]])
        store.prepare(declaration, song: h.songs[0])
        try store.write(bad, at: 0, for: "short")
        h.player.audioStore = store
        h.player.streamLoader = nil
        var remoteLoads = 0
        var invalidations = 0
        let good = h.short
        h.player.remoteStreamLoader = { song, _ in
            remoteLoads += 1
            return Harness.stream(song.id, url: good, duration: song.duration)
        }
        h.player.onLocalAudioInvalidated = { _ in invalidations += 1 }
        h.player.networkSnapshotOverride = NetworkSnapshot(status: initiallyOffline ? .offline : .online, interface: .wifi)
        let occurrence = h.player.queue.current?.id
        let engine = h.player.engineIdentifier
        h.player.resume()
        try await waitFor("confirmed bad local file rejection") { invalidations == 1 }
        #expect(store.completeStream("short") == nil)
        #expect(store.entry("short")?.isDownload == true)
        if initiallyOffline {
            #expect(remoteLoads == 0)
            #expect(!h.player.wantsToPlay)
            h.player.networkSnapshotOverride = NetworkSnapshot(status: .online, interface: .wifi)
            h.player.resume()
        }
        try await waitFor("replacement stream at the saved position") {
            remoteLoads >= 1 && h.player.currentPlayerItem?.status == .readyToPlay && h.player.position() >= 42
        }
        #expect(remoteLoads == 1)
        #expect(invalidations == 1)
        #expect(h.player.queue.current?.id == occurrence)
        #expect(h.player.engineIdentifier == engine)
        #expect(h.player.position() < 44)
        #expect(h.player.audioInformation.retryAttempt == (initiallyOffline ? 0 : 1))
    }
}
