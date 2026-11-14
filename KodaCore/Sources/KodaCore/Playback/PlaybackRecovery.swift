import Foundation

/// Privacy-safe failure categories. No underlying error text or URL is retained.
public enum PlaybackFailureReason: String, Codable, Sendable, Equatable {
    case network, timeout, serviceUnavailable, rateLimited, authentication, forbidden, unavailable, cancelled, unknown

    public var message: String {
        switch self {
        case .network: NSLocalizedString("The network connection was interrupted.", bundle: KodaLocalization.bundle, comment: "")
        case .timeout: NSLocalizedString("The audio stream timed out.", bundle: KodaLocalization.bundle, comment: "")
        case .serviceUnavailable: NSLocalizedString("The audio service is temporarily unavailable.", bundle: KodaLocalization.bundle, comment: "")
        case .rateLimited: NSLocalizedString("The service is limiting requests. Try again later.", bundle: KodaLocalization.bundle, comment: "")
        case .authentication: NSLocalizedString("Sign in again to continue playback.", bundle: KodaLocalization.bundle, comment: "")
        case .forbidden: NSLocalizedString("The service refused access. Automatic retries have stopped.", bundle: KodaLocalization.bundle, comment: "")
        case .unavailable: NSLocalizedString("This audio is unavailable or cannot be decoded.", bundle: KodaLocalization.bundle, comment: "")
        case .cancelled: NSLocalizedString("Playback was cancelled.", bundle: KodaLocalization.bundle, comment: "")
        case .unknown: NSLocalizedString("Playback failed. Automatic recovery is unavailable for this error.", bundle: KodaLocalization.bundle, comment: "")
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .serviceUnavailable: true
        default: false
        }
    }

    public static func classify(_ error: Error?) -> Self {
        guard let error else { return .timeout } // A measured player stall, without an NSError.
        if let music = error as? MusicError {
            switch music {
            case .network: return .network
            case .signedOut: return .authentication
            case .botCheck: return .forbidden
            case .unplayable: return .unavailable
            case .rateLimited: return .rateLimited
            case .badResponse(let status): return classifyHTTPStatus(status)
            }
        }
        return classifyNSError(error as NSError, depth: 0)
    }

    private static func classifyNSError(_ error: NSError, depth: Int) -> Self {
        guard depth < 5 else { return .unknown }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return .cancelled }
        if error.domain == AudioStreamResponseError.errorDomain { return classifyHTTPStatus(error.code) }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           let verdict = permanentHTTPVerdict(underlying, depth: depth + 1) { return verdict }
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication: return .authentication
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                 NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed: return .network
            default:
                if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                    return classifyNSError(underlying, depth: depth + 1)
                }
                return .unavailable
            }
        }
        // These are AVFoundation's public OSStatus values; never retry an unrecognized
        // decoder/authorization failure merely because its localized text says "network".
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            let reason = classifyNSError(underlying, depth: depth + 1)
            if reason != .unknown { return reason }
        }
        if error.domain == "AVFoundationErrorDomain", error.code == -11819 { return .serviceUnavailable }
        return .unknown
    }

    /// A generic outer timeout cannot turn an actual access/not-found/rate-limit verdict
    /// into a retry. Explicit cancellation still takes priority over any inner response.
    private static func permanentHTTPVerdict(_ error: NSError, depth: Int) -> Self? {
        guard depth < 5 else { return nil }
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return .cancelled }
        if error.domain == AudioStreamResponseError.errorDomain, [401, 403, 404, 429].contains(error.code) {
            return classifyHTTPStatus(error.code)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return permanentHTTPVerdict(underlying, depth: depth + 1)
        }
        return nil
    }

    private static func classifyHTTPStatus(_ status: Int) -> Self {
        switch status {
        case 401: .authentication
        case 403: .forbidden
        case 408: .timeout
        case 429: .rateLimited
        case 500...599: .serviceUnavailable
        default: .unavailable
        }
    }
}

/// A delayed retry belongs to exactly one queue occurrence and one generation.
public struct RecoveryTicket: Equatable, Sendable {
    public let occurrenceID: UUID
    public let generation: UInt64
    public let attempt: Int
    public let delay: TimeInterval
    public let position: TimeInterval
}

/// Pure retry policy: no timers, player creation, network calls, or queue advancement.
/// A recovered stream retains its finite attempt budget until a different occurrence
/// starts (or the user explicitly starts a new session), preventing endless flapping.
public struct PlaybackRecovery: Sendable {
    public enum Decision: Equatable, Sendable {
        case retry(RecoveryTicket), waitForNetwork, stop(PlaybackFailureReason), ignore
    }
    /// Reloads actually begun, not timers scheduled or cancelled before a network return.
    public private(set) var attempts = 0
    public private(set) var pending: RecoveryTicket?
    public private(set) var waitingForNetwork = false
    public private(set) var lastFailure: PlaybackFailureReason?
    private var occurrenceID: UUID?
    private var generation: UInt64 = 0
    private let maximumAttempts: Int
    private let baseDelay: TimeInterval
    private let maximumDelay: TimeInterval

    public init(maximumAttempts: Int = 3, baseDelay: TimeInterval = 1, maximumDelay: TimeInterval = 8) {
        self.maximumAttempts = min(5, max(0, maximumAttempts))
        self.baseDelay = baseDelay.isFinite ? min(30, max(0.1, baseDelay)) : 1
        self.maximumDelay = maximumDelay.isFinite ? min(60, max(0.1, maximumDelay)) : 8
    }

