import Foundation

/// A provider's language-tagged translation, aligned to the selected original's immutable row IDs.
public struct LyricEmbeddedTranslation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let language: String
    public let lines: [Int: String]
    public let convertedToTraditional: Bool
    public var isChinese: Bool { Locale.Language(identifier: language).languageCode?.identifier == "zh" }

    init(language: String, lines: [Int: String]) {
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        self.language = normalized
        let locale = Locale.Language(identifier: normalized)
        let chinese = locale.languageCode?.identifier == "zh"
        let convert = chinese && locale.script?.identifier != "Hant"
        self.lines = convert ? lines.mapValues(TraditionalChineseLyrics.convert) : lines
        convertedToTraditional = convert && self.lines != lines
        // Language and actual translated text distinguish different editions without
        // touching the original version's identity or its calibration.
        let content = lines.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.utf8.count):\($0.value)" }.joined()
        id = normalized + "|" + LyricsCandidate.digest(Data(content.utf8))
    }

    static func collect(_ entries: [(id: Int, language: String, text: String)]) -> [Self] {
        var groups: [String: [Int: String]] = [:]
        var ambiguous: [String: Set<Int>] = [:]
        for (id, language, text) in entries {
            let language = language.replacingOccurrences(of: "_", with: "-").lowercased()
            guard language.utf8.count <= 32,
                  language.range(of: #"^[a-z]{2,3}(-[a-z0-9]{2,8})*$"#, options: .regularExpression) != nil,
                  language != "und" else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 8192 else { continue }
            if let old = groups[language]?[id], old != trimmed { ambiguous[language, default: []].insert(id) }
            else { groups[language, default: [:]][id] = trimmed }
        }
        return groups.keys.sorted().prefix(12).compactMap { language in
            let valid = (groups[language] ?? [:]).filter { !(ambiguous[language]?.contains($0.key) ?? false) }
            return valid.isEmpty ? nil : Self(language: language, lines: valid)
        }
    }
}

public enum LyricTranslationSelection: Codable, Equatable, Hashable, Sendable {
    case automatic, provider(String), imported, appleTranslation

    private enum LegacyKey: String, CodingKey {
        case automatic, provider, imported, appleTranslation, quickApple, qualityApple
        case foundationModels, immersiveAI, pureAI
    }

    private enum Payload: String, CodingKey { case value = "_0" }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: LegacyKey.self)
        switch root.allKeys.first {
        case .provider:
            let value = try root.nestedContainer(keyedBy: Payload.self, forKey: .provider)
            self = .provider(try value.decode(String.self, forKey: .value))
        case .imported: self = .imported
        case .automatic, nil: self = .automatic
        default: self = .appleTranslation
        }
    }

    public func encode(to encoder: Encoder) throws {
        var root = encoder.container(keyedBy: LegacyKey.self)
        switch self {
        case .automatic: _ = root.nestedContainer(keyedBy: Payload.self, forKey: .automatic)
        case .imported: _ = root.nestedContainer(keyedBy: Payload.self, forKey: .imported)
        case .appleTranslation: _ = root.nestedContainer(keyedBy: Payload.self, forKey: .appleTranslation)
        case .provider(let id):
            var content = root.nestedContainer(keyedBy: Payload.self, forKey: .provider)
            try content.encode(id, forKey: .value)
        }
    }
}

public enum LyricTranslationOrigin: Equatable, Hashable, Sendable {
    case provider(String), imported, appleTranslation, edited
}

public struct ResolvedLyricTranslations: Equatable, Sendable {
    public private(set) var lines: [Int: String] = [:]
    public private(set) var origins: [Int: LyricTranslationOrigin] = [:]

    public init(selection: LyricTranslationSelection, embedded: [LyricEmbeddedTranslation], prefersProvider: Bool,
                imported: [Int: String], base: [Int: String], edits: [Int: String]) {
        let provider = embedded.filter(\.isChinese).sorted {
            if $0.convertedToTraditional != $1.convertedToTraditional { return !$0.convertedToTraditional }
            return $0.lines.count > $1.lines.count
        }.first
        func add(_ rows: [Int: String], from origin: LyricTranslationOrigin) {
            for (id, text) in rows where !text.isEmpty {
                lines[id] = text
                origins[id] = origin
            }
        }
        add(base, from: .appleTranslation)
        switch selection {
        case .automatic:
            if prefersProvider, let provider { add(provider.lines, from: .provider(provider.id)) }
            add(imported, from: .imported)
        case .provider(let id):
            if let provider = embedded.first(where: { $0.id == id }) { add(provider.lines, from: .provider(id)) }
        case .imported: add(imported, from: .imported)
        case .appleTranslation: break
        }
        add(edits, from: .edited)
    }
}
