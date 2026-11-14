import Testing
@testable import KodaCore

struct AutomaticLyricDownloadPolicyTests {
    private let english = AutomaticLyricDownloadPolicy.Pair(source: "en", target: "zh-Hant")
    private let japanese = AutomaticLyricDownloadPolicy.Pair(source: "ja", target: "zh-Hant")

    @Test func cancellingOneSongSuppressesTheSameLanguagePairOnLaterSongs() {
        var policy = AutomaticLyricDownloadPolicy()
        let started = policy.begin(english, requestID: "song-a")
        #expect(started)
        let finished = policy.finish(english, requestID: "song-a", installed: false)
        #expect(finished)
        #expect(!policy.allows(english, requestID: "song-b"))
        let laterStarted = policy.begin(english, requestID: "song-c")
        #expect(!laterStarted)
        #expect(policy.allows(japanese, requestID: "song-d"))
        policy.retry(english)
        let retried = policy.begin(english, requestID: "explicit-retry")
        #expect(retried)
    }

    @Test func replacingTheViewCannotStartTwoPromptsForTheSamePair() {
        var policy = AutomaticLyricDownloadPolicy()
        let started = policy.begin(english, requestID: "old-host")
        #expect(started)
        #expect(policy.allows(english, requestID: "old-host"))
        let duplicate = policy.begin(english, requestID: "old-host")
        #expect(!duplicate)
        #expect(!policy.allows(english, requestID: "new-song-host"))
        let finished = policy.finish(english, requestID: "old-host", installed: true)
        #expect(finished)
        let nextStarted = policy.begin(english, requestID: "new-song-host")
        #expect(nextStarted)
        let staleFinished = policy.finish(english, requestID: "old-host", installed: false)
        #expect(!staleFinished)
        #expect(policy.allows(english, requestID: "new-song-host"))
    }

    @Test func explicitRetryDuringCancellationWaitsForTheOldPromptThenRemainsAllowed() {
        var policy = AutomaticLyricDownloadPolicy()
        let started = policy.begin(english, requestID: "cancelled-host")
        #expect(started)
        policy.retry(english)
        let duplicate = policy.begin(english, requestID: "retry-host")
        #expect(!duplicate)
        let finished = policy.finish(english, requestID: "cancelled-host", installed: false)
        #expect(finished)
        let retried = policy.begin(english, requestID: "retry-host")
        #expect(retried)
    }

    @Test func retryingAnotherLanguageDoesNotUndoAnEarlierCancellation() {
        var policy = AutomaticLyricDownloadPolicy()
        let started = policy.begin(english, requestID: "english")
        #expect(started)
        let finished = policy.finish(english, requestID: "english", installed: false)
        #expect(finished)
        policy.retry(japanese)
        #expect(!policy.allows(english, requestID: "later-song"))
        policy.retry()
        #expect(policy.allows(english, requestID: "explicit-all-retry"))
    }

    @Test func movingTheDownloadHostReleasesItsClaimWithoutSuppressingThePair() {
        var policy = AutomaticLyricDownloadPolicy()
        let started = policy.begin(english, requestID: "root-view")
        #expect(started)
        #expect(!policy.allows(english, requestID: "now-playing"))
        let cancelled = policy.cancelHost(english, requestID: "root-view")
        #expect(cancelled)
        #expect(policy.allows(english, requestID: "now-playing"))
        let replacementStarted = policy.begin(english, requestID: "now-playing")
        #expect(replacementStarted)
        let declined = policy.finish(english, requestID: "now-playing", installed: false)
        #expect(declined)
        #expect(!policy.allows(english, requestID: "next-song"))
    }

    @Test func aLateHostCancellationCannotReleaseAReplacementPrompt() {
        var policy = AutomaticLyricDownloadPolicy()
        let started = policy.begin(english, requestID: "old")
        #expect(started)
        let cancelled = policy.cancelHost(english, requestID: "old")
        #expect(cancelled)
        let replacementStarted = policy.begin(english, requestID: "replacement")
        #expect(replacementStarted)
        let staleCancellation = policy.cancelHost(english, requestID: "old")
        #expect(!staleCancellation)
        #expect(policy.allows(english, requestID: "replacement"))
        #expect(!policy.allows(english, requestID: "third-host"))
    }
}
