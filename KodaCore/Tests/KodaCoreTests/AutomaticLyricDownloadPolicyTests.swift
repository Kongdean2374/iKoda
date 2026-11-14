import Testing
@testable import KodaCore

struct AutomaticLyricDownloadPolicyTests {
    private let english = AutomaticLyricDownloadPolicy.Pair(source: "en", target: "zh-Hant")
    private let japanese = AutomaticLyricDownloadPolicy.Pair(source: "ja", target: "zh-Hant")

    @Test func cancellingOneSongSuppressesTheSameLanguagePairOnLaterSongs() {
        var policy = AutomaticLyricDownloadPolicy()
        #expect(policy.begin(english, requestID: "song-a"))
        #expect(policy.finish(english, requestID: "song-a", installed: false))
        #expect(!policy.allows(english, requestID: "song-b"))
        #expect(!policy.begin(english, requestID: "song-c"))
        #expect(policy.allows(japanese, requestID: "song-d"))
        policy.retry(english)
        #expect(policy.begin(english, requestID: "explicit-retry"))
    }

    @Test func replacingTheViewCannotStartTwoPromptsForTheSamePair() {
        var policy = AutomaticLyricDownloadPolicy()
        #expect(policy.begin(english, requestID: "old-host"))
        #expect(policy.allows(english, requestID: "old-host"))
        #expect(!policy.begin(english, requestID: "old-host"))
        #expect(!policy.allows(english, requestID: "new-song-host"))
        #expect(policy.finish(english, requestID: "old-host", installed: true))
        #expect(policy.begin(english, requestID: "new-song-host"))
        #expect(!policy.finish(english, requestID: "old-host", installed: false))
        #expect(policy.allows(english, requestID: "new-song-host"))
    }

    @Test func explicitRetryDuringCancellationWaitsForTheOldPromptThenRemainsAllowed() {
        var policy = AutomaticLyricDownloadPolicy()
        #expect(policy.begin(english, requestID: "cancelled-host"))
        policy.retry(english)
        #expect(!policy.begin(english, requestID: "retry-host"))
        #expect(policy.finish(english, requestID: "cancelled-host", installed: false))
        #expect(policy.begin(english, requestID: "retry-host"))
    }

    @Test func retryingAnotherLanguageDoesNotUndoAnEarlierCancellation() {
        var policy = AutomaticLyricDownloadPolicy()
        #expect(policy.begin(english, requestID: "english"))
        #expect(policy.finish(english, requestID: "english", installed: false))
        policy.retry(japanese)
        #expect(!policy.allows(english, requestID: "later-song"))
        policy.retry()
        #expect(policy.allows(english, requestID: "explicit-all-retry"))
    }
}
