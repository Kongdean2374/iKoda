import Foundation
import Testing
@testable import KodaCore

struct PlaybackRecoveryTests {
    private let online = NetworkSnapshot(status: .online, interface: .wifi)
    private let offline = NetworkSnapshot(status: .offline)

    @Test func retryBudgetAndExponentialBackoffAreFinite() throws {
        let id = UUID()
        var policy = PlaybackRecovery()
        for (attempt, delay) in [1.0, 2.0, 4.0].enumerated() {
            let decision = policy.request(for: id, at: 42, error: URLError(.timedOut), wantsToPlay: true, network: online)
            guard case .retry(let ticket) = decision else { Issue.record("Expected a bounded retry"); return }
            #expect(ticket.attempt == attempt + 1)
            #expect(ticket.delay == delay)
            #expect(ticket.position == 42)
            #expect(ticket.occurrenceID == id)
            #expect(policy.attempts == attempt, "scheduling a timer does not begin a reload")
            let consumed = policy.consume(ticket)
            #expect(consumed)
            #expect(policy.attempts == attempt + 1)
            let consumedTwice = policy.consume(ticket)
            #expect(!consumedTwice, "one ticket can begin only one reload")
            // Even brief successful playback cannot create an unbounded retry loop.
            policy.markRecovered()
        }
        let exhausted = policy.request(for: id, at: 42, error: URLError(.timedOut), wantsToPlay: true, network: online)
        #expect(exhausted == .stop(.timeout))
        #expect(policy.attempts == 3)
        policy.restart(for: id)
        #expect(policy.attempts == 0)
        guard case .retry(let fresh) = policy.request(for: id, at: 42, error: nil, wantsToPlay: true, network: online) else {
            Issue.record("A deliberate retry should start a new bounded session"); return
        }
        #expect(fresh.attempt == 1)
    }

    @Test func offlineWaitUsesNoTimersAndReconnectsSameOccurrenceAtSamePosition() {
        let id = UUID()
        var policy = PlaybackRecovery()
        let waiting = policy.request(for: id, at: 91, error: MusicError.network, wantsToPlay: true, network: offline)
        #expect(waiting == .waitForNetwork)
        #expect(policy.attempts == 0)
        #expect(policy.pending == nil)
        let repeatedFailure = policy.request(for: id, at: 91, error: MusicError.network, wantsToPlay: true, network: offline)
        #expect(repeatedFailure == .ignore)
        guard case .retry(let ticket) = policy.networkRestored(for: id, at: 91, wantsToPlay: true) else {
            Issue.record("Expected recovery after network restoration"); return
        }
        #expect(ticket.occurrenceID == id)
        #expect(ticket.position == 91)
        #expect(ticket.attempt == 1)
        #expect(policy.attempts == 0)
        let repeatedRestoration = policy.networkRestored(for: id, at: 91, wantsToPlay: true)
        #expect(repeatedRestoration == .ignore)
    }

    @Test func tenNetworkFlapsBeforeRetryStartsSpendNoAttempts() {
        let id = UUID()
        var policy = PlaybackRecovery()
        var decision = policy.request(for: id, at: 91, error: URLError(.timedOut), wantsToPlay: true, network: online)
        var staleTickets: [RecoveryTicket] = []
        for _ in 0..<10 {
            guard case .retry(let ticket) = decision else {
                Issue.record("Restoration should schedule the same unspent attempt"); return
            }
            #expect(ticket.attempt == 1)
            #expect(ticket.delay == 1)
            #expect(ticket.position == 91)
            #expect(policy.attempts == 0)
            let suspended = policy.suspendForNetwork(ticket)
            #expect(suspended)
            #expect(policy.waitingForNetwork)
            #expect(policy.pending == nil)
            #expect(policy.attempts == 0)
            staleTickets.append(ticket)
            decision = policy.networkRestored(for: id, at: 91, wantsToPlay: true)
        }
        guard case .retry(let ready) = decision else { Issue.record("Expected a final retry"); return }
        for stale in staleTickets {
            let staleConsume = policy.consume(stale)
            let staleSuspension = policy.suspendForNetwork(stale)
            #expect(!staleConsume)
            #expect(!staleSuspension)
        }
        #expect(policy.isCurrent(ready))
        let started = policy.consume(ready)
        #expect(started)
        #expect(policy.attempts == 1)
        // The next two actual starts retain the normal 2/4-second backoff and limit.
        for attempt in 2...3 {
            guard case .retry(let ticket) = policy.request(for: id, at: 91, error: MusicError.network,
                                                         wantsToPlay: true, network: online) else {
                Issue.record("Flapping must not exhaust the real reload budget"); return
            }
            #expect(ticket.attempt == attempt)
            #expect(ticket.delay == Double(attempt == 2 ? 2 : 4))
            let consumed = policy.consume(ticket)
            #expect(consumed)
        }
        let exhausted = policy.request(for: id, at: 91, error: MusicError.network, wantsToPlay: true, network: online)
        #expect(exhausted == .stop(.network))
        #expect(policy.attempts == 3)
    }

