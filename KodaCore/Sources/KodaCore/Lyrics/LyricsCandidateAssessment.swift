import Foundation

public struct LyricTimingQuality: Codable, Equatable, Sendable {
    public enum Grade: Int, Codable, Comparable, Sendable {
        case plain, line, partialWords, highCoverageWords, completeWords
        public static func < (left: Self, right: Self) -> Bool { left.rawValue < right.rawValue }
    }

    public let grade: Grade
    public let wordCoverage: Double
    public let timedLines: Int
    public let sungLines: Int
    public let invalidTimes: Int
    public let textMismatches: Int
    public let voicedLines: Int
    public var untimedWordLines: Int { sungLines - timedLines }

    public static func measure(_ lyrics: Lyrics, duration: TimeInterval?) -> Self {
        guard case .synced(let lines) = lyrics else {
            return .init(grade: .plain, wordCoverage: 0, timedLines: 0, sungLines: 0,
                         invalidTimes: 0, textMismatches: 0, voicedLines: 0)
        }
        let limit = duration.flatMap { $0.isFinite && $0 > 0 ? $0 + max(2, $0 * 0.035) : nil }
        var bad = 0, textMismatches = 0, full = 0, total = 0, voiced = 0, covered = 0, characters = 0
        var previousStart: TimeInterval = 0
        for line in lines {
            let timeOK = line.time.isFinite && line.time >= previousStart && line.time >= 0
                && (limit.map { line.time <= $0 } ?? true)
            if !timeOK { bad += 1 }
            else { previousStart = line.time }
            if let end = line.end, !end.isFinite || end < line.time || (limit.map { end > $0 + 2 } ?? false) {
                bad += 1
            }
            if line.voice != .lead || !line.background.isEmpty { voiced += 1 }
            let source = LyricsVerificationText.tokens(line.text)
            let size = source.joined().count
            if size > 0 {
                total += 1
                characters += size
            }
            var wordStart: TimeInterval?
            var verified: [String] = []
            for word in line.words {
                let valid = word.start.isFinite && word.end.isFinite && word.start >= 0 && word.end > word.start
                    && word.start >= line.time - 1.0
                    && (wordStart.map { word.start >= $0 - 0.04 } ?? true)
                    && (limit.map { word.end <= $0 + 1 } ?? true)
                    && (line.end.map { word.start <= $0 + 0.75 } ?? true)
                if valid, timeOK {
                    wordStart = word.start
                    verified.append(word.text)
                    if word.spaceAfter { verified.append(" ") }
                } else { bad += 1 }
            }
            // Each backing voice may legitimately overlap the main singer and
            // another background part. It is evaluated against the song clock.
            for word in line.background where !word.start.isFinite || !word.end.isFinite
                || word.start < 0 || word.end <= word.start || (limit.map { word.end > $0 + 1 } ?? false) {
                bad += 1
            }
            guard size > 0, !verified.isEmpty else { continue }
            let words = LyricsVerificationText.tokens(verified.joined())
            if source == words {
                full += 1
                covered += size
            } else {
                textMismatches += 1
                // Only ordered matching words are counted. A few timestamps
                // attached to different text cannot claim full word coverage.
                var cursor = source.startIndex
                for word in words {
                    if let match = source[cursor...].firstIndex(of: word) {
                        covered += word.count
                        cursor = source.index(after: match)
                    }
                }
            }
        }
        let coverage = characters > 0 ? Double(covered) / Double(characters) : 0
        let grade: Grade
        if total > 0, full == total, bad == 0 { grade = .completeWords }
        else if coverage >= 0.90, full * 10 >= total * 8, bad == 0 { grade = .highCoverageWords }
        else if covered > 0 { grade = .partialWords }
        else { grade = .line }
        return .init(grade: grade, wordCoverage: coverage, timedLines: full, sungLines: total,
                     invalidTimes: bad, textMismatches: textMismatches, voicedLines: voiced)
    }
}

public struct LyricsCandidateAssessment: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case unconfirmed, textAgrees, verified, differentRecording, conflict
    }
    public let timing: LyricTimingQuality
    public var content: Content = .unconfirmed
    public var comparedSource: String?
    public var similarity: Double?
    public var completeness: Double?
    public var independentSources = 0

    public var excludesAutomaticSelection: Bool {
        timing.invalidTimes > 0 || content == .conflict || content == .differentRecording
    }
}

public enum LyricsCandidateEvaluator {
    private static let maximumCandidates = 32
    private static let maximumAnchors = 5
    private static let minimumComparableLines = 4
    private static let minimumAgreement = 0.93
    private static let minimumCompleteness = 0.88

    private struct Comparison {
        let completeness: Double
        let similarity: Double
        let sameWords: Bool
        let negationsAgree: Bool
        let temporal: Bool?
    }

    public actor Cache {
        private var pairs: [String: Comparison] = [:]

        public init() {}

        public func evaluate(_ candidates: [LyricsCandidate]) -> [LyricsCandidate.Identity: LyricsCandidateAssessment] {
            if pairs.count > 384 { pairs.removeAll(keepingCapacity: true) }
            return LyricsCandidateEvaluator.evaluate(candidates, pairs: &pairs)
        }
    }

