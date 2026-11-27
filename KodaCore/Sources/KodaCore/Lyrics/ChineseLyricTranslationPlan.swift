import Foundation

/// Text-only work for automatic Chinese lyrics. Each response is attached to a source
/// row/fragment, never to a new timestamp. A Chinese song may still contain foreign rows.
public struct ChineseLyricTranslationPlan: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let id: Int
        public let text: String
        public init(id: Int, text: String) { self.id = id; self.text = text }
    }

    public struct Fragment: Equatable, Sendable, Identifiable {
        public let id: String
        public let lineID: Int
        public let text: String
        public let language: String
    }

    public let fragments: [Fragment]
    /// Unknown foreign text needs an honest unavailable notice. Already-Traditional
    /// Chinese, URLs and numeric-only rows need no semantic translation or notice.
    public let hasUnrecognizedText: Bool
    private let rows: [PreparedRow]
    var semanticRows: Set<Int> {
        Set(fragments.map(\.lineID) + rows.filter(\.unrecognized).map(\.id))
    }

    private enum Piece: Equatable, Sendable {
        case literal(String), fragment(Fragment)
    }
    private struct PreparedRow: Equatable, Sendable {
        let id: Int
        let originalText: String
        let chinese: Bool
        var pieces: [Piece]
        var unrecognized = false
    }
    private enum Script: Equatable { case latin, kana, hangul, other }
    private enum Unit {
        case literal(String), space(String), candidate(String, Script)
    }

    public init(rows input: [Row],
                detectLanguage: @Sendable (String) -> String? = { LyricsRomanizer.language(of: [$0]) }) {
        var prepared: [PreparedRow] = []
        var seenIDs: Set<Int> = []
        var unrecognized = false
        let context = input.prefix(64).map { String($0.text.prefix(160)) }.joined(separator: "\n")
        let overall = Self.languageCode(detectLanguage(context))
        for row in input where Self.hasText(row.text) && seenIDs.insert(row.id).inserted {
            let sections = Self.urlPieces(row.text)
            let sourceText = sections.filter { !$0.1 }.map { $0.0 }.joined()
            let detected = Self.hasText(sourceText) ? detectLanguage(sourceText) : nil
            let shortHan = sourceText.count < 16 && Self.containsHan(sourceText)
                && !Self.containsKana(sourceText) && !Self.containsHangul(sourceText) && !Self.containsLatin(sourceText)
            let contextual = shortHan && (overall == "ja" || overall == "ko") ? overall : detected
            let language = Self.languageCode(contextual)
            let kana = Self.containsKana(sourceText), hangul = Self.containsHangul(sourceText)
            // A positively identified Japanese/Korean line keeps its Han characters with
            // the whole phrase. Hans-Hant must never rewrite Japanese kanji beforehand.
            let chinese = language != "ja" && language != "ko"
                && (TraditionalChineseLyrics.isChinese(language: contextual)
                    || (Self.containsHan(sourceText) && !kana && !hangul))
            let wholeLanguage: String? = chinese ? nil : (kana ? "ja" : (hangul ? "ko" : contextual))
            var result = PreparedRow(id: row.id, originalText: row.text, chinese: chinese, pieces: [])
            var fragmentIndex = 0
            for (text, isURL) in sections {
                if isURL {
                    result.pieces.append(.literal(text))
                } else if chinese {
                    Self.appendMixed(text, to: &result, next: &fragmentIndex, detectLanguage: detectLanguage)
                } else if let wholeLanguage, Self.hasLetters(text),
                          !TraditionalChineseLyrics.isChinese(language: wholeLanguage) {
                    Self.appendFragment(text, language: wholeLanguage, to: &result, next: &fragmentIndex)
                } else {
                    result.pieces.append(.literal(text))
                }
            }
            if !chinese, Self.hasLetters(sourceText), !result.pieces.contains(where: {
                if case .fragment = $0 { return true }
                return false
            }) { result.unrecognized = true }
            unrecognized = unrecognized || result.unrecognized
            prepared.append(result)
        }
        rows = prepared
        hasUnrecognizedText = unrecognized
        fragments = prepared.flatMap { row in
            row.pieces.compactMap { piece in
                if case .fragment(let fragment) = piece { return fragment }
                return nil
            }
        }
    }

    /// Missing or unsupported fragments keep their original text. Entirely untranslated
    /// foreign rows and unchanged automatic text are omitted, retaining the original
    /// timed row instead of adding a duplicate line beneath already-Traditional Chinese.
    /// Duplicate input IDs retain the first row instead of crashing or mixing responses.
    public func renderedLines(translations: [String: String]) -> [Int: String] {
        var result: [Int: String] = [:]
        for row in rows {
            var hasTranslation = false
            let text = row.pieces.map { piece -> String in
                switch piece {
                case .literal(let text): return text
                case .fragment(let fragment):
                    guard let translated = translations[fragment.id], Self.hasText(translated) else { return fragment.text }
                    hasTranslation = true
                    return translated
                }
            }.joined()
            if (row.chinese || hasTranslation), text != row.originalText { result[row.id] = text }
        }
        return result
    }

    func rowProgress(translations: [String: String]) -> (completed: Int, total: Int) {
        let completed = rows.count { row in
            !row.unrecognized && row.pieces.allSatisfy {
                if case .fragment(let fragment) = $0 { return translations[fragment.id] != nil }
                return true
            }
        }
        return (completed, rows.count)
    }

    private static func appendFragment(_ text: String, language: String, to row: inout PreparedRow, next: inout Int) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasText(content) else { row.pieces.append(.literal(text)); return }
        let leading = String(text.prefix(while: \.isWhitespace))
        let trailing = String(text.reversed().prefix(while: \.isWhitespace).reversed())
        if !leading.isEmpty { row.pieces.append(.literal(leading)) }
        row.pieces.append(.fragment(Fragment(id: "\(row.id):\(next)", lineID: row.id, text: content, language: language)))
        next += 1
        if !trailing.isEmpty { row.pieces.append(.literal(trailing)) }
    }

    private static func appendMixed(_ text: String, to row: inout PreparedRow, next: inout Int,
                                    detectLanguage: @Sendable (String) -> String?) {
        var units: [Unit] = []
        for token in runs(text, splittingOn: \.isWhitespace) {
            if token.first?.isWhitespace == true { units.append(.space(token)); continue }
            // Keep an inline Japanese/Korean token whole, including any Han characters.
            // Whitespace is the conservative boundary for ambiguous mixed Han phrases.
            if containsKana(token) { units.append(.candidate(token, .kana)); continue }
            if containsHangul(token) { units.append(.candidate(token, .hangul)); continue }
            for part in runs(token, splittingOn: { $0.unicodeScalars.contains(where: isHan) }) {
                if containsHan(part) { units.append(.literal(TraditionalChineseLyrics.convert(part))) }
                else if hasLetters(part) { units.append(.candidate(part, containsLatin(part) ? .latin : .other)) }
                else { units.append(.literal(part)) }
            }
        }
        var index = 0
        while index < units.count {
            switch units[index] {
            case .literal(let text), .space(let text):
                row.pieces.append(.literal(text))
                index += 1
            case .candidate(var text, let script):
                index += 1
                // Give the detector whole foreign phrases rather than guessing every
                // Latin token is English; e.g. "I love you" or "Bonjour tout le monde".
                while index + 1 < units.count,
                      case .space(let space) = units[index],
                      case .candidate(let following, let nextScript) = units[index + 1], nextScript == script {
                    text += space + following
                    index += 2
                }
                let detected = detectLanguage(text)
                let source = script == .kana ? "ja" : (script == .hangul ? "ko" : detected)
                if let source, !TraditionalChineseLyrics.isChinese(language: source) {
                    appendFragment(text, language: source, to: &row, next: &next)
                } else {
                    row.unrecognized = true
                    row.pieces.append(.literal(text))
                }
            }
        }
    }

    /// Consecutive characters for which the predicate has the same answer, with every
    /// character preserved. Character boundaries retain combining marks and emoji.
    private static func runs(_ text: String, splittingOn predicate: (Character) -> Bool) -> [String] {
        var result: [String] = [], current = ""
        var previous: Bool?
        for character in text {
            let value = predicate(character)
            if let previous, previous != value { result.append(current); current = "" }
            current.append(character)
            previous = value
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func urlPieces(_ text: String) -> [(String, Bool)] {
        guard let pattern = try? NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<>]+"#, options: .caseInsensitive) else {
            return [(text, false)]
        }
        var result: [(String, Bool)] = []
        var start = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            if start < range.lowerBound { result.append((String(text[start..<range.lowerBound]), false)) }
            result.append((String(text[range]), true))
            start = range.upperBound
        }
        if start < text.endIndex { result.append((String(text[start...]), false)) }
        return result
    }

    private static func languageCode(_ language: String?) -> String? {
        guard let language else { return nil }
        return language.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased()
    }
    private static func hasText(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private static func hasLetters(_ text: String) -> Bool { text.unicodeScalars.contains { $0.properties.isAlphabetic } }
    private static func containsHan(_ text: String) -> Bool { text.unicodeScalars.contains(where: isHan) }
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x30000...0x323AF: true
        default: false
        }
    }
    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0xFF66...0xFF9D).contains($0.value) }
    }
    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }
    private static func containsLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
                || (0xC0...0x24F).contains($0.value) || (0x1E00...0x1EFF).contains($0.value)
        }
    }
}
