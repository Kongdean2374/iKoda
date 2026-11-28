import Foundation

public enum LyricAIWorkPhase: String, Sendable {
    case queued, identifying, preparing, summarizing, generating, validating, retrying, awaitingCancellation
    case paused, complete, partial, unavailable, failed, cancelled
}

public enum LyricAIRowState: String, Codable, Sendable {
    case pending, processing, translated, unchanged, unnecessary, unsupported, invalid, timedOut, cancelled, reused, cached
}

public enum LyricAISummaryState: String, Sendable {
    case waiting, running, complete, shortContext, unsupportedPrimary, failed, cancelled
}

public struct LyricAIRequest: Encodable, Sendable {
    public struct Reference: Encodable, Sendable {
        public let id: Int
        public let baseHint: String
    }

    public let title: String
    public let artist: String
    public let overview: String?
    public let context: [LyricContextRow]
    public let requested: [Int]
    public let references: [Reference]?

    public init(mode: LyricsTranslationMode, title: String, artist: String, overview: String?,
                context: [LyricContextRow], requested: [Int], base: [Int: String]) {
        self.title = String(title.prefix(100))
        self.artist = String(artist.prefix(100))
        self.overview = overview
        self.context = context
        self.requested = requested
        let hints = mode.usesAppleTranslation ? requested.compactMap { id in
            base[id].map { Reference(id: id, baseHint: String($0.prefix(300))) }
        } : []
        references = hints.isEmpty ? nil : hints
    }
}

public enum LyricAIRetry {
    public static func permits(_ error: LyricWorkError) -> Bool {
        switch error {
        case .invalidOutput, .incompleteOutput, .timeout, .context: true
        default: false
        }
    }

    public static func resume(_ state: LyricAIRowState) -> Bool {
        state == .invalid || state == .timedOut || state == .cancelled
    }
}

public enum LyricModelDeadline {
    /// A deadline updates the UI as soon as it fires. Structured concurrency
    /// retains the slot until a cancelled model invocation has actually exited.
    public static func run<Value: Sendable>(
        for timeout: Duration,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                await onTimeout()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}

public enum LyricAISummaryPolicy {
    public static func primaryIsUsable(_ evidence: LyricLanguageProfile.Evidence?, supported: [String: Bool]) -> Bool {
        guard let evidence, evidence.confidence >= 0.65 else { return true }
        return supported[evidence.language] != false
    }
}
