import Foundation

/// The expendable catalogue and the listener's durable edits have separate roots.
public actor LyricsVersionStore {
    public struct Preference: Codable, Sendable {
        public var selected: LyricsCandidate?
        public var offsets: [String: TimeInterval] = [:]
        public var translations: [String: [Int: String]] = [:]
        public var imports: [String: LyricTranslationDocument]?

        public init() {}

        public func offset(for id: LyricsCandidate.Identity) -> TimeInterval {
            let value = offsets[id.cacheNamespace] ?? 0
            return value.isFinite ? min(30, max(-30, value)) : 0
        }

        public func edits(for id: LyricsCandidate.Identity) -> [Int: String] {
            translations[id.cacheNamespace] ?? [:]
        }
    }

    public func importTranslation(_ document: LyricTranslationDocument?, for candidate: LyricsCandidate,
                                  profile: URL) throws -> Preference {
        let validated = try document?.validated()
        if let validated {
            guard case .synced(let lines) = candidate.lyrics, !validated.aligned(to: lines).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        return try modify(profile, songID: candidate.songID) {
            var imports = $0.imports ?? [:]
            imports[candidate.id.cacheNamespace] = validated
            $0.imports = imports
        }
    }

    public struct Catalogue: Codable, Sendable {
        public let results: [LyricsSourceResult]
        public let fetchedAt: Date
        public var isFresh: Bool { abs(Date().timeIntervalSince(fetchedAt)) < 24 * 60 * 60 }

        public init(results: [LyricsSourceResult], fetchedAt: Date = Date()) {
            self.results = results
            self.fetchedAt = fetchedAt
        }
    }

    private let cache: URL
    private let maximumBytes: Int
    private let maximumRecordBytes = 6_000_000
    private var cacheGeneration = UUID()

    public func ticket() -> UUID { cacheGeneration }

    public init(cache: URL, maximumBytes: Int = 20_000_000) {
        self.cache = cache
        self.maximumBytes = max(0, maximumBytes)
    }

    public func catalogue(key: String) -> Catalogue? {
        let file = location(cache, key)
        guard let value: Catalogue = load(file, limit: maximumRecordBytes) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return value
    }

    public func cache(_ value: Catalogue, key: String, ticket: UUID? = nil) {
        guard ticket == nil || ticket == cacheGeneration else { return }
        let results = value.results.filter { $0.state == .found || $0.state == .empty }
        guard results.contains(where: { !$0.candidates.isEmpty }) else { return }
        let bounded = Catalogue(results: results, fetchedAt: value.fetchedAt)
        try? persist(bounded, to: location(cache, key), limit: min(maximumBytes, maximumRecordBytes))
        var total = 0
        for file in cacheFiles() {
            total += file.size
            if total > maximumBytes { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    public func usage() -> Int { cacheFiles().reduce(0) { $0 + $1.size } }

    public func clearCache() throws {
        cacheGeneration = UUID()
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
    }

    public func preference(profile: URL, songID: String) -> Preference {
        load(location(userDirectory(profile), songID), limit: maximumRecordBytes) ?? Preference()
    }

    @discardableResult
    public func select(_ candidate: LyricsCandidate?, profile: URL, songID: String) throws -> Preference {
        guard candidate == nil || candidate?.songID == songID else { throw CocoaError(.fileWriteInvalidFileName) }
        return try modify(profile, songID: songID) { $0.selected = candidate }
    }

    @discardableResult
    public func setOffset(_ value: TimeInterval, for identity: LyricsCandidate.Identity,
                          profile: URL, songID: String) throws -> Preference {
        try modify(profile, songID: songID) {
            let offset = value.isFinite ? (min(30, max(-30, value)) * 10).rounded() / 10 : 0
            $0.offsets[identity.cacheNamespace] = offset == 0 ? nil : offset
        }
    }

    @discardableResult
    public func saveEdits(_ edits: [Int: String], for candidate: LyricsCandidate,
                          profile: URL) throws -> Preference {
        let valid: Set<Int>
        switch candidate.lyrics {
        case .plain(let text): valid = Set(LyricsCandidate.plainLines(text).indices)
        case .synced(let lines): valid = Set(lines.map(\.id))
        }
        let safe = edits.filter { valid.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && $0.value.utf8.count <= 8_192 }
        return try modify(profile, songID: candidate.songID) {
            $0.translations[candidate.id.cacheNamespace] = safe.isEmpty ? nil : safe
        }
    }

    /// Reset source selections, retaining corrections and written translations.
    public func resetSelections(profile: URL) throws {
        let directory = userDirectory(profile)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file.pathExtension == "json" {
            guard var data: Preference = load(file, limit: maximumRecordBytes), data.selected != nil else { continue }
            data.selected = nil
            try persist(data, to: file, limit: maximumRecordBytes)
        }
    }

    private func modify(_ profile: URL, songID: String, using update: (inout Preference) -> Void) throws -> Preference {
        var data = preference(profile: profile, songID: songID)
        update(&data)
        try persist(data, to: location(userDirectory(profile), songID), limit: maximumRecordBytes)
        return data
    }

    private func userDirectory(_ profile: URL) -> URL { profile.appendingPathComponent("LyricVersions-v1", isDirectory: true) }
    private func location(_ directory: URL, _ key: String) -> URL {
        directory.appendingPathComponent(LyricsCandidate.digest(Data(key.utf8)) + ".json")
    }

    private func load<T: Decodable>(_ url: URL, limit: Int) -> T? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, to url: URL, limit: Int) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func cacheFiles() -> [(url: URL, size: Int, used: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> (url: URL, size: Int, used: Date)? in
            guard url.pathExtension == "json", let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.used > $1.used }
    }
}
