import KodaCore
import SwiftUI
import Translation

/// Translation input is text-only; source lyric IDs and timing remain unchanged.
nonisolated struct LyricsTranslationText: Equatable, Sendable {
    let id: Int
    let text: String
}

nonisolated struct AutomaticLyricsResult: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle, preparing, translating, ready, needsLanguage, unavailable, failed, paused
    }
    var phase: Phase = .idle
    var lines: [Int: String] = [:]
    var completed = 0
    var total = 0
}

/// Installed language sessions belong to the work task, not to any lyrics view.
/// SwiftUI sessions below are used only for the system's foreground download prompt.
nonisolated enum NativeLyricsTranslationEngine {
    private struct LanguageChoice: Sendable {
        let source: Locale.Language
        let target: Locale.Language
        let installed: Bool
    }

    @concurrent
    static func translate(_ fragments: [ChineseLyricTranslationPlan.Fragment],
                          publish: @escaping @Sendable ([String: String]) async -> Void) async throws -> AutomaticLyricTranslationPipeline.Outcome {
        var languages: [String] = []
        for fragment in fragments where !languages.contains(fragment.language) { languages.append(fragment.language) }
        let choices = await languageChoices(for: languages)
        try Task.checkCancellation()
        var unavailable = false
        var missingLanguage: AutomaticLyricTranslationPipeline.LanguagePair?
        var translated: [String: String] = [:]
        for language in languages {
            try Task.checkCancellation()
            guard let choice = choices[language] else { unavailable = true; continue }
            guard choice.installed else {
                if missingLanguage == nil {
                    missingLanguage = .init(source: choice.source.minimalIdentifier, target: choice.target.minimalIdentifier)
                }
                continue
            }
            // Repeated choruses need one translation per unique text, then fan out to all
            // original IDs. Submit the complete language group; no 24-line barriers.
            let group = fragments.filter { $0.language == language }
            var byText: [String: [ChineseLyricTranslationPlan.Fragment]] = [:]
            var unique: [ChineseLyricTranslationPlan.Fragment] = []
            for fragment in group {
                if byText[fragment.text] == nil { unique.append(fragment) }
                byText[fragment.text, default: []].append(fragment)
            }
            let responsesByID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, byText[$0.text]!) })
            let requests = unique.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            let session = TranslationSession(installedSource: choice.source, target: choice.target)
            // Apple's iterator cancellation is cooperative and may not yield immediately.
            // The pipeline waits for this worker to exit before starting another session.
            defer { session.cancel() }
            var lastPublished = ContinuousClock.now
            for try await response in session.translate(batch: requests) {
                try Task.checkCancellation()
                guard let id = response.clientIdentifier, let matching = responsesByID[id],
                      !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let text = TraditionalChineseLyrics.convert(response.targetText)
                for fragment in matching { translated[fragment.id] = text }
                let now = ContinuousClock.now
                if lastPublished.duration(to: now) >= .milliseconds(100) {
                    await publish(translated)
                    lastPublished = now
                }
            }
            try Task.checkCancellation()
            await publish(translated)
            if group.contains(where: { translated[$0.id] == nil }) { unavailable = true }
        }
        try Task.checkCancellation()
        if let missingLanguage { return .needsLanguage(missingLanguage) }
        return unavailable ? .unavailable : .complete
    }

    /// Keep the non-Sendable availability object entirely on the generic executor.
    /// An installed Chinese variant is preferred over a supported-but-uninstalled one.
    @concurrent
    private static func languageChoices(for sourceLanguages: [String]) async -> [String: LanguageChoice] {
        let availability = LanguageAvailability()
        let supported = await availability.supportedLanguages
        guard !Task.isCancelled else { return [:] }
        let chinese = supported.filter { $0.languageCode?.identifier == "zh" }
        let targets = chinese.filter { $0.script?.identifier == "Hant" } + chinese.filter { $0.script?.identifier != "Hant" }
        var result: [String: LanguageChoice] = [:]
        for sourceID in sourceLanguages {
            let source = Locale.Language(identifier: sourceID)
            var downloadable: Locale.Language?
            for target in targets {
                let status = await availability.status(from: source, to: target)
                guard !Task.isCancelled else { return [:] }
                switch status {
                case .installed:
                    result[sourceID] = LanguageChoice(source: source, target: target, installed: true)
                case .supported:
                    if downloadable == nil { downloadable = target }
                case .unsupported: break
                @unknown default: break
                }
                if result[sourceID] != nil { break }
            }
            if result[sourceID] == nil, let target = downloadable {
                result[sourceID] = LanguageChoice(source: source, target: target, installed: false)
            }
        }
        return result
    }

    @concurrent
    static func isInstalled(source: String, target: String) async -> Bool {
        let availability = LanguageAvailability()
        let status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        if case .installed = status { return true }
        return false
    }
}

/// Mount once on the currently presented app surface. It never owns translated results
/// or installed-model work, so dismissing that surface cannot erase cached translations.
struct LyricsTranslationDownloadHost: View {
    let coordinator: LyricsTranslationCoordinator

    var body: some View {
        ZStack {
            if let request = coordinator.downloadRequest {
                NativeLyricsLanguageDownload(request: request, coordinator: coordinator)
                    .id(request.id)
            }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct NativeLyricsLanguageDownload: View {
    let request: LyricsTranslationCoordinator.DownloadRequest
    let coordinator: LyricsTranslationCoordinator

    var body: some View {
        Color.clear.translationTask(TranslationSession.Configuration(
            source: Locale.Language(identifier: request.source), target: Locale.Language(identifier: request.target)),
            action: Self.prepare(request: request, coordinator: coordinator))
    }

    nonisolated private static func prepare(request: LyricsTranslationCoordinator.DownloadRequest,
                                            coordinator: LyricsTranslationCoordinator) -> @concurrent (TranslationSession) async -> Void {
        { @concurrent session in
            guard await coordinator.beginLanguageDownload(request) else { return }
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                try Task.checkCancellation()
                // Preparation may return while a model is downloading. Do not assume an
                // installed session is usable until the actual language pair says so.
                let installed = await NativeLyricsTranslationEngine.isInstalled(source: request.source, target: request.target)
                try Task.checkCancellation()
                await coordinator.finishLanguageDownload(request, installed: installed)
            } catch {
                if Task.isCancelled { await coordinator.cancelLanguageDownload(request) }
                else { await coordinator.finishLanguageDownload(request, installed: false) }
            }
        }
    }
}

/// Progress is an honest count of completed source fragments, not playback position.
struct AutomaticLyricsNotice: View {
    let result: AutomaticLyricsResult
    let retry: () -> Void

    var body: some View {
        switch result.phase {
        case .preparing:
            Label("Preparing On-Device Translation…", systemImage: "translate")
        case .translating:
            if result.total > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Translating Lyrics: \(result.completed) of \(result.total)")
                    ProgressView(value: Double(result.completed), total: Double(max(1, result.total)))
                }
            } else {
                Label("Translating on This Device…", systemImage: "translate")
            }
        case .needsLanguage:
            VStack(alignment: .leading, spacing: 6) {
                Text("Download the requested languages to translate on this device. Existing translations are kept.")
                Button("Retry Translation", action: retry)
            }
        case .paused:
            Text("Translation is paused. Saved translations are kept and remaining lines resume when the app is active.")
        case .unavailable:
            Text("On-device translation is unavailable for some lyric languages. Available translations are shown; unsupported text keeps its original wording.")
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("Translation could not finish. Completed translations are saved; retry continues with the remaining lines.")
                Button("Retry Translation", action: retry)
            }
        case .idle, .ready:
            EmptyView()
        }
    }
}
