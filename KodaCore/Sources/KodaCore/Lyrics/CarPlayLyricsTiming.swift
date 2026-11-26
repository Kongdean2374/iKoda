import Foundation

/// The car display uses its own delay and shows a single sung line at a time.
public enum CarPlayLyricsTiming {
    public static let range: ClosedRange<TimeInterval> = -10...10

    public static func normalizedOffset(_ offset: TimeInterval) -> TimeInterval {
        guard offset.isFinite else { return 0 }
        let clamped = min(max(offset, range.lowerBound), range.upperBound)
        return (clamped * 10).rounded() / 10
    }

    public struct Sample: Equatable, Sendable {
        public let line: LyricLine?
        /// The next display transition expressed in the player's time coordinate.
        public let nextPosition: TimeInterval?
    }

    public static func sample(at position: TimeInterval, offset: TimeInterval, versionOffset: TimeInterval = 0, in lines: [LyricLine]) -> Sample {
        guard position.isFinite else { return Sample(line: nil, nextPosition: nil) }
        let delay = normalizedOffset(offset) + (versionOffset.isFinite ? min(30, max(-30, versionOffset)) : 0)
        let time = position - delay
        let index = Lyrics.index(of: time, in: lines)
        let nextIndex = index.map { $0 + 1 } ?? 0
        let following = nextIndex < lines.count ? lines[nextIndex].time : nil
        var line: LyricLine?
        if let index {
            // Adjacent overlapping voices can have different end times. Prefer
            // lead/together at the same timestamp and never show an expired voice.
            for item in stride(from: index, through: max(0, index - 15), by: -1) {
                let candidate = lines[item]
                if let line, candidate.time < line.time { break }
                guard candidate.end.map({ time < $0 }) ?? (item == index),
                      !candidate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if line == nil || (line?.voice == .duet && candidate.voice != .duet) { line = candidate }
            }
        }
        let boundary = [line?.end, following].compactMap { $0 }
            .filter { $0.isFinite && $0 > time }.min()
        return Sample(line: line, nextPosition: boundary.map { $0 + delay })
    }
}
