import Foundation

/// Provider-only lookup variants. Song metadata and lyric text are never rewritten.
/// Presentation labels may differ between YouTube and a lyric catalogue, while a
/// recording qualifier (live/remix/acoustic/etc.) must remain part of the identity.
struct LyricsQuery: Sendable, Hashable {
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    /// Additional complete credits supplied by the song, never guessed collaborators.
    var artistCredits: [String] = []

    /// Keep the original first, then a small, deterministic set of fallbacks. The
    /// provider decides which variants fit within its request/time budget.
    func variants() -> [LyricsQuery] {
        var result = [self]
        func append(_ value: LyricsQuery) {
            guard result.count < 6, !result.contains(value), !value.title.isEmpty, !value.artist.isEmpty else { return }
            result.append(value)
        }
        let cleaned = LyricsQuery(title: Self.lookupTitle(title), artist: Self.lookupArtist(artist),
                                  album: nil, duration: duration, artistCredits: artistCredits)
        append(cleaned)
        for credit in artistCredits.map(Self.lookupArtist) where !credit.isEmpty && credit != cleaned.artist {
            var alternate = cleaned
            alternate.artist = credit
            append(alternate)
            append(alternate.converted(toTraditional: false))
        }
        let simplified = cleaned.converted(toTraditional: false)
        append(simplified)
        for alias in ([cleaned.artist] + artistCredits.map(Self.lookupArtist)).flatMap(Self.artistAliases) {
            var alternate = cleaned
            alternate.artist = alias
            append(alternate)
            append(alternate.converted(toTraditional: false))
        }
        append(cleaned.converted(toTraditional: true))
        return result
    }

    /// Search endpoints can return unrelated popular songs. Accept only the same
    /// normalized title and full artist or an explicit bilingual artist alias.
    /// Retaining recording qualifiers also prevents studio lyrics matching a live cut.
    func candidateScore(title candidateTitle: String, artist candidateArtist: String,
                        duration candidateDuration: TimeInterval?) -> Double? {
        let wantedTitle = Self.identity(Self.lookupTitle(title))
        let foundTitle = Self.identity(Self.lookupTitle(candidateTitle))
        guard !wantedTitle.isEmpty, wantedTitle == foundTitle else { return nil }
        let wantedArtist = Self.lookupArtist(artist)
        let foundArtist = Self.lookupArtist(candidateArtist)
        let knownCredits = ([wantedArtist] + artistCredits.map(Self.lookupArtist)).filter { !$0.isEmpty }
        let directCredits = Set(knownCredits.map(Self.identity))
        let wanted = Set(knownCredits.flatMap { [$0] + Self.artistAliases($0) }.map(Self.identity).filter { !$0.isEmpty })
        let found = Set(([foundArtist] + Self.artistAliases(foundArtist)).map(Self.identity).filter { !$0.isEmpty })
        guard !wanted.isDisjoint(with: found) else { return nil }
        var score = directCredits.contains(Self.identity(foundArtist)) ? 120.0 : 110.0
        if let duration, duration.isFinite, duration > 0,
           let candidateDuration, candidateDuration.isFinite, candidateDuration > 0 {
            let difference = abs(duration - candidateDuration)
            guard difference <= 10 else { return nil }
            score += 20 - difference
        }
        return score
    }

    private func converted(toTraditional: Bool) -> LyricsQuery {
        let transform = StringTransform(rawValue: toTraditional ? "Simplified-Traditional" : "Traditional-Simplified")
        return LyricsQuery(title: title.applyingTransform(transform, reverse: false) ?? title,
                           artist: artist.applyingTransform(transform, reverse: false) ?? artist,
                           album: nil, duration: duration, artistCredits: artistCredits)
    }

    private static func spaces(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func lookupArtist(_ text: String) -> String {
        spaces(text.replacingOccurrences(of: #"\s+[-–—]\s*Topic\s*$"#, with: "",
                                         options: [.regularExpression, .caseInsensitive]))
    }

    private static func lookupTitle(_ text: String) -> String {
        var result = spaces(text)
        // Deliberately recognize complete tags only: `(Live Official Video)` still
        // contains recording information, and must not turn into a studio title.
        let expression = try! NSRegularExpression(pattern: #"[\(\[（【]([^()\[\]（）【】]+)[\)\]）】]"#)
        for match in expression.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let bodyRange = Range(match.range(at: 1), in: result),
                  isPresentationTag(String(result[bodyRange])),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: " ")
        }
        result = spaces(result)
        var removedSuffix = true
        while removedSuffix {
            removedSuffix = false
            for separator in [" - ", " – ", " — ", " | ", " • "] {
                if let range = result.range(of: separator, options: .backwards),
                   isPresentationTag(String(result[range.upperBound...])) {
                    result = spaces(String(result[..<range.lowerBound]))
                    removedSuffix = true
                }
            }
        }
        // A title consisting only of an unusual presentation tag is still a title.
        return result.isEmpty ? spaces(text) : result
    }

    private static func isPresentationTag(_ text: String) -> Bool {
        var key = identity(text)
        let labels: Set<String> = [
            "officialvideo", "officialmusicvideo", "officialaudio", "officiallyricvideo",
            "officiallyricsvideo", "lyricvideo", "lyricsvideo", "lyrics", "lyric",
            "musicvideo", "mv", "officialvisualizer", "visualizer", "hd", "hq", "4k", "1080p", "720p",
            "官方音乐录影带", "官方音乐录像带", "官方mv", "官方歌词版", "歌词版", "字幕版", "中英字幕",
        ]
        if labels.contains(key) { return true }
        for suffix in ["1080p", "720p", "4k", "hd", "hq"] where key.hasSuffix(suffix) {
            key.removeLast(suffix.count)
            return labels.contains(key)
        }
        return false
    }

    private static func identity(_ text: String) -> String {
        let simplified = text.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? text
        let folded = simplified.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Common catalogue credits use `南征北战 NZBZ` or `JJ Lin 林俊傑`.
    /// Do not split collaborations, short initials, arbitrary Latin names or word lists.
    private static func artistAliases(_ text: String) -> [String] {
        let forward = #"^([\p{Han}]{2,})\s+([A-Za-z][A-Za-z0-9 .'-]{2,})$"#
        let reverse = #"^([A-Za-z][A-Za-z0-9 .'-]{2,})\s+([\p{Han}]{2,})$"#
        for (pattern, hanIndex, latinIndex) in [(forward, 1, 2), (reverse, 2, 1)] {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let hanRange = Range(match.range(at: hanIndex), in: text),
                  let latinRange = Range(match.range(at: latinIndex), in: text) else { continue }
            let han = String(text[hanRange]), latin = spaces(String(text[latinRange]))
            let words = latin.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard !words.contains(where: { ["feat", "ft", "featuring", "with", "and", "vs", "topic"].contains($0) }),
                  latin.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count >= 3 else { continue }
            return [han, latin]
        }
        return []
    }
}
