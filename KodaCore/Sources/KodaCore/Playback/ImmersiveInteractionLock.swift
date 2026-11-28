import Foundation

public struct ImmersiveInteractionLock: Equatable, Sendable {
    public private(set) var isLocked = false
    public private(set) var revealUntil: Date?

    public init() {}

    public mutating func lock(at now: Date) {
        isLocked = true
        revealUntil = now.addingTimeInterval(5)
    }

    public mutating func showIfHidden(at now: Date) {
        guard isLocked, revealUntil == nil else { return }
        revealUntil = now.addingTimeInterval(5)
    }

    public mutating func hideIfExpired(at now: Date) {
        if let revealUntil, now >= revealUntil { self.revealUntil = nil }
    }

    @discardableResult
    public mutating func unlock(at now: Date) -> Bool {
        hideIfExpired(at: now)
        guard isLocked, revealUntil != nil else { return false }
        self = Self()
        return true
    }
}