    public static func evaluate(_ candidates: [LyricsCandidate]) -> [LyricsCandidate.Identity: LyricsCandidateAssessment] {
        var pairs: [String: Comparison] = [:]
        return evaluate(candidates, pairs: &pairs)
    }

    private static func evaluate(_ candidates: [LyricsCandidate], pairs: inout [String: Comparison])
        -> [LyricsCandidate.Identity: LyricsCandidateAssessment] {
        var counts: [String: Int] = [:]
        let candidates = Array(candidates.filter {
            counts[$0.id.source, default: 0] += 1
            return counts[$0.id.source, default: 0] <= 8
        }.prefix(maximumCandidates))
        var output: [LyricsCandidate.Identity: LyricsCandidateAssessment] = [:]
        var profiles: [String: LyricsVerificationText] = [:]
        for candidate in candidates {
            if Task.isCancelled { return [:] }
            if profiles[candidate.id.fingerprint] == nil { profiles[candidate.id.fingerprint] = .init(candidate.lyrics) }
            output[candidate.id] = .init(timing: candidate.timing)
        }
        let ranked = candidates.filter {
            [.medium, .high].contains($0.match.confidence)
                && $0.match.evidence.contains(.title) && $0.match.evidence.contains(.artist)
                && $0.timing.invalidTimes == 0
        }.sorted { $0.match.identityScore > $1.match.identityScore }
        var known = Set<String>()
        let anchors = ranked.filter { candidate in
            guard let upstream = verificationOrigin(candidate) else { return false }
            return known.insert(upstream).inserted
        }.prefix(maximumAnchors)

        for candidate in candidates where candidate.match.confidence != .conflict {
            if Task.isCancelled { return [:] }
            guard let origin = verificationOrigin(candidate), let profile = profiles[candidate.id.fingerprint],
                  profile.canCompare, var assessed = output[candidate.id] else { continue }
            var agreements = Set<String>()
            var resultRank = 0
            for anchor in anchors where anchor.id != candidate.id {
                guard let otherOrigin = verificationOrigin(anchor), otherOrigin != origin,
                      let other = profiles[anchor.id.fingerprint], other.canCompare else { continue }
                let pair = candidate.id.fingerprint + ":" + anchor.id.fingerprint
                let comparison: Comparison
                if let saved = pairs[pair] { comparison = saved }
                else {
                    let completeness = Double(min(profile.tokens.count, other.tokens.count)) / Double(max(profile.tokens.count, other.tokens.count))
                    let similarity = profile.similarity(to: other)
                    let negationsAgree = profile.negations == other.negations
                    let voicesAgree = profile.backing.isEmpty || other.backing.isEmpty || profile.backing == other.backing
                    let agrees = similarity >= minimumAgreement && completeness >= minimumCompleteness && negationsAgree && voicesAgree
                    comparison = .init(completeness: completeness, similarity: similarity, sameWords: agrees,
                                       negationsAgree: negationsAgree, temporal: agrees ? profile.timingAgreement(with: other) : nil)
                    if !Task.isCancelled { pairs[pair] = comparison }
                }
                let completeness = comparison.completeness
                let similarity = comparison.similarity
                let sameWords = comparison.sameWords
                let recordingConflict = candidate.metadata.recordingID.flatMap { id in
                    anchor.metadata.recordingID.map { id != $0 }
                } ?? false
                let temporal = comparison.temporal
                let content: LyricsCandidateAssessment.Content
                let rank: Int
                if sameWords && !recordingConflict && temporal == true {
                    content = .verified
                    rank = 4
                    agreements.insert(otherOrigin)
                } else if sameWords && (recordingConflict || temporal == false) {
                    content = .differentRecording
                    rank = 2
                } else if sameWords {
                    content = .textAgrees
                    rank = 3
                } else if similarity < 0.74 || !comparison.negationsAgree {
                    content = .conflict
                    rank = 1
                } else { continue }
                if rank > resultRank || (rank == resultRank && similarity > (assessed.similarity ?? 0)) {
                    resultRank = rank
                    assessed.content = content
                    assessed.comparedSource = anchor.sourceName
                    assessed.similarity = similarity
                    assessed.completeness = completeness
                }
            }
            assessed.independentSources = agreements.count
            output[candidate.id] = assessed
        }
        return output
    }

    /// Only named upstream catalogues can corroborate. Mirrors and aggregators
    /// without provenance confer no independence.
    static func verificationOrigin(_ candidate: LyricsCandidate) -> String? {
        if let raw = (candidate.id.upstream ?? candidate.metadata.provenance)?.lowercased().filter({ $0.isLetter || $0.isNumber }) {
            switch raw {
            case "apple", "qapple", "applemusic", "qapplemusic": return "apple"
            case "kugou", "qkugou": return "kugou"
            case "musixmatch", "qmusixmatch", "mxm": return "musixmatch"
            case "lrclib": return "lrclib"
            case "qq", "qqmusic", "qqq": return "qq"
            case "netease", "neteasemusic": return "netease"
            default: break
            }
        }
        return candidate.id.source == LyricsSource.lrclib.rawValue ? "lrclib" : nil
    }

