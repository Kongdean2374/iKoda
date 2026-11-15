import Foundation

/// Browsing may reuse complete snapshots; mutation verification never uses this
/// policy and always reads from the service. An explicit refresh bypasses age and
/// failure cooldowns, but joins a request already reading the same resource.
public struct CloudPlaylistCachePolicy: Sendable {
    public enum Decision: Equatable, Sendable { case useCache, join, fetch }
    public let freshness: TimeInterval
    public let failureCooldown: TimeInterval

    public static let catalog = CloudPlaylistCachePolicy(freshness: 15 * 60)
    public static let snapshot = CloudPlaylistCachePolicy(freshness: 15 * 60)

    public init(freshness: TimeInterval, failureCooldown: TimeInterval = 30) {
        self.freshness = max(0, freshness)
        self.failureCooldown = max(0, failureCooldown)
    }

    public func decision(fetchedAt: Date?, failedAt: Date?, force: Bool,
                         isInFlight: Bool, now: Date = Date()) -> Decision {
        if isInFlight { return .join }
        if force { return .fetch }
        if let fetchedAt, (0..<freshness).contains(now.timeIntervalSince(fetchedAt)) { return .useCache }
        if let failedAt, (0..<failureCooldown).contains(now.timeIntervalSince(failedAt)) { return .useCache }
        return .fetch
    }

    /// Bound disk and memory use without truncating any playlist. Newest entries
    /// come first, and a large newest playlist remains a complete single snapshot.
    public static func retainedSnapshots(_ newestFirst: [CloudPlaylistSnapshot],
                                         limit: Int = 12, rowBudget: Int = 20_000) -> [CloudPlaylistSnapshot] {
        guard limit > 0, rowBudget > 0 else { return [] }
        var retained: [CloudPlaylistSnapshot] = [], seen = Set<String>(), rows = 0
        for snapshot in newestFirst where seen.insert(snapshot.id).inserted {
            let count = snapshot.rows.count + snapshot.unavailableCount
            if retained.count >= limit { break }
            if !retained.isEmpty, rows + count > rowBudget { continue }
            retained.append(snapshot)
            rows += count
        }
        return retained
    }
}
