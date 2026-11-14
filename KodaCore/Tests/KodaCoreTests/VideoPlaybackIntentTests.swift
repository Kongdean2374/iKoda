import Foundation
import Testing
@testable import KodaCore

/// The gate deliberately ignores Task cancellation, like a service or AVFoundation operation
/// that has already begun. Only the production generation checks can reject its late result.
private actor VideoIntentGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        opened = true
        let continuations = waiting
        waiting = []
        for continuation in continuations { continuation.resume() }
    }
}

struct VideoPlaybackIntentTests {
    @Test func musicSelectionRejectsAnInFlightStreamEvenIfCancellationIsIgnored() async {
        var intent = VideoPlaybackIntent()
        let ticket = intent.begin(videoID: "mv-a")
        let gate = VideoIntentGate()
        let pendingStream = Task { await gate.wait(); return ticket }
        intent.pause()
        await gate.release()
        let returnedTicket = await pendingStream.value
        #expect(!intent.accepts(returnedTicket))
        #expect(!intent.wantsToPlay)
        #expect(intent.currentID == "mv-a")
        let autoplayAfterPause = intent.beginAutoplay()
        #expect(autoplayAfterPause == nil)
    }

    @Test func pauseDuringResumeSeekPreventsTheLaterPlayCallback() async {
        var intent = VideoPlaybackIntent()
        let preparing = intent.begin(videoID: "mv-a")
        #expect(intent.accepts(preparing)) // Stream installation is allowed before the pause.
        let seek = VideoIntentGate()
        let pendingReady = Task { await seek.wait(); return preparing }
        intent.pause()
        let explicitResume = intent.begin(videoID: "mv-a")
        await seek.release()
        let returnedTicket = await pendingReady.value
        #expect(!intent.accepts(returnedTicket))
        #expect(intent.accepts(explicitResume))
    }

    @Test func sameVideoRetryHasANewGeneration() {
        var intent = VideoPlaybackIntent()
        let first = intent.begin(videoID: "mv-a")
        let retry = intent.begin(videoID: "mv-a")
        #expect(first != retry)
        #expect(!intent.accepts(first)) // Old errors and defer cleanup cannot alter the retry.
        #expect(intent.accepts(retry))
    }

    @Test func oldFailureCannotStopOrClearTheNewVideoRequest() async {
        var intent = VideoPlaybackIntent()
        let old = intent.begin(videoID: "mv-a")
        let failingRequest = VideoIntentGate()
        let oldFailure = Task { await failingRequest.wait(); return old }
        let latest = intent.begin(videoID: "mv-b")
        await failingRequest.release()
        let returnedTicket = await oldFailure.value
        #expect(!intent.accepts(returnedTicket))
        #expect(intent.currentID == "mv-b")
        #expect(intent.wantsToPlay)
        #expect(intent.accepts(latest))
    }

    @Test func musicSelectionCancelsWatchPageAndCountdownAutoplay() async throws {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        let requestedAutoplay = intent.beginAutoplay()
        let autoplay = try #require(requestedAutoplay)
        let watchPage = VideoIntentGate()
        let pendingNextVideo = Task { await watchPage.wait(); return autoplay }
        intent.pause()
        await watchPage.release()
        let returnedTicket = await pendingNextVideo.value
        #expect(!intent.accepts(returnedTicket))
        #expect(!intent.accepts(autoplay)) // Every countdown wake-up checks the same ticket.
        let autoplayAfterPause = intent.beginAutoplay()
        #expect(autoplayAfterPause == nil)
    }

    @Test func cancelAutoplayDoesNotInvalidateNormalPlayback() throws {
        var intent = VideoPlaybackIntent()
        let load = intent.begin(videoID: "mv-a")
        let firstAutoplay = intent.beginAutoplay()
        let oldCountdown = try #require(firstAutoplay)
        intent.cancelAutoplay()
        #expect(intent.accepts(load))
        #expect(!intent.accepts(oldCountdown))
        let secondAutoplay = intent.beginAutoplay()
        let laterCountdown = try #require(secondAutoplay)
        #expect(intent.accepts(laterCountdown))
        #expect(!intent.accepts(oldCountdown))
    }

    @Test func rapidVideoMusicSwitchesRejectBothLateLoads() async {
        var intent = VideoPlaybackIntent()
        let first = intent.begin(videoID: "mv-a")
        let gate = VideoIntentGate()
        let firstLoad = Task { await gate.wait(); return first }
        intent.pause()
        let second = intent.begin(videoID: "mv-b")
        let secondLoad = Task { await gate.wait(); return second }
        intent.pause()
        await gate.release()
        let firstReturnedTicket = await firstLoad.value
        let secondReturnedTicket = await secondLoad.value
        #expect(!intent.accepts(firstReturnedTicket))
        #expect(!intent.accepts(secondReturnedTicket))
        #expect(intent.currentID == "mv-b") // Selection survives; automatic playback does not.
        let explicitResume = intent.begin(videoID: "mv-b")
        #expect(intent.accepts(explicitResume))
    }

    @Test func stopInvalidatesEverythingAndUnchangedIntentCanComplete() async throws {
        var intent = VideoPlaybackIntent()
        let load = intent.begin(videoID: "mv-a")
        let ready = VideoIntentGate()
        let task = Task { await ready.wait(); return load }
        await ready.release()
        let returnedTicket = await task.value
        #expect(intent.accepts(returnedTicket))
        let requestedAutoplay = intent.beginAutoplay()
        let countdown = try #require(requestedAutoplay)
        intent.stop()
        #expect(intent.currentID == nil)
        #expect(!intent.wantsToPlay)
        #expect(!intent.accepts(load))
        #expect(!intent.accepts(countdown))
    }
}
