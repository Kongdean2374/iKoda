import Foundation

/// User-owned translations live with the profile rather than with LRU caches.
public actor PreservedLyricTranslationStore {
    public struct Record: Codable, Equatable, Sendable {
        public let songID: String
        public let original: LyricsCandidate.Identity
        public let mode: LyricsTranslationMode
        public let engine: String
        public let promptVersion: String
        public let languageVersion: String
        public let target: String
        public let languages: [String]
        public let lines: [Int: String]
        public let edits: [Int: String]
        public let isComplete: Bool
        public let savedAt: Date

        public init(candidate: LyricsCandidate, mode: LyricsTranslationMode, target: String, languages: [String],
                    lines: [Int: String], edits: [Int: String], isComplete: Bool) {
            songID = candidate.songID
            original = candidate.id
            self.mode = mode
            engine = "SystemLanguageModel.default"
            promptVersion = LyricContextPassages.promptVersion
            languageVersion = LyricLanguageProfile.version
            self.target = target
            self.languages = languages
            self.lines = lines
            self.edits = edits
            self.isComplete = isComplete
            savedAt = Date()
        }
    }

    private let maximumRecordBytes = 2_000_000

    public init() {}

    public func save(_ record: Record, for candidate: LyricsCandidate, profile: URL) throws {
        let ids = Self.rowIDs(candidate)
        guard Self.compatible(record, candidate: candidate, mode: record.mode), !record.lines.isEmpty,
              record.lines.allSatisfy({ ids.contains($0.key) && !$0.value.isEmpty && $0.value.utf8.count <= 8_192 }),
              record.edits.allSatisfy({ ids.contains($0.key) && $0.value.utf8.count <= 8_192 }) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let data = try JSONEncoder().encode(record)
        guard data.count <= maximumRecordBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = directory(profile)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(candidate, mode: record.mode, profile: profile), options: .atomic)
    }

    public func read(_ candidate: LyricsCandidate, mode: LyricsTranslationMode, profile: URL) throws -> Record? {
        let url = file(candidate, mode: mode, profile: profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximumRecordBytes + 1),
              data.count <= maximumRecordBytes else { throw CocoaError(.fileReadCorruptFile) }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard Self.compatible(record, candidate: candidate, mode: mode) else { return nil }
        let ids = Self.rowIDs(candidate)
        guard record.lines.keys.allSatisfy(ids.contains) else { throw CocoaError(.fileReadCorruptFile) }
        return record
    }

    public func remove(_ candidate: LyricsCandidate, mode: LyricsTranslationMode, profile: URL) throws {
        let url = file(candidate, mode: mode, profile: profile)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    public func usage(profile: URL) throws -> Int {
        let path = directory(profile)
        guard FileManager.default.fileExists(atPath: path.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    private static func compatible(_ record: Record, candidate: LyricsCandidate, mode: LyricsTranslationMode) -> Bool {
        mode.usesContextModel && record.mode == mode && record.songID == candidate.songID && record.original == candidate.id
    }

    private static func rowIDs(_ candidate: LyricsCandidate) -> Set<Int> {
        switch candidate.lyrics {
        case .plain(let text): Set(LyricsCandidate.plainLines(text).indices)
        case .synced(let rows): Set(rows.map(\.id))
        }
    }

    private func directory(_ profile: URL) -> URL { profile.appending(path: "PreservedLyricTranslations") }

    private func file(_ candidate: LyricsCandidate, mode: LyricsTranslationMode, profile: URL) -> URL {
        let key = [candidate.songID, candidate.id.cacheNamespace, mode.rawValue]
        let data = (try? JSONEncoder().encode(key)) ?? Data()
        return directory(profile).appending(path: LyricsCandidate.digest(data) + ".json")
    }
}
