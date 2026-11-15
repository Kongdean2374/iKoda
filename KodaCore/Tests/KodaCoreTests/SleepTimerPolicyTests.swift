import Foundation
import Testing
@testable import KodaCore

@Suite struct SleepTimerPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func defaultsToFinishingTheSessionWithoutStartingATimer() {
        let policy = SleepTimerPolicy()
        #expect(policy.state.preferredAction == .finishPlaybackSession)
        #expect(policy.state.action == .finishPlaybackSession)
        #expect(policy.state.lastDurationMinutes == 30)
        #expect(!policy.state.isActive)
        #expect(policy.state.deadline == nil)
        #expect(!policy.suppressesAutomaticResume)
    }

    @Test(arguments: [1, 5, 10, 15, 30, 45, 60, 90, 120, 180, 720])
    func supportedDurationsUseAbsoluteDeadlines(_ minutes: Int) throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: minutes, at: now)
        #expect(policy.state.deadline == now.addingTimeInterval(Double(minutes * 60)))
        #expect(policy.state.lastDurationMinutes == minutes)
        #expect(policy.state.plan?.durationMinutes == minutes)
        #expect(policy.state.action == .finishPlaybackSession)
    }

    @Test(arguments: [Int.min, -1, 0, 721, Int.max])
    func invalidDurationsCannotReplaceAnExistingTimer(_ minutes: Int) throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, action: .pause, at: now)
        let previous = policy.state
        #expect(throws: SleepTimerValidationError.invalidDuration) { try policy.start(minutes: minutes, at: now) }
        #expect(policy.state == previous)
    }

    @Test(arguments: [SleepTimerAction.pause, .finishPlaybackSession])
    func deadlineFiresTheSelectedActionExactlyOnce(_ action: SleepTimerAction) throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, action: action, at: now)
        let revision = try #require(policy.state.plan?.revision)
        let deadline = now.addingTimeInterval(1_800)
        let before = policy.evaluate(at: deadline.addingTimeInterval(-0.001), revision: revision)
        #expect(before == .none)
        let exact = policy.evaluate(at: deadline, revision: revision)
        #expect(exact == .fire(action))
        #expect(!policy.state.isActive)
        #expect(policy.state.completion == SleepTimerCompletion(revision: revision, action: action, firedAt: deadline))
        #expect(policy.suppressesAutomaticResume)
        let repeated = policy.evaluate(at: deadline.addingTimeInterval(10), revision: revision)
        #expect(repeated == .none)
    }

    @Test func delayedWakeUsesTheDeadlineNotTheLengthOfTheSleep() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 60, at: now)
        let result = policy.evaluate(at: now.addingTimeInterval(7_200))
        #expect(result == .fire(.finishPlaybackSession))
        #expect(policy.state.completion?.firedAt == now.addingTimeInterval(7_200))
    }

    @Test func clockMovingBackwardsDoesNotFireEarly() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, at: now)
        let result = policy.evaluate(at: now.addingTimeInterval(-3_600))
        #expect(result == .none)
        #expect(policy.state.remaining(at: now.addingTimeInterval(-3_600)) == 5_400)
        #expect(policy.state.deadline == now.addingTimeInterval(1_800))
    }

    @Test func extensionPreservesActionAndResetDurationButRevokesTheOldWake() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, action: .pause, at: now)
        let oldRevision = try #require(policy.state.plan?.revision)
        try policy.extend(minutes: 15, at: now.addingTimeInterval(600))
        #expect(policy.state.deadline == now.addingTimeInterval(2_700))
        #expect(policy.state.action == .pause)
        #expect(policy.state.plan?.durationMinutes == 30)
        #expect(policy.state.plan?.revision != oldRevision)
        let staleWake = policy.evaluate(at: now.addingTimeInterval(3_600), revision: oldRevision)
        #expect(staleWake == .none)
        #expect(policy.state.isActive)
        try policy.reset(at: now.addingTimeInterval(1_000))
        #expect(policy.state.deadline == now.addingTimeInterval(2_800))
    }

    @Test func extensionAfterTheDeadlineUsesNowAndDoesNotAcknowledgePlayback() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 1, at: now)
        try policy.extend(minutes: 10, at: now.addingTimeInterval(120))
        #expect(policy.state.deadline == now.addingTimeInterval(720))
        #expect(policy.state.completion == nil)
        #expect(policy.state.plan?.durationMinutes == 1)
    }

    @Test func extensionCannotCreateAnUnboundedTimer() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 720, at: now)
        let previous = policy.state
        #expect(throws: SleepTimerValidationError.invalidDuration) { try policy.extend(minutes: 1, at: now) }
        #expect(policy.state == previous)
        policy.cancel()
        #expect(throws: SleepTimerValidationError.notRunning) { try policy.extend(minutes: 5, at: now) }
    }

    @Test func cancelAndRestartInvalidateAnIdenticalDeadline() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, at: now)
        let oldRevision = try #require(policy.state.plan?.revision)
        policy.cancel()
        let cancelled = policy.evaluate(at: now.addingTimeInterval(1_800), revision: oldRevision)
        #expect(cancelled == .none)
        try policy.start(minutes: 30, at: now)
        let staleWake = policy.evaluate(at: now.addingTimeInterval(1_800), revision: oldRevision)
        #expect(staleWake == .none)
        let current = policy.evaluate(at: now.addingTimeInterval(1_800), revision: policy.state.plan?.revision)
        #expect(current == .fire(.finishPlaybackSession))
    }

    @Test func actionChangeKeepsScheduleAndInvalidatesOldTickets() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, at: now)
        let oldRevision = try #require(policy.state.plan?.revision)
        let deadline = policy.state.deadline
        policy.setAction(.pause)
        #expect(policy.state.deadline == deadline)
        #expect(policy.state.preferredAction == .pause)
        let stale = policy.evaluate(at: now.addingTimeInterval(1_800), revision: oldRevision)
        #expect(stale == .none)
        let active = policy.evaluate(at: now.addingTimeInterval(1_800))
        #expect(active == .fire(.pause))
    }

    @Test(arguments: [SleepTimerAction.pause, .finishPlaybackSession])
    func endOfSongIsIndependentOfTheChosenAction(_ action: SleepTimerAction) throws {
        var policy = SleepTimerPolicy()
        let occurrence = UUID()
        try policy.stopAtEndOfSong(occurrenceID: occurrence, action: action, at: now)
        let revision = try #require(policy.state.plan?.revision)
        #expect(policy.state.deadline == nil)
        #expect(policy.state.remaining(at: now) == nil)
        let clockOnly = policy.evaluate(at: now.addingTimeInterval(3_600))
        #expect(clockOnly == .none)
        let wrongSong = policy.songEnded(occurrenceID: UUID(), revision: revision, at: now)
        #expect(wrongSong == .none)
        let rightSong = policy.songEnded(occurrenceID: occurrence, revision: revision, at: now)
        #expect(rightSong == .fire(action))
        let twice = policy.songEnded(occurrenceID: occurrence, revision: revision, at: now)
        #expect(twice == .none)
    }

    @Test func restartingAtTheSameRepeatOneOccurrenceRejectsTheOldTimerTicket() throws {
        var policy = SleepTimerPolicy()
        let occurrence = UUID()
        try policy.stopAtEndOfSong(occurrenceID: occurrence, at: now)
        let oldRevision = try #require(policy.state.plan?.revision)
        policy.cancel()
        try policy.stopAtEndOfSong(occurrenceID: occurrence, at: now)
        let stale = policy.songEnded(occurrenceID: occurrence, revision: oldRevision, at: now)
        #expect(stale == .none)
        #expect(policy.state.isActive)
    }

    @Test func endOfSongResetAndExtensionKeepTheirDistinctMeanings() throws {
        var policy = SleepTimerPolicy()
        let occurrence = UUID()
        try policy.stopAtEndOfSong(occurrenceID: occurrence, action: .pause, at: now)
        let oldRevision = try #require(policy.state.plan?.revision)
        try policy.reset(at: now.addingTimeInterval(10))
        #expect(policy.state.plan?.schedule == .endOfSong(occurrenceID: occurrence))
        #expect(policy.state.plan?.revision != oldRevision)
        try policy.extend(minutes: 5, at: now.addingTimeInterval(20))
        #expect(policy.state.deadline == now.addingTimeInterval(320))
        #expect(policy.state.action == .pause)
    }

    @Test func newSelectionCancelsOnlyAnEndOfSongTimer() throws {
        var policy = SleepTimerPolicy()
        let occurrence = UUID()
        try policy.stopAtEndOfSong(occurrenceID: occurrence, at: now)
        let same = policy.selectionChanged(to: occurrence)
        #expect(!same && policy.state.isActive)
        let changed = policy.selectionChanged(to: UUID())
        #expect(changed && !policy.state.isActive)
        #expect(policy.state.completion == nil)
        try policy.start(minutes: 30, at: now)
        let countdownChanged = policy.selectionChanged(to: nil)
        #expect(!countdownChanged && policy.state.isActive)
    }

    @Test func completedTimerSuppressesAutomaticResumeUntilExplicitPlayback() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 1, action: .pause, at: now)
        _ = policy.evaluate(at: now.addingTimeInterval(60))
        policy.cancel()
        #expect(policy.suppressesAutomaticResume)
        policy.setAction(.finishPlaybackSession)
        #expect(policy.suppressesAutomaticResume)
        try policy.start(minutes: 30, at: now.addingTimeInterval(120))
        #expect(policy.suppressesAutomaticResume)
        policy.acknowledgeManualPlayback()
        #expect(!policy.suppressesAutomaticResume)
        #expect(policy.state.isActive)
    }

    @Test func resetAfterCompletionDoesNotItselfResumePlayback() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 90, action: .pause, at: now)
        _ = policy.evaluate(at: now.addingTimeInterval(5_400))
        try policy.reset(at: now.addingTimeInterval(6_000))
        #expect(policy.state.deadline == now.addingTimeInterval(11_400))
        #expect(policy.state.action == .pause)
        #expect(policy.suppressesAutomaticResume)
    }

    @Test func explicitSessionFinishCreatesTheSamePersistentResumeBarrier() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, action: .pause, at: now)
        let oldRevision = try #require(policy.state.plan?.revision)
        policy.recordCompletion(action: .finishPlaybackSession, at: now)
        #expect(!policy.state.isActive && policy.suppressesAutomaticResume)
        #expect(policy.state.preferredAction == .pause)
        #expect(policy.state.completion?.action == .finishPlaybackSession)
        let oldTimer = policy.evaluate(at: now.addingTimeInterval(3_600), revision: oldRevision)
        #expect(oldTimer == .none)
        let data = try #require(SleepTimerStore.encode(policy.state))
        #expect(SleepTimerPolicy(state: SleepTimerStore.decode(data, at: now)).suppressesAutomaticResume)
    }

    @Test func remainingTimeNeverBecomesNegative() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 1, at: now)
        #expect(policy.state.remaining(at: now.addingTimeInterval(30)) == 30)
        #expect(policy.state.remaining(at: now.addingTimeInterval(90)) == 0)
        let invalid = Date(timeIntervalSinceReferenceDate: .infinity)
        #expect(policy.state.remaining(at: invalid) == nil)
    }

    @Test func invalidClockCannotReplaceOrConsumeAnActiveTimer() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, at: now)
        let previous = policy.state
        let invalid = Date(timeIntervalSinceReferenceDate: .nan)
        #expect(throws: SleepTimerValidationError.invalidDate) { try policy.start(minutes: 30, at: invalid) }
        #expect(policy.state == previous)
        let result = policy.evaluate(at: invalid)
        #expect(result == .none)
        #expect(policy.state == previous)
    }
}

