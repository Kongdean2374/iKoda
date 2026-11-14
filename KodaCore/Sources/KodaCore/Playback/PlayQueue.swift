import Foundation

/// One occurrence of a song in the queue. The same song can be queued twice,
/// so anything planned across a suspension (preloading, a retry, a skip)
/// anchors on this id, never on an index or the video id.
public struct QueueItem: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var song: Song

    public init(song: Song, id: UUID = UUID()) {
        self.id = id
        self.song = song
    }
}

public enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    public var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// The play queue: what plays now, what came before and what comes next.
///
/// `items` is always the order playback follows, so a queue screen draws it
/// as is. Shuffle reorders `items` and remembers the order it replaced; turning
/// shuffle off puts that order back with the current song still current.
public struct PlayQueue: Codable, Sendable, Equatable {
    public private(set) var items: [QueueItem] = []
    public private(set) var currentIndex: Int?
    public private(set) var isShuffled = false
    public private(set) var isSmartShuffled = false
    /// Occurrences explicitly placed by the listener are never moved by smart shuffle.
    private var protectedUpcoming: Set<UUID> = []
    public var repeatMode: RepeatMode = .off
    /// The order before shuffle, by occurrence. Empty while not shuffled.
    private var unshuffledOrder: [UUID] = []
    /// A finite collection remains available for repeat/shuffle after its songs have played.
    /// Radio additions are not retained here, so their old history can still be bounded.
    private var retainedCollectionOccurrenceIDs: Set<UUID> = []
    public static let maximumRetainedCollectionCount = 20_000

    public init() {}

