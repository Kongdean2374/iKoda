import Foundation

/// Numbers each save, so a background write that has been overtaken by a newer
/// save is dropped instead of overwriting it.
final class SaveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var newest = 0

    func next() -> Int {
        lock.withLock {
            newest += 1
            return newest
        }
    }

    func isNewest(_ version: Int) -> Bool {
        lock.withLock { version == newest }
    }

    var current: Int { lock.withLock { newest } }

    /// Only the tiny atomic rename belongs here. Encoding and writing a temporary file
    /// happen before this lock, so the main actor never waits for a large JSON write.
    @discardableResult
    func commit(_ version: Int, advancing: Bool = false, _ publish: () throws -> Void) rethrows -> Bool {
        try lock.withLock {
            guard version == newest else { return false }
            try publish()
            if advancing { newest += 1 }
            return true
        }
    }
}
