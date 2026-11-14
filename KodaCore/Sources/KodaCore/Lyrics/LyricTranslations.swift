import CryptoKit
import Foundation

/// Presentation only: no mode changes the provider's lyrics or their word timing.
public enum LyricsDisplayMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case original, translation, bilingual
    public var id: Self { self }
    public var title: String {
        switch self {
        case .original: NSLocalizedString("Original Lyrics", bundle: KodaLocalization.bundle, comment: "")
        case .translation: NSLocalizedString("Chinese Translation", bundle: KodaLocalization.bundle, comment: "")
        case .bilingual: NSLocalizedString("Original and Chinese", bundle: KodaLocalization.bundle, comment: "")
        }
    }
}

/// A user's translation is a separate document, never written into provider lyric data.
public struct LyricTranslationDocument: Codable, Sendable, Equatable {
    public struct Line: Codable, Sendable, Equatable {
        public var time: TimeInterval
        public var text: String
        /// Optional source text disambiguates singers with the same timestamp.
        public var original: String?
        /// Optional "lead", "duet", or "together" for simultaneous voices.
        public var voice: String?
        public init(time: TimeInterval, text: String, original: String? = nil, voice: String? = nil) {
            self.time = time; self.text = text; self.original = original; self.voice = voice
        }
    }

    public var version: Int
    public var language: String
    public var lines: [Line]
    public init(lines: [Line], language: String = "zh-Hant", version: Int = 1) {
        self.version = version; self.language = language; self.lines = lines
    }

    public enum ImportError: LocalizedError {
        case invalidFormat, tooLarge, unsupportedVersion, unsupportedLanguage
        public var errorDescription: String? {
            switch self {
            case .invalidFormat: NSLocalizedString("Use a UTF-8 translation LRC or a valid translation JSON file.", bundle: KodaLocalization.bundle, comment: "")
            case .tooLarge: NSLocalizedString("This translation file is too large. Use a file under 1 MB with at most 5,000 lines.", bundle: KodaLocalization.bundle, comment: "")
            case .unsupportedVersion: NSLocalizedString("This translation file uses an unsupported version.", bundle: KodaLocalization.bundle, comment: "")
            case .unsupportedLanguage: NSLocalizedString("Choose a Traditional Chinese translation file (zh-Hant or zh-TW).", bundle: KodaLocalization.bundle, comment: "")
            }
        }
    }

    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 1_000_000 else { throw ImportError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalidFormat }
        let document: Self
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            guard let decoded = try? JSONDecoder().decode(Self.self, from: data) else { throw ImportError.invalidFormat }
            document = decoded
        } else {
            // A single LRC row can expand into many repeated timestamps; bound it before parsing.
            guard text.reduce(0, { $0 + ($1 == "[" ? 1 : 0) }) <= 5_000 else { throw ImportError.tooLarge }
            document = Self(lines: Lyrics.parseLRC(text).map { Line(time: $0.time, text: $0.text) })
        }
        return try document.validated()
    }

    public func validated() throws -> Self {
        guard version == 1 else { throw ImportError.unsupportedVersion }
        guard ["zh-Hant", "zh-TW", "zh-Hant-TW"].contains(language) else { throw ImportError.unsupportedLanguage }
        guard lines.count <= 5_000 else { throw ImportError.tooLarge }
        guard !lines.isEmpty, lines.allSatisfy({
            $0.time.isFinite && $0.time >= 0 && $0.time < 86_400 && $0.text.count <= 2_000
                && ($0.original?.count ?? 0) <= 2_000
                && ($0.voice == nil || ["lead", "duet", "together"].contains($0.voice!))
        }) else { throw ImportError.invalidFormat }
        let clean = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !clean.isEmpty else { throw ImportError.invalidFormat }
        return Self(lines: clean, language: language, version: version)
    }

    /// Each translation occurrence can serve only one original occurrence. Repeated choruses
    /// match by timestamp, not text; original+translation pairs sharing an LRC stamp are supported.
    /// Unmatched rows stay original. JSON can disambiguate simultaneous singers explicitly.
    public func aligned(to originals: [LyricLine], tolerance: TimeInterval = 0.5) -> [Int: String] {
        let tolerance = min(1, max(0, tolerance))
        var used = Set<Int>()
        var result: [Int: String] = [:]
        let candidates = lines.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }
        let originalTimes = Dictionary(grouping: originals, by: \.text).mapValues { $0.map(\.time) }
        func firstCandidate(at time: TimeInterval) -> Int {
            var low = 0, high = candidates.count
            while low < high {
                let mid = (low + high) / 2
                if candidates[mid].element.time < time { low = mid + 1 } else { high = mid }
            }
            return low
        }
        for original in originals {
            let voice: String
            switch original.voice {
            case .lead: voice = "lead"
            case .duet: voice = "duet"
            case .together: voice = "together"
            }
            let start = firstCandidate(at: original.time - tolerance)
            let end = firstCandidate(at: original.time + tolerance + 0.000_001)
            let matching = candidates[start..<end].filter { index, candidate in
                !used.contains(index) && abs(candidate.time - original.time) <= tolerance
                    && (candidate.original == nil || candidate.original == original.text)
                    && (candidate.voice == nil || candidate.voice == voice)
                    && candidate.text.trimmingCharacters(in: .whitespacesAndNewlines) != original.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Ignore original rows in a bilingual LRC, including another singer's row.
                    && !(originalTimes[candidate.text] ?? []).contains { abs($0 - candidate.time) <= tolerance }
            }
            let best = matching.min { lhs, rhs in
                let leftSpecific = lhs.element.original != nil || lhs.element.voice != nil
                let rightSpecific = rhs.element.original != nil || rhs.element.voice != nil
                if leftSpecific != rightSpecific { return leftSpecific }
                let left = abs(lhs.element.time - original.time), right = abs(rhs.element.time - original.time)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            if let best {
                used.insert(best.offset)
                result[original.id] = best.element.text
            }
        }
        return result
    }
}

