public struct ImmersiveInteractionLock: Equatable, Sendable {
    public private(set) var isLocked = false
    public private(set) var revealUntil: ContinuousClock.Instant?

    public init() {}

    public mutating func lock(at now: ContinuousClock.Instant) {
        isLocked = true
        revealUntil = now.advanced(by: .seconds(5))
    }

    public mutating func showIfHidden(at now: ContinuousClock.Instant) {
        guard isLocked, revealUntil == nil else { return }
        revealUntil = now.advanced(by: .seconds(5))
    }

    public mutating func hideIfExpired(at now: ContinuousClock.Instant) {
        if let revealUntil, now >= revealUntil { self.revealUntil = nil }
    }

    @discardableResult
    public mutating func unlock(at now: ContinuousClock.Instant) -> Bool {
        hideIfExpired(at: now)
        guard isLocked, revealUntil != nil else { return false }
        self = Self()
        return true
    }
}
