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
        public let strategy: Strategy?
        public let supportedTaiwanTargets: [String]?
        public let reportedTarget: String?
        public init(source: String, target: String?, support: Support, strategy: Strategy? = nil,
                    supportedTaiwanTargets: [String]? = nil, reportedTarget: String? = nil) {
            self.source = source
            self.target = target
            self.support = support
            self.strategy = strategy
            self.supportedTaiwanTargets = supportedTaiwanTargets
            self.reportedTarget = reportedTarget
        }
    }

    public var strategies: Set<Strategy> = []
    public var languages: [LanguageRoute] = []
    public var usedCompatibility: Bool?
    public var lastError: LyricWorkError?
    public init() {}
}

public extension Duration {
    var lyricSeconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
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
