import Foundation

/// Display ordering only. Cloud IDs remain authoritative; these preferences never
/// change the remote playlist or create a local copy of its contents.
public struct HomePlaylistPreferences: Codable, Equatable, Sendable {
    public private(set) var pinnedIDs: [String]
    public private(set) var order: [String]

    public init(pinnedIDs: [String] = [], order: [String] = []) {
        self.pinnedIDs = Self.unique(pinnedIDs)
        self.order = Self.unique(order)
    }

    public func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    public mutating func togglePin(_ id: String) {
        guard !id.isEmpty else { return }
        if pinnedIDs.contains(id) { pinnedIDs.removeAll { $0 == id } }
        else { pinnedIDs.append(id) }
    }

    public func sorted(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        let pinPositions = Dictionary(uniqueKeysWithValues: pinnedIDs.enumerated().map { ($1, $0) })
        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var seen = Set<String>()
        let unique = playlists.filter { seen.insert($0.id).inserted }
        return unique.enumerated().sorted { lhs, rhs in
            let a = pinPositions[lhs.element.id], b = pinPositions[rhs.element.id]
            if (a != nil) != (b != nil) { return a != nil }
            if let a, let b { return a < b }
            return (positions[lhs.element.id] ?? (order.count + lhs.offset)) < (positions[rhs.element.id] ?? (order.count + rhs.offset))
        }.map(\.element)
    }

    /// Reorder within the pinned or unpinned group so moving an item cannot
    /// silently unpin it. Missing remote IDs are retained in the preferences.
    public mutating func move(_ id: String, by offset: Int, in playlists: [PlaylistSummary]) {
        let pinned = isPinned(id)
        var group = sorted(playlists).filter { isPinned($0.id) == pinned }.map(\.id)
        guard let index = group.firstIndex(of: id) else { return }
        let target = index + offset
        guard group.indices.contains(target) else { return }
        group.swapAt(index, target)
        if pinned { pinnedIDs = group + pinnedIDs.filter { !group.contains($0) } }
        else { order = group + order.filter { !group.contains($0) } }
    }

    public static func load(profileID: UUID, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key(profileID)), let value = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        return Self(pinnedIDs: value.pinnedIDs, order: value.order)
    }

    public func save(profileID: UUID, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(profileID))
    }

    private static func key(_ id: UUID) -> String { "koda.home.cloudPlaylistDisplay.v1.\(id.uuidString)" }
    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
