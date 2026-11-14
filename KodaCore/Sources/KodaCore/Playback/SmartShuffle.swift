import Foundation

/// Preferences affect only explicitly requested smart shuffles and newly shuffled queues.
/// Editing a preference never changes an already arranged queue.
public struct SmartShuffleSettings: Codable, Equatable, Sendable {
    public enum Strength: String, Codable, CaseIterable, Sendable { case low, standard, high }
    public var enabled: Bool
    public var recentWindow: Int
    public var artistLimit: Int
    public var likedWeight: Double
    public var strength: Strength

    public init(enabled: Bool = false, recentWindow: Int = 25, artistLimit: Int = 1,
                likedWeight: Double = 1.5, strength: Strength = .standard) {
        self.enabled = enabled
        self.recentWindow = recentWindow
        self.artistLimit = artistLimit
        self.likedWeight = likedWeight
        self.strength = strength
    }

    public var validated: Self {
        Self(enabled: enabled, recentWindow: min(50, max(10, recentWindow)),
             artistLimit: min(3, max(1, artistLimit)),
             likedWeight: likedWeight.isFinite ? min(3, max(1, likedWeight)) : 1.5, strength: strength)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  recentWindow: try c.decodeIfPresent(Int.self, forKey: .recentWindow) ?? 25,
                  artistLimit: try c.decodeIfPresent(Int.self, forKey: .artistLimit) ?? 1,
                  likedWeight: try c.decodeIfPresent(Double.self, forKey: .likedWeight) ?? 1.5,
                  strength: (try c.decodeIfPresent(String.self, forKey: .strength)).flatMap(Strength.init(rawValue:)) ?? .standard)
        self = validated
    }
}

/// App-owned local data, copied before ranking. IDs are never sent to a recommendation service.
public struct SmartShuffleContext: Sendable {
    /// Oldest first; repeated occurrences count separately.
    public var recentSongIDs: [String]
    public var playCounts: [String: Int]
    public var skipCounts: [String: Int]
    public var likedSongIDs: Set<String>

    public init(recentSongIDs: [String] = [], playCounts: [String: Int] = [:],
                skipCounts: [String: Int] = [:], likedSongIDs: Set<String> = []) {
        self.recentSongIDs = recentSongIDs
        self.playCounts = playCounts
        self.skipCounts = skipCounts
        self.likedSongIDs = likedSongIDs
    }
}

/// Bounded per-profile observations. Clearing history discards both plays and skips.
public struct SmartShuffleHistory: Codable, Equatable, Sendable {
    private struct Event: Codable, Equatable, Sendable {
        var songID: String
        var skipped: Bool
    }
    public static let eventLimit = 500
    private var events: [Event] = []
    public init() {}

    public mutating func recordPlay(_ song: Song) { record(song, skipped: false) }
    public mutating func recordSkip(_ song: Song) { record(song, skipped: true) }
    public mutating func clear() { events = [] }
    public var eventCount: Int { events.count }

    private mutating func record(_ song: Song, skipped: Bool) {
        events.append(Event(songID: song.id, skipped: skipped))
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }

    public func context(likedSongIDs: Set<String> = []) -> SmartShuffleContext {
        var plays: [String: Int] = [:], skips: [String: Int] = [:]
        for event in events {
            if event.skipped { skips[event.songID, default: 0] += 1 }
            else { plays[event.songID, default: 0] += 1 }
        }
        return SmartShuffleContext(recentSongIDs: Array(events.filter { !$0.skipped }.suffix(50).map(\.songID)),
                                   playCounts: plays, skipCounts: skips, likedSongIDs: likedSongIDs)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = Array((try c.decodeIfPresent([Event].self, forKey: .events) ?? []).suffix(Self.eventLimit))
    }
}

/// Weighted randomized ordering, never adding or removing an occurrence. Artist and duplicate
/// penalties are applied while selecting, so repeats in the source playlist are spread out too.
public enum SmartShuffle {
    private struct Candidate {
        var item: QueueItem
        var artist: String?
        var priority: Double
    }

