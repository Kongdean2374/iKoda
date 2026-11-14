import Foundation

/// Presentation-only helpers for locally generated Traditional Chinese lyrics.
/// Script conversion is not semantic translation. Callers must identify Chinese
/// source text first; Japanese kanji and other languages still need translation.
public enum TraditionalChineseLyrics {
    public static func isChinese(language: String?) -> Bool {
        guard let language else { return false }
        let identifier = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-", omittingEmptySubsequences: false).first?.lowercased() == "zh"
    }

    /// Foundation's on-device ICU transform changes the script, while retaining
    /// punctuation, line breaks and spacing. It does not rewrite regional wording.
    public static func convert(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }

    /// Separate text by the provider's stable line ID. No original, word timing,
    /// backing-vocal or singer data is edited, and repeated lines keep their IDs.
    public static func convertedLines(_ lines: [LyricLine]) -> [Int: String] {
        var result: [Int: String] = [:]
        for line in lines where hasText(line.text) {
            result[line.id] = convert(line.text)
        }
        return result
    }

    /// An explicit import takes priority only for its available lines. Automatic
    /// results fill gaps; blank entries never hide an available automatic line.
    public static func merged(automatic: [Int: String], imported: [Int: String],
                              importsEnabled: Bool) -> [Int: String] {
        var result = automatic.filter { hasText($0.value) }
        if importsEnabled {
            for (id, text) in imported where hasText(text) { result[id] = text }
        }
        return result
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
