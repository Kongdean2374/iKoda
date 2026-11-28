import Foundation
import NaturalLanguage

/// One classification for Apple Translation and Foundation Models. It contains
/// row identities and language evidence only, without retaining raw lyric text.
public struct LyricLanguageProfile: Equatable, Sendable {
    public static let version = "lyric-language-v3"

    public struct Evidence: Equatable, Sendable {
        public let language: String
        public let confidence: Double

        public init(_ language: String, confidence: Double) {
            self.language = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() ?? ""
            self.confidence = confidence
        }
    }

    public struct Paragraph: Equatable, Sendable {
        public let rows: [Int]
        public let language: String?
    }

    public typealias Detector = @Sendable (String) -> Evidence?

    public let primary: Evidence?
    public let paragraphs: [Paragraph]
    public let rowLanguages: [Int: String]
    public let noTranslation: Set<Int>
    public let vocalizations: Set<Int>
    public let corrected: Int

    public static func detect(_ text: String) -> Evidence? {
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first,
              best.key != .undetermined else { return nil }
        return Evidence(best.key.rawValue, confidence: best.value)
    }

    public init(rows: [ChineseLyricTranslationPlan.Row], detect: Detector = LyricLanguageProfile.detect) {
        var paragraphs: [[(Int, String)]] = []
        var ongoing: [(Int, String)] = []
        var skipped = Set<Int>()
        var sung = Set<Int>()
        var ids = Set<Int>()
        for row in rows where ids.insert(row.id).inserted {
            let text = row.text.replacingOccurrences(of: #"(?:https?://|www\.)[^\s<>]+"#, with: "",
                                                      options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let alphabetic = text.unicodeScalars.contains { $0.properties.isAlphabetic }
            let vocal = alphabetic && Self.isVocalization(text)
            if !alphabetic || vocal {
                skipped.insert(row.id)
                if vocal { sung.insert(row.id) }
                if text.isEmpty, !ongoing.isEmpty { paragraphs.append(ongoing); ongoing = [] }
                continue
            }
            ongoing.append((row.id, String(text.prefix(220))))
            if ongoing.count == 8 { paragraphs.append(ongoing); ongoing = [] }
        }
        if !ongoing.isEmpty { paragraphs.append(ongoing) }
        let effectiveRows = paragraphs.flatMap { $0 }
        let stride = max(1, (effectiveRows.count + 95) / 96)
        let sample = effectiveRows.enumerated().filter { $0.offset % stride == 0 }.map { $0.element.1 }
        let primary = detect(sample.joined(separator: "\n"))
        self.primary = primary
        var translated: [Int: String] = [:]
        var correctionCount = 0
        self.paragraphs = paragraphs.enumerated().map { paragraphIndex, group in
            let detectorResult = paragraphIndex < 160 ? detect(group.map { $0.1 }.joined(separator: "\n")) : nil
            let local = group.count >= 2 && (detectorResult?.confidence ?? 0) >= 0.70 ? detectorResult?.language : nil
            let fallback = local ?? ((primary?.confidence ?? 0) >= 0.52 ? primary?.language : nil)
            let detected = group.map { paragraphIndex < 160 ? detect($0.1) : nil }
            for (index, row) in group.enumerated() {
                let evidence = detected[index]
                let letters = row.1.unicodeScalars.count { $0.properties.isAlphabetic }
                let tokens = row.1.split(whereSeparator: \.isWhitespace).count
                let cjkContext = evidence?.language == "zh" && (evidence?.confidence ?? 0) >= 0.80
                    && fallback != "ja" && fallback != "ko" ? "zh" : fallback
                let script = Self.scriptLanguage(row.1, context: cjkContext)
                let hasHan = row.1.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
                let adjacent = [index - 1, index + 1].contains {
                    detected.indices.contains($0) && detected[$0]?.language == evidence?.language
                        && (detected[$0]?.confidence ?? 0) >= 0.78
                }
                // One short Latin-script phrase is weak evidence of a language
                // change. Prefer a sustained switch or a well-supported sentence.
                let trustworthy = (evidence?.confidence ?? 0) >= 0.84 && letters >= 18 && tokens >= 4
                    || adjacent && letters >= 10 && (evidence?.confidence ?? 0) >= 0.78
                    || fallback == nil && (evidence?.confidence ?? 0) >= 0.68 && letters >= 3
                let language = script ?? (hasHan && evidence?.language == "zh" ? "zh" : nil)
                    ?? (trustworthy ? evidence?.language : fallback)
                    ?? (hasHan ? "zh" : nil)
                if let language { translated[row.0] = language }
                if let evidence, let language, evidence.language != language, script == nil { correctionCount += 1 }
            }
            return Paragraph(rows: group.map { $0.0 }, language: fallback)
        }
        rowLanguages = translated
        noTranslation = skipped
        vocalizations = sung
        corrected = correctionCount
    }

    public static func isVocalization(_ text: String) -> Bool {
        let sounds: Set<String> = ["doo", "du", "dooh", "da", "la", "na", "sha", "dum", "ba", "bap",
                                   "oh", "ooh", "ah", "aah", "uh", "eh", "mm", "mmm", "hmm",
                                   "啦", "喔", "哦", "呀", "啊", "嗚", "哼", "啦啦", "喔喔", "ラ", "ル"]
        let words = text.lowercased().split { !$0.isLetter }.map(String.init)
        guard !words.isEmpty else { return false }
        if words.allSatisfy({ sounds.contains($0) }) { return true }
        // CJK singing sounds may be adjacent without spaces. Only skip exact
        // repeats of a known sound, never a word-containing phrase.
        return words.count == 1 && words[0].count >= 2 && words[0].allSatisfy {
            sounds.contains(String($0)) && !$0.isASCII
        }
    }

    private static func scriptLanguage(_ text: String, context: String?) -> String? {
        let scalars = text.unicodeScalars
        let han = scalars.count { (0x3400...0x9FFF).contains($0.value) }
        let kana = scalars.count { (0x3041...0x30FA).contains($0.value) || (0xFF66...0xFF9D).contains($0.value) }
        let hangul = scalars.count { (0x1100...0x11FF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        if kana > 0 && (context != "zh" || han == 0) { return "ja" }
        if hangul > 0 && (context != "zh" || han == 0) { return "ko" }
        if han > 0 && kana == 0 && hangul == 0 && (context == "ja" || context == "ko")
            && scalars.allSatisfy({ !$0.properties.isAlphabetic || (0x3400...0x9FFF).contains($0.value) }) { return context }
        return nil
    }
}