/// Pure display policy, shared by UI and tests. Original word/voice data is never rewritten.
public struct LyricTranslationPresentation: Equatable, Sendable {
    public var showsOriginal: Bool
    public var translation: String?
    public init(mode: LyricsDisplayMode, enabled: Bool, translation: String?) {
        let available = translation.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        self.translation = enabled && mode != .original ? available : nil
        showsOriginal = mode != .translation || self.translation == nil
    }
}

/// Local-only, bounded import cache. The disk work runs on this actor, never the rendering path.
public actor LyricTranslationStore {
    public static let shared = LyricTranslationStore()
    private struct Saved: Codable { var songID: String; var document: LyricTranslationDocument }
    private let directory: URL
    private let maximumDocuments: Int
    private let maximumBytes: Int

    public init(directory: URL? = nil, maximumDocuments: Int = 100, maximumBytes: Int = 10_000_000) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koda/LyricTranslations", isDirectory: true)
        self.maximumDocuments = max(1, maximumDocuments)
        self.maximumBytes = max(1_000_000, maximumBytes)
    }

    private func url(for songID: String) -> URL {
        let hash = SHA256.hash(data: Data(songID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    public func document(for songID: String) -> LyricTranslationDocument? {
        guard let data = try? Data(contentsOf: url(for: songID)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.songID == songID,
              let document = try? saved.document.validated() else { return nil }
        return document
    }

    public func translations(for songID: String, originals: [LyricLine]) -> [Int: String] {
        document(for: songID)?.aligned(to: originals) ?? [:]
    }

    public func save(_ document: LyricTranslationDocument, for songID: String) throws {
        let clean = try document.validated()
        let data = try JSONEncoder().encode(Saved(songID: songID, document: clean))
        guard data.count <= 1_000_000 else { throw LyricTranslationDocument.ImportError.tooLarge }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: songID), options: .atomic)
        try trim()
    }

    public func remove(for songID: String) throws {
        let path = url(for: songID)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

    private func trim() throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (URL, Date, Int)? in
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, file) in files.enumerated() {
            bytes += file.2
            if index >= maximumDocuments || bytes > maximumBytes { try FileManager.default.removeItem(at: file.0) }
        }
    }
}
