import Foundation

/// The expendable catalogue and the listener's durable edits have separate roots.
public actor LyricsVersionStore {
    public struct Preference: Codable, Sendable {
        public var selected: LyricsCandidate?
        public var offsets: [String: TimeInterval] = [:]
        public var translations: [String: [Int: String]] = [:]
        public var imports: [String: LyricTranslationDocument]?
        public var localVersions: [LyricsCandidate]?
        public var translationSelections: [String: LyricTranslationSelection]?
        public fileprivate(set) var revision: UInt64?

        public init() {}

        public func offset(for id: LyricsCandidate.Identity) -> TimeInterval {
            let value = offsets[id.cacheNamespace] ?? 0
            return value.isFinite ? min(30, max(-30, value)) : 0
        }

        public func edits(for id: LyricsCandidate.Identity) -> [Int: String] {
            translations[id.cacheNamespace] ?? [:]
        }
    }

    /// Old generated records may contain a user-edit snapshot. Remove the
    /// generated lines only after preserving that snapshot for the exact
    /// original identity. Active edits and intentionally removed rows are untouched.
    public func removeRetiredGeneratedTranslations(profile: URL) throws {
        struct EditArchive: Codable, Equatable {
            let songID: String
            let original: LyricsCandidate.Identity
            let edits: [Int: String]
        }

        let manager = FileManager.default
        let retired = profile.appending(path: "PreservedLyricTranslations")
        let archive = profile.appending(path: "ArchivedLyricEdits")
        guard manager.fileExists(atPath: retired.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let files = try manager.contentsOfDirectory(at: retired, includingPropertiesForKeys: Array(keys),
                                                     options: .skipsHiddenFiles)
        for file in files where file.pathExtension == "json" {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let record: EditArchive = load(file, limit: maximumRecordBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if !record.edits.isEmpty {
                let destination = archive.appending(component: file.lastPathComponent)
                if manager.fileExists(atPath: destination.path) {
                    guard let existing: EditArchive = load(destination, limit: maximumRecordBytes), existing == record else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                } else {
                    try persist(record, to: destination, limit: maximumRecordBytes)
                }
            }
            try manager.removeItem(at: file)
        }
    }

    public func selectTranslation(_ selection: LyricTranslationSelection, for candidate: LyricsCandidate,
                                  profile: URL) throws -> Preference {
        try modify(profile, songID: candidate.songID) {
            var selections = $0.translationSelections ?? [:]
            selections[candidate.id.cacheNamespace] = selection == .automatic ? nil : selection
            $0.translationSelections = selections
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

        public func confirmsMissing(sources: Set<String>, now: Date = Date()) -> Bool {
            let age = now.timeIntervalSince(fetchedAt)
            return age >= 0 && age < 86_400 && !sources.isEmpty && Set(results.map(\.source)) == sources
                && results.allSatisfy { $0.state == .empty && $0.candidates.isEmpty }
        }

        public init(results: [LyricsSourceResult], fetchedAt: Date = Date()) {
            self.results = results
            self.fetchedAt = fetchedAt
        }
    }

    private let cache: URL
    private var maximumBytes: Int
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
        let results = value.results.map { item in
            LyricsSourceResult(source: item.source, name: item.name, state: item.state,
                               candidates: item.candidates.map { $0.withMeasuredTiming() })
        }
        return Catalogue(results: results, fetchedAt: value.fetchedAt)
    }

    public func cache(_ value: Catalogue, key: String, ticket: UUID? = nil, expectedSources: Set<String> = []) {
        guard ticket == nil || ticket == cacheGeneration else { return }
        guard !Task.isCancelled else { return }
        // Keep usable candidates from a provider that subsequently timed out
        // or entered cooldown. The next lookup rechecks its live status.
        let incoming = value.results.compactMap { result -> LyricsSourceResult? in
            guard !result.candidates.isEmpty else { return nil }
            return LyricsSourceResult(source: result.source, name: result.name, state: .found,
                                      candidates: result.candidates)
        }
        let file = location(cache, key)
        let existing: Catalogue? = load(file, limit: maximumRecordBytes)
        guard existing.map({ $0.fetchedAt <= value.fetchedAt }) ?? true else { return }
        if incoming.isEmpty {
            guard value.confirmsMissing(sources: expectedSources),
                  existing?.results.contains(where: { !$0.candidates.isEmpty }) != true else { return }
            try? persist(value, to: file, limit: min(maximumBytes, maximumRecordBytes))
            trimCache()
            return
        }
        var results = existing?.results.filter { $0.state == .found } ?? []
        for result in incoming {
            guard let index = results.firstIndex(where: { $0.source == result.source }) else {
                results.append(result)
                continue
            }
            results[index] = .init(source: result.source, name: result.name, state: .found,
                                   candidates: result.candidates + results[index].candidates)
        }
        let bounded = Catalogue(results: results, fetchedAt: value.fetchedAt)
        try? persist(bounded, to: file, limit: min(maximumBytes, maximumRecordBytes))
        trimCache()
    }

    public func setCapacity(_ bytes: Int) {
        maximumBytes = max(0, bytes)
        trimCache()
    }

    private func trimCache() {
        var total = 0
        for (index, file) in cacheFiles().enumerated() {
            total += file.size
            if index >= 200 || total > maximumBytes { try? FileManager.default.removeItem(at: file.url) }
        }
    }

    public func usage() -> Int { cacheFiles().reduce(0) { $0 + $1.size } }

    public func clearCache() throws {
        cacheGeneration = UUID()
        if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
    }

    public func preference(profile: URL, songID: String) -> Preference {
        var saved: Preference = load(location(userDirectory(profile), songID), limit: maximumRecordBytes) ?? Preference()
        saved.selected = saved.selected?.withMeasuredTiming()
        saved.localVersions = saved.localVersions?.map { $0.withMeasuredTiming() }
        return saved
    }

    @discardableResult
    public func select(_ candidate: LyricsCandidate?, profile: URL, songID: String) throws -> Preference {
        guard candidate == nil || candidate?.songID == songID else { throw CocoaError(.fileWriteInvalidFileName) }
        return try modify(profile, songID: songID) {
            $0.selected = candidate
            if let candidate, candidate.id.source == "local" {
                var imported = $0.localVersions ?? []
                if !imported.contains(where: { $0.id == candidate.id }) { imported.append(candidate) }
                $0.localVersions = imported
            }
        }
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
        let safe = edits.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard safe.allSatisfy({ valid.contains($0.key) && $0.value.utf8.count <= 8_192 }) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
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
            data.revision = (data.revision ?? 0) &+ 1
            try persist(data, to: file, limit: maximumRecordBytes)
        }
    }

    private func modify(_ profile: URL, songID: String, using update: (inout Preference) -> Void) throws -> Preference {
        let url = location(userDirectory(profile), songID)
        var data = Preference()
        if FileManager.default.fileExists(atPath: url.path) {
            guard let saved: Preference = load(url, limit: maximumRecordBytes) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data = saved
        }
        update(&data)
        data.revision = (data.revision ?? 0) &+ 1
        try persist(data, to: url, limit: maximumRecordBytes)
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
