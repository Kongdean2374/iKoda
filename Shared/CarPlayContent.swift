#if !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation

nonisolated struct KodaLyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        enum Status: String, Codable, Sendable {
            case hidden, loading, unavailable, betweenLines, line
        }

        var title: String
        var isPlaying: Bool
        var status: Status
        var original: String?
        var translation: String?

        init(title: String, isPlaying: Bool, status: Status, original: String? = nil, translation: String? = nil) {
            // Bound even pathological input well below ActivityKit's combined 4 KB limit,
            // including multibyte text and strings requiring JSON escapes.
            self.title = Self.bounded(title, bytes: 165)
            self.isPlaying = isPlaying
            self.status = status
            self.original = original.map { Self.bounded($0, bytes: 220) }
            self.translation = translation.map { Self.bounded($0, bytes: 220) }
        }

        private static func bounded(_ text: String, bytes: Int) -> String {
            var available = bytes
            return String(text.prefix(while: { character in
                available -= String(character).utf8.count
                return available >= 0
            }))
        }
    }
}

nonisolated struct CarPlayPlayerSnapshot: Codable, Equatable, Sendable {
    static let widgetKind = "KodaCarPlayPlayer"
    var nowPlayingTitle: String?
    var wantsToPlay: Bool
    var hasQueueItem: Bool
    var hasLikedSongs: Bool
    var artwork: Data?

    // The same provisioning-authorized group must be available in both processes.
    // With ordinary sideload signing the group may be unavailable; never fall back
    // to an unrelated container or copy credentials or the library into this file.
    static var file: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "KodaCarPlayAppGroup") as? String,
              group.hasPrefix("group.") else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("carplay-player-v1.json")
    }

    static func read(from file: URL) -> Self? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 160_000, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
#endif
