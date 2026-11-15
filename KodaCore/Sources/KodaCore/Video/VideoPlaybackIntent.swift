import Foundation

/// The listener's current video intent, independent of AVPlayer readiness. Every explicit
/// replacement, pause or stop invalidates work from earlier requests, including a request
/// for the same video ID. Canceling autoplay alone does not cancel ordinary playback.
public struct VideoPlaybackIntent: Sendable, Equatable {
    public struct Ticket: Sendable, Equatable {
        public let videoID: String
        fileprivate let generation: UInt64
    }

    public struct AutoplayTicket: Sendable, Equatable {
        fileprivate let playback: Ticket
        fileprivate let generation: UInt64
    }

    public private(set) var currentID: String?
    public private(set) var wantsToPlay = false
    public private(set) var isBackgrounded = false
    private var generation: UInt64 = 0
    private var autoplayGeneration: UInt64 = 0
    private var lastSelectionID: String?
    private var externalControlsAuthorized = false
    private var backgroundPictureInPicture: BackgroundContinuation?

    private struct BackgroundContinuation: Sendable, Equatable {
        let ticket: Ticket
        let beganAt: TimeInterval
    }

    /// An observed AVPlayer rate is state, not a new user request. Only an already
    /// authorized external presentation may resume through its native controls.
    public enum ObservedPlayback: Sendable, Equatable {
        case continuePlayback, resumeExternalPlayback, pause
    }

    public init() {}

    @discardableResult
    public mutating func begin(videoID: String) -> Ticket {
        generation &+= 1
        autoplayGeneration &+= 1
        currentID = videoID
        lastSelectionID = videoID
        wantsToPlay = true
        externalControlsAuthorized = false
        backgroundPictureInPicture = nil
        return Ticket(videoID: videoID, generation: generation)
    }

    /// Keeps the current selection so the UI can explicitly resume it, but no pending work
    /// may start it, report an old failure, or claim that a newer load is finished.
    public mutating func pause(preservingExternalControls: Bool = false) {
        generation &+= 1
        autoplayGeneration &+= 1
        wantsToPlay = false
        if !preservingExternalControls { externalControlsAuthorized = false }
        backgroundPictureInPicture = nil
    }

    public mutating func stop() {
        pause()
        currentID = nil
    }

    /// Reappearing views only refresh an existing selection. In particular, an item
    /// missing because its load was cancelled is not permission to start it again.
    public func canStartFromWatchPage(videoID: String) -> Bool {
        !isBackgrounded && lastSelectionID != videoID
    }

    public func canStartPlayback(hasExternalPresentation: Bool) -> Bool {
        !isBackgrounded || (hasExternalPresentation && externalControlsAuthorized)
    }

    /// Called from an actual PiP/external presentation event while playback is already
    /// authorized, or from the listener's explicit PiP button (which may float a paused item).
    public mutating func authorizeExternalControls(explicitPresentation: Bool = false) {
        guard currentID != nil, wantsToPlay || explicitPresentation else { return }
        externalControlsAuthorized = true
    }

    public var hasExternalControlAuthorization: Bool { externalControlsAuthorized }

    public mutating func revokeExternalControls() {
        externalControlsAuthorized = false
        backgroundPictureInPicture = nil
    }

    public mutating func cancelPictureInPictureContinuation() { backgroundPictureInPicture = nil }

    /// AVPlayer can publish rate zero before its didPlayToEnd notification. Consult its
    /// real clock so natural completion still reaches the existing Up Next policy.
    @discardableResult
    public mutating func observedNativePause(position: TimeInterval, duration: TimeInterval,
                                             isLoading: Bool, hasEnded: Bool,
                                             hasExternalPresentation: Bool,
                                             wasPlaying: Bool, receivedRateStop: Bool) -> Bool {
        guard hasExternalPresentation, wantsToPlay, !isLoading, !hasEnded,
              wasPlaying || receivedRateStop else { return false }
        let atEnd = position.isFinite && duration.isFinite && duration > 0 && position >= max(0, duration - 0.1)
        guard !atEnd else { return false }
        authorizeExternalControls()
        pause(preservingExternalControls: true)
        return true
    }

    /// Returns whether the platform player must be paused. A very short continuation
    /// handles automatic PiP's willStart arriving after the background notification.
    /// It is bound to this selection and invalidated by every later user/media request.
    @discardableResult
    public mutating func enterBackground(hasExternalPresentation: Bool,
                                         mayContinueIntoPictureInPicture: Bool,
                                         at now: TimeInterval) -> Bool {
        guard !isBackgrounded else { return false }
        isBackgrounded = true
        if hasExternalPresentation && externalControlsAuthorized { return false }
        let wasPlaying = wantsToPlay && mayContinueIntoPictureInPicture
        pause()
        if wasPlaying, let currentID, now.isFinite {
            backgroundPictureInPicture = BackgroundContinuation(
                ticket: Ticket(videoID: currentID, generation: generation), beganAt: now)
        }
        return currentID != nil
    }

    /// Foreground entry changes visibility only. It never revives playback or an old
    /// automatic PiP handoff, even if AVFoundation subsequently publishes a positive rate.
    public mutating func enterForeground() {
        isBackgrounded = false
        backgroundPictureInPicture = nil
    }

    public func hasPictureInPictureContinuation(at now: TimeInterval) -> Bool {
        guard isBackgrounded, let pending = backgroundPictureInPicture,
              pending.ticket.videoID == currentID, pending.ticket.generation == generation,
              now.isFinite, now >= pending.beganAt else { return false }
        return now - pending.beganAt <= 2
    }

    /// Only a real PiP lifecycle callback may consume this permission. A rate change,
    /// page appearance or return to the foreground cannot do so.
    @discardableResult
    public mutating func continueIntoPictureInPicture(at now: TimeInterval) -> Bool {
        guard hasPictureInPictureContinuation(at: now) else { return false }
        backgroundPictureInPicture = nil
        generation &+= 1
        autoplayGeneration &+= 1
        wantsToPlay = true
        externalControlsAuthorized = true
        return true
    }

    public mutating func observedPlaying(hasExternalPresentation: Bool,
                                         isStartingPictureInPicture: Bool = false) -> ObservedPlayback {
        if wantsToPlay {
            let continuesHandoff = isStartingPictureInPicture && externalControlsAuthorized
            if !isBackgrounded || hasExternalPresentation || continuesHandoff { return .continuePlayback }
            pause()
            return .pause
        }
        guard hasExternalPresentation, externalControlsAuthorized, currentID != nil else { return .pause }
        generation &+= 1
        autoplayGeneration &+= 1
        wantsToPlay = true
        backgroundPictureInPicture = nil
        return .resumeExternalPlayback
    }

    public func accepts(_ ticket: Ticket) -> Bool {
        wantsToPlay && currentID == ticket.videoID && generation == ticket.generation
    }

    public mutating func beginAutoplay() -> AutoplayTicket? {
        guard wantsToPlay, let currentID else { return nil }
        autoplayGeneration &+= 1
        return AutoplayTicket(playback: Ticket(videoID: currentID, generation: generation), generation: autoplayGeneration)
    }

    public mutating func cancelAutoplay() { autoplayGeneration &+= 1 }

    public func accepts(_ ticket: AutoplayTicket) -> Bool {
        accepts(ticket.playback) && autoplayGeneration == ticket.generation
    }
}
