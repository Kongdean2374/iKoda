import Foundation

/// Serializes the final version check and atomic replacement of queue.json.
/// Reserve before encoding a snapshot. Encoding can happen on any thread; an old
/// snapshot can never commit after a newer reservation, even if that encoding fails.
final class QueueSnapshotWriter: @unchecked Sendable {
    struct Version: Equatable, Sendable {
        fileprivate let owner: UUID
        fileprivate let sequence: UInt64
    }

    private let lock = NSLock()
    private let owner = UUID()
    private var newest: UInt64 = 0
    private var committed: UInt64 = 0
    private let writeFile: @Sendable (Data, URL) throws -> Void

    /// The injectable operation lets tests hold or fail a write without timing guesses.
    /// Production always uses Foundation's atomic file replacement.
    init(writeFile: @escaping @Sendable (Data, URL) throws -> Void = { data, file in
        try data.write(to: file, options: .atomic)
    }) {
        self.writeFile = writeFile
    }

    func reserve() -> Version {
        lock.withLock {
            precondition(newest < UInt64.max, "Queue snapshot versions exhausted")
            newest += 1
            return Version(owner: owner, sequence: newest)
        }
    }

    /// An optional early check to avoid expensive encoding. It is never a write permit:
    /// write(_:version:to:) repeats the check while holding the lock through replacement.
    func isCurrent(_ version: Version) -> Bool {
        lock.withLock { accepts(version) }
    }

    /// Synchronous for the app-background flush. A concurrent older write either
    /// finishes before reserve() returns, or is rejected here; it cannot overwrite this
    /// commit later. Only the small, already encoded file write holds the lock.
    @discardableResult
    func write(_ data: Data, version: Version, to file: URL) throws -> Bool {
        try lock.withLock {
            guard accepts(version) else { return false }
            try writeFile(data, file)
            committed = version.sequence
            return true
        }
    }

    /// Caller holds lock. Failed writes leave the newest reservation intact, so no
    /// older delayed snapshot becomes eligible merely because the newest write failed.
    private func accepts(_ version: Version) -> Bool {
        version.owner == owner && version.sequence == newest && version.sequence > committed
    }
}