    @Test func unknownConnectivityWaitsWithoutSpendingAnAttempt() {
        var policy = PlaybackRecovery()
        let decision = policy.request(for: UUID(), at: 23, error: MusicError.network,
                                      wantsToPlay: true, network: NetworkSnapshot())
        #expect(decision == .waitForNetwork)
        #expect(policy.pending == nil)
        #expect(policy.attempts == 0)
    }

    @Test func pauseAndQueueChangeInvalidateDelayedWork() {
        let first = UUID(), second = UUID()
        var policy = PlaybackRecovery()
        guard case .retry(let stale) = policy.request(for: first, at: 12, error: nil, wantsToPlay: true, network: online) else {
            Issue.record("Expected a ticket"); return
        }
        let duplicate = policy.request(for: first, at: 12, error: nil, wantsToPlay: true, network: online)
        #expect(duplicate == .ignore)
        policy.cancel()
        let consumed = policy.consume(stale)
        #expect(!consumed)
        #expect(policy.attempts == 0)
        let whilePaused = policy.request(for: first, at: 12, error: nil, wantsToPlay: false, network: online)
        #expect(whilePaused == .ignore)
        policy.begin(for: second)
        #expect(!policy.isCurrent(stale))
        #expect(policy.attempts == 0)
    }

    @Test func accessVerdictsAndUnknownFailuresNeverRetry() {
        let failures: [(Error, PlaybackFailureReason)] = [
            (MusicError.signedOut, .authentication), (MusicError.botCheck, .forbidden),
            (MusicError.badResponse(403), .forbidden), (MusicError.badResponse(401), .authentication),
            (MusicError.badResponse(429), .rateLimited), (MusicError.rateLimited, .rateLimited),
            (MusicError.unplayable("network timeout, token=secret"), .unavailable),
            (NSError(domain: "AnUnknownDecoder", code: 42), .unknown)
        ]
        for (error, expected) in failures {
            var policy = PlaybackRecovery()
            let decision = policy.request(for: UUID(), at: 0, error: error, wantsToPlay: true, network: online)
            #expect(decision == .stop(expected))
            #expect(policy.attempts == 0)
        }
        #expect(PlaybackFailureReason.classify(URLError(.cancelled)) == .cancelled)
        #expect(PlaybackFailureReason.classify(MusicError.badResponse(503)) == .serviceUnavailable)
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        #expect(PlaybackFailureReason.classify(wrapped) == .network)
    }

    @Test func permanentVerdictsInvalidatePendingOrOfflineRetriesImmediately() {
        for suspend in [false, true] {
            let id = UUID()
            var policy = PlaybackRecovery()
            guard case .retry(let ticket) = policy.request(for: id, at: 42, error: MusicError.network,
                                                         wantsToPlay: true, network: online) else {
                Issue.record("Expected initial transient retry"); return
            }
            if suspend { policy.suspendForNetwork(ticket) }
            let stopped = policy.request(for: id, at: 42, error: MusicError.badResponse(403),
                                         wantsToPlay: true, network: offline)
            #expect(stopped == .stop(.forbidden))
            #expect(policy.lastFailure == .forbidden)
            #expect(policy.pending == nil)
            #expect(!policy.waitingForNetwork)
            let staleStart = policy.consume(ticket)
            #expect(!staleStart)
            let restored = policy.networkRestored(for: id, at: 42, wantsToPlay: true)
            #expect(restored == .ignore)
            #expect(policy.attempts == 0)
        }
    }

    @Test func nonfinitePositionIsNeverPassedBackIntoThePlayer() {
        var policy = PlaybackRecovery()
        guard case .retry(let ticket) = policy.request(for: UUID(), at: .nan, error: nil, wantsToPlay: true, network: online) else {
            Issue.record("Expected a ticket"); return
        }
        #expect(ticket.position == 0)
    }