    public static func artistKey(_ song: Song) -> String? {
        if let id = song.artists.first?.id, !id.isEmpty { return id }
        let byline = song.artistLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return byline.isEmpty ? nil : byline.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func order<R: RandomNumberGenerator>(_ items: [QueueItem], after previous: Song? = nil,
                                                       settings: SmartShuffleSettings, context: SmartShuffleContext,
                                                       using rng: inout R) -> [QueueItem] {
        guard items.count > 2 else { return items.shuffled(using: &rng) }
        let settings = settings.validated
        let distinctArtists = Set(items.compactMap { artistKey($0.song) })
        let hasSignals = !context.recentSongIDs.isEmpty || !context.playCounts.isEmpty || !context.skipCounts.isEmpty
            || !context.likedSongIDs.isEmpty || distinctArtists.count > 1 || Set(items.map(\.song.id)).count < items.count
        guard hasSignals else { return items.shuffled(using: &rng) }
        let strength: Double = switch settings.strength { case .low: 0.5; case .standard: 1; case .high: 1.75 }
        let historical = Dictionary(context.recentSongIDs.suffix(settings.recentWindow).map { ($0, 1) }, uniquingKeysWith: +)
        var pool = items.map { item -> Candidate in
            let id = item.song.id
            var weight = context.likedSongIDs.contains(id) ? 1 + (settings.likedWeight - 1) * strength : 1
            weight /= 1 + Double(min(20, max(0, context.skipCounts[id, default: 0]))) * strength
            weight /= 1 + log1p(Double(max(0, context.playCounts[id, default: 0]))) * 0.15 * strength
            weight /= 1 + Double(historical[id, default: 0]) * 6 * strength
            // Weighted random permutation; the small floor avoids infinities for an RNG returning zero.
            let u = max(0.000_000_001, Double.random(in: 0..<1, using: &rng))
            return Candidate(item: item, artist: artistKey(item.song), priority: pow(u, 1 / max(0.0001, weight)))
        }.sorted { $0.priority > $1.priority }
        var artistCounts: [String: Int] = [:]
        for candidate in pool { if let artist = candidate.artist { artistCounts[artist, default: 0] += 1 } }
        var recent = Array(context.recentSongIDs.suffix(settings.recentWindow))
        if let previous { recent.append(previous.id) }
        var lastArtist = previous.flatMap(artistKey)
        var artistRun = lastArtist == nil ? 0 : 1
        var result: [QueueItem] = []
        result.reserveCapacity(items.count)
        for index in pool.indices {
            let avoidArtist = artistRun >= settings.artistLimit && artistCounts.keys.contains { $0 != lastArtist }
            let recentSet = Set(recent.suffix(settings.recentWindow))
            let end = min(pool.count, index + 32)
            var chosen: Int?
            var best = -Double.infinity
            // Bounded lookahead keeps large playlists inexpensive; it is not run on playback ticks.
            for candidateIndex in index..<end {
                let candidate = pool[candidateIndex]
                if avoidArtist, candidate.artist == lastArtist { continue }
                let score = candidate.priority - (recentSet.contains(candidate.item.song.id) ? 0.8 * strength : 0)
                if score > best { best = score; chosen = candidateIndex }
            }
            if chosen == nil, avoidArtist {
                // A minority artist further down may be the only way to meet the configured limit.
                chosen = (index..<pool.count).first { pool[$0].artist != lastArtist }
            }
            let picked = chosen ?? index
            pool.swapAt(index, picked)
            let next = pool[index]
            result.append(next.item)
            recent.append(next.item.song.id)
            if recent.count > settings.recentWindow { recent.removeFirst(recent.count - settings.recentWindow) }
            if let artist = next.artist {
                artistRun = artist == lastArtist ? artistRun + 1 : 1
                artistCounts[artist, default: 0] -= 1
                if artistCounts[artist] == 0 { artistCounts.removeValue(forKey: artist) }
            } else { artistRun = 0 }
            lastArtist = next.artist
        }
        return result
    }
}
