import Foundation

/// What happens at the selected boundary. Finishing a session is independent of
/// waiting for the end of a song: a countdown always fires at its wall-clock deadline.
public enum SleepTimerAction: String, CaseIterable, Codable, Equatable, Sendable {
    case pause, finishPlaybackSession

    public var title: String {
        switch self {
        case .pause: NSLocalizedString("Pause Playback", bundle: KodaLocalization.bundle, comment: "")
        case .finishPlaybackSession: NSLocalizedString("Finish Playback Session", bundle: KodaLocalization.bundle, comment: "")
        }
    }
}

public enum SleepTimerSchedule: Codable, Equatable, Sendable {
    case countdown(deadline: Date)
    case endOfSong(occurrenceID: UUID)
}

public struct SleepTimerPlan: Codable, Equatable, Sendable {
    /// Replaced on every start, extension, reset or action change. A cancelled task
    /// cannot fire a new timer, even when both happen to have the same deadline.
    public let revision: UUID
    public let schedule: SleepTimerSchedule
    public let action: SleepTimerAction
    public let startedAt: Date
    /// The original duration, used by Reset. Extensions do not change this preference.
    public let durationMinutes: Int?

    public init(revision: UUID = UUID(), schedule: SleepTimerSchedule, action: SleepTimerAction = .finishPlaybackSession,
                startedAt: Date, durationMinutes: Int? = nil) {
        self.revision = revision; self.schedule = schedule; self.action = action
        self.startedAt = startedAt; self.durationMinutes = durationMinutes
    }
}

public struct SleepTimerCompletion: Codable, Equatable, Sendable {
    public let revision: UUID
    public let action: SleepTimerAction
    public let firedAt: Date

    public init(revision: UUID, action: SleepTimerAction, firedAt: Date) {
        self.revision = revision; self.action = action; self.firedAt = firedAt
    }
}

public struct SleepTimerState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var plan: SleepTimerPlan?
    public var preferredAction: SleepTimerAction
    public var lastDurationMinutes: Int
    /// Persist before changing AVPlayer or the queue file. If the process exits between
    /// those writes, this marker still prevents an older wasPlaying snapshot restarting.
    /// Only an explicit new playback request acknowledges it; Cancel does not.
    public var completion: SleepTimerCompletion?

    public init(plan: SleepTimerPlan? = nil, preferredAction: SleepTimerAction = .finishPlaybackSession,
                lastDurationMinutes: Int = 30, completion: SleepTimerCompletion? = nil) {
        schemaVersion = 1
        self.plan = plan; self.preferredAction = preferredAction
        self.lastDurationMinutes = lastDurationMinutes; self.completion = completion
    }

    public var isActive: Bool { plan != nil }
    public var deadline: Date? {
        guard let plan, case .countdown(let deadline) = plan.schedule else { return nil }
        return deadline
    }
    public var action: SleepTimerAction { plan?.action ?? preferredAction }
    public func remaining(at date: Date) -> TimeInterval? {
        guard let deadline, SleepTimerPolicy.isValidDate(date) else { return nil }
        return max(0, deadline.timeIntervalSince(date))
    }

    var isValid: Bool {
        guard schemaVersion == 1, SleepTimerPolicy.minuteRange.contains(lastDurationMinutes) else { return false }
        if let completion, !SleepTimerPolicy.isValidDate(completion.firedAt) { return false }
        guard let plan else { return true }
        guard SleepTimerPolicy.isValidDate(plan.startedAt) else { return false }
        switch plan.schedule {
        case .countdown(let deadline):
            guard SleepTimerPolicy.isValidDate(deadline), let minutes = plan.durationMinutes,
                  SleepTimerPolicy.minuteRange.contains(minutes) else { return false }
            let interval = deadline.timeIntervalSince(plan.startedAt)
            return interval >= 60 && interval <= TimeInterval(SleepTimerPolicy.minuteRange.upperBound * 60)
        case .endOfSong:
            return plan.durationMinutes == nil
        }
    }
}

public enum SleepTimerValidationError: Error, LocalizedError, Equatable, Sendable {
    case invalidDuration, invalidDate, notRunning
    public var errorDescription: String? {
        switch self {
        case .invalidDuration: NSLocalizedString("Choose a sleep timer between 1 and 720 minutes.", bundle: KodaLocalization.bundle, comment: "")
        case .invalidDate: NSLocalizedString("The sleep timer time is invalid. Try setting it again.", bundle: KodaLocalization.bundle, comment: "")
        case .notRunning: NSLocalizedString("The sleep timer is not running.", bundle: KodaLocalization.bundle, comment: "")
        }
    }
}

/// Pure deadline and ownership policy. No sleeping, player operations or system clock
/// reads occur here. The player supplies Date and persists every returned state change.
public struct SleepTimerPolicy: Equatable, Sendable {
    public enum Effect: Equatable, Sendable { case none, fire(SleepTimerAction) }
    public static let minuteRange = 1...720
    public private(set) var state: SleepTimerState

    public init(state: SleepTimerState = SleepTimerState()) {
        self.state = state.isValid ? state : SleepTimerStore.invalidState(at: Date(timeIntervalSince1970: 0))
    }

    public var suppressesAutomaticResume: Bool { state.completion != nil }

    public mutating func start(minutes: Int, action: SleepTimerAction = .finishPlaybackSession, at now: Date) throws {
        try Self.validate(minutes: minutes, at: now)
        state.plan = SleepTimerPlan(schedule: .countdown(deadline: now.addingTimeInterval(TimeInterval(minutes * 60))),
                                   action: action, startedAt: now, durationMinutes: minutes)
        state.preferredAction = action
        state.lastDurationMinutes = minutes
    }