    public mutating func begin(for id: UUID) {
        guard occurrenceID != id else { return }
        cancel()
        occurrenceID = id
        attempts = 0
        lastFailure = nil
    }

    /// Only a deliberate new play/retry request may reset an exhausted budget.
    public mutating func restart(for id: UUID) {
        occurrenceID = nil
        begin(for: id)
    }

    public mutating func request(for id: UUID, at position: TimeInterval, error: Error?,
                                 wantsToPlay: Bool, network: NetworkSnapshot) -> Decision {
        guard wantsToPlay else { return .ignore }
        begin(for: id)
        let reason = PlaybackFailureReason.classify(error)
        guard reason != .cancelled else { return .ignore }
        // A permanent access verdict wins even if an earlier transient failure was
        // already waiting to retry. Its old ticket can no longer start a reload.
        guard reason.isRetryable else {
            lastFailure = reason
            cancel()
            return .stop(reason)
        }
        guard pending == nil, !waitingForNetwork else { return .ignore }
        lastFailure = reason
        guard attempts < maximumAttempts else { return .stop(reason) }
        if network.status != .online {
            waitingForNetwork = true
            return .waitForNetwork
        }
        return schedule(for: id, position: position)
    }

    public mutating func networkRestored(for id: UUID, at position: TimeInterval, wantsToPlay: Bool) -> Decision {
        guard wantsToPlay, occurrenceID == id, waitingForNetwork, pending == nil else { return .ignore }
        waitingForNetwork = false
        guard attempts < maximumAttempts else { return .stop(lastFailure ?? .network) }
        return schedule(for: id, position: position)
    }

    /// Only after AudioStore positively identified and discarded this exact invalid local
    /// file, its legitimate remote source may replace it using the same finite retry budget.
    public mutating func requestLocalReplacement(for id: UUID, at position: TimeInterval,
                                                wantsToPlay: Bool, network: NetworkSnapshot) -> Decision {
        guard wantsToPlay else { return .ignore }
        begin(for: id)
        guard pending == nil, !waitingForNetwork else { return .ignore }
        lastFailure = .unavailable
        guard network.status == .online, attempts < maximumAttempts else { return .stop(.unavailable) }
        return schedule(for: id, position: position)
    }

    private mutating func schedule(for id: UUID, position: TimeInterval) -> Decision {
        let nextAttempt = attempts + 1
        generation &+= 1
        let ticket = RecoveryTicket(occurrenceID: id, generation: generation, attempt: nextAttempt,
                                    delay: min(maximumDelay, baseDelay * pow(2, Double(nextAttempt - 1))),
                                    position: position.isFinite ? max(0, position) : 0)
        pending = ticket
        return .retry(ticket)
    }

    public func isCurrent(_ ticket: RecoveryTicket) -> Bool {
        ticket == pending && ticket.occurrenceID == occurrenceID && ticket.generation == generation
    }

    /// Reserve no attempt when connectivity disappears during the delay. Invalidating
    /// the ticket also makes a late timer callback harmless after another restoration.
    @discardableResult
    public mutating func suspendForNetwork(_ ticket: RecoveryTicket) -> Bool {
        guard isCurrent(ticket) else { return false }
        pending = nil
        waitingForNetwork = true
        generation &+= 1
        return true
    }

    /// Commit immediately before the actual reload, after every suspension point and
    /// after the owner checks current intent, online connectivity and load generation.
    /// Scheduling, going offline and stale/cancelled callbacks spend no retry budget.
    @discardableResult
    public mutating func consume(_ ticket: RecoveryTicket) -> Bool {
        guard isCurrent(ticket), attempts < maximumAttempts, ticket.attempt == attempts + 1 else { return false }
        attempts = ticket.attempt
        pending = nil
        return true
    }

    public mutating func markRecovered() {
        pending = nil
        waitingForNetwork = false
        generation &+= 1
    }

    /// Pause, stop, seek or a queue switch invalidates every outstanding timer.
    /// Attempts intentionally survive cancellation for the same occurrence.
    public mutating func cancel() {
        pending = nil
        waitingForNetwork = false
        generation &+= 1
    }
}

/// The system may resume an interruption only when both the user's earlier intent and
/// the system's shouldResume flag allow it. A user pause during the interruption wins.
public struct PlaybackInterruptionState: Sendable, Equatable {
    public private(set) var isInterrupted = false
    private var resumeRequested = false
    public init() {}
    public mutating func began(wantsToPlay: Bool) {
        guard !isInterrupted else { return }
        isInterrupted = true
        resumeRequested = wantsToPlay
    }
    public mutating func userPaused() { resumeRequested = false }
    /// A deliberate play action may recover a missing interruption-ended notification,
    /// but only after the system actually allowed activation of the audio session.
    public mutating func explicitResume(activationSucceeded: Bool) -> Bool {
        guard activationSucceeded else { return false }
        isInterrupted = false
        resumeRequested = false
        return true
    }
    public mutating func ended(shouldResume: Bool) -> Bool {
        let resume = isInterrupted && resumeRequested && shouldResume
        isInterrupted = false
        resumeRequested = false
        return resume
    }
}
