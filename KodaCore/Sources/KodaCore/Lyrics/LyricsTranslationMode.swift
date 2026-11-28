import Foundation

public enum LyricsTranslationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case quick, quality, immersive, pureAI
    public var id: Self { self }
    public var usesContextModel: Bool { self == .immersive || self == .pureAI }
    public var usesAppleTranslation: Bool { self != .pureAI }

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
        let valid = validRows(output, expected: expected)
        return valid.count == expected.count ? valid : nil
    }

    /// Keep individually verifiable rows from an incomplete response. Duplicated
    /// IDs are ambiguous and require a new answer. Unknown IDs are ignored.
    public static func validRows(_ output: [Line], expected: [Line]) -> [Int: String] {
        let references = Dictionary(expected.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        let counts = Dictionary(grouping: output, by: \.id).mapValues(\.count)
        let positions = Dictionary(expected.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var previousPosition = -1
        var result: [Int: String] = [:]
        for value in output where counts[value.id] == 1 {
            guard let reference = references[value.id], let position = positions[value.id], position > previousPosition else { continue }
            let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= min(440, max(42, reference.count * 3 + 16)),
                  text.rangeOfCharacter(from: .newlines) == nil,
                  text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
                  text.range(of: #"(?i)\b(?:system prompt|ignore previous|as an ai)\b|系統提示|忽略以上指令|無法協助|无法协助|^(?:譯文|翻譯結果|解釋)[:：]"#,
                             options: .regularExpression) == nil,
                  text.range(of: #"佢哋|我哋|你哋|唔係|冇得|喺度|([一-龥])\1{7,}"#, options: .regularExpression) == nil else { continue }
            previousPosition = position
            result[value.id] = TraditionalChineseLyrics.convert(text)
        }
        return result
    }
}
