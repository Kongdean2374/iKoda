import Foundation
import Testing
@testable import KodaCore

@MainActor
private final class CatcherGate<Value: Sendable> {
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []
    func wait() async -> Value {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func release(_ value: Value) {
        self.value = value
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume(returning: value) }
    }
}

/// A caller's account/playback intent changes on MainActor while an external
/// permission or catalog callback is suspended. Keep that state actor-isolated,
/// rather than capturing a mutable stack variable across the asynchronous flow.
@MainActor
private final class CatcherTestIntent {
    private(set) var isCurrent = true
    func invalidate() { isCurrent = false }
}

@MainActor
private final class CatcherTestProvider: MusicRecognitionProviding {
    var isAvailable = true
    let permission = CatcherGate<Bool>()
    let match = CatcherGate<Result<RecognizedMusic, MusicRecognitionFailure>>()
    let permissionStarted = CatcherGate<Bool>()
    let recordingStarted = CatcherGate<Bool>()
    var permissionCalls = 0
    var recognitionCalls = 0
    var recording = false
    var cancellations = 0
    func requestPermission() async -> Bool {
        permissionCalls += 1
        permissionStarted.release(true)
        // Deliberately ignore task cancellation, just like a system permission alert.
        return await permission.wait()
    }
    func recognize() async throws -> RecognizedMusic {
        recognitionCalls += 1
        recording = true
        recordingStarted.release(true)
        return try await match.wait().get()
    }
    func cancel() {
        recording = false
        cancellations += 1
        // A late SDK result is delivered by the test, so generation protection is
        // exercised instead of accidentally depending on a cooperative mock.
    }
}

@MainActor
struct MusicRecognitionTests {
    private let recognition = RecognizedMusic(title: "Song", artist: "Artist")
    private let song = Song(id: "song-1", title: "Song", artistLine: "Artist", duration: 180)

    @Test func permissionDeniedDoesNotPauseOrRecord() async {
        let provider = CatcherTestProvider()
        provider.permission.release(false)
        let flow = MusicRecognitionFlow()
        var paused = 0
        var restored = 0
        let work = flow.start(provider: provider, isCurrent: { true }, beforeRecording: { paused += 1; return true },
                              stoppedRecording: { _ in restored += 1 }, search: { _ in [] })
        await work.value
        #expect(flow.phase == .failed(.permissionDenied))
        #expect(provider.recognitionCalls == 0)
        #expect(paused == 0 && restored == 0)
    }

    @Test func cancelledPermissionCannotStartMicrophoneWhenItEventuallyGrants() async {
        let provider = CatcherTestProvider()
        let flow = MusicRecognitionFlow()
        var paused = 0
        let work = flow.start(provider: provider, isCurrent: { true }, beforeRecording: { paused += 1; return true },
                              stoppedRecording: { _ in }, search: { _ in [] })
        _ = await provider.permissionStarted.wait()
        flow.cancel()
        provider.permission.release(true)
        await work.value
        #expect(provider.recognitionCalls == 0 && paused == 0)
        #expect(flow.phase == .idle)
    }

