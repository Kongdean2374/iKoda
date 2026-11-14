import Foundation
import Testing
@testable import KodaCore

/// System permission dialogs can finish after the awaiting task is canceled.
/// Deliberately ignore cancellation so the production lifecycle must reject it.
private actor VoicePermissionGate {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func grant() {
        released = true
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume() }
    }
}

struct VoiceSearchLifecycleTests {
    @Test func canceledSpeechAuthorizationCannotStartMicrophoneOrTouchPlayback() async throws {
        var lifecycle = VoiceSearchLifecycle()
        let generation = lifecycle.begin()
        let speech = VoicePermissionGate()
        let pending = Task { await speech.wait(); return generation }
        let ended = lifecycle.end(generation)
        let cleanup = try #require(ended)
        #expect(!cleanup.restoreAudioSession)
        await speech.grant()
        let lateGrant = await pending.value
        #expect(!lifecycle.accepts(lateGrant))
        let acquiredLate = lifecycle.acquiredAudioSession(for: lateGrant)
        #expect(!acquiredLate)
        let staleCleanup = lifecycle.end(lateGrant)
        #expect(staleCleanup == nil)
    }

    @Test func canceledMicrophoneAuthorizationCannotStartRecording() async throws {
        var lifecycle = VoiceSearchLifecycle()
        let generation = lifecycle.begin()
        #expect(lifecycle.accepts(generation)) // Speech authorization was already granted.
        let microphone = VoicePermissionGate()
        let pending = Task { await microphone.wait(); return generation }
        let ended = lifecycle.end(generation)
        let cleanup = try #require(ended)
        #expect(!cleanup.restoreAudioSession)
        await microphone.grant()
        let lateGrant = await pending.value
        #expect(!lifecycle.accepts(lateGrant))
        let acquiredLate = lifecycle.acquiredAudioSession(for: lateGrant)
        #expect(!acquiredLate)
    }

    @Test func canceledAwaitingTaskIsRejectedEvenBeforeItsCancellationHandlerRuns() async throws {
        var lifecycle = VoiceSearchLifecycle()
        let generation = lifecycle.begin()
        let microphone = VoicePermissionGate()
        let pending = Task {
            await microphone.wait()
            return Task.isCancelled
        }
        pending.cancel()
        await microphone.grant()
        let canceled = await pending.value
        #expect(canceled)
        #expect(!lifecycle.accepts(generation, taskIsCancelled: canceled))
        let ended = lifecycle.end(generation)
        let cleanup = try #require(ended)
        #expect(!cleanup.restoreAudioSession)
    }

    @Test func oldPermissionGrantCannotClaimOrCleanUpANewerRecordingSession() async throws {
        var lifecycle = VoiceSearchLifecycle()
        let old = lifecycle.begin()
        let permission = VoicePermissionGate()
        let pending = Task { await permission.wait(); return old }
        _ = lifecycle.end(old)
        let latest = lifecycle.begin()
        let acquiredLatest = lifecycle.acquiredAudioSession(for: latest)
        #expect(acquiredLatest)
        await permission.grant()
        let lateGrant = await pending.value
        #expect(old != latest)
        #expect(!lifecycle.accepts(lateGrant))
        let acquiredLate = lifecycle.acquiredAudioSession(for: lateGrant)
        #expect(!acquiredLate)
        let staleCleanup = lifecycle.end(lateGrant)
        #expect(staleCleanup == nil)
        #expect(lifecycle.accepts(latest))
        let ended = lifecycle.end(latest)
        let cleanup = try #require(ended)
        #expect(cleanup.restoreAudioSession)
    }

    @Test func deniedPermissionOrFailedCategoryChangeDoesNotDeactivatePlayback() throws {
        var lifecycle = VoiceSearchLifecycle()
        for _ in 0..<3 { // Speech denied, microphone denied, or setCategory threw.
            let generation = lifecycle.begin()
            let ended = lifecycle.end(generation)
            let cleanup = try #require(ended)
            #expect(!cleanup.restoreAudioSession)
            #expect(!lifecycle.accepts(generation))
        }
    }

    @Test func activationOrEngineFailureRestoresAnAcquiredSessionExactlyOnce() throws {
        var lifecycle = VoiceSearchLifecycle()
        for _ in 0..<2 { // setActive or engine.start threw after the category changed.
            let generation = lifecycle.begin()
            let acquired = lifecycle.acquiredAudioSession(for: generation)
            #expect(acquired)
            let ended = lifecycle.end(generation)
            let cleanup = try #require(ended)
            #expect(cleanup.restoreAudioSession)
            let duplicateCleanup = lifecycle.end(generation)
            #expect(duplicateCleanup == nil)
            #expect(!lifecycle.accepts(generation))
        }
    }

    @Test func oldRecognitionErrorAndSilenceTimerCannotEndANewSession() throws {
        var lifecycle = VoiceSearchLifecycle()
        let old = lifecycle.begin()
        let acquiredOld = lifecycle.acquiredAudioSession(for: old)
        #expect(acquiredOld)
        _ = lifecycle.end(old)
        let latest = lifecycle.begin()
        let acquiredLatest = lifecycle.acquiredAudioSession(for: latest)
        #expect(acquiredLatest)
        #expect(!lifecycle.accepts(old))
        let staleCleanup = lifecycle.end(old)
        #expect(staleCleanup == nil)
        #expect(lifecycle.accepts(latest))
        let ended = lifecycle.end(latest)
        let cleanup = try #require(ended)
        #expect(cleanup.restoreAudioSession)
    }

    @Test func repeatedStartCancelFinishAndFailureLeaveNoOwnershipBehind() throws {
        var lifecycle = VoiceSearchLifecycle()
        var previous: VoiceSearchLifecycle.Generation?
        for index in 0..<100 {
            let generation = lifecycle.begin()
            #expect(generation != previous)
            if let previous {
                #expect(!lifecycle.accepts(previous))
                let staleCleanup = lifecycle.end(previous)
                #expect(staleCleanup == nil)
            }
            let recorded = index.isMultiple(of: 2)
            if recorded {
                let acquired = lifecycle.acquiredAudioSession(for: generation)
                #expect(acquired)
            }
            let ended = lifecycle.end(generation)
            let cleanup = try #require(ended)
            #expect(cleanup.restoreAudioSession == recorded)
            #expect(lifecycle.current == nil)
            let duplicateCleanup = lifecycle.end(generation)
            #expect(duplicateCleanup == nil)
            previous = generation
        }
    }
}
