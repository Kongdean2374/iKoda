import Foundation

public struct LyricContextRow: Equatable, Codable, Sendable, Identifiable {
    public let id: Int
    public let text: String
    public let voice: LyricVoice?
    public init(id: Int, text: String, voice: LyricVoice? = nil) {
        self.id = id
        self.text = text
        self.voice = voice
    }
}

/// The model receives consecutive original lines, including across line breaks.
/// UI timing and line IDs always remain owned by the selected lyrics version.
public enum LyricContextPassages {
    public static func cacheKey(songID: String, originalNamespace: String) -> AutomaticLyricTranslationCache.Key {
        .init(songID: songID, rows: [], namespace: originalNamespace + "|immersive|tw-lyric-context-v2")
    }

    private static let boundaries = CharacterSet(charactersIn: ".!?。！？…")

    public static func groups(_ rows: [LyricContextRow], translating ids: Set<Int>,
                              maxRows: Int = 10, maxBytes: Int = 3200) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentBytes = 0
        for (index, row) in rows.enumerated() {
            if let previous = current.last,
               (index > previous + 1 || current.count >= max(1, maxRows) || currentBytes + row.text.utf8.count > maxBytes) {
                groups.append(current)
                current = []
                currentBytes = 0
            }
            guard ids.contains(row.id) else { continue }
            current.append(index)
            currentBytes += row.text.utf8.count
            // Prefer a natural boundary once a passage has room for multiple lines.
            if current.count >= 5, let scalar = row.text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last,
               boundaries.contains(scalar) {
                groups.append(current)
                current = []
                currentBytes = 0
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Entire short lyrics fit in the passage prompt. Longer lyrics can request a
    /// single overview, using evenly spaced passages when the entire text cannot fit.
    public static func overview(_ rows: [LyricContextRow], byteLimit: Int = 5200) -> (rows: [LyricContextRow], excerpted: Bool) {
        guard rows.reduce(0, { $0 + $1.text.utf8.count + 12 }) > byteLimit else { return (rows, false) }
        let stride = max(1, rows.count / 22)
        var sampled: [LyricContextRow] = []
        var remaining = byteLimit
        for (index, row) in rows.enumerated() where index % stride == 0 || index == rows.count - 1 {
            let text = String(row.text.prefix(80))
            let cost = text.utf8.count + 12
            guard cost <= remaining else { continue }
            sampled.append(.init(id: row.id, text: text, voice: row.voice))
            remaining -= cost
        }
        return (sampled, true)
    }
}
