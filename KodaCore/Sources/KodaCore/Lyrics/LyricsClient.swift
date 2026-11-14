import Foundation

/// Lyrics from several services at once, keeping the best: word-timed from
/// YouLyPlus or BetterLyrics (Apple Music's timings), else line-timed or plain
/// from LRCLIB.
///
/// The services answer at different speeds and come and go. All of them are
/// asked together; a word-timed answer is taken as soon as every service ranked
/// above it has answered, and otherwise the best answer by the deadline.
public struct LyricsClient: Sendable {
    let session: URLSession
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport?
    private let cache: LyricsCache
    private let deadline: Duration
    private static let sharedCache = LyricsCache()

    private static let youLyPlusMirrors = [
        "https://lyricsplus.binimum.org/",
        "https://lyricsplus.prjktla.my.id/",
        "https://lyricsplus.prjktla.workers.dev/",
        "https://lyricsplus.atomix.one/",
        "https://lyricsplus-seven.vercel.app/",
    ]

    private static let betterLyricsEndpoints = [
        "https://lyrics-api.boidu.dev/getLyrics",
        "https://lyrics-api.boidu.dev/qq/getLyrics",
        "https://lyrics-api.boidu.dev/kugou/getLyrics",
    ]

    public init(session: URLSession = .shared) {
        self.session = session
        transport = nil
        cache = Self.sharedCache
        deadline = .seconds(12)
    }

    /// A local transport seam keeps provider, cancellation and cache tests independent
    /// of the public services and of other LyricsClient instances.
    init(transport: @escaping Transport, deadline: Duration = .seconds(12)) {
        session = .shared
        self.transport = transport
        cache = LyricsCache()
        self.deadline = deadline
    }

    typealias Query = LyricsQuery

    /// Lyrics for `song` from the given services, ranked in the order given.
    public func lyrics(for song: Song, sources: [LyricsSource] = LyricsSource.allCases,
                       customSources: [CustomLyricsSource] = [], refresh: Bool = false) async -> Lyrics? {
        guard !Task.isCancelled else { return nil }
        var seen = Set<String>()
        let sources = sources.filter { seen.insert($0.rawValue).inserted }
        let customSources = Array(customSources.filter(\.isEnabled).prefix(CustomLyricsSource.maximumCount))
        guard !sources.isEmpty || !customSources.isEmpty else { return nil }
        let artist = song.artists.first?.name ?? song.artistLine
        let credits = song.artistLine.isEmpty || song.artistLine == artist ? [] : [song.artistLine]
        let query = Query(title: song.title, artist: artist, album: song.album?.title,
                          duration: song.duration, artistCredits: credits)
        guard !query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let key = LyricsCache.Key(songID: song.id, query: query, sources: sources.map(\.rawValue),
                                  customSources: customSources.map { $0.id.uuidString + "|" + $0.urlTemplate })
        if !refresh, let cached = await cache[key] { return Task.isCancelled ? nil : cached }
        let reservation = await cache.begin(key)
        let found = await best(query, sources: sources, customSources: customSources)
        await cache.finish(Task.isCancelled ? nil : found, for: key, reservation: reservation)
        guard !Task.isCancelled else { return nil }
        return found
    }

    /// Forget lyrics found this session, so the next look asks the services again.
    public func clearCache() async {
        await cache.clear()
    }

    // MARK: Choosing

