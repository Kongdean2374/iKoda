import AudioToolbox
import Foundation
import Testing
@testable import KodaCore

struct ImmersiveListeningTests {
    @Test func lockShieldUsesTwoDistinctTapsAfterTheDeadline() {
        let start = ContinuousClock.now
        var lock = ImmersiveInteractionLock()
        lock.lock(at: start)
        #expect(lock.isLocked)
        #expect(lock.revealUntil == start.advanced(by: .seconds(5)))
        lock.showIfHidden(at: start.advanced(by: .seconds(3)))
        #expect(lock.revealUntil == start.advanced(by: .seconds(5)))
        lock.hideIfExpired(at: start.advanced(by: .seconds(5)))
        #expect(lock.isLocked && lock.revealUntil == nil)
        let unlockedWhileHidden = lock.unlock(at: start.advanced(by: .seconds(6)))
        #expect(!unlockedWhileHidden)
        lock.showIfHidden(at: start.advanced(by: .seconds(6)))
        #expect(lock.revealUntil == start.advanced(by: .seconds(11)))
        let unlockedWhileVisible = lock.unlock(at: start.advanced(by: .seconds(7)))
        #expect(unlockedWhileVisible)
        #expect(!lock.isLocked && lock.revealUntil == nil)
    }

    @Test func airPlayOnlyAddsReceiverDelayWhileConnected() {
        #expect(abs(LyricsDisplayTiming.correction(song: 1.2, version: -0.5, airPlay: 2.1, isAirPlay: true) - 2.8) < 0.0001)
        #expect(abs(LyricsDisplayTiming.correction(song: 1.2, version: -0.5, airPlay: 2.1, isAirPlay: false) - 0.7) < 0.0001)
        #expect(LyricsDisplayTiming.airPlayOffset(-0.44) == -0.4)
        #expect(LyricsDisplayTiming.airPlayOffset(.infinity) == 0)
        #expect(LyricsDisplayTiming.airPlayOffset(25) == 10)
    }

