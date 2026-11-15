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

    @Test func aRestoredWatchPageCannotResumeAPausedOrStoppedSelection() {
        var intent = VideoPlaybackIntent()
        #expect(intent.canStartFromWatchPage(videoID: "mv-a"))
        intent.begin(videoID: "mv-a")
        intent.pause()
        #expect(!intent.canStartFromWatchPage(videoID: "mv-a"))
        intent.stop()
        #expect(intent.currentID == nil)
        #expect(!intent.canStartFromWatchPage(videoID: "mv-a"))
        #expect(intent.canStartFromWatchPage(videoID: "mv-b"))
        let explicitPlay = intent.begin(videoID: "mv-a")
        #expect(intent.accepts(explicitPlay))
    }

    @Test func backgroundCancelsLateLoadAndAutoplayAndForegroundNeverRestartsEither() async throws {
        var intent = VideoPlaybackIntent()
        let load = intent.begin(videoID: "mv-a")
        let countdownRequest = intent.beginAutoplay()
        let countdown = try #require(countdownRequest)
        let gate = VideoIntentGate()
        let lateStream = Task { await gate.wait(); return load }
        let mustPause = intent.enterBackground(hasExternalPresentation: false,
            mayContinueIntoPictureInPicture: false, at: 10)
        #expect(mustPause)
        #expect(!intent.canStartPlayback(hasExternalPresentation: false))
        #expect(!intent.canStartPlayback(hasExternalPresentation: true))
        #expect(!intent.canStartFromWatchPage(videoID: "mv-b"))
        intent.enterForeground()
        await gate.release()
        let returned = await lateStream.value
        #expect(!intent.accepts(returned))
        #expect(!intent.accepts(countdown))
        #expect(!intent.wantsToPlay)
        let unsolicitedRate = intent.observedPlaying(hasExternalPresentation: false)
        #expect(unsolicitedRate == .pause)
        #expect(!intent.wantsToPlay)
        #expect(!intent.canStartFromWatchPage(videoID: "mv-a"))
        let explicitPlay = intent.begin(videoID: "mv-a")
        #expect(intent.accepts(explicitPlay))
    }

    @Test func activeExternalPlaybackKeepsItsExistingIntentAcrossBackgroundAndForeground() {
        var intent = VideoPlaybackIntent()
        let ticket = intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        let mustPause = intent.enterBackground(hasExternalPresentation: true,
            mayContinueIntoPictureInPicture: false, at: 10)
        #expect(!mustPause)
        #expect(intent.canStartPlayback(hasExternalPresentation: true))
        #expect(intent.accepts(ticket))
        let playing = intent.observedPlaying(hasExternalPresentation: true)
        #expect(playing == .continuePlayback)
        intent.enterForeground()
        #expect(intent.accepts(ticket))
    }

    @Test func nativePauseInvalidatesPendingWorkButItsAuthorizedNativePlayStillWorks() throws {
        var intent = VideoPlaybackIntent()
        let seek = intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        let requestedAutoplay = intent.beginAutoplay()
        let countdown = try #require(requestedAutoplay)
        intent.pause(preservingExternalControls: true)
        #expect(!intent.accepts(seek))
        #expect(!intent.accepts(countdown))
        #expect(!intent.wantsToPlay)
        let inlineRestoration = intent.observedPlaying(hasExternalPresentation: false)
        #expect(inlineRestoration == .pause)
        #expect(!intent.wantsToPlay)
        let nativePlay = intent.observedPlaying(hasExternalPresentation: true)
        #expect(nativePlay == .resumeExternalPlayback)
        #expect(intent.wantsToPlay)
        #expect(!intent.accepts(seek))
    }

    @Test func nativeRateZeroBeforeTheEndNotificationDoesNotCancelUpNext() throws {
        var intent = VideoPlaybackIntent()
        let playback = intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        let wasUserPause = intent.observedNativePause(position: 179.99, duration: 180,
            isLoading: false, hasEnded: false, hasExternalPresentation: true, wasPlaying: true, receivedRateStop: false)
        #expect(!wasUserPause)
        #expect(intent.accepts(playback))
        let countdown = intent.beginAutoplay()
        #expect(countdown != nil)
        let endAlreadyReported = intent.observedNativePause(position: 180, duration: 180,
            isLoading: false, hasEnded: true, hasExternalPresentation: true, wasPlaying: true, receivedRateStop: false)
        #expect(!endAlreadyReported)
        let pending = try #require(countdown)
        #expect(intent.accepts(pending))
    }

    @Test func nativePauseAwayFromTheActualEndCancelsSeekAndCountdownWithoutRevokingItsControls() throws {
        var intent = VideoPlaybackIntent()
        let playback = intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        let requested = intent.beginAutoplay()
        let countdown = try #require(requested)
        let paused = intent.observedNativePause(position: 42, duration: 180,
            isLoading: false, hasEnded: false, hasExternalPresentation: true, wasPlaying: true, receivedRateStop: false)
        #expect(paused)
        #expect(!intent.accepts(playback))
        #expect(!intent.accepts(countdown))
        #expect(!intent.wantsToPlay)
        #expect(intent.hasExternalControlAuthorization)
        let resumed = intent.observedPlaying(hasExternalPresentation: true)
        #expect(resumed == .resumeExternalPlayback)
    }

    @Test func aFailedPiPHandoffCannotLaterResumeButDoesNotRevokeAnotherExternalPresentation() {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.enterBackground(hasExternalPresentation: false, mayContinueIntoPictureInPicture: true, at: 10)
        intent.authorizeExternalControls(explicitPresentation: true)
        intent.cancelPictureInPictureContinuation()
        let stalePiP = intent.continueIntoPictureInPicture(at: 10.5)
        #expect(!stalePiP)
        let activeAirPlay = intent.observedPlaying(hasExternalPresentation: true)
        #expect(activeAirPlay == .resumeExternalPlayback)
    }

    @Test func nativePauseWhileBufferingUsesTheRateTransitionWithoutMistakingInitialPausedStateForAnAction() throws {
        var intent = VideoPlaybackIntent()
        let pendingSeek = intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        let requested = intent.beginAutoplay()
        let countdown = try #require(requested)
        // During buffering the UI no longer reports isPlaying. Simply observing a
        // paused/preparing item must not cancel the listener's existing request.
        let noPauseEvidence = intent.observedNativePause(position: 42, duration: 180,
            isLoading: false, hasEnded: false, hasExternalPresentation: true,
            wasPlaying: false, receivedRateStop: false)
        #expect(!noPauseEvidence)
        #expect(intent.accepts(pendingSeek))
        // Native Pause supplies a positive-to-zero rate transition for that same item.
        let nativePause = intent.observedNativePause(position: 42, duration: 180,
            isLoading: false, hasEnded: false, hasExternalPresentation: true,
            wasPlaying: false, receivedRateStop: true)
        #expect(nativePause)
        #expect(!intent.accepts(pendingSeek))
        #expect(!intent.accepts(countdown))
        #expect(!intent.wantsToPlay)
        let nativeResume = intent.observedPlaying(hasExternalPresentation: true)
        #expect(nativeResume == .resumeExternalPlayback)
    }

    @Test func aMusicOrAppPauseRevokesExternalControlPermission() {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        intent.pause()
        // A route/controller still being visible is not fresh permission to pause music.
        intent.authorizeExternalControls()
        let staleNativeRate = intent.observedPlaying(hasExternalPresentation: true)
        #expect(staleNativeRate == .pause)
        #expect(!intent.wantsToPlay)
        #expect(!intent.hasExternalControlAuthorization)
        intent.enterBackground(hasExternalPresentation: true, mayContinueIntoPictureInPicture: false, at: 10)
        #expect(!intent.canStartPlayback(hasExternalPresentation: true))
    }

    @Test func anAuthorizedPiPHandoffCanContinueButStartingAloneCannotResumeAPausedVideo() {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.authorizeExternalControls()
        intent.enterBackground(hasExternalPresentation: true, mayContinueIntoPictureInPicture: false, at: 10)
        let duringHandoff = intent.observedPlaying(hasExternalPresentation: false, isStartingPictureInPicture: true)
        #expect(duringHandoff == .continuePlayback)
        intent.pause(preservingExternalControls: true)
        let merelyStarting = intent.observedPlaying(hasExternalPresentation: false, isStartingPictureInPicture: true)
        #expect(merelyStarting == .pause)
        #expect(!intent.wantsToPlay)
        let nativePlayAfterStarting = intent.observedPlaying(hasExternalPresentation: true)
        #expect(nativePlayAfterStarting == .resumeExternalPlayback)
    }

    @Test func explicitlyFloatingAPausedVideoAllowsItsNativePlayWithoutStartingIt() {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.pause()
        intent.authorizeExternalControls(explicitPresentation: true)
        #expect(!intent.wantsToPlay)
        let backgroundPause = intent.enterBackground(hasExternalPresentation: true,
            mayContinueIntoPictureInPicture: false, at: 10)
        #expect(!backgroundPause)
        #expect(!intent.wantsToPlay)
        let nativePlay = intent.observedPlaying(hasExternalPresentation: true)
        #expect(nativePlay == .resumeExternalPlayback)
    }

    @Test func onlyAnActualTimelyPiPCallbackCanContinueThePreBackgroundPlayingGeneration() {
        var intent = VideoPlaybackIntent()
        let previous = intent.begin(videoID: "mv-a")
        let mustPause = intent.enterBackground(hasExternalPresentation: false,
            mayContinueIntoPictureInPicture: true, at: 10)
        #expect(mustPause)
        #expect(!intent.accepts(previous))
        #expect(!intent.wantsToPlay)
        let inlineRate = intent.observedPlaying(hasExternalPresentation: false)
        #expect(inlineRate == .pause)
        #expect(intent.hasPictureInPictureContinuation(at: 10.5))
        let actualPiPStarted = intent.continueIntoPictureInPicture(at: 10.5)
        #expect(actualPiPStarted)
        #expect(intent.wantsToPlay)
        #expect(intent.hasExternalControlAuthorization)
        let duplicatedCallback = intent.continueIntoPictureInPicture(at: 10.6)
        #expect(!duplicatedCallback)
        #expect(!intent.accepts(previous))
    }

    @Test(arguments: ["pause", "stop", "another-video", "same-video", "foreground", "external-ended"])
    func laterIntentAlwaysRevokesThePendingAutomaticPiPHandoff(_ event: String) {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.enterBackground(hasExternalPresentation: false, mayContinueIntoPictureInPicture: true, at: 10)
        switch event {
        case "pause": intent.pause()
        case "stop": intent.stop()
        case "another-video": intent.begin(videoID: "mv-b")
        case "same-video": intent.begin(videoID: "mv-a")
        case "foreground": intent.enterForeground()
        default: intent.revokeExternalControls()
        }
        let latePiP = intent.continueIntoPictureInPicture(at: 10.5)
        #expect(!latePiP)
    }

    @Test(arguments: [9.0, 12.01, Double.infinity, Double.nan])
    func expiredOrInvalidPiPHandoffsCannotResume(_ callbackTime: Double) {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.enterBackground(hasExternalPresentation: false, mayContinueIntoPictureInPicture: true, at: 10)
        let allowed = intent.continueIntoPictureInPicture(at: callbackTime)
        #expect(!allowed)
        #expect(!intent.wantsToPlay)
    }

    @Test func aPausedVideoHasNoAutomaticPiPHandoffAndLosingExternalPresentationCannotPlayInlineInBackground() {
        var intent = VideoPlaybackIntent()
        intent.begin(videoID: "mv-a")
        intent.pause()
        intent.enterBackground(hasExternalPresentation: false, mayContinueIntoPictureInPicture: true, at: 10)
        let pausedHandoff = intent.continueIntoPictureInPicture(at: 10.5)
        #expect(!pausedHandoff)
        let unsolicitedExternalRate = intent.observedPlaying(hasExternalPresentation: true)
        #expect(unsolicitedExternalRate == .pause)
        intent.enterForeground()
        intent.begin(videoID: "mv-b")
        intent.authorizeExternalControls()
        intent.enterBackground(hasExternalPresentation: true, mayContinueIntoPictureInPicture: false, at: 20)
        intent.revokeExternalControls()
        let lostRoute = intent.observedPlaying(hasExternalPresentation: false)
        #expect(lostRoute == .pause)
        #expect(!intent.wantsToPlay)
        intent.enterForeground()
        let lateForegroundRate = intent.observedPlaying(hasExternalPresentation: false)
        #expect(lateForegroundRate == .pause)
    }
}
