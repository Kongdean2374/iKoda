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

    /// Maximum-coverage, one-to-one matching inside the timestamp tolerance. If a nearer
    /// translation would strand another line, an augmenting path reassigns earlier matches.
    /// Explicit source/voice fields are hard constraints; compatible explicit rows are tried
    /// before unlabelled rows, then by distance and file order. No global time shift is inferred.
    ///
    /// Neighbours are generated from narrow timestamp windows, not an n×m matrix. The search
    /// is iterative (no recursion for long files), with O(n + m) auxiliary memory. Ambiguous
    /// unlabelled matches are put back into chronological order after coverage is established.
    public func aligned(to originals: [LyricLine], tolerance: TimeInterval = 0.5) -> [Int: String] {
        let tolerance = tolerance.isFinite ? min(1, max(0, tolerance)) : 0.5
        let sources = originals.enumerated().filter { $0.element.time.isFinite }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
        guard !sources.isEmpty else { return [:] }

        func firstTime(_ times: [TimeInterval], at time: TimeInterval) -> Int {
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < time { low = mid + 1 } else { high = mid }
            }
            return low
        }
        // Ignore source-text rows in bilingual LRC before matching. This test is independent
        // of a candidate's eventual partner and also handles two singers at the same stamp.
        let originalTimes = Dictionary(grouping: sources, by: {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }).mapValues { $0.map(\.time) }
        let candidates = lines.enumerated().filter { _, candidate in
            guard candidate.time.isFinite else { return false }
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            guard let times = originalTimes[text] else { return true }
            var index = firstTime(times, at: candidate.time - tolerance - 0.000_001)
            while index < times.count, times[index] <= candidate.time + tolerance + 0.000_001 {
                if abs(times[index] - candidate.time) <= tolerance { return false }
                index += 1
            }
            return true
        }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }
        guard !candidates.isEmpty else { return [:] }
        let times = candidates.map { $0.element.time }
        var groupStarts = [Int](repeating: 0, count: candidates.count)
        for index in candidates.indices where index > 0 {
            groupStarts[index] = times[index] == times[index - 1] ? groupStarts[index - 1] : index
        }
        let hasExplicit = candidates.contains { $0.element.original != nil || $0.element.voice != nil }
        let windows = sources.map { source in
            // Widen only the binary-search window for floating-point subtraction rounding;
            // the edge predicate below still enforces the exact requested tolerance.
            (lower: firstTime(times, at: source.time - tolerance - 0.000_001),
             upper: firstTime(times, at: source.time + tolerance + 0.000_001),
             pivot: firstTime(times, at: source.time))
        }
        let voices = sources.map { source -> String in
            switch source.voice {
            case .lead: "lead"
            case .duet: "duet"
            case .together: "together"
            }
        }

        // Two monotone cursors enumerate each window by distance without sorting or storing
        // its edges. Returning true stops the search as soon as an augmenting path is found.
        func visitCandidates(for sourceIndex: Int, _ visit: (Int) -> Bool) -> Bool {
            let source = sources[sourceIndex]
            let window = windows[sourceIndex]
            for pass in 0..<(hasExplicit ? 2 : 1) {
                let wantsExplicit = hasExplicit && pass == 0
                var leftEnd = window.pivot - 1, right = window.pivot
                var left = leftEnd >= window.lower ? max(window.lower, groupStarts[leftEnd]) : window.lower - 1
                while leftEnd >= window.lower || right < window.upper {
                    let takeLeft: Bool
                    if leftEnd < window.lower {
                        takeLeft = false
                    } else if right >= window.upper {
                        takeLeft = true
                    } else {
                        let before = abs(times[left] - source.time), after = abs(times[right] - source.time)
                        takeLeft = before < after || (before == after && candidates[left].offset < candidates[right].offset)
                    }
                    let index: Int
                    if takeLeft {
                        index = left
                        left += 1
                        if left > leftEnd {
                            leftEnd = groupStarts[leftEnd] - 1
                            left = leftEnd >= window.lower ? max(window.lower, groupStarts[leftEnd]) : window.lower - 1
                        }
                    } else {
                        index = right; right += 1
                    }
                    let candidate = candidates[index].element
                    let explicit = candidate.original != nil || candidate.voice != nil
                    guard explicit == wantsExplicit, abs(candidate.time - source.time) <= tolerance,
                          candidate.original == nil || candidate.original == source.text,
                          candidate.voice == nil || candidate.voice == voices[sourceIndex] else { continue }
                    if visit(index) { return true }
                }
            }
            return false
        }

        var sourceMatch = [Int?](repeating: nil, count: sources.count)
        var candidateMatch = [Int?](repeating: nil, count: candidates.count)
        var visitedSources = [Int](repeating: -1, count: sources.count)
        var visitedCandidates = [Int](repeating: -1, count: candidates.count)
        var predecessor = [Int](repeating: -1, count: candidates.count)
        var closedCandidates = [Bool](repeating: false, count: candidates.count)
        var matchedCount = 0
        // Give explicit anchors and closer pairs first choice when several sources compete
        // for a partial translation. Augmentation can still move them to cover more lines.
        let firstChoices = sources.indices.map { source -> Int? in
            var first: Int?
            _ = visitCandidates(for: source) { candidate in first = candidate; return true }
            return first
        }
        let searchOrder = sources.indices.filter { firstChoices[$0] != nil }.sorted { lhs, rhs in
            let a = firstChoices[lhs]!, b = firstChoices[rhs]!
            let aExplicit = candidates[a].element.original != nil || candidates[a].element.voice != nil
            let bExplicit = candidates[b].element.original != nil || candidates[b].element.voice != nil
            if aExplicit != bExplicit { return aExplicit }
            let aDistance = abs(times[a] - sources[lhs].time), bDistance = abs(times[b] - sources[rhs].time)
            return aDistance == bDistance ? lhs < rhs : aDistance < bDistance
        }
        for root in searchOrder {
            if matchedCount == candidates.count { break }
            var pending = [root]
            var head = 0
            visitedSources[root] = root
            var endpoint: Int?
            var reachedCandidates: [Int] = []
            while head < pending.count, endpoint == nil {
                let source = pending[head]
                head += 1
                _ = visitCandidates(for: source) { candidate in
                    guard !closedCandidates[candidate], visitedCandidates[candidate] != root else { return false }
                    visitedCandidates[candidate] = root
                    reachedCandidates.append(candidate)
                    predecessor[candidate] = source
                    guard let owner = candidateMatch[candidate] else {
                        endpoint = candidate
                        return true
                    }
                    if visitedSources[owner] != root {
                        visitedSources[owner] = root
                        pending.append(owner)
                    }
                    return false
                }
            }
            if endpoint == nil {
                // A failed search found a saturated closed set: every compatible edge of
                // its matched owners stays inside this set. Later sources cannot add a
                // free candidate to it. Freeze it rather than repeatedly scanning a dense
                // deficient group (for example thousands of simultaneous untranslated rows).
                for candidate in reachedCandidates { closedCandidates[candidate] = true }
            } else {
                matchedCount += 1
            }
            // Flip the entire alternating path, so every previous covered line stays covered.
            while let candidate = endpoint {
                let source = predecessor[candidate]
                endpoint = sourceMatch[source]
                sourceMatch[source] = candidate
                candidateMatch[candidate] = source
            }
        }

        // Generic rows have only interval constraints. Uncrossing their matches preserves
        // validity and coverage, never increases absolute timestamp distance, and avoids
        // reversing adjacent translated lines just because the later one was a little nearer.
        let genericSources = sources.indices.filter { source in
            guard let match = sourceMatch[source] else { return false }
            return candidates[match].element.original == nil && candidates[match].element.voice == nil
        }
        let genericCandidates = genericSources.compactMap { sourceMatch[$0] }.sorted()
        for (source, candidate) in zip(genericSources, genericCandidates) { sourceMatch[source] = candidate }

        var result: [Int: String] = [:]
        for source in sources.indices {
            if let candidate = sourceMatch[source] { result[sources[source].id] = candidates[candidate].element.text }
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

/// Legacy song-keyed imports. The app only reads these when a listener explicitly attaches one to a version.
public actor LyricTranslationStore {
    public static let shared = LyricTranslationStore()
    private struct Saved: Codable { var songID: String; var document: LyricTranslationDocument }
    private let directory: URL
    private let maximumDocuments: Int
    private let maximumBytes: Int

    public init(directory: URL? = nil, maximumDocuments: Int = .max, maximumBytes: Int = .max) {
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
        let destination = url(for: songID)
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        let others = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "json" && $0 != destination }
        let bytes = try others.reduce(data.count) { try $0 + ($1.resourceValues(forKeys: keys).fileSize ?? 0) }
        guard others.count < maximumDocuments, bytes <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: destination, options: .atomic)
    }

    public func remove(for songID: String) throws {
        let path = url(for: songID)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }

}
