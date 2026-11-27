import CryptoKit
import Foundation

public struct LyricsCandidate: Codable, Equatable, Identifiable, Sendable {
    public struct Identity: Codable, Hashable, Sendable {
        public let source: String
        public let upstream: String?
        public let version: String?
        public let fingerprint: String
        public let cacheNamespace: String

        init(source: String, upstream: String?, version: String?, fingerprint: String) {
            self.source = source
            self.upstream = upstream
            self.version = version
            self.fingerprint = fingerprint
            let components = [source, upstream, version, fingerprint]
            cacheNamespace = LyricsCandidate.digest((try? JSONEncoder().encode(components)) ?? Data())
        }
    }

    public enum Format: String, Codable, Sendable { case word, line, plain }

    public struct Metadata: Codable, Equatable, Sendable {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var duration: TimeInterval?
        public var recordingID: String?
        public var provenance: String?

        public init(title: String? = nil, artist: String? = nil, album: String? = nil, duration: TimeInterval? = nil,
                    recordingID: String? = nil, provenance: String? = nil) {
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let isrc = recordingID?.uppercased().replacingOccurrences(of: "-", with: "")
            self.recordingID = isrc?.range(of: #"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"#, options: .regularExpression) == nil ? nil : isrc
            self.provenance = provenance
        }
    }

    public let id: Identity
    public let songID: String
    public let sourceName: String
    public let metadata: Metadata
    public let lyrics: Lyrics
    /// Optional for backwards compatibility with 0.7.0 candidate files.
    public private(set) var embeddedTranslations: [LyricEmbeddedTranslation]?
    public let original: String?
    public let fetchedAt: Date
    public let match: LyricsMatch
    private let measuredTiming: LyricTimingQuality?
    public var timing: LyricTimingQuality { measuredTiming ?? .measure(lyrics, duration: metadata.duration) }
    public var format: Format { timing.grade >= .partialWords ? .word : timing.grade == .line ? .line : .plain }
    public var lineCount: Int {
        switch lyrics {
        case .synced(let lines): lines.count
        case .plain(let text): Self.plainLines(text).count
        }
    }

    public init(song: Song, source: String, sourceName: String, upstream: String? = nil, version: String? = nil,
                metadata: Metadata, lyrics: Lyrics, original: String? = nil, query: LyricsSearch? = nil,
                embeddedTranslations: [LyricEmbeddedTranslation] = []) {
        id = Identity(source: source, upstream: upstream, version: version,
                      fingerprint: Self.digest((try? JSONEncoder.sorted.encode(lyrics)) ?? Data()))
        songID = song.id
        self.sourceName = sourceName
        self.metadata = metadata
        self.lyrics = lyrics
        self.embeddedTranslations = embeddedTranslations.isEmpty ? nil : embeddedTranslations
        self.original = original
        fetchedAt = Date()
        let measurement = LyricTimingQuality.measure(lyrics, duration: song.duration ?? metadata.duration)
        measuredTiming = measurement
        let quality = measurement.grade >= .highCoverageWords ? 2 : measurement.grade == .plain ? 0 : 1
        match = LyricsMatch.evaluate(query ?? LyricsSearch(song: song), metadata: metadata, quality: quality)
    }

    public static func imported(song: Song, sourceName: String, text: String) -> Self? {
        guard text.utf8.count <= 1_000_000, let payload = Lyrics.parseCandidateFile(text),
              areUsable(payload.lyrics) else { return nil }
        return Self(song: song, source: "local", sourceName: sourceName, metadata: .init(),
                    lyrics: payload.lyrics, original: text, embeddedTranslations: payload.translations)
    }

    public func retainingTranslations(from previous: Self) -> Self {
        guard id == previous.id, songID == previous.songID else { return self }
        var result = self
        var seen = Set<String>()
        let merged = ((embeddedTranslations ?? []) + (previous.embeddedTranslations ?? []))
            .filter { seen.insert($0.id).inserted }
        result.embeddedTranslations = merged.isEmpty ? nil : Array(merged.prefix(12))
        return result
    }