    /// Old queue files have none of the smart-shuffle fields. Decode them without changing
    /// their order, and sanitize invalid indexes/duplicate occurrence IDs before array access.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([QueueItem].self, forKey: .items) ?? []
        var seen: Set<UUID> = []
        items = items.map { item in
            seen.insert(item.id).inserted ? item : QueueItem(song: item.song)
        }
        let savedIndex = try c.decodeIfPresent(Int.self, forKey: .currentIndex)
        currentIndex = items.isEmpty ? nil : min(max(savedIndex ?? 0, 0), items.count - 1)
        isShuffled = try c.decodeIfPresent(Bool.self, forKey: .isShuffled) ?? false
        isSmartShuffled = try c.decodeIfPresent(Bool.self, forKey: .isSmartShuffled) ?? false
        if isSmartShuffled { isShuffled = true }
        repeatMode = (try c.decodeIfPresent(String.self, forKey: .repeatMode)).flatMap(RepeatMode.init(rawValue:)) ?? .off
        unshuffledOrder = try c.decodeIfPresent([UUID].self, forKey: .unshuffledOrder) ?? []
        let available = Set(items.map(\.id))
        var restored: Set<UUID> = []
        unshuffledOrder = unshuffledOrder.filter { available.contains($0) && restored.insert($0).inserted }
        protectedUpcoming = (try c.decodeIfPresent(Set<UUID>.self, forKey: .protectedUpcoming) ?? []).intersection(available)
        let retained = (try c.decodeIfPresent(Set<UUID>.self, forKey: .retainedCollectionOccurrenceIDs) ?? []).intersection(available)
        retainedCollectionOccurrenceIDs = retained.count <= Self.maximumRetainedCollectionCount ? retained : []
    }

    public var current: QueueItem? { currentIndex.map { items[$0] } }
    public var isEmpty: Bool { items.isEmpty }

    /// What plays after the current song, in order.
    public var upcoming: ArraySlice<QueueItem> {
        guard let currentIndex else { return items[...] }
        return items[(currentIndex + 1)...]
    }

    /// What already played, oldest first.
    public var history: ArraySlice<QueueItem> {
        guard let currentIndex else { return [] }
        return items[..<currentIndex]
    }

    // MARK: Replacing

    /// Play `songs` starting at `startIndex`; shuffled, the start song plays first and the rest follow in random order.
    public mutating func replace(with songs: [Song], startAt startIndex: Int = 0, shuffled: Bool = false) {
        var rng = SystemRandomNumberGenerator()
        replace(with: songs, startAt: startIndex, shuffled: shuffled, using: &rng)
    }

    public mutating func replace<R: RandomNumberGenerator>(with songs: [Song], startAt startIndex: Int, shuffled: Bool, using rng: inout R) {
        let fresh = songs.map { QueueItem(song: $0) }
        guard !fresh.isEmpty else {
            self = PlayQueue(repeatMode: repeatMode)
            return
        }
        let start = min(max(startIndex, 0), fresh.count - 1)
        items = fresh
        currentIndex = start
        isShuffled = false
        isSmartShuffled = false
        protectedUpcoming = []
        unshuffledOrder = []
        retainedCollectionOccurrenceIDs = []
        if shuffled { setShuffle(true, using: &rng) }
    }

    /// Mark a complete, explicitly selected collection before playback trims its history.
    /// The pagination limit also bounds this set; future radio results never grow it.
    public mutating func retainCurrentCollection() {
        retainedCollectionOccurrenceIDs = items.count <= Self.maximumRetainedCollectionCount ? Set(items.map(\.id)) : []
    }

    /// A new shuffled collection has no played history: the tapped song starts first and
    /// every other source occurrence follows, including songs before the tapped index.
    public mutating func replaceSmart(with songs: [Song], startAt index: Int = 0,
                                      settings: SmartShuffleSettings, context: SmartShuffleContext) {
        var rng = SystemRandomNumberGenerator()
        replaceSmart(with: songs, startAt: index, settings: settings, context: context, using: &rng)
    }

    public mutating func replaceSmart<R: RandomNumberGenerator>(with songs: [Song], startAt index: Int,
                                                                settings: SmartShuffleSettings,
                                                                context: SmartShuffleContext, using rng: inout R) {
        replace(with: songs, startAt: index)
        guard let currentIndex else { return }
        unshuffledOrder = items.map(\.id)
        let first = items.remove(at: currentIndex)
        items.insert(first, at: 0)
        self.currentIndex = 0
        isShuffled = true
        setSmartShuffle(true, settings: settings, context: context, using: &rng)
    }

    private init(repeatMode: RepeatMode) {
        self.repeatMode = repeatMode
    }

    public mutating func clear() {
        self = PlayQueue(repeatMode: repeatMode)
    }

    // MARK: Adding and removing

    /// Insert right after the current song, in the order given.
    public mutating func playNext(_ songs: [Song]) {
        let added = songs.map { QueueItem(song: $0) }
        guard !added.isEmpty else { return }
        guard let currentIndex else {
            append(songs)
            return
        }
        items.insert(contentsOf: added, at: currentIndex + 1)
        protectedUpcoming.formUnion(added.map(\.id))
        if isShuffled, let anchor = unshuffledOrder.firstIndex(of: items[currentIndex].id) {
            unshuffledOrder.insert(contentsOf: added.map(\.id), at: anchor + 1)
        }
    }

    /// Add to the end of the queue.
    public mutating func append(_ songs: [Song], protectingOrder: Bool = true) {
        let added = songs.map { QueueItem(song: $0) }
        items += added
        if protectingOrder { protectedUpcoming.formUnion(added.map(\.id)) }
        if isShuffled { unshuffledOrder += added.map(\.id) }
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    /// Remove an occurrence. The current song cannot be removed this way; skip it instead.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), index != currentIndex else { return false }
        items.remove(at: index)
        unshuffledOrder.removeAll { $0 == id }
        protectedUpcoming.remove(id)
        retainedCollectionOccurrenceIDs.remove(id)
        if let currentIndex, index < currentIndex { self.currentIndex = currentIndex - 1 }
        return true
    }

    /// Drop everything after the current song.
    public mutating func clearUpcoming() {
        guard let currentIndex else {
            clear()
            return
        }
        let dropped = Set(items[(currentIndex + 1)...].map(\.id))
        items.removeSubrange((currentIndex + 1)...)
        unshuffledOrder.removeAll { dropped.contains($0) }
        protectedUpcoming.subtract(dropped)
        retainedCollectionOccurrenceIDs.subtract(dropped)
    }

    /// Undo Clear by putting those songs before whatever was queued afterward. Restored
    /// songs are new, manually protected occurrences; equal song IDs are never deduplicated.
    /// Current/history and every occurrence added since Clear remain intact.
    public mutating func restoreClearedUpcoming(_ songs: [Song]) {
        playNext(songs)
    }

    /// Reorder within the upcoming songs; offsets count from the first upcoming song, as a list of them does.
    public mutating func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        let base = (currentIndex ?? -1) + 1
        var upcoming = Array(items[base...])
        let valid = source.filter { upcoming.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { upcoming[$0] }
        let insertAt = min(max(destination, 0), upcoming.count) - valid.filter { $0 < destination }.count
        for index in valid.reversed() { upcoming.remove(at: index) }
        upcoming.insert(contentsOf: moving, at: insertAt)
        items.replaceSubrange(base..., with: upcoming)
        // A drag expresses the listener's order for the whole visible list, not just one row.
        protectedUpcoming.formUnion(upcoming.map(\.id))
    }

    /// Bound old radio/history additions while retaining an explicitly selected finite
    /// collection. Removing played collection occurrences would shrink repeat-all and
    /// future shuffle pools, including after restoring queue.json.
    public mutating func trimHistory(keeping: Int) {
        let keeping = max(0, keeping)
        guard let currentIndex, currentIndex > keeping else { return }
        let dropCount = currentIndex - keeping
        let retained = retainedCollectionOccurrenceIDs
        let dropped = Set(items[..<dropCount].lazy.map(\.id).filter { !retained.contains($0) })
        guard !dropped.isEmpty else { return }
        items.removeAll { dropped.contains($0.id) }
        self.currentIndex = currentIndex - dropped.count
        if isShuffled { unshuffledOrder.removeAll { dropped.contains($0) } }
        protectedUpcoming.subtract(dropped)
    }

    // MARK: Moving through the queue

    /// Make `id` the current song.
    @discardableResult
    public mutating func jump(to id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        currentIndex = index
        return true
    }

    /// The index that would play next. A song ending on its own repeats under
    /// repeat one; a skip always moves on.
    public func nextIndex(automatic: Bool) -> Int? {
        guard let currentIndex else { return items.isEmpty ? nil : 0 }
        if automatic, repeatMode == .one { return currentIndex }
        if currentIndex + 1 < items.count { return currentIndex + 1 }
        return repeatMode == .off ? nil : 0
    }

    public func peekNext(automatic: Bool) -> QueueItem? {
        nextIndex(automatic: automatic).map { items[$0] }
    }

    /// Move to the next song; nil at the end of a queue that does not repeat, and the queue is left unchanged.
    @discardableResult
    public mutating func advance(automatic: Bool) -> QueueItem? {
        guard let next = nextIndex(automatic: automatic) else { return nil }
        currentIndex = next
        return items[next]
    }

    /// Move to the previous song; at the start it wraps under repeat all and otherwise stays.
    @discardableResult
    public mutating func retreat() -> QueueItem? {
        guard let currentIndex else { return nil }
        if currentIndex > 0 {
            self.currentIndex = currentIndex - 1
        } else if repeatMode != .off, items.count > 1 {
            self.currentIndex = items.count - 1
        }
        return current
    }

    // MARK: Smart shuffle

    public mutating func setSmartShuffle(_ on: Bool, settings: SmartShuffleSettings, context: SmartShuffleContext) {
        var rng = SystemRandomNumberGenerator()
        setSmartShuffle(on, settings: settings, context: context, using: &rng)
    }

    /// Reorders only unprotected upcoming slots. Current/history, occurrence IDs and manually
    /// placed rows remain fixed, so preloading, previous, repeat and AutoMix keep their anchors.
    public mutating func setSmartShuffle<R: RandomNumberGenerator>(_ on: Bool, settings: SmartShuffleSettings,
                                                                  context: SmartShuffleContext, using rng: inout R) {
        guard on != isSmartShuffled else { return }
        let base = (currentIndex ?? -1) + 1
        let slots = (base..<items.count).filter { !protectedUpcoming.contains(items[$0].id) }
        if on {
            if !isShuffled { unshuffledOrder = items.map(\.id) }
            let candidates = slots.map { items[$0] }
            let ranked = SmartShuffle.order(candidates, after: current?.song, settings: settings, context: context, using: &rng)
            for (slot, item) in zip(slots, ranked) { items[slot] = item }
            isShuffled = true
            isSmartShuffled = true
        } else {
            if protectedUpcoming.isEmpty {
                // With no manual edits, disabling shuffle restores the collection's original
                // order exactly, as ordinary shuffle does, keeping the same occurrence current.
                let currentID = current?.id
                let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                let known = Set(unshuffledOrder)
                items = unshuffledOrder.compactMap { byID[$0] } + items.filter { !known.contains($0.id) }
                currentIndex = currentID.flatMap { id in items.firstIndex { $0.id == id } }
                isShuffled = false
                isSmartShuffled = false
                unshuffledOrder = []
                return
            }
            let candidates = Dictionary(uniqueKeysWithValues: slots.map { (items[$0].id, items[$0]) })
            var restored = unshuffledOrder.compactMap { candidates[$0] }
            let known = Set(restored.map(\.id))
            restored += slots.map { items[$0] }.filter { !known.contains($0.id) }
            for (slot, item) in zip(slots, restored) { items[slot] = item }
            isShuffled = false
            isSmartShuffled = false
            unshuffledOrder = []
        }
    }

    // MARK: Shuffle

    public mutating func setShuffle(_ on: Bool) {
        var rng = SystemRandomNumberGenerator()
        setShuffle(on, using: &rng)
    }

    /// On: the current song stays current and every other song follows in random order.
    /// Off: the order from before shuffle comes back, songs added meanwhile kept where they were added.
    public mutating func setShuffle<R: RandomNumberGenerator>(_ on: Bool, using rng: inout R) {
        if isSmartShuffled {
            if !on {
                setSmartShuffle(false, settings: SmartShuffleSettings(), context: SmartShuffleContext(), using: &rng)
                return
            }
            // An explicit ordinary-shuffle request retains the original undo order.
            let original = unshuffledOrder
            isSmartShuffled = false
            isShuffled = false
            setShuffle(true, using: &rng)
            unshuffledOrder = original
            return
        }
        guard on != isShuffled else { return }
        if on {
            unshuffledOrder = items.map(\.id)
            guard let currentIndex else {
                items.shuffle(using: &rng)
                isShuffled = true
                return
            }
            let current = items[currentIndex]
            var rest = items
            rest.remove(at: currentIndex)
            rest.shuffle(using: &rng)
            items = [current] + rest
            self.currentIndex = 0
        } else {
            let currentId = current?.id
            let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            var restored = unshuffledOrder.compactMap { byId[$0] }
            // Anything the shuffled order gained that the old order never saw goes at the end.
            let known = Set(unshuffledOrder)
            restored += items.filter { !known.contains($0.id) }
            items = restored
            currentIndex = currentId.flatMap { id in items.firstIndex { $0.id == id } } ?? (items.isEmpty ? nil : 0)
            unshuffledOrder = []
        }
        isShuffled = on
    }
}