    public mutating func stopAtEndOfSong(occurrenceID: UUID, action: SleepTimerAction = .finishPlaybackSession, at now: Date) throws {
        guard Self.isValidDate(now) else { throw SleepTimerValidationError.invalidDate }
        state.plan = SleepTimerPlan(schedule: .endOfSong(occurrenceID: occurrenceID), action: action, startedAt: now)
        state.preferredAction = action
    }

    /// Extending a song-end timer changes it to a countdown from now. An expired
    /// countdown extends from now, never from a deadline already in the past.
    public mutating func extend(minutes: Int, at now: Date) throws {
        try Self.validate(minutes: minutes, at: now)
        guard let plan = state.plan else { throw SleepTimerValidationError.notRunning }
        let base = max(now, state.deadline ?? now)
        let deadline = base.addingTimeInterval(TimeInterval(minutes * 60))
        guard deadline.timeIntervalSince(now) <= TimeInterval(Self.minuteRange.upperBound * 60), Self.isValidDate(deadline) else {
            throw SleepTimerValidationError.invalidDuration
        }
        state.plan = SleepTimerPlan(schedule: .countdown(deadline: deadline), action: plan.action,
                                   startedAt: now, durationMinutes: plan.durationMinutes ?? minutes)
    }

    public mutating func reset(at now: Date) throws {
        if let plan = state.plan, case .endOfSong(let occurrence) = plan.schedule {
            try stopAtEndOfSong(occurrenceID: occurrence, action: plan.action, at: now)
        } else {
            try start(minutes: state.plan?.durationMinutes ?? state.lastDurationMinutes, action: state.action, at: now)
        }
    }

    public mutating func setAction(_ action: SleepTimerAction) {
        state.preferredAction = action
        if let plan = state.plan {
            state.plan = SleepTimerPlan(schedule: plan.schedule, action: action, startedAt: plan.startedAt,
                                       durationMinutes: plan.durationMinutes)
        }
    }

    public mutating func cancel() { state.plan = nil }

    /// This is an explicit listener request, not a network return, interruption ending,
    /// foreground event or preference change. It does not cancel a future active timer.
    public mutating func acknowledgeManualPlayback() { state.completion = nil }

    /// An explicit Finish action needs the same durable barrier as a fired timer.
    /// It does not overwrite the listener's preferred action for their next timer.
    public mutating func recordCompletion(action: SleepTimerAction, at now: Date) {
        state.plan = nil
        state.completion = SleepTimerCompletion(revision: UUID(), action: action,
                                               firedAt: Self.isValidDate(now) ? now : Date(timeIntervalSince1970: 0))
    }

    /// Call before cold-launch resume as well as at the scheduled wake. A persisted
    /// past deadline is consumed immediately regardless of the chosen playback action.
    public mutating func evaluate(at now: Date, revision: UUID? = nil) -> Effect {
        guard Self.isValidDate(now), let plan = state.plan,
              revision == nil || revision == plan.revision,
              case .countdown(let deadline) = plan.schedule, now >= deadline else { return .none }
        return consume(plan, at: now)
    }

    /// The caller also verifies the actual AVPlayerItem identity. Repeat-one can reuse
    /// a queue occurrence UUID for a new AV item, which is not the old item's end event.
    public mutating func songEnded(occurrenceID: UUID, revision: UUID, at now: Date) -> Effect {
        guard Self.isValidDate(now), let plan = state.plan, revision == plan.revision,
              case .endOfSong(let target) = plan.schedule, target == occurrenceID else { return .none }
        return consume(plan, at: now)
    }

    /// A listener selecting a different song revokes an old end-of-song request.
    /// Ordinary countdown deadlines remain in force across song and queue changes.
    @discardableResult
    public mutating func selectionChanged(to occurrenceID: UUID?) -> Bool {
        guard let plan = state.plan, case .endOfSong(let target) = plan.schedule, target != occurrenceID else { return false }
        cancel()
        return true
    }

    private mutating func consume(_ plan: SleepTimerPlan, at now: Date) -> Effect {
        state.plan = nil
        state.completion = SleepTimerCompletion(revision: plan.revision, action: plan.action, firedAt: now)
        return .fire(plan.action)
    }

    static func isValidDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }

    private static func validate(minutes: Int, at now: Date) throws {
        guard minuteRange.contains(minutes) else { throw SleepTimerValidationError.invalidDuration }
        guard isValidDate(now), isValidDate(now.addingTimeInterval(TimeInterval(minutes * 60))) else {
            throw SleepTimerValidationError.invalidDate
        }
    }
}

public enum SleepTimerStore {
    public static let key = "koda.sleepTimer.v1"

    public static func load(defaults: UserDefaults = .standard, at now: Date = Date()) -> SleepTimerState {
        guard let value = defaults.object(forKey: key) else { return SleepTimerState() }
        guard let data = value as? Data else { return invalidState(at: now) }
        return decode(data, at: now)
    }

    public static func decode(_ data: Data?, at now: Date) -> SleepTimerState {
        guard let data else { return SleepTimerState() }
        guard let state = try? JSONDecoder().decode(SleepTimerState.self, from: data), state.isValid else {
            return invalidState(at: now)
        }
        return state
    }

    public static func encode(_ state: SleepTimerState) -> Data? {
        guard state.isValid else { return nil }
        return try? JSONEncoder().encode(state)
    }

    @discardableResult
    public static func save(_ state: SleepTimerState, defaults: UserDefaults = .standard) -> Bool {
        guard let data = encode(state) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    static func invalidState(at now: Date) -> SleepTimerState {
        SleepTimerState(completion: SleepTimerCompletion(revision: UUID(), action: .finishPlaybackSession,
                                                        firedAt: SleepTimerPolicy.isValidDate(now) ? now : Date(timeIntervalSince1970: 0)))
    }
}
