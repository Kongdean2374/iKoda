import Foundation

public enum LyricsTranslationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick, quality, immersive
    public var id: Self { self }
}

/// The on-device editor cannot assign text to a different occurrence.
public enum LyricsPolishValidation {
    public struct Line: Codable, Equatable, Sendable {
        public let id: Int
        public let text: String
        public init(id: Int, text: String) { self.id = id; self.text = text }
    }

    public static func validate(_ output: [Line], expected: [Line]) -> [Int: String]? {
        guard output.map(\.id) == expected.map(\.id), Set(output.map(\.id)).count == output.count else { return nil }
        var result: [Int: String] = [:]
        for (value, reference) in zip(output, expected) {
            let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= min(360, max(40, reference.text.count * 3 + 12)),
                  text.rangeOfCharacter(from: .newlines) == nil,
                  text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
                  text.range(of: #"(?i)\b(?:system prompt|ignore previous|as an ai)\b|系統提示|忽略以上指令|無法協助|无法协助"#,
                             options: .regularExpression) == nil else { return nil }
            result[value.id] = TraditionalChineseLyrics.convert(text)
        }
        return result
    }
}
