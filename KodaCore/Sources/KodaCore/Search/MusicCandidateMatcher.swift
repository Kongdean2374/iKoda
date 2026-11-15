import Foundation

public struct MusicRecognitionCandidate: Identifiable, Equatable, Sendable {
    public enum Confidence: Equatable, Sendable { case close, needsReview, differentVersion }
    public var song: Song
    public var confidence: Confidence
    public var id: String { song.id }
    public init(song: Song, confidence: Confidence) { self.song = song; self.confidence = confidence }
}

/// Metadata helps order the choices, not decide what to save. Versions remain visible
/// and always require the listener to choose; Shazam and YouTube IDs are not equivalent.
public enum MusicCandidateMatcher {
    private struct RankedCandidate {
        let sourceIndex: Int
        let score: Double
        let candidate: MusicRecognitionCandidate
    }

    public static func rank(_ songs: [Song], for recognized: RecognizedMusic, limit: Int = 20) -> [MusicRecognitionCandidate] {
        guard limit > 0 else { return [] }
        let title = normalized(recognized.title)
        let artist = normalized(recognized.artist)
        let versions = versionMarkers(recognized.title)
        var seen = Set<String>()
        var ranked: [RankedCandidate] = []
        ranked.reserveCapacity(songs.count)
        for (index, song) in songs.enumerated() {
            guard !song.id.isEmpty, seen.insert(song.id).inserted else { continue }
            let candidateTitle = normalized(song.title)
            let candidateArtist = normalized(song.artistLine)
            let exactTitle = !title.isEmpty && title == candidateTitle
            let includesArtist = song.artists.contains { normalized($0.name) == artist }
            let exactArtist = !artist.isEmpty && (artist == candidateArtist || includesArtist)
            let sameVersion = versionMarkers(song.title) == versions
            var compatibleDuration = true
            let titleScore = similarity(title, candidateTitle) * 0.65
            let artistScore = similarity(artist, candidateArtist) * 0.3
            var score = titleScore + artistScore
            if exactArtist { score += 0.05 }
            if let expected = recognized.duration, let actual = song.duration,
               expected.isFinite, actual.isFinite, expected > 0, actual > 0 {
                let difference = abs(expected - actual)
                score += max(0, 1 - difference / 20) * 0.05
                compatibleDuration = difference <= max(10, expected * 0.05)
            }
            if !sameVersion { score -= 0.45 }
            let confidence: MusicRecognitionCandidate.Confidence
            if !sameVersion { confidence = .differentVersion }
            else if exactTitle && exactArtist && compatibleDuration { confidence = .close }
            else { confidence = .needsReview }
            let candidate = MusicRecognitionCandidate(song: song, confidence: confidence)
            ranked.append(RankedCandidate(sourceIndex: index, score: score, candidate: candidate))
        }
        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score { return lhs.sourceIndex < rhs.sourceIndex }
            return lhs.score > rhs.score
        }
        return ranked.prefix(limit).map(\.candidate)
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        let a = Set(lhs.split(separator: " "))
        let b = Set(rhs.split(separator: " "))
        return Double(a.intersection(b).count) / Double(max(1, a.union(b).count))
    }

    private static func versionMarkers(_ title: String) -> Set<String> {
        let folded = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(normalized(title).split(separator: " ").map(String.init))
        let markers = ["remix", "cover", "instrumental", "karaoke", "acoustic"]
        var found = Set(markers.filter { words.contains($0) })
        let localizedMarkers = ["混音", "翻唱", "伴奏", "現場", "现场", "演唱會", "演唱会"]
        found.formUnion(localizedMarkers.filter { folded.contains($0) })
        // "Live Forever" is a song title, not evidence of a concert recording.
        if folded.range(of: #"[\(\[（【][^\)\]）】]*\blive\b|\s[-–—]\s*live\b|\blive\s+(at|from|in)\b"#,
                        options: .regularExpression) != nil { found.insert("live") }
        return found
    }
}
