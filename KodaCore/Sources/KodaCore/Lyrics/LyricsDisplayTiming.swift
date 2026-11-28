import Foundation

public enum LyricsDisplayTiming {
    public static func airPlayOffset(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return (min(10, max(-10, value)) * 10).rounded() / 10
    }

    /// The source offset is already included in the parsed timestamps.
    public static func correction(song: TimeInterval, version: TimeInterval,
                                  airPlay: TimeInterval, isAirPlay: Bool) -> TimeInterval {
        (song.isFinite ? song : 0) + (version.isFinite ? version : 0)
            + (isAirPlay ? airPlayOffset(airPlay) : 0)
    }
}