    @Test func cancelledAwaitingTaskRejectsAnUncooperativePermissionAPI() async {
        let provider = CatcherTestProvider()
        let flow = MusicRecognitionFlow()
        let work = flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                              stoppedRecording: { _ in }, search: { _ in [] })
        _ = await provider.permissionStarted.wait()
        work.cancel()
        provider.permission.release(true)
        await work.value
        #expect(provider.recognitionCalls == 0)
        #expect(flow.phase == .idle)
    }

    @Test func changedAccountOrPlaybackIntentRejectsPermissionGrant() async {
        let provider = CatcherTestProvider()
        let flow = MusicRecognitionFlow()
        let intent = CatcherTestIntent()
        let work = flow.start(provider: provider, isCurrent: { intent.isCurrent }, beforeRecording: { true },
                              stoppedRecording: { _ in }, search: { _ in [] })
        _ = await provider.permissionStarted.wait()
        intent.invalidate()
        provider.permission.release(true)
        await work.value
        #expect(provider.recognitionCalls == 0)
        #expect(flow.phase == .idle)
    }

    @Test func permissionAlertInactivityWaitsForForegroundBeforeRecording() async {
        let provider = CatcherTestProvider()
        let flow = MusicRecognitionFlow()
        let activity = MusicRecognitionActivityGate()
        let waitingForActive = CatcherGate<Bool>()
        var capturedWhileActive = false
        let work = flow.start(provider: provider, isCurrent: { true }, waitUntilActive: {
            waitingForActive.release(true)
            return await activity.waitUntilActive()
        }, beforeRecording: { capturedWhileActive = activity.state == .active; return capturedWhileActive },
        stoppedRecording: { _ in }, search: { _ in [] })
        _ = await provider.permissionStarted.wait()
        activity.update(.inactive)
        provider.permission.release(true)
        _ = await waitingForActive.wait()
        #expect(provider.recognitionCalls == 0)
        activity.update(.active)
        _ = await provider.recordingStarted.wait()
        #expect(capturedWhileActive)
        provider.match.release(.success(recognition))
        await work.value
        #expect(flow.phase == .ready)
    }

    @Test func backgroundAfterPermissionNeverStartsRecording() async {
        let provider = CatcherTestProvider()
        let flow = MusicRecognitionFlow()
        let activity = MusicRecognitionActivityGate()
        activity.update(.inactive)
        let waitingForActive = CatcherGate<Bool>()
        provider.permission.release(true)
        let work = flow.start(provider: provider, isCurrent: { true }, waitUntilActive: {
            waitingForActive.release(true)
            return await activity.waitUntilActive()
        }, beforeRecording: { true }, stoppedRecording: { _ in }, search: { _ in [] })
        _ = await waitingForActive.wait()
        activity.update(.background)
        await work.value
        activity.update(.active)
        #expect(provider.recognitionCalls == 0)
        #expect(flow.phase == .idle)
    }

    @Test func cancelDuringForegroundWaitCannotBeRevivedByActiveScene() async {
        let provider = CatcherTestProvider()
        let flow = MusicRecognitionFlow()
        let activity = MusicRecognitionActivityGate()
        let waiting = CatcherGate<Bool>()
        activity.update(.inactive)
        provider.permission.release(true)
        let work = flow.start(provider: provider, isCurrent: { true }, waitUntilActive: {
            waiting.release(true)
            return await activity.waitUntilActive()
        }, beforeRecording: { true }, stoppedRecording: { _ in }, search: { _ in [] })
        _ = await waiting.wait()
        flow.cancel()
        activity.update(.active)
        await work.value
        #expect(provider.recognitionCalls == 0)
        #expect(flow.phase == .idle)
    }

    @Test func cancelledMatchDoesNotSearchAndCleansRecordingExactlyOnce() async {
        let provider = CatcherTestProvider()
        provider.permission.release(true)
        let flow = MusicRecognitionFlow()
        var searched = false
        var cleanup: [Bool] = []
        let work = flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                              stoppedRecording: { cleanup.append($0) }, search: { _ in searched = true; return [] })
        _ = await provider.recordingStarted.wait()
        flow.cancel(allowPlaybackRestore: false)
        provider.match.release(.success(recognition))
        await work.value
        #expect(!searched && !provider.recording)
        #expect(cleanup == [false])
        #expect(flow.recognized == nil && flow.candidates.isEmpty)
    }

    @Test func microphoneStopsBeforeCatalogSearchAndNoChoiceIsMadeAutomatically() async {
        let provider = CatcherTestProvider()
        provider.permission.release(true)
        provider.match.release(.success(recognition))
        let flow = MusicRecognitionFlow()
        var cleanups: [Bool] = []
        var query = ""
        let work = flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                              stoppedRecording: { cleanups.append($0) }, search: { text in
            #expect(!provider.recording)
            #expect(cleanups == [true])
            query = text
            return [song]
        })
        await work.value
        #expect(query == "Song Artist")
        #expect(flow.phase == .ready)
        #expect(flow.candidates.map(\.id) == [song.id])
    }

    @Test func lateSearchCannotPublishAfterAccountOrIntentChanges() async {
        let provider = CatcherTestProvider()
        provider.permission.release(true)
        provider.match.release(.success(recognition))
        let flow = MusicRecognitionFlow()
        let searching = CatcherGate<Bool>()
        let results = CatcherGate<[Song]>()
        let intent = CatcherTestIntent()
        let work = flow.start(provider: provider, isCurrent: { intent.isCurrent }, beforeRecording: { true },
                              stoppedRecording: { _ in }, search: { _ in searching.release(true); return await results.wait() })
        _ = await searching.wait()
        intent.invalidate()
        results.release([song])
        await work.value
        #expect(flow.phase == .idle && flow.candidates.isEmpty)
    }

    @Test func interruptionDoesNotAutomaticallyRestorePlayback() async {
        let provider = CatcherTestProvider()
        provider.permission.release(true)
        provider.match.release(.failure(.interrupted))
        let flow = MusicRecognitionFlow()
        var cleanup: [Bool] = []
        let work = flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                              stoppedRecording: { cleanup.append($0) }, search: { _ in [] })
        await work.value
        #expect(flow.phase == .failed(.interrupted))
        #expect(cleanup == [false])
    }

    @Test func unavailableServiceDoesNotRequestMicrophone() async {
        let provider = CatcherTestProvider()
        provider.isAvailable = false
        let flow = MusicRecognitionFlow()
        await flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                         stoppedRecording: { _ in }, search: { _ in [] }).value
        #expect(flow.phase == .failed(.unavailable))
        #expect(provider.permissionCalls == 0 && provider.recognitionCalls == 0)
    }

    @Test func noMatchReleasesMicrophoneAndAllowsExplicitRetry() async {
        let first = CatcherTestProvider()
        first.permission.release(true)
        first.match.release(.failure(.noMatch))
        let flow = MusicRecognitionFlow()
        var cleanups: [Bool] = []
        await flow.start(provider: first, isCurrent: { true }, beforeRecording: { true },
                         stoppedRecording: { cleanups.append($0) }, search: { _ in [] }).value
        #expect(flow.phase == .failed(.noMatch))
        #expect(!first.recording && cleanups == [true])

        let retry = CatcherTestProvider()
        retry.permission.release(true)
        retry.match.release(.success(recognition))
        await flow.start(provider: retry, isCurrent: { true }, beforeRecording: { true },
                         stoppedRecording: { cleanups.append($0) }, search: { _ in [song] }).value
        #expect(flow.phase == .ready && flow.candidates.map(\.id) == [song.id])
        #expect(!retry.recording && cleanups == [true, true])
    }

    @Test func oldMatchCannotCancelNewRecognition() async {
        let old = CatcherTestProvider(), new = CatcherTestProvider()
        old.permission.release(true); new.permission.release(true)
        let flow = MusicRecognitionFlow()
        let first = flow.start(provider: old, isCurrent: { true }, beforeRecording: { true },
                               stoppedRecording: { _ in }, search: { _ in [] })
        _ = await old.recordingStarted.wait()
        let second = flow.start(provider: new, isCurrent: { true }, beforeRecording: { true },
                                stoppedRecording: { _ in }, search: { _ in [song] })
        _ = await new.recordingStarted.wait()
        old.match.release(.success(recognition))
        await first.value
        #expect(new.recording && flow.phase == .listening)
        new.match.release(.success(recognition))
        await second.value
        #expect(flow.phase == .ready && flow.candidates.count == 1)
    }

    @Test func noCatalogCandidatesPreservesRecognizedTitleForManualSearch() async {
        let provider = CatcherTestProvider()
        provider.permission.release(true); provider.match.release(.success(recognition))
        let flow = MusicRecognitionFlow()
        await flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                         stoppedRecording: { _ in }, search: { _ in [] }).value
        #expect(flow.phase == .ready && flow.candidates.isEmpty)
        #expect(flow.recognized?.searchQuery == "Song Artist")
    }

    @Test func catalogFailureKeepsRecognizedMetadataAndLeavesMicrophoneStopped() async {
        let provider = CatcherTestProvider()
        provider.permission.release(true); provider.match.release(.success(recognition))
        let flow = MusicRecognitionFlow()
        await flow.start(provider: provider, isCurrent: { true }, beforeRecording: { true },
                         stoppedRecording: { _ in }, search: { _ in throw URLError(.notConnectedToInternet) }).value
        #expect(flow.phase == .failed(.searchFailed))
        #expect(flow.recognized == recognition && !provider.recording)
    }

    @Test func playbackLeaseRejectsNewIntentBackgroundSleepAndOtherAudioOwners() {
        let profile = UUID(), occurrence = UUID()
        let lease = MusicCatcherPlaybackLease(profileID: profile, occurrenceID: occurrence, intentRevision: 4, wasPlaying: true)
        #expect(lease.canRestore(profileID: profile, occurrenceID: occurrence, intentRevision: 4,
                                 sceneIsActive: true, sessionFinished: false, otherAudioOwner: false))
        #expect(!lease.canRestore(profileID: UUID(), occurrenceID: occurrence, intentRevision: 4,
                                  sceneIsActive: true, sessionFinished: false, otherAudioOwner: false))
        #expect(!lease.canRestore(profileID: profile, occurrenceID: UUID(), intentRevision: 4,
                                  sceneIsActive: true, sessionFinished: false, otherAudioOwner: false))
        #expect(!lease.canRestore(profileID: profile, occurrenceID: occurrence, intentRevision: 5,
                                  sceneIsActive: true, sessionFinished: false, otherAudioOwner: false))
        #expect(!lease.canRestore(profileID: profile, occurrenceID: occurrence, intentRevision: 4,
                                  sceneIsActive: false, sessionFinished: false, otherAudioOwner: false))
        #expect(!lease.canRestore(profileID: profile, occurrenceID: occurrence, intentRevision: 4,
                                  sceneIsActive: true, sessionFinished: true, otherAudioOwner: false))
        #expect(!lease.canRestore(profileID: profile, occurrenceID: occurrence, intentRevision: 4,
                                  sceneIsActive: true, sessionFinished: false, otherAudioOwner: true))
        let paused = MusicCatcherPlaybackLease(profileID: profile, occurrenceID: occurrence, intentRevision: 4, wasPlaying: false)
        #expect(!paused.canRestore(profileID: profile, occurrenceID: occurrence, intentRevision: 4,
                                   sceneIsActive: true, sessionFinished: false, otherAudioOwner: false))
    }
}

