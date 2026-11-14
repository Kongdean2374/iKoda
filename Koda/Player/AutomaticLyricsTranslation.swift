import KodaCore
import SwiftUI
import Translation

/// Text-only input: translated sentences reuse their source row ID, never invented word timings.
nonisolated struct LyricsTranslationText: Equatable, Sendable {
    let id: Int
    let text: String
}

nonisolated struct AutomaticLyricsResult: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, preparing, translating, ready, unavailable, failed }
    var phase: Phase = .idle
    var lines: [Int: String] = [:]
}

/// A zero-size worker shared by synced and plain lyrics. Apple sessions stay inside their
/// translationTask lifetime. Each new content/request mounts a new host and rejects old replies.
@MainActor
struct AutomaticLyricsTranslationTask: View {
    let songID: String?
    let lines: [LyricsTranslationText]
    let enabled: Bool
    let retry: Int
    @Binding var result: AutomaticLyricsResult
    @Environment(Player.self) private var player
    @State private var activeRequest = UUID()
    @State private var plan: Plan?
    @State private var pending: [Plan] = []
    @State private var textPlan: ChineseLyricTranslationPlan?
    @State private var translatedFragments: [String: String] = [:]
    @State private var hasUnsupportedLanguage = false
    @State private var hasFailure = false

    private struct Request: Equatable {
        let songID: String?
        let lines: [LyricsTranslationText]
        let enabled: Bool
        let retry: Int
    }
    private struct Plan {
        let id = UUID()
        let request: UUID
        let source: Locale.Language
        let target: Locale.Language
        let fragments: [ChineseLyricTranslationPlan.Fragment]
    }

