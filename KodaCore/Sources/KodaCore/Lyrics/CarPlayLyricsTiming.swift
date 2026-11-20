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

    public static func sample(at position: TimeInterval, offset: TimeInterval, in lines: [LyricLine]) -> Sample {
        guard position.isFinite else { return Sample(line: nil, nextPosition: nil) }
        let delay = normalizedOffset(offset)
        let time = position - delay
        let index = Lyrics.index(of: time, in: lines)
        let nextIndex = index.map { $0 + 1 } ?? 0
        let following = nextIndex < lines.count ? lines[nextIndex].time : nil
        let candidate = index.map { lines[$0] }
        let line = candidate.flatMap { line in
            (line.end.map { time < $0 } ?? true) &&
            !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : nil
        }
        let boundary = [line?.end, following].compactMap { $0 }
            .filter { $0.isFinite && $0 > time }.min()
        return Sample(line: line, nextPosition: boundary.map { $0 + delay })
    }
}