    private func best(_ query: Query, sources: [LyricsSource], customSources: [CustomLyricsSource]) async -> Lyrics? {
        var providers = sources.map { source -> @Sendable () async -> Lyrics? in
            switch source {
            case .youLyPlus: { await youLyPlus(query) }
            case .betterLyrics: { await betterLyrics(query) }
            case .lrclib: { await lrclib(query) }
            case .lrcAPI: { await lrcAPI(query) }
            case .lyricsOVH: { await lyricsOVH(query) }
            }
        }
        providers += customSources.map { source -> @Sendable () async -> Lyrics? in
            { await customLyrics(query, source: source) }
        }
        return await withTaskGroup(of: (Int, Lyrics?)?.self) { group in
            for (rank, provider) in providers.enumerated() {
                group.addTask { (rank, await provider()) }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            var answers: [Int: Lyrics] = [:]
            var pending = Set(providers.indices)
            while let next = await group.next() {
                // nil is the deadline.
                guard let answer = next else { break }
                let (rank, lyrics) = answer
                pending.remove(rank)
                if let lyrics { answers[rank] = lyrics }
                // Word timing from the best-ranked service still in the running wins outright.
                if let top = answers.filter({ $0.value.quality == 2 }).min(by: { $0.key < $1.key }),
                   !pending.contains(where: { $0 < top.key }) {
                    group.cancelAll()
                    return top.value
                }
                if pending.isEmpty { break }
            }
            group.cancelAll()
            return answers.max { a, b in a.value.quality != b.value.quality ? a.value.quality < b.value.quality : a.key > b.key }?.value
        }
    }

    // MARK: YouLyPlus

    private func youLyPlus(_ query: Query) async -> Lyrics? {
        guard !query.artist.isEmpty else { return nil }
        let parameters = Self.youLyParameters(query)
        let original = Self.youLyPlusMirrors.prefix(3).map { ($0 + "v2/lyrics/get", parameters) }
        if let found = await race(original, decode: Self.decodeYouLyPlus) {
            return found
        }
        guard !Task.isCancelled else { return nil }
        // Keep both provider formats, while limiting the mirror fan-out to seven
        // requests total instead of retrying every spelling against every mirror.
        let fallback = Self.fallbackQuery(query)
        let legacy = Self.youLyPlusMirrors.prefix(2).map { ($0 + "v1/ttml/get", parameters) }
        let alternative = Self.youLyPlusMirrors.suffix(2).map { ($0 + "v2/lyrics/get", Self.youLyParameters(fallback)) }
        return await race(legacy + alternative, decode: Self.decodeYouLyPlus)
    }

    private static func youLyParameters(_ query: Query) -> [String: String] {
        var parameters = ["title": query.title, "artist": query.artist]
        if let album = query.album, !album.isEmpty { parameters["album"] = album }
        if let duration = durationParameter(query.duration) { parameters["duration"] = duration }
        return parameters
    }

    private static func durationParameter(_ duration: TimeInterval?) -> String? {
        guard let duration, duration.isFinite, duration > 0, duration <= 7 * 24 * 60 * 60 else { return nil }
        return String(Int(duration.rounded()))
    }

    private static func decodeYouLyPlus(_ data: Data) -> Lyrics? {
        if let json = try? JSON(data: data), let lines = Lyrics.parseYouLyPlus(json) { return .synced(lines) }
        return decodeWrapped(data)
    }

    private static func fallbackQuery(_ query: Query) -> Query {
        let variants = query.variants().dropFirst()
        return variants.first { $0.title != query.title || $0.artist != query.artist }
            ?? variants.first ?? query
    }

    /// Prefer word timings over a faster plain/line answer from another mirror.
    private func race(_ requests: [(String, [String: String])], decode: @escaping @Sendable (Data) -> Lyrics?) async -> Lyrics? {
        await withTaskGroup(of: Lyrics?.self) { group in
            for (url, parameters) in requests {
                group.addTask {
                    guard let data = await fetch(url, parameters) else { return nil }
                    return decode(data)
                }
            }
            var best: Lyrics?
            for await result in group {
                if let result {
                    if result.quality == 2 {
                        group.cancelAll()
                        return result
                    }
                    if best == nil || result.quality > best!.quality { best = result }
                }
            }
            return best
        }
    }

    // MARK: BetterLyrics

    private func betterLyrics(_ query: Query) async -> Lyrics? {
        guard !query.artist.isEmpty else { return nil }
        let fallback = Self.fallbackQuery(query)
        for variant in fallback == query ? [query] : [query, fallback] {
            guard !Task.isCancelled else { return nil }
            var parameters = ["s": variant.title, "a": variant.artist]
            if let album = variant.album, !album.isEmpty { parameters["al"] = album }
            if let duration = Self.durationParameter(variant.duration) { parameters["d"] = duration }
            let requests = Self.betterLyricsEndpoints.map { ($0, parameters) }
            if let found = await race(requests, decode: Self.decodeWrapped) { return found }
        }
        return nil
    }

    /// TTML or LRC as the body, or inside a JSON object under a key such as `ttml` or `lyrics`.
    static func decodeWrapped(_ data: Data) -> Lyrics? {
        guard let body = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if body.hasPrefix("<") { return Lyrics.parseAny(body) }
        guard let json = try? JSON(data: data) else {
            // Some mirrors return a plain LRC body rather than wrapping it in JSON.
            // Require actual timestamps, so a text error page is not cached as lyrics.
            let lines = Lyrics.parseLRC(body)
            return lines.isEmpty ? nil : .synced(lines)
        }
        for key in ["ttml", "syncedLyrics", "lyrics", "lrc", "plainLyrics", "content", "text"] {
            if let text = json[key].nonEmpty, let lyrics = Lyrics.parseAny(text) { return lyrics }
        }
        return nil
    }

    // MARK: LRCLIB

    private func lrclib(_ query: Query) async -> Lyrics? {
        var exact = ["artist_name": query.artist, "track_name": query.title]
        if let album = query.album { exact["album_name"] = album }
        if let duration = Self.durationParameter(query.duration) { exact["duration"] = duration }
        if let data = await fetch("https://lrclib.net/api/get", exact), let json = try? JSON(data: data), json.isObject,
           let found = Self.lrclibMatch([json], query: query) {
            return found
        }
        var searched = Set<String>()
        for variant in query.variants() {
            guard !Task.isCancelled else { return nil }
            let identity = variant.artist + "\u{1F}" + variant.title
            guard searched.insert(identity).inserted else { continue }
            let parameters = ["artist_name": variant.artist, "track_name": variant.title]
            if let data = await fetch("https://lrclib.net/api/search", parameters), let json = try? JSON(data: data),
               let found = Self.lrclibMatch(json.array, query: query) { return found }
        }
        // LRCLIB's free-text index sometimes finds records missed by field search.
        // Every result still passes the original song's title/artist/version checks.
        let fallback = Self.fallbackQuery(query)
        guard let data = await fetch("https://lrclib.net/api/search", ["q": fallback.title + " " + fallback.artist]),
              let json = try? JSON(data: data) else { return nil }
        return Self.lrclibMatch(json.array, query: query)
    }

    static func lrclibMatch(_ items: [JSON], query: Query) -> Lyrics? {
        let matches = items.enumerated().compactMap { index, item -> (Int, Double, Lyrics)? in
            guard item["instrumental"].bool != true,
                  let title = item["trackName"].nonEmpty, let artist = item["artistName"].nonEmpty,
                  let score = query.candidateScore(title: title, artist: artist, duration: item["duration"].double),
                  let lyrics = lrclibLyrics(from: item) else { return nil }
            return (index, score, lyrics)
        }
        return matches.max { a, b in
            if a.2.quality != b.2.quality { return a.2.quality < b.2.quality }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0 > b.0
        }?.2
    }

    static func lrclibLyrics(from item: JSON) -> Lyrics? {
        if let synced = item["syncedLyrics"].nonEmpty {
            let lines = Lyrics.parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = item["plainLyrics"].nonEmpty { return .plain(plain) }
        return nil
    }

    // MARK: Additional public providers and user-configured sources

    private func lyricsOVH(_ query: Query) async -> Lyrics? {
        guard !query.artist.isEmpty else { return nil }
        let fallback = Self.fallbackQuery(query)
        for variant in fallback == query ? [query] : [query, fallback] {
            guard !Task.isCancelled else { return nil }
            var segmentCharacters = CharacterSet.urlPathAllowed
            segmentCharacters.remove(charactersIn: "/?#%")
            guard let artist = variant.artist.addingPercentEncoding(withAllowedCharacters: segmentCharacters),
                  let title = variant.title.addingPercentEncoding(withAllowedCharacters: segmentCharacters),
                  let url = URL(string: "https://api.lyrics.ovh/v1/" + artist + "/" + title),
                  let data = await fetch(url), let json = try? JSON(data: data),
                  let text = json["lyrics"].nonEmpty,
                  let found = Lyrics.parseAny(text) else { continue }
            return found
        }
        return nil
    }

    private func lrcAPI(_ query: Query) async -> Lyrics? {
        guard !query.artist.isEmpty else { return nil }
        let fallback = Self.fallbackQuery(query)
        for variant in fallback == query ? [query] : [query, fallback] {
            guard !Task.isCancelled else { return nil }
            var parameters = ["title": variant.title, "artist": variant.artist]
            if let album = variant.album, !album.isEmpty { parameters["album"] = album }
            guard let data = await fetch("https://api.lrc.cx/jsonapi", parameters),
                  let json = try? JSON(data: data) else { continue }
            let matches = json.array.enumerated().compactMap { index, item -> (Int, Double, Lyrics)? in
                guard let title = item["title"].nonEmpty, let artist = item["artist"].nonEmpty,
                      let score = query.candidateScore(title: title, artist: artist, duration: item["duration"].double),
                      let text = item["lyrics"].nonEmpty, let found = Lyrics.parseAny(text) else { return nil }
                return (index, score, found)
            }
            if let best = matches.max(by: { a, b in
                if a.2.quality != b.2.quality { return a.2.quality < b.2.quality }
                if a.1 != b.1 { return a.1 < b.1 }
                return a.0 > b.0
            }) { return best.2 }
        }
        return nil
    }

    private func customLyrics(_ query: Query, source: CustomLyricsSource) async -> Lyrics? {
        guard let url = try? source.requestURL(title: query.title, artist: query.artist,
                                              album: query.album, duration: query.duration),
              let data = await fetch(url) else { return nil }
        if let decoded = Self.decodeWrapped(data) { return decoded }
        // A user-configured plain-text endpoint is explicit, unlike a generic provider
        // error page. JSON/HTML responses still require a recognized lyric format/key.
        if let _ = try? JSON(data: data) { return nil }
        guard let body = String(data: data, encoding: .utf8) else { return nil }
        return Lyrics.parseAny(body)
    }

    // MARK: Network

    private func fetch(_ url: String, _ parameters: [String: String]) async -> Data? {
        guard !Task.isCancelled, var components = URLComponents(string: url) else { return nil }
        components.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { return nil }
        return await fetch(url)
    }

    private func fetch(_ url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Koda iOS (https://github.com/Ivorisnoob/Koda-iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, application/xml, text/plain, */*", forHTTPHeaderField: "Accept")
        let result: (Data, URLResponse)?
        if let transport { result = try? await transport(request) }
        else { result = try? await session.data(for: request) }
        guard !Task.isCancelled, let (data, response) = result,
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              !data.isEmpty, data.count <= 2_000_000 else { return nil }
        return data
    }
}

/// Lyrics already found this session, so reopening the panel or replaying a song is instant.
private actor LyricsCache {
    struct Key: Hashable, Sendable {
        var songID: String
        var query: LyricsQuery
        var sources: [String]
        var customSources: [String]
    }
    private var entries: [Key: Lyrics] = [:]
    private var order: [Key] = []
    private var reservations: [Key: UUID] = [:]

    subscript(id: Key) -> Lyrics? { entries[id] }

    func clear() {
        entries = [:]
        order = []
        reservations = [:]
    }

    func begin(_ id: Key) -> UUID {
        let reservation = UUID()
        reservations[id] = reservation
        return reservation
    }

    func finish(_ lyrics: Lyrics?, for id: Key, reservation: UUID) {
        guard reservations[id] == reservation else { return }
        reservations[id] = nil
        guard let lyrics else { return }
        if entries[id] == nil { order.append(id) }
        entries[id] = lyrics
        if order.count > 60 { entries[order.removeFirst()] = nil }
    }
}

/// A service lyrics can come from.
public enum LyricsSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case youLyPlus, betterLyrics, lrclib, lrcAPI, lyricsOVH

    public var id: Self { self }

    public var title: String {
        switch self {
        case .youLyPlus: "YouLyPlus"
        case .betterLyrics: "BetterLyrics"
        case .lrclib: "LRCLIB"
        case .lrcAPI: "LrcAPI"
        case .lyricsOVH: "lyrics.ovh"
        }
    }

    /// What the listener gets from it.
    public var detail: String {
        switch self {
        case .youLyPlus: NSLocalizedString("Word-by-word, with duets and backing vocals", bundle: KodaLocalization.bundle, comment: "")
        case .betterLyrics: NSLocalizedString("Word-by-word, from several catalogues", bundle: KodaLocalization.bundle, comment: "")
        case .lrclib: NSLocalizedString("Line-by-line and plain lyrics, community-made", bundle: KodaLocalization.bundle, comment: "")
        case .lrcAPI: NSLocalizedString("Synced lyrics from a public lyrics catalogue", bundle: KodaLocalization.bundle, comment: "")
        case .lyricsOVH: NSLocalizedString("Plain lyrics as an additional fallback", bundle: KodaLocalization.bundle, comment: "")
        }
    }
}