    var body: some View {
        // Keep the request task and cancellation boundary on one stable view node while
        // individual language/session hosts are replaced underneath it.
        ZStack {
            if let plan {
                NativeLyricsTranslationHost(source: plan.source, target: plan.target,
                    fragments: plan.fragments, token: plan.request) { token, update in
                    guard isCurrent(token) else { return }
                    for (id, text) in update.fragments { translatedFragments[id] = text }
                    result.lines = textPlan?.renderedLines(translations: translatedFragments) ?? [:]
                    switch update.phase {
                    case .ready:
                        startNext(token)
                    case .unavailable:
                        hasUnsupportedLanguage = true
                        startNext(token)
                    case .failed:
                        hasFailure = true
                        startNext(token)
                    default:
                        result.phase = update.phase
                    }
                }
                .id(plan.id)
            } else {
                Color.clear
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
        .task(id: Request(songID: songID, lines: lines, enabled: enabled, retry: retry)) { await prepare() }
        .onDisappear { activeRequest = UUID(); plan = nil; pending = [] }
    }

    private func prepare() async {
        let token = UUID()
        activeRequest = token
        plan = nil
        pending = []
        textPlan = nil
        translatedFragments = [:]
        hasUnsupportedLanguage = false
        hasFailure = false
        result = AutomaticLyricsResult()
        guard enabled, songID != nil, lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        result.phase = .preparing
        let rows = lines.map { ChineseLyricTranslationPlan.Row(id: $0.id, text: $0.text) }
        let prepared = await Task.detached(priority: .userInitiated) {
            ChineseLyricTranslationPlan(rows: rows)
        }.value
        guard isCurrent(token) else { return }
        textPlan = prepared
        hasUnsupportedLanguage = prepared.hasUnrecognizedText
        result.lines = prepared.renderedLines(translations: [:])
        guard !prepared.fragments.isEmpty else {
            result.phase = prepared.hasUnrecognizedText ? .unavailable : .ready
            return
        }
        var sourceLanguages: [String] = []
        for fragment in prepared.fragments where !sourceLanguages.contains(fragment.language) { sourceLanguages.append(fragment.language) }
        let supported = await Self.supportedLanguagePairs(for: sourceLanguages)
        guard isCurrent(token) else { return }
        hasUnsupportedLanguage = hasUnsupportedLanguage || supported.count < sourceLanguages.count
        pending = supported.map { pair in
            Plan(request: token, source: pair.source, target: pair.target,
                 fragments: prepared.fragments.filter { $0.language == pair.sourceID })
        }
        startNext(token)
    }

    /// LanguageAvailability is not Sendable. Create it and perform every asynchronous
    /// query on the generic executor, returning only Sendable locale value types to the UI.
    @concurrent
    nonisolated private static func supportedLanguagePairs(for sourceLanguages: [String]) async -> [SupportedLyricsLanguage] {
        guard !Task.isCancelled else { return [] }
        let availability = LanguageAvailability()
        let languages = await availability.supportedLanguages
        guard !Task.isCancelled else { return [] }
        let chinese = languages.filter { $0.languageCode?.identifier == "zh" }
        // Choose from Apple's actual supported languages. A supported Simplified target
        // can be converted locally; an unsupported Traditional target is never assumed.
        let targets = chinese.filter { $0.script?.identifier == "Hant" }
            + chinese.filter { $0.script?.identifier != "Hant" }
        var result: [SupportedLyricsLanguage] = []
        for language in sourceLanguages {
            guard !Task.isCancelled else { return [] }
            let source = Locale.Language(identifier: language)
            for target in targets {
                let status = await availability.status(from: source, to: target)
                guard !Task.isCancelled else { return [] }
                switch status {
                case .installed, .supported:
                    result.append(SupportedLyricsLanguage(sourceID: language, source: source, target: target))
                case .unsupported: continue
                @unknown default: continue
                }
                break
            }
        }
        return result
    }

    /// Language groups run one at a time, avoiding simultaneous system language-download prompts.
    private func startNext(_ token: UUID) {
        guard isCurrent(token) else { return }
        if pending.isEmpty {
            plan = nil
            result.phase = hasFailure ? .failed : hasUnsupportedLanguage ? .unavailable : .ready
        } else {
            plan = pending.removeFirst()
            result.phase = .preparing
        }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        !Task.isCancelled && activeRequest == token && enabled && player.current?.id == songID
    }
}

nonisolated private struct SupportedLyricsLanguage: Sendable {
    let sourceID: String
    let source: Locale.Language
    let target: Locale.Language
}

nonisolated private struct NativeLyricsResult: Sendable {
    let phase: AutomaticLyricsResult.Phase
    var fragments: [String: String] = [:]
}

@MainActor
private struct NativeLyricsTranslationHost: View {
    let source: Locale.Language
    let target: Locale.Language
    let fragments: [ChineseLyricTranslationPlan.Fragment]
    let token: UUID
    let publish: @MainActor @Sendable (UUID, NativeLyricsResult) -> Void

    var body: some View {
        Color.clear
            .translationTask(TranslationSession.Configuration(source: source, target: target),
                             action: Self.translate(fragments, token: token, publish: publish))
    }

    nonisolated private static func translate(_ fragments: [ChineseLyricTranslationPlan.Fragment], token: UUID,
        publish: @escaping @MainActor @Sendable (UUID, NativeLyricsResult) -> Void
    ) -> @concurrent (TranslationSession) async -> Void {
        { @concurrent session in
            var translated: [String: String] = [:]
            do {
                try Task.checkCancellation()
                // Apple asks permission for missing language packs; installed models work offline.
                // This session receives only one source language, including for mixed-language songs.
                try await session.prepareTranslation()
                try Task.checkCancellation()
                await publish(token, NativeLyricsResult(phase: .translating))
                for start in stride(from: 0, to: fragments.count, by: 24) {
                    try Task.checkCancellation()
                    let batch = fragments[start..<min(start + 24, fragments.count)]
                    let allowedIDs = Set(batch.map(\.id))
                    let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
                    let responses = try await session.translations(from: requests)
                    try Task.checkCancellation()
                    for response in responses {
                        guard let id = response.clientIdentifier, allowedIDs.contains(id),
                              !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        translated[id] = TraditionalChineseLyrics.convert(response.targetText)
                    }
                    await publish(token, NativeLyricsResult(phase: .translating, fragments: translated))
                }
                try Task.checkCancellation()
                await publish(token, NativeLyricsResult(phase: translated.count == fragments.count ? .ready : .unavailable, fragments: translated))
            } catch {
                guard !Task.isCancelled else { return }
                await publish(token, NativeLyricsResult(phase: .failed, fragments: translated))
            }
        }
    }
}

/// Shared, honest status messages. A failed or unsupported pair never hides original lines.
struct AutomaticLyricsNotice: View {
    let phase: AutomaticLyricsResult.Phase
    let retry: () -> Void

    var body: some View {
        switch phase {
        case .preparing:
            Label("Preparing On-Device Translation…", systemImage: "translate")
        case .translating:
            Label("Translating on This Device…", systemImage: "translate")
        case .unavailable:
            Text("On-device translation is unavailable for some lyric languages. Available translations are shown; unsupported text keeps its original wording.")
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("Translation could not finish. Original lyrics are shown for missing lines. Download the requested languages and try again.")
                Button("Retry Translation", action: retry)
            }
        case .idle, .ready:
            EmptyView()
        }
    }
}
