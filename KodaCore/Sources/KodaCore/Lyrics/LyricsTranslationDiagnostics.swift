import Foundation

public enum LyricCacheUse: String, Codable, Sendable {
    case unchecked, miss, partial, hit, legacy
}

public enum LyricWorkError: String, Codable, Sendable {
    case translation, language, timeout, model, invalidOutput, refused, incompleteOutput, context
}

public struct AppleLyricDiagnostics: Codable, Equatable, Sendable {
    public enum Strategy: String, Codable, Sendable, Hashable { case standard, lowLatency, highFidelity }
    public enum Support: String, Codable, Sendable { case available, download, unsupported, unknown }
    public struct LanguageRoute: Codable, Equatable, Sendable, Identifiable {
        public var id: String { source }
        public let source: String
        public let target: String?
        public let support: Support
        public init(source: String, target: String?, support: Support) {
            self.source = source
            self.target = target
            self.support = support
        }
    }

    public var strategies: Set<Strategy> = []
    public var languages: [LanguageRoute] = []
    public var usedCompatibility: Bool?
    public var lastError: LyricWorkError?
    public init() {}
}

public enum LyricModelAvailability: String, Codable, Sendable {
    case unchecked, available, ineligible, disabled, notReady, unknown
}

public enum LyricWorkLimit: String, Sendable {
    case lowPower, thermal, background, buffering, memory
}

public enum ImmersiveLyricStatus: Equatable, Sendable {
    public enum Base: Equatable, Sendable { case preparing, translating, ready, partial, unavailable }
    public enum Polish: Equatable, Sendable {
        case idle, checking, working, completed, partial, unavailable, language, paused, failed, unnecessary
    }
    case preparing, baseTranslation, polishing, completed, partial, modelUnavailable, languageUnsupported, paused, fallback, failed, unnecessary, unavailable

    public static func resolve(base: Base, polish: Polish) -> Self {
        if base == .preparing { return .preparing }
        if base == .translating { return .baseTranslation }
        switch polish {
        case .idle, .checking: return .preparing
        case .working: return .polishing
        case .completed: return .completed
        case .partial: return .partial
        case .unavailable: return .modelUnavailable
        case .language: return .languageUnsupported
        case .paused: return .paused
        case .failed: return .failed
        case .unnecessary:
            return base == .ready ? .unnecessary : base == .partial ? .fallback : .unavailable
        }
    }
}

public struct LyricPolishDiagnostics: Equatable, Sendable {
    public var availability: LyricModelAvailability = .unchecked
    public var sources: [String: Bool] = [:]
    public var target: String?
    public var targetSupported: Bool?
    public var total = 0
    public var processed = 0
    public var validated = 0
    public var changed = 0
    public var translatedWithoutBase = 0
    public var failedBatches = 0
    public var rejectedBatches = 0
    public var cache: LyricCacheUse = .unchecked
    public var cachedRows = 0
    public var summarySeconds: TimeInterval?
    public var generationSeconds: TimeInterval?
    public var validationSeconds: TimeInterval?
    public var cacheSeconds: TimeInterval?
    public var lastError: LyricWorkError?
    public var limits: Set<LyricWorkLimit> = []
    public var unchanged: Int { max(0, validated - changed - translatedWithoutBase) }
    public init() {}
}

public enum LyricTranslationLocale {
    /// Preserve script distinctions. Try equivalent identifier forms before rejecting a locale.
    public static func variants(for identifier: String) -> [String] {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let language = Locale.Language(identifier: normalized)
        let parts = normalized.split(separator: "-")
        let bare = parts.first.map(String.init) ?? normalized
        let script = language.script?.identifier
        var candidates = [normalized]
        if bare != "zh" || script == nil || language.minimalIdentifier.contains(script ?? "") {
            candidates.append(language.minimalIdentifier)
        }
        if bare == "zh", script == "Hant" { candidates.append("zh-TW") }
        if let script { candidates.append(bare + "-" + script) }
        if bare != "zh" || script == nil { candidates.append(bare) }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

public extension Duration {
    var lyricSeconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

public struct LyricPolishBatch {
    public struct Result: Sendable {
        public let translations: [Int: String]
        public var missing: [LyricsPolishValidation.Line]
        public let changed: Int
        public var unchanged: Int { translations.count - changed }
    }

    public static func assess(_ output: [LyricsPolishValidation.Line], expected: [LyricsPolishValidation.Line]) -> Result {
        let valid = LyricsPolishValidation.validRows(output, expected: expected)
        let changed = expected.count { row in
            guard let text = valid[row.id] else { return false }
            return text != TraditionalChineseLyrics.convert(row.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .init(translations: valid, missing: expected.filter { valid[$0.id] == nil }, changed: changed)
    }

    /// A single smaller retry pass is enough to salvage a refused or oversized passage.
    public static func retryGroups<T>(_ missing: [T]) -> [[T]] {
        guard !missing.isEmpty else { return [] }
        let middle = (missing.count + 1) / 2
        return [Array(missing.prefix(middle)), Array(missing.dropFirst(middle))].filter { !$0.isEmpty }
    }
}

public enum LyricsPlayerChrome: Equatable, Sendable {
    case full, compact, expanded

    public static func resolve(isPortraitPhone: Bool, lyricsVisible: Bool, translationVisible: Bool,
                               enabled: Bool, controlsExpanded: Bool) -> Self {
        guard isPortraitPhone, lyricsVisible, translationVisible, enabled else { return .full }
        return controlsExpanded ? .expanded : .compact
    }
}