@Suite struct SleepTimerStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func firstLaunchHasNoTimerAndNoSuppressionMarker() {
        let state = SleepTimerStore.decode(nil, at: now)
        #expect(state == SleepTimerState())
        #expect(!SleepTimerPolicy(state: state).suppressesAutomaticResume)
    }

    @Test(arguments: [SleepTimerAction.pause, .finishPlaybackSession])
    func expiredColdLaunchConsumesAndSuppressesBeforeAnyResume(_ action: SleepTimerAction) throws {
        var original = SleepTimerPolicy()
        try original.start(minutes: 30, action: action, at: now)
        let data = try #require(SleepTimerStore.encode(original.state))
        var restored = SleepTimerPolicy(state: SleepTimerStore.decode(data, at: now.addingTimeInterval(3_600)))
        let result = restored.evaluate(at: now.addingTimeInterval(3_600))
        #expect(result == .fire(action))
        #expect(restored.suppressesAutomaticResume)
        #expect(!restored.state.isActive)
        let completedData = try #require(SleepTimerStore.encode(restored.state))
        var secondLaunch = SleepTimerPolicy(state: SleepTimerStore.decode(completedData, at: now.addingTimeInterval(7_200)))
        let repeated = secondLaunch.evaluate(at: now.addingTimeInterval(7_200))
        #expect(repeated == .none)
        #expect(secondLaunch.suppressesAutomaticResume)
    }

    @Test func futureCountdownAndSongEndSurviveRoundTrip() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 120, action: .pause, at: now)
        var data = try #require(SleepTimerStore.encode(policy.state))
        #expect(SleepTimerStore.decode(data, at: now) == policy.state)
        try policy.stopAtEndOfSong(occurrenceID: UUID(), action: .finishPlaybackSession, at: now)
        data = try #require(SleepTimerStore.encode(policy.state))
        #expect(SleepTimerStore.decode(data, at: now) == policy.state)
    }

    @Test func corruptAndUnknownSchemaSettingsFailClosed() throws {
        let malformed = SleepTimerStore.decode(Data("broken".utf8), at: now)
        #expect(!malformed.isActive)
        #expect(SleepTimerPolicy(state: malformed).suppressesAutomaticResume)
        #expect(malformed.completion?.action == .finishPlaybackSession)
        var state = SleepTimerState()
        state.schemaVersion = 99
        let unknown = SleepTimerStore.decode(try JSONEncoder().encode(state), at: now)
        #expect(!unknown.isActive && unknown.completion != nil)
        #expect(SleepTimerStore.encode(state) == nil)
    }

    @Test func invalidDurationsAndDatesInStoredStateDoNotCreatePlaybackIntent() throws {
        let badDuration = SleepTimerState(lastDurationMinutes: Int.max)
        let decoded = SleepTimerStore.decode(try JSONEncoder().encode(badDuration), at: now)
        #expect(decoded.completion != nil && !decoded.isActive)
        let wrongOrder = SleepTimerPlan(schedule: .countdown(deadline: now.addingTimeInterval(-60)), startedAt: now, durationMinutes: 1)
        let wrongState = SleepTimerState(plan: wrongOrder)
        let wrong = SleepTimerStore.decode(try JSONEncoder().encode(wrongState), at: now)
        #expect(wrong.completion != nil && !wrong.isActive)
        let infinite = SleepTimerState(plan: SleepTimerPlan(schedule: .countdown(deadline: Date(timeIntervalSinceReferenceDate: .infinity)), startedAt: now, durationMinutes: 1))
        #expect(SleepTimerStore.encode(infinite) == nil)
        #expect(SleepTimerPolicy(state: infinite).suppressesAutomaticResume)
    }

    @Test func unknownActionsDoNotFallBackToAutomaticPlayback() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 30, at: now)
        let data = try #require(SleepTimerStore.encode(policy.state))
        let text = try #require(String(data: data, encoding: .utf8))
        let unknown = Data(text.replacingOccurrences(of: "finishPlaybackSession", with: "futureAction").utf8)
        let decoded = SleepTimerStore.decode(unknown, at: now)
        #expect(!decoded.isActive && decoded.completion != nil)
    }

    @Test func storedCompletionClosesTheGapBeforeQueueWasPlayingIsUpdated() throws {
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 1, at: now)
        _ = policy.evaluate(at: now.addingTimeInterval(60))
        let data = try #require(SleepTimerStore.encode(policy.state))
        let restored = SleepTimerPolicy(state: SleepTimerStore.decode(data, at: now.addingTimeInterval(120)))
        let staleQueueWasPlaying = true
        let shouldConsiderAutomaticResume = staleQueueWasPlaying && !restored.suppressesAutomaticResume
        #expect(!shouldConsiderAutomaticResume)
    }

    @Test func defaultsSaveRestoreAndManualAcknowledgementRemainIsolated() throws {
        let suite = "sleep-timer-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SleepTimerStore.load(defaults: defaults, at: now) == SleepTimerState())
        var policy = SleepTimerPolicy()
        try policy.start(minutes: 1, action: .pause, at: now)
        #expect(SleepTimerStore.save(policy.state, defaults: defaults))
        #expect(SleepTimerStore.load(defaults: defaults, at: now) == policy.state)
        _ = policy.evaluate(at: now.addingTimeInterval(60))
        #expect(SleepTimerStore.save(policy.state, defaults: defaults))
        var restored = SleepTimerPolicy(state: SleepTimerStore.load(defaults: defaults, at: now))
        #expect(restored.suppressesAutomaticResume)
        restored.acknowledgeManualPlayback()
        #expect(SleepTimerStore.save(restored.state, defaults: defaults))
        #expect(!SleepTimerPolicy(state: SleepTimerStore.load(defaults: defaults, at: now)).suppressesAutomaticResume)
    }

    @Test func wrongDefaultsValueTypeAlsoSuppressesAutomaticResume() throws {
        let suite = "sleep-timer-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unexpected string", forKey: SleepTimerStore.key)
        let policy = SleepTimerPolicy(state: SleepTimerStore.load(defaults: defaults, at: now))
        #expect(!policy.state.isActive && policy.suppressesAutomaticResume)
    }
}