    @MainActor
    @Test func instrumentalMarksAndAirPlayDelaySurviveRestartAndRemainProfileLocal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "KodaImmersive-\(UUID())")
        let profile = root.appending(path: "primary")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let song = Song(id: "same-stable-id", title: "Instrumental Fixture", artistLine: "Test Artist")
        let library = Library(directory: profile)
        library.setLyricsOffset(2, for: song.id)
        library.setInstrumental(song, marked: true)
        library.setAirPlayLyricsDelay(-2.7)
        library.flush(force: true)
        let restored = Library(directory: profile)
        #expect(restored.instrumentalSongs[song.id]?.title == song.title)
        #expect(restored.airPlayLyricsDelay == -2.7)
        #expect(restored.lyricsOffset(for: song.id) == 2)
        restored.open(directory: root.appending(path: "second"))
        #expect(restored.instrumentalSongs.isEmpty)
        #expect(restored.airPlayLyricsDelay == 0)
        restored.open(directory: profile)
        restored.unmarkInstrumental([song.id])
        restored.flush(force: true)
        #expect(Library(directory: profile).instrumentalSongs.isEmpty)
        #expect(Library(directory: profile).lyricsOffset(for: song.id) == 2)
    }

    @Test func negativeCatalogueRequiresEverySourceToConfirmAtTheSameQuery() {
        let start = Date(timeIntervalSinceReferenceDate: 900)
        let one = LyricsSourceResult(source: "one", name: "One", state: .empty)
        let two = LyricsSourceResult(source: "two", name: "Two", state: .empty)
        let expected: Set<String> = ["one", "two"]
        let catalogue = LyricsVersionStore.Catalogue(results: [one, two], fetchedAt: start)
        #expect(catalogue.confirmsMissing(sources: expected, now: start))
        #expect(!catalogue.confirmsMissing(sources: expected, now: start.addingTimeInterval(86_400)))
        #expect(!catalogue.confirmsMissing(sources: expected, now: start.addingTimeInterval(-10)))
        #expect(!LyricsVersionStore.Catalogue(results: [one], fetchedAt: start).confirmsMissing(sources: expected, now: start))
        for state: LyricsSourceResult.State in [.failed, .timedOut, .rateLimited, .cancelled, .invalid] {
            let failure = LyricsSourceResult(source: "two", name: "Two", state: state)
            #expect(!LyricsVersionStore.Catalogue(results: [one, failure], fetchedAt: start).confirmsMissing(sources: expected, now: start))
        }
    }

    @Test func sourceThrottleAppliesToDifferentSongsAndMirrors() async throws {
        let gate = LyricsRequestGate()
        let one = try #require(URL(string: "https://example.test/a"))
        let two = try #require(URL(string: "https://mirror.example.test/b"))
        do {
            _ = try await gate.fetch(source: "provider", url: one) { throw LyricsRequestGate.Rejection.limited("120") }
            Issue.record("Expected 429")
        } catch LyricsRequestGate.Rejection.cooled(let until) {
            #expect(until.timeIntervalSinceNow > 100)
        }
        do {
            _ = try await gate.fetch(source: "provider", url: two) { Issue.record("Called cooled provider"); return Data() }
            Issue.record("Expected provider-wide cooldown")
        } catch LyricsRequestGate.Rejection.cooled {} catch { Issue.record(error) }
        let independent = try await gate.fetch(source: "independent", url: two) { Data([1]) }
        #expect(independent == Data([1]))
    }

    @Test func fftAndWaveformFollowDecodedSamples() throws {
        let count = 2048
        for rate in [32_000.0, 44_100, 48_000] {
            let frequency = rate * 64 / Double(count)
            let samples = (0..<count).map { Float(0.4 * sin(2 * Double.pi * Double($0) * frequency / rate)) }
            let frame = try #require(AudioVisualizationAnalysis.analyze(samples, sampleRate: rate))
            let band = try #require(frame.spectrum.indices.max(by: { frame.spectrum[$0] < frame.spectrum[$1] }))
            let expected = Int(log(frequency / 20) / log(min(20_000, rate / 2) / 20) * 128)
            #expect(abs(band - expected) <= 1)
            #expect(abs(frame.peak - 0.4) < 0.0001)
            #expect(abs(frame.rms - 0.4 / Float(2).squareRoot()) < 0.002)
            #expect(frame.waveform.contains(where: { $0 < -0.39 }))
            #expect(frame.waveform.contains(where: { $0 > 0.39 }))
        }
        let quiet = try #require(AudioVisualizationAnalysis.analyze(Array(repeating: 0, count: count), sampleRate: 48_000))
        #expect(quiet.waveform.allSatisfy { $0 == 0 })
        #expect(quiet.spectrum.allSatisfy { $0 == 0 })
        #expect(quiet.peak == 0 && quiet.rms == 0)
    }

    @Test func pcmReadsDecodedStereoWithoutTouchingTheOtherChannel() throws {
        let input = AudioVisualizationInput()
        let now = 21.0
        #expect(input.samples(near: now) == nil)
        var pcm = (0..<2048).flatMap { index -> [Float] in
            [Float(sin(Double(index) * Double.pi / 16) * 0.5), 0.9]
        }
        pcm.withUnsafeMutableBytes { samples in
            var buffer = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(samples.count), mData: samples.baseAddress)
            withUnsafeMutablePointer(to: &buffer) {
                input.capture(UnsafeMutableBufferPointer(start: $0, count: 1), frames: 2048, rate: 48_000, end: now)
            }
        }
        let sample = try #require(input.samples(near: now))
        #expect(sample.values.count == 2048)
        #expect(sample.sampleRate == 48_000)
        #expect(sample.values.allSatisfy { abs($0) <= 0.501 })
        #expect(input.samples(after: sample.serial, near: now) == nil)
        #expect(input.samples(near: now + 3) == nil)
        input.reset()
        #expect(input.samples(near: now) == nil)
    }

    @Test func providerTemporaryFailureDoesNotLookLikeAnEmptyResult() async throws {
        let gate = LyricsRequestGate()
        let url = try #require(URL(string: "https://example.test/lyrics"))
        do {
            _ = try await gate.fetch(source: "provider", url: url) { throw LyricsRequestGate.Rejection.serverBusy(nil) }
            Issue.record("Expected temporary provider error")
        } catch LyricsRequestGate.Rejection.unavailableUntil(let until) {
            #expect(until.timeIntervalSinceNow > 0)
        }
        do {
            _ = try await gate.fetch(source: "provider", url: url) { Issue.record("Retried during backoff"); return Data() }
            Issue.record("Expected brief cooldown")
        } catch LyricsRequestGate.Rejection.unavailableUntil {} catch { Issue.record(error) }
    }

    @Test func retireGeneratedTranslationsPreservesCapturedUserEdits() async throws {
        struct OldRecord: Encodable {
            let songID: String
            let original: LyricsCandidate.Identity
            let lines: [Int: String]
            let edits: [Int: String]
        }
        let profile = FileManager.default.temporaryDirectory.appending(path: "KodaLyricsMigration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: profile) }
        let old = profile.appending(path: "PreservedLyricTranslations")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let store = LyricsVersionStore(cache: profile.appending(path: "cached"))
        let song = Song(id: "track", title: "Fixture", artistLine: "Artist")
        let original = try #require(LyricsCandidate.imported(song: song, sourceName: "Fixture",
                                                           text: "[00:02.00]Sing beside me"))
        let originalFile = old.appending(path: "legacy.json")
        let legacy = OldRecord(songID: song.id, original: original.id, lines: [0: "generated"], edits: [0: "user-owned"])
        try JSONEncoder().encode(legacy).write(to: originalFile)
        try await store.removeRetiredGeneratedTranslations(profile: profile)
        try await store.removeRetiredGeneratedTranslations(profile: profile)
        #expect(!FileManager.default.fileExists(atPath: originalFile.path))
        let archive = profile.appending(path: "ArchivedLyricEdits").appending(path: "legacy.json")
        let saved = try Data(contentsOf: archive)
        let payload = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(payload["lines"] == nil)
        #expect((payload["edits"] as? [String: String])?["0"] == "user-owned")
        #expect(payload["songID"] as? String == song.id)
    }

    @Test func retiredTranslationSelectionsResolveToAppleWithoutChangingManualData() throws {
        let decoder = JSONDecoder()
        for key in ["immersiveAI", "pureAI", "foundationModels", "quickApple", "qualityApple"] {
            let data = Data("{\"\(key)\":{}}".utf8)
            #expect(try decoder.decode(LyricTranslationSelection.self, from: data) == .appleTranslation)
        }
        let data = Data("{\"provider\":{\"_0\":\"saved-provider\"}}".utf8)
        #expect(try decoder.decode(LyricTranslationSelection.self, from: data) == .provider("saved-provider"))
    }
}