    static func areUsable(_ lyrics: Lyrics) -> Bool {
        switch lyrics {
        case .plain(let text):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .synced(let lines):
            guard !lines.isEmpty, lines.count <= 20_000 else { return false }
            var ids = Set<Int>()
            var previous: TimeInterval = 0
            var hasText = false
            for line in lines {
                guard line.time.isFinite, line.time >= previous, line.time <= 604_800,
                      ids.insert(line.id).inserted,
                      line.end.map({ $0.isFinite && $0 >= line.time }) ?? true,
                      line.words.allSatisfy(isValidWord),
                      line.background.allSatisfy(isValidWord) else { return false }
                previous = line.time
                hasText = hasText || !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return hasText
        }
    }

    private static func isValidWord(_ word: LyricWord) -> Bool {
        word.start.isFinite && word.end.isFinite && word.start >= 0 && word.end >= word.start
    }

    public static func plainLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public struct LyricsSearch: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var duration: TimeInterval?
    public var credits: [String]

    public init(song: Song) {
        title = song.title
        let primaryArtist = song.artists.first?.name ?? song.artistLine
        artist = primaryArtist
        album = song.album?.title
        duration = song.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        credits = (song.artists.map(\.name) + [song.artistLine]).filter { !$0.isEmpty && $0 != primaryArtist }
    }

    var query: LyricsQuery {
        LyricsQuery(title: title, artist: artist, album: album, duration: duration, artistCredits: credits)
    }
}

public struct LyricsMatch: Codable, Equatable, Sendable {
    public enum Confidence: String, Codable, Sendable { case high, medium, low, conflict }
    public enum Evidence: String, Codable, Sendable {
        case title, artist, duration, recording, album, differentTitle, differentArtist, differentDuration, differentRecording, missingMetadata
    }
    public let identityScore: Double
    public let evidenceWeight: Double
    public let timingQuality: Double
    public let confidence: Confidence
    public let evidence: [Evidence]

    public var score: Double { identityScore + timingQuality }

    static func evaluate(_ search: LyricsSearch, metadata: LyricsCandidate.Metadata, quality: Int) -> Self {
        var identity = 0.0
        var weight = 0.0
        var evidence: [Evidence] = []
        var conflict = false
        func compare(_ amount: Double, agrees: Bool, good: Evidence, bad: Evidence?, fraction: Double = 1) {
            weight += amount
            if agrees { identity += amount * fraction; evidence.append(good) }
            else if let bad { conflict = true; evidence.append(bad) }
        }

        if let title = metadata.title, !title.isEmpty, !search.title.isEmpty {
            let lhs = recording(LyricsQuery.lookupTitle(search.title))
            let rhs = recording(LyricsQuery.lookupTitle(title))
            let matches = !lhs.title.isEmpty && lhs.title == rhs.title
            compare(25, agrees: matches, good: .title, bad: .differentTitle)
            compare(15, agrees: lhs.tags == rhs.tags, good: .recording, bad: .differentRecording)
        }
        if let artist = metadata.artist, !artist.isEmpty, !search.artist.isEmpty {
            let wanted = artistNames([search.artist] + search.credits)
            let actual = artistNames([artist])
            let matches = !wanted.isDisjoint(with: actual)
            compare(25, agrees: matches, good: .artist, bad: .differentArtist)
        }
        if let duration = search.duration, duration > 0, let actual = metadata.duration {
            let delta = abs(duration - actual)
            let tolerance = min(12, max(3, duration * 0.035))
            compare(25, agrees: delta <= tolerance, good: .duration, bad: .differentDuration,
                    fraction: max(0.5, 1 - delta / (2 * tolerance)))
        }
        if let wanted = search.album, let found = metadata.album, !wanted.isEmpty, !found.isEmpty {
            compare(5, agrees: LyricsQuery.identity(wanted) == LyricsQuery.identity(found), good: .album, bad: nil)
        }
        if weight < 95 { evidence.append(.missingMetadata) }
        let confidence: Confidence = if conflict { .conflict }
        else if identity >= 77 && evidence.contains(.title) && evidence.contains(.artist) { .high }
        else if evidence.contains(.title) && evidence.contains(.artist) { .medium }
        else { .low }
        return Self(identityScore: identity, evidenceWeight: weight, timingQuality: Double(quality) * 2.5,
                    confidence: confidence, evidence: evidence)
    }

    private static func artistNames(_ names: [String]) -> Set<String> {
        Set(names.flatMap { name -> [String] in
            let clean = LyricsQuery.lookupArtist(name)
            let parts = clean.replacingOccurrences(of: #"\b(?:feat\.?|ft\.?|featuring|with)\s+"#,
                with: " & ", options: [.regularExpression, .caseInsensitive])
                .components(separatedBy: CharacterSet(charactersIn: "&、,，×"))
            return [clean] + LyricsQuery.artistAliases(clean) + parts.filter { $0.trimmingCharacters(in: .whitespaces).count >= 2 }
        }.map(LyricsQuery.identity).filter { !$0.isEmpty })
    }