struct MusicCandidateMatcherTests {
    @Test func exactArtistAndTitleRankAheadOfRemixCoverLiveAndWrongArtist() {
        let recognized = RecognizedMusic(title: "Blue Sky", artist: "Singer")
        let songs = [
            Song(id: "remix", title: "Blue Sky (Remix)", artistLine: "Singer"),
            Song(id: "wrong", title: "Blue Sky", artistLine: "Other"),
            Song(id: "live", title: "Blue Sky (Live)", artistLine: "Singer"),
            Song(id: "cover", title: "Blue Sky (Cover)", artistLine: "Singer"),
            Song(id: "original", title: "Blue Sky", artistLine: "Singer"),
        ]
        let result = MusicCandidateMatcher.rank(songs, for: recognized)
        #expect(result.first?.id == "original")
        #expect(result.first?.confidence == .close)
        #expect(result.first { $0.id == "wrong" }?.confidence == .needsReview)
        for id in ["remix", "live", "cover"] { #expect(result.first { $0.id == id }?.confidence == .differentVersion) }
        #expect(result.count == 5) // Different versions stay visible, not silently deleted.
    }

    @Test func punctuationCaseAndDiacriticsNormalizeWithoutChangingMetadata() {
        let song = Song(id: "x", title: "CAFÉ — DANCE!", artistLine: "SÍNGER")
        let result = MusicCandidateMatcher.rank([song], for: RecognizedMusic(title: "Cafe Dance", artist: "Singer"))
        #expect(result.first?.confidence == .close)
        #expect(result.first?.song == song)
    }

    @Test func liveInAnOrdinaryTitleIsNotInventedAsConcertMetadata() {
        let song = Song(id: "x", title: "Live Forever", artistLine: "Singer")
        let result = MusicCandidateMatcher.rank([song], for: RecognizedMusic(title: "Live Forever", artist: "Singer"))
        #expect(result.first?.confidence == .close)
    }

    @Test func stableIDsDeduplicateAndTiesPreserveServiceOrder() {
        let first = Song(id: "a", title: "Song", artistLine: "Artist")
        let second = Song(id: "b", title: "Song", artistLine: "Artist")
        let result = MusicCandidateMatcher.rank([second, first, second], for: RecognizedMusic(title: "Song", artist: "Artist"))
        #expect(result.map(\.id) == ["b", "a"])
    }

    @Test func unknownArtistCannotBecomeAConfidentMatchAndResultsAreBounded() {
        let songs = (0..<100).map { Song(id: "\($0)", title: "Song", artistLine: "Artist") }
        let result = MusicCandidateMatcher.rank(songs, for: RecognizedMusic(title: "Song", artist: ""))
        #expect(result.count == 20)
        #expect(result.allSatisfy { $0.confidence == .needsReview })
        #expect(MusicCandidateMatcher.rank(songs, for: RecognizedMusic(title: "Song", artist: ""), limit: 0).isEmpty)
    }

    @Test func matchingLiveVersionsCanBeComparedWithoutCallingTheStudioVersionEqual() {
        let songs = [Song(id: "studio", title: "Song", artistLine: "Artist"),
                     Song(id: "live", title: "Song (Live)", artistLine: "Artist")]
        let result = MusicCandidateMatcher.rank(songs, for: RecognizedMusic(title: "Song (Live)", artist: "Artist"))
        #expect(result.first?.id == "live")
        #expect(result.first?.confidence == .close)
        #expect(result.last?.confidence == .differentVersion)
    }

    @Test func materiallyDifferentDeclaredDurationsNeedReviewEvenWithEqualTitles() {
        let recognized = RecognizedMusic(title: "Song", artist: "Artist", duration: 180)
        let song = Song(id: "extended", title: "Song", artistLine: "Artist", duration: 480)
        let result = MusicCandidateMatcher.rank([song], for: recognized)
        #expect(result.first?.confidence == .needsReview)
        #expect(result.first?.song.duration == 480)
    }
}