    static func isLongEnoughToAlign(_ count: Int) -> Bool { count >= minimumComparableLines }
}

private struct LyricsVerificationText {
    struct Row {
        var tokens: [String]
        var offset: Int
        var time: TimeInterval?
    }

    let tokens: [String]
    let rows: [Row]
    let negations: [String]
    let backing: [String]
    let canCompare: Bool

    init(_ lyrics: Lyrics) {
        let input: [(String, TimeInterval?)]
        switch lyrics {
        case .plain(let text):
            input = LyricsCandidate.plainLines(text).map { ($0, nil) }
            backing = []
        case .synced(let lines):
            input = lines.map { ($0.text, $0.time) }
            backing = lines.prefix(224).flatMap { row in Self.tokens(Lyrics.joined(row.background)) }
        }
        var rows: [Row] = []
        var sequence: [String] = []
        var exceeded = false
        for (text, time) in input {
            // A limit also rejects a prefix-only comparison for oversized files.
            guard rows.count < 224, text.utf8.count <= 4096 else { exceeded = true; break }
            let words = Self.tokens(text)
            guard !words.isEmpty else { continue }
            guard sequence.count + words.count <= 1800 else { exceeded = true; break }
            rows.append(.init(tokens: words, offset: sequence.count, time: time))
            sequence += words
        }
        tokens = sequence
        self.rows = rows
        canCompare = !exceeded && (sequence.count >= 12 || rows.count >= 4)
        let negative: Set<String> = ["no", "not", "never", "cannot", "nothing", "neither", "nor", "不", "未", "無", "无", "沒", "没", "別", "别"]
        negations = sequence.filter { negative.contains($0) || $0.hasSuffix("n't") }
    }

    static func tokens(_ input: String) -> [String] {
        let normalized = input.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty {
                let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                if !trimmed.isEmpty { tokens.append(trimmed) }
                word = ""
            }
        }
        for character in normalized {
            let cjk = character.unicodeScalars.contains { scalar in
                (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
                    || (0xAC00...0xD7AF).contains(scalar.value)
            }
            if cjk { flush(); tokens.append(String(character)) }
            else if character == "'" || character.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) {
                word.append(character)
            } else { flush() }
        }
        flush()
        return tokens
    }

    func similarity(to other: Self) -> Double {
        guard tokens != other.tokens else { return 1 }
        let n = tokens.count, m = other.tokens.count
        let longest = max(n, m)
        let band = max(4, longest * 27 / 100)
        guard longest > 0, abs(n - m) <= band else { return 0 }
        var previous = Array(0...m)
        var current = Array(repeating: band + longest + 1, count: m + 1)
        let outside = band + longest + 1
        guard n > 0, m > 0 else { return 0 }
        for i in 1...n {
            if Task.isCancelled { return 0 }
            let first = max(1, i - band), last = min(m, i + band)
            current[first - 1] = first == 1 ? i : outside
            if first <= last {
                for j in first...last {
                    current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                     previous[j - 1] + (tokens[i - 1] == other.tokens[j - 1] ? 0 : 1))
                }
            }
            if last < m { current[last + 1] = outside }
            swap(&current, &previous)
        }
        return max(0, 1 - Double(previous[m]) / Double(longest))
    }

    func timingAgreement(with other: Self) -> Bool? {
        guard rows.first?.time != nil, other.rows.first?.time != nil else { return nil }
        var differences: [Double] = []
        if tokens == other.tokens {
            // Token positions retain repetition. Identical choruses from a
            // different occurrence cannot be matched merely by their text.
            let times = Dictionary(other.rows.map { ($0.offset, $0.time ?? 0) }, uniquingKeysWith: { first, _ in first })
            differences = rows.compactMap { row in times[row.offset].map { (row.time ?? 0) - $0 } }
        } else {
            // Only identical lines, in order, within a bounded sequence window.
            var last = -1
            for (i, row) in rows.enumerated() {
                let start = max(last + 1, i - 8)
                let end = min(other.rows.count, i + 9)
                guard start < end else { continue }
                let matches = (start..<end).filter { other.rows[$0].tokens == row.tokens }
                guard matches.count == 1, let index = matches.first else { continue }
                differences.append((row.time ?? 0) - (other.rows[index].time ?? 0))
                last = index
            }
        }
        guard LyricsCandidateEvaluator.isLongEnoughToAlign(differences.count),
              differences.count * 4 >= min(rows.count, other.rows.count) * 3 else { return nil }
        let magnitudes = differences.map(abs).sorted()
        let median = magnitudes[magnitudes.count / 2]
        let p90 = magnitudes[min(magnitudes.count - 1, magnitudes.count * 9 / 10)]
        return median <= 1.15 && p90 <= 2.75
    }
}
