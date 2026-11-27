import Foundation

/// One sung word, or part of one: providers split long words into syllables.
public struct LyricWord: Hashable, Codable, Sendable {
    public var text: String
    /// Seconds from the start of the song.
    public var start: TimeInterval
    public var end: TimeInterval
    /// A space follows before the next word; false between syllables of one word.
    public var spaceAfter: Bool

    public init(text: String, start: TimeInterval, end: TimeInterval, spaceAfter: Bool = true) {
        self.text = text
        self.start = start
        self.end = end
        self.spaceAfter = spaceAfter
    }

    public var duration: TimeInterval { max(end - start, 0.001) }
}

/// Who sings a line, when the lyrics say.
public enum LyricVoice: Hashable, Codable, Sendable {
    /// The main singer, or the only one.
    case lead
    /// The second singer of a duet.
    case duet
    /// Several singers at once.
    case together
}

public struct LyricLine: Hashable, Codable, Sendable, Identifiable {
    public var id: Int
    /// Seconds from the start of the song.
    public var time: TimeInterval
    public var text: String
    /// Word timings, when the provider has them; empty for line-timed lyrics.
    public var words: [LyricWord]
    /// Backing vocals sung over the line, timed the same way.
    public var background: [LyricWord]
    /// When the line is done; nil when only its start is known.
    public var end: TimeInterval?
    public var voice: LyricVoice

    public init(id: Int, time: TimeInterval, text: String, words: [LyricWord] = [], background: [LyricWord] = [],
                end: TimeInterval? = nil, voice: LyricVoice = .lead) {
        self.id = id
        self.time = time
        self.text = text
        self.words = words
        self.background = background
        self.end = end
        self.voice = voice
    }

    public var isWordTimed: Bool { !words.isEmpty }
}

public enum Lyrics: Codable, Sendable, Equatable {
    case synced([LyricLine])
    case plain(String)

    /// The compatibility lookup promotes only substantially word-synchronized lyrics.
    var quality: Int {
        switch LyricTimingQuality.measure(self, duration: nil).grade {
        case .plain: 0
        case .line, .partialWords: 1
        case .highCoverageWords, .completeWords: 2
        }
    }

    /// The line playing at `time`: the last one that has started.
    public static func index(of time: TimeInterval, in lines: [LyricLine]) -> Int? {
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// `[mm:ss.xx] text` lines, with `<mm:ss.xx>` word stamps when the file has them
    /// (enhanced LRC). Several line stamps repeat the line; lines without one are dropped.
    public static func parseLRC(_ text: String) -> [LyricLine] {
        struct Raw { var time: TimeInterval; var text: String; var words: [LyricWord] }
        var lines: [Raw] = []
        let clean = text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        let offsetTag = /(?i)\[offset:\s*([+-]?\d{1,8})\s*\]/
        let milliseconds = clean.matches(of: offsetTag).last.flatMap { Double($0.output.1) } ?? 0
        let offset = abs(milliseconds) <= 600_000 ? milliseconds / 1000 : 0
        let stamp = /\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]/
        let wordStamp = /<(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)>/
        func seconds(_ minutes: Substring, _ rest: Substring) -> TimeInterval? {
            guard let minutes = Double(minutes),
                  let seconds = Double(rest.replacingOccurrences(of: ":", with: ".")), seconds < 60 else { return nil }
            // LRC's positive file offset advances the written timestamps. The
            // listener's positive display delay is a separate, later operation.
            return max(0, minutes * 60 + seconds - offset)
        }
        for raw in clean.split(whereSeparator: \.isNewline) {
            let matches = raw.matches(of: stamp).filter { seconds($0.output.1, $0.output.2) != nil }
            guard let last = matches.last else { continue }
            let body = raw[last.range.upperBound...]
            let wordMatches = body.matches(of: wordStamp).filter { seconds($0.output.1, $0.output.2) != nil }
            var words: [LyricWord] = []
            for (index, match) in wordMatches.enumerated() {
                let textEnd = index + 1 < wordMatches.count ? wordMatches[index + 1].range.lowerBound : body.endIndex
                let segment = body[match.range.upperBound..<textEnd]
                let trimmed = segment.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let start = seconds(match.output.1, match.output.2) else { continue }
                let end = index + 1 < wordMatches.count
                    ? seconds(wordMatches[index + 1].output.1, wordMatches[index + 1].output.2) ?? start : start
                words.append(LyricWord(text: trimmed, start: start, end: end, spaceAfter: segment.last?.isWhitespace ?? true))
            }
            let display = body.replacing(wordStamp, with: "").trimmingCharacters(in: .whitespaces)
            for (index, match) in matches.enumerated() {
                // Word stamps belong to the first time the line is sung; repeats are line-timed.
                guard let start = seconds(match.output.1, match.output.2) else { continue }
                lines.append(Raw(time: start, text: display, words: index == 0 ? words : []))
            }
        }
        let sorted = lines.sorted { $0.time < $1.time }
        var result = finish(sorted.map { LyricLine(id: 0, time: $0.time, text: $0.text, words: $0.words) })
        // A same-time occurrence keeps its own identity and shares the next distinct
        // boundary. A plain LRC last line should not occupy the entire outro.
        var next: TimeInterval?
        for index in result.indices.reversed() {
            if index + 1 < result.count, result[index + 1].time > result[index].time { next = result[index + 1].time }
            if result[index].end == nil || result[index].end == result[index].time {
                result[index].end = next ?? result[index].time + 5
            }
        }
        return result
    }

    /// Number the lines in order, and fill in end times a provider left out:
    /// a word ends where the next starts, a line where the next line starts.
    static func finish(_ lines: [LyricLine]) -> [LyricLine] {
        let sorted = lines.sorted { $0.time < $1.time }
        return sorted.enumerated().map { index, line in
            var line = line
            line.id = index
            let nextLine = index + 1 < sorted.count ? sorted[index + 1].time : nil
            let fallbackEnd = nextLine.map { max($0, line.time) } ?? line.time + 5
            line.words = complete(line.words, lineEnd: line.end ?? fallbackEnd)
            line.background = complete(line.background, lineEnd: line.end ?? fallbackEnd)
            if line.end == nil {
                line.end = (line.words + line.background).map(\.end).max() ?? nextLine
            }
            return line
        }
    }

    private static func complete(_ words: [LyricWord], lineEnd: TimeInterval) -> [LyricWord] {
        let sorted = words.sorted { $0.start < $1.start }
        return sorted.enumerated().map { index, word in
            guard word.end <= word.start else { return word }
            var word = word
            let next = index + 1 < sorted.count ? sorted[index + 1].start : lineEnd
            word.end = word.start + min(max(next - word.start, 0.08), 10)
            return word
        }
    }

    /// Lead and duet by alternating singers; a group agent sings together. One singer is always lead.
    static func voices(for agents: [String?], groups: Set<String>) -> [LyricVoice] {
        var people: [String] = []
        for agent in agents.compactMap({ $0 }) where !groups.contains(agent) && !people.contains(agent) { people.append(agent) }
        guard people.count >= 2 else { return agents.map { _ in .lead } }
        return agents.map { agent in
            guard let agent else { return .lead }
            if groups.contains(agent) { return .together }
            return (people.firstIndex(of: agent) ?? 0) % 2 == 1 ? .duet : .lead
        }
    }
}