    @Test func systemInterruptionRespectsBothUserAndSystemIntent() {
        var state = PlaybackInterruptionState()
        state.began(wantsToPlay: true)
        let resume = state.ended(shouldResume: true)
        #expect(resume)
        let duplicateEnd = state.ended(shouldResume: true)
        #expect(!duplicateEnd, "duplicate end cannot resume twice")
        state.began(wantsToPlay: true)
        state.userPaused()
        let afterUserPause = state.ended(shouldResume: true)
        #expect(!afterUserPause)
        state.began(wantsToPlay: true)
        let systemDeclined = state.ended(shouldResume: false)
        #expect(!systemDeclined)
        state.began(wantsToPlay: false)
        let originallyPaused = state.ended(shouldResume: true)
        #expect(!originallyPaused)
    }
}

struct AudioStreamMetadataTests {
    @Test func selectedFormatDeclarationsAreReadWithoutInferringFromQuality() throws {
        let root = JSON(["streamingData": ["adaptiveFormats": [
            ["itag": 140, "url": "https://example.invalid/audio", "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
             "bitrate": 127_999, "audioSampleRate": "44100", "audioChannels": 2]
        ]]])
        let stream = try #require(StreamResolver.pickAudio(root, videoId: "id"))
        #expect(stream.metadata?.codec == "AAC")
        #expect(stream.metadata?.bitrate == 127_999)
        #expect(stream.metadata?.sampleRate == 44_100)
        #expect(stream.metadata?.channels == 2)
        let undeclared = JSON(["streamingData": ["adaptiveFormats": [
            ["itag": 140, "url": "https://example.invalid/audio", "mimeType": "audio/mp4"]
        ]]])
        let unknown = try #require(StreamResolver.pickAudio(undeclared, videoId: "id", quality: .dataSaver))
        #expect(unknown.metadata?.codec == nil)
        #expect(unknown.metadata?.bitrate == nil)
        #expect(unknown.metadata?.sampleRate == nil)
        #expect(unknown.metadata?.channels == nil)
        #expect(AudioStreamMetadata(mimeType: "audio/webm; codecs=\"opus\"").codec == "Opus")
    }

    @Test func invalidDeclarationsAndBufferValuesRemainUnavailable() {
        let metadata = AudioStreamMetadata(bitrate: -1, sampleRate: .infinity, channels: 0)
        #expect(metadata.bitrate == nil)
        #expect(metadata.sampleRate == nil)
        #expect(metadata.channels == nil)
        #expect(AudioPlaybackInformation(bufferedSeconds: .nan).bufferedSeconds == nil)
        #expect(!AudioPlaybackInformation().hasStream)
    }
}

@MainActor
struct PlaybackDiagnosticTests {
    @Test func boundedTypedEventsContainNoUnderlyingPrivateErrorText() throws {
        let store = PlaybackDiagnosticStore(capacity: 3)
        let secret = "Authorization: Bearer private-token; https://example.invalid/?cookie=private"
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/?cookie=private")!])
        for _ in 0..<8 { store.record(.playbackFailed, reason: .classify(error), attempt: 1) }
        #expect(store.events.count == 3)
        let encoded = String(decoding: try JSONEncoder().encode(store.events), as: UTF8.self)
        #expect(!encoded.contains("private-token"))
        #expect(!encoded.contains("https://"))
        #expect(!encoded.contains("Authorization"))
        #expect(store.events.allSatisfy { $0.reason == .timeout })
    }

    @Test func persistenceAndClearStayOrdered() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("diagnostics.json")
        let store = PlaybackDiagnosticStore(storage: file)
        store.record(.networkChanged, network: NetworkSnapshot(status: .offline))
        store.record(.networkChanged, network: NetworkSnapshot(status: .offline))
        #expect(store.events.count == 1)
        await store.flush()
        #expect(PlaybackDiagnosticStore(storage: file).events == store.events)
        store.clear()
        store.record(.recovered)
        await store.flush()
        let restored = PlaybackDiagnosticStore(storage: file)
        #expect(restored.events.count == 1)
        #expect(restored.events.first?.kind == .recovered)
        store.clear()
        await store.flush()
        #expect(PlaybackDiagnosticStore(storage: file).events.isEmpty)
    }
}
