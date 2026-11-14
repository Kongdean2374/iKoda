import Foundation
import Testing
@testable import KodaCore

@MainActor
@Suite(.serialized)
struct PlayerEnhancementTests {
    private func preferences(_ suite: String) -> UserDefaults { UserDefaults(suiteName: suite)! }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func legacySnapshot(at directory: URL, position: Double = 42) throws -> PlayQueue {
        var queue = PlayQueue()
        queue.replace(with: [Song(id: "legacy-a", title: "Original name", artistLine: "Original artist", duration: 200),
                             Song(id: "legacy-b", title: "Second", artistLine: "Other artist", duration: 180)])
        let encoded = try JSONEncoder().encode(queue)
        var queueJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // These fields did not exist in the previous released queue schema.
        queueJSON.removeValue(forKey: "isSmartShuffled")
        queueJSON.removeValue(forKey: "protectedUpcoming")
        let snapshot: [String: Any] = ["queue": queueJSON, "position": position]
        let data = try JSONSerialization.data(withJSONObject: snapshot)
        try data.write(to: directory.appending(path: "queue.json"))
        return queue
    }

    @Test func legacyQueueRestoresPausedWithoutStartingANetworkLoad() throws {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try legacySnapshot(at: directory)
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), storageDirectory: directory, defaults: defaults)
        #expect(player.queue.current?.id == original.current?.id)
        #expect(player.current?.title == "Original name")
        #expect(player.position() == 42)
        #expect(player.phase == .idle)
        #expect(!player.wantsToPlay)
        #expect(player.loadedItemCount == 0)
        player.applicationBecameActive()
        #expect(!player.wantsToPlay)
        #expect(player.loadedItemCount == 0)
        player.persistQueueNow()
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "queue.json"))) as? [String: Any])
        #expect(saved["schemaVersion"] as? Int == 2)
        #expect(saved["wasPlaying"] as? Bool == false)
        #expect(saved["smartHistory"] != nil)
    }

    @Test func restoredPositionIsClampedAndManualQueueOrderSurvives() throws {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try legacySnapshot(at: directory, position: 10_000)
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), storageDirectory: directory, defaults: defaults)
        #expect(player.position() < 200)
        player.addToQueue([Song(id: "manual", title: "Manual", artistLine: "Me")])
        player.moveUpcoming(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let upcoming = player.upcoming.map(\.id)
        player.setSmartShuffle(true)
        #expect(player.upcoming.map(\.id) == upcoming)
        player.persistQueueNow()
        let restored = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), storageDirectory: directory, defaults: defaults)
        #expect(restored.upcoming.map(\.id) == upcoming)
        #expect(!restored.wantsToPlay)
    }

    @Test func actualOutputGainHonorsLimitEvenWhenEqualizerIsOff() {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), defaults: defaults)
        let old = player.soundSettings
        defer { player.soundSettings = old }
        var settings = SoundSettings()
        settings.enabled = false
        settings.outputLimit = 0.25
        player.soundSettings = settings
        player.volume = 1
        #expect(player.outputVolume == 0.25)
        player.volume = 0.1
        #expect(abs(player.outputVolume - 0.1) < 0.0001)
        player.volume = .nan
        #expect(player.outputVolume.isFinite)
        #expect(player.outputVolume <= 0.25)
        player.soundSettings = SoundSettings()
        player.volume = 1
        #expect(player.outputVolume == 1)
    }

    @Test func savedPlaybackIntentRequiresOptInAndAvailableAudio() {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        func allowed(enabled: Bool = true, wasPlaying: Bool = true, foreground: Bool = true,
                     interrupted: Bool = false, online: Bool = true, local: Bool = false) -> Bool {
            RestoredPlaybackPolicy.shouldResume(enabled: enabled, wasPlaying: wasPlaying,
                foregroundActivated: foreground, isInterrupted: interrupted, isIdle: true,
                hasSong: true, isOnline: online, hasLocalAudio: local)
        }
        #expect(allowed())
        #expect(!allowed(enabled: false))
        #expect(!allowed(wasPlaying: false)) // Explicit pause wins over the old snapshot.
        #expect(!allowed(foreground: false))
        #expect(!allowed(interrupted: true))
        #expect(!allowed(online: false))
        #expect(allowed(online: false, local: true))
    }


    @Test func authenticationFailureNeverSkipsOrStartsAnotherPlayer() async throws {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try legacySnapshot(at: directory)
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), storageDirectory: directory, defaults: defaults)
        let engine = player.engineIdentifier
        var loads = 0
        player.streamLoader = { _, _ in
            loads += 1
            throw MusicError.signedOut
        }
        player.resume()
        for _ in 0..<100 {
            if case .failed = player.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(player.queue.current?.id == original.current?.id)
        #expect(player.queue.currentIndex == 0)
        #expect(player.position() == 42)
        #expect(!player.wantsToPlay)
        #expect(player.audioInformation.lastFailure == .authentication)
        #expect(player.engineIdentifier == engine)
        #expect(player.loadedItemCount == 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(loads == 1)
    }

    @Test func transientRetryKeepsOccurrencePositionAndPlayerThenStopsOnDenial() async throws {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try legacySnapshot(at: directory)
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), storageDirectory: directory, defaults: defaults)
        player.networkSnapshotOverride = NetworkSnapshot(status: .online, interface: .wifi)
        let engine = player.engineIdentifier
        var loads = 0
        player.streamLoader = { _, _ in
            loads += 1
            throw loads == 1 ? MusicError.network : MusicError.badResponse(403)
        }
        player.resume()
        for _ in 0..<300 {
            if case .failed = player.phase { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(loads == 2)
        #expect(player.queue.current?.id == original.current?.id)
        #expect(player.position() == 42)
        #expect(player.engineIdentifier == engine)
        #expect(player.audioInformation.lastFailure == .forbidden)
        #expect(!player.wantsToPlay)
        #expect(player.diagnosticEvents.filter { $0.kind == .retryStarted }.count == 1)
        player.clearDiagnostics()
        #expect(player.diagnosticEvents.isEmpty)
        #expect(player.queue.current?.id == original.current?.id)
    }


    @Test func customCurveSurvivesRestoringANonOffBuiltInPreset() {
        let suite = "koda.player-enhancements." + UUID().uuidString
        let defaults = preferences(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let savedPreset = defaults.object(forKey: "koda.equalizer")
        let savedSound = SoundSettingsStore.load(defaults: defaults)
        defer {
            if let savedPreset { defaults.set(savedPreset, forKey: "koda.equalizer") }
            else { defaults.removeObject(forKey: "koda.equalizer") }
            SoundSettingsStore.save(savedSound, defaults: defaults)
        }
        defaults.set(EqualizerPreset.rock.rawValue, forKey: "koda.equalizer")
        var custom = SoundSettings()
        custom.customEnabled = true
        custom.gains[3] = -7
        custom.preampDB = -3
        SoundSettingsStore.save(custom, defaults: defaults)
        let player = Player(music: YouTubeMusic(defaultsSuite: "koda.player-enhancement-tests"), defaults: defaults)
        #expect(player.equalizer == .rock)
        #expect(player.soundSettings.customEnabled)
        #expect(player.soundSettings.gains[3] == -7)
        #expect(player.soundSettings.preampDB == -3)
    }

}
