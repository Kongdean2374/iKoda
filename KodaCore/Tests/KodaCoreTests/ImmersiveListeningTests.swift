import Foundation
import Testing
@testable import KodaCore

struct ImmersiveListeningTests {
    @Test func lockShieldUsesTwoDistinctTapsAfterTheDeadline() {
        let start = Date(timeIntervalSinceReferenceDate: 900)
        var lock = ImmersiveInteractionLock()
        lock.lock(at: start)
        #expect(lock.isLocked)
        #expect(lock.revealUntil == start.addingTimeInterval(5))
        lock.showIfHidden(at: start.addingTimeInterval(3))
        #expect(lock.revealUntil == start.addingTimeInterval(5))
        lock.hideIfExpired(at: start.addingTimeInterval(5))
        #expect(lock.isLocked && lock.revealUntil == nil)
        #expect(!lock.unlock(at: start.addingTimeInterval(6)))
        lock.showIfHidden(at: start.addingTimeInterval(6))
        #expect(lock.revealUntil == start.addingTimeInterval(11))
        #expect(lock.unlock(at: start.addingTimeInterval(7)))
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