    private static func recording(_ title: String) -> (title: String, tags: Set<String>) {
        let markers: [(String, String)] = [
            ("live", "live|concert|現場|现场|라이브|ライブ"), ("cover", "cover|翻唱|カバー|커버"),
            ("remix", "remix|混音|リミックス|리믹스"), ("acoustic", "acoustic|unplugged|不插電|不插电"),
            ("instrumental", "instrumental|karaoke|伴奏|純音樂|纯音乐"),
            ("sped", "sped[ -]?up|speed[ -]?up|加速"), ("slow", "slowed|慢速|降速"), ("nightcore", "nightcore"),
            ("radio", "radio[ -]?edit|radio[ -]?version"), ("extended", "extended[ -]?mix|extended[ -]?version"),
        ]
        let qualifier = try! NSRegularExpression(pattern: #"\s*(?:[\(\[（【]([^\)\]）】]+)[\)\]）】]|\s+[-–—|]\s+([^\[\(（【]+))"#)
        var result = title
        var tags: Set<String> = []
        for match in qualifier.matches(in: title, range: NSRange(title.startIndex..., in: title)).reversed() {
            let part = (1...2).compactMap { Range(match.range(at: $0), in: title).map { String(title[$0]) } }.joined()
            let found = markers.filter { part.range(of: "(?i)(?:\\b|(?=[^\\x00-\\x7F]))(?:" + $0.1 + ")(?:\\b|$|(?=[^\\x00-\\x7F]))", options: .regularExpression) != nil }
            guard !found.isEmpty, let range = Range(match.range, in: result) else { continue }
            tags.formUnion(found.map(\.0))
            result.removeSubrange(range)
        }
        return (LyricsQuery.identity(result), tags)
    }
}

public struct LyricsSourceResult: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case found, empty, timedOut, invalid, rateLimited, failed, cancelled }
    public var source: String
    public var name: String
    public var state: State
    public var candidates: [LyricsCandidate]

    public init(source: String, name: String, state: State, candidates: [LyricsCandidate] = []) {
        self.source = source
        self.name = name
        self.state = state
        var indices: [LyricsCandidate.Identity: Int] = [:]
        var unique: [LyricsCandidate] = []
        for candidate in candidates {
            if let index = indices[candidate.id] {
                unique[index] = unique[index].retainingTranslations(from: candidate)
            } else {
                indices[candidate.id] = unique.count
                unique.append(candidate)
            }
        }
        self.candidates = unique
    }
}

/// Keeps an automatically presented version stable as later candidates arrive.
public struct LyricsVersionSelection: Sendable {
    public private(set) var current: LyricsCandidate?
    public private(set) var preferred: LyricsCandidate.Identity?

    public init(preferred: LyricsCandidate? = nil) {
        current = preferred
        self.preferred = preferred?.id
    }

    public static func recommended(_ candidates: [LyricsCandidate], allowLowConfidence: Bool,
                                   assessments: [LyricsCandidate.Identity: LyricsCandidateAssessment]? = nil) -> LyricsCandidate? {
        let assessments = assessments ?? LyricsCandidateEvaluator.evaluate(candidates)
        let eligible = candidates.filter { candidate in
            candidate.match.confidence != .conflict && candidate.timing.invalidTimes == 0
                && assessments[candidate.id]?.excludesAutomaticSelection != true
        }
        let trusted = eligible.filter {
            [.medium, .high].contains($0.match.confidence) || assessments[$0.id]?.content == .verified
        }
        if !trusted.isEmpty {
            return trusted.max { left, right in
                if left.timing.grade != right.timing.grade { return left.timing.grade < right.timing.grade }
                if left.timing.wordCoverage != right.timing.wordCoverage { return left.timing.wordCoverage < right.timing.wordCoverage }
                let leftVerified = assessments[left.id]?.content == .verified
                let rightVerified = assessments[right.id]?.content == .verified
                if leftVerified != rightVerified { return !leftVerified }
                return left.match.identityScore < right.match.identityScore
            }
        }
        guard allowLowConfidence else { return nil }
        return eligible.max { left, right in
            if left.match.identityScore != right.match.identityScore { return left.match.identityScore < right.match.identityScore }
            return left.timing.grade < right.timing.grade
        }
    }

    public mutating func offer(_ candidates: [LyricsCandidate], finished: Bool) {
        guard current == nil else { return }
        current = Self.recommended(candidates, allowLowConfidence: finished)
    }
}
