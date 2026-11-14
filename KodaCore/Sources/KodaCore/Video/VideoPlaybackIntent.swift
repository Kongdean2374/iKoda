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
    private var generation: UInt64 = 0
    private var autoplayGeneration: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func begin(videoID: String) -> Ticket {
        generation &+= 1
        autoplayGeneration &+= 1
        currentID = videoID
        wantsToPlay = true
        return Ticket(videoID: videoID, generation: generation)
    }

    /// Keeps the current selection so the UI can explicitly resume it, but no pending work
    /// may start it, report an old failure, or claim that a newer load is finished.
    public mutating func pause() {
        generation &+= 1
        autoplayGeneration &+= 1
        wantsToPlay = false
    }

    public mutating func stop() {
        pause()
        currentID = nil
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
