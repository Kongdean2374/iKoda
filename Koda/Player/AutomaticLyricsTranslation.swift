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
    var playbackSessionFinished = false
    var strategyStatus: String?
    var immersiveStatus: ImmersiveLyricStatus?
    var baseDiagnostics = AutomaticLyricTranslationPipeline.Snapshot()
    var polishDiagnostics = LyricPolishDiagnostics()
    var originalReady = false
    var originalSearching = false
    var originalLookupSeconds: TimeInterval?
    var originalCacheUse: LyricCacheUse = .unchecked
    var origins: [Int: LyricTranslationOrigin] = [:]
    var selectedSource: LyricTranslationSelection = .automatic
    var limits: Set<LyricWorkLimit> = []
    var languageProfile: LyricLanguageProfile?
    var skippedRows = 0
}

/// Installed language sessions belong to the work task, not to any lyrics view.
/// SwiftUI sessions below are used only for the system's foreground download prompt.
nonisolated enum NativeLyricsTranslationEngine {
    @concurrent
    static func translate(_ input: AutomaticLyricTranslationPipeline.Input, _ fragments: [ChineseLyricTranslationPlan.Fragment],
                          publish: @escaping AutomaticLyricTranslationPipeline.Publish,
                          report: @escaping AutomaticLyricTranslationPipeline.Report) async throws -> AutomaticLyricTranslationPipeline.Outcome {
        guard input.mode.usesAppleTranslation else { return .unavailable }
        let selected: [AppleLyricDiagnostics.LanguageRoute]
        if let routes = input.routes { selected = routes }
        else { selected = await routes(for: fragments, mode: input.mode) }
        let choices = Dictionary(selected.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        var languages: [String] = []
        for fragment in fragments where !languages.contains(fragment.language) { languages.append(fragment.language) }
        try Task.checkCancellation()
        var unavailable = false
        var usedCompatibility = false
        var diagnostics = AppleLyricDiagnostics()
        diagnostics.languages = selected
        await report(diagnostics)
        var missingLanguage: AutomaticLyricTranslationPipeline.LanguagePair?
        var translated: [String: String] = [:]
        for language in languages {
            try Task.checkCancellation()
            guard let choice = choices[language], let targetID = choice.target else { unavailable = true; continue }
            let source = Locale.Language(identifier: language)
            let target = Locale.Language(identifier: targetID)
            guard choice.support == .available else {
                if missingLanguage == nil {
                    missingLanguage = .init(source: language, target: targetID)
                }
                continue
            }
            // Repeated choruses need one translation per unique text, then fan out to all
            // original IDs. Submit the complete language group; no 24-line barriers.
            let group = fragments.filter { $0.language == language }
            var byText: [String: [ChineseLyricTranslationPlan.Fragment]] = [:]
            var unique: [ChineseLyricTranslationPlan.Fragment] = []
            for fragment in group {
                let key = input.mode == .quick ? fragment.text : fragment.id
                if byText[key] == nil { unique.append(fragment) }
                byText[key, default: []].append(fragment)
            }
            let responsesByID = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, byText[input.mode == .quick ? $0.text : $0.id] ?? []) })
            let strategy = choice.strategy ?? .standard
            usedCompatibility = usedCompatibility || (input.mode != .quick && strategy != .highFidelity)
            let requests = unique.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            let session: TranslationSession
            #if compiler(>=6.3)
            if #available(iOS 26.4, macCatalyst 26.4, *) {
                session = TranslationSession(installedSource: source, target: target,
                                             preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
            } else {
                session = TranslationSession(installedSource: source, target: target)
            }
            #else
            session = TranslationSession(installedSource: source, target: target)
            #endif
            diagnostics.strategies.insert(strategy)
            diagnostics.usedCompatibility = usedCompatibility
            await report(diagnostics)
            defer { session.cancel() }
            var lastPublished = ContinuousClock.now
            var reportedTarget: String?
            do {
                for try await response in session.translate(batch: requests) {
                    try Task.checkCancellation()
                    guard let id = response.clientIdentifier, let matching = responsesByID[id],
                          !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let actual = response.targetLanguage.minimalIdentifier
                    if reportedTarget != actual {
                        reportedTarget = actual
                        if let index = diagnostics.languages.firstIndex(where: { $0.source == language }) {
                            diagnostics.languages[index] = .init(source: language, target: targetID, support: .available,
                                strategy: strategy, supportedTaiwanTargets: choice.supportedTaiwanTargets, reportedTarget: actual)
                            await report(diagnostics)
                        }
                    }
                    let text = TraditionalChineseLyrics.convert(response.targetText)
                    for fragment in matching { translated[fragment.id] = text }
                    let now = ContinuousClock.now
                    if lastPublished.duration(to: now) >= .milliseconds(100) {
                        await publish(translated)
                        lastPublished = now
                    }
                }
            } catch {
                try Task.checkCancellation()
                diagnostics.lastError = (error as? URLError)?.code == .timedOut ? .timeout : .translation
                unavailable = true
                await report(diagnostics)
            }
            try Task.checkCancellation()
            await publish(translated)
            if group.contains(where: { translated[$0.id] == nil }) { unavailable = true }
        }
        try Task.checkCancellation()
        if let missingLanguage { return .needsLanguage(missingLanguage) }
        if unavailable { return .unavailable }
        return usedCompatibility ? .compatible : .complete
    }

    @concurrent
    static func routes(for fragments: [ChineseLyricTranslationPlan.Fragment], mode: LyricsTranslationMode) async
        -> [AppleLyricDiagnostics.LanguageRoute] {
        guard mode.usesAppleTranslation else { return [] }
        let sources = Set(fragments.map(\.language)).sorted()
        guard !sources.isEmpty else { return [] }
        var compatible: AppleLyricDiagnostics.Strategy = .standard
        #if compiler(>=6.3)
        if #available(iOS 26.4, macCatalyst 26.4, *) { compatible = .lowLatency }
        #endif
        let ordinary = await supportedRoutes(sources, strategy: compatible)
        var candidates = ordinary
        #if compiler(>=6.3)
        if #available(iOS 26.4, macCatalyst 26.4, *), mode != .quick, !Task.isCancelled {
            candidates += await supportedRoutes(sources, strategy: .highFidelity)
        }
        #endif
        return sources.map { source in
            let options = candidates.filter { $0.source == source }
            let taiwan = Set(options.compactMap(\.target).filter { LyricChineseTarget.tier($0) <= 2 }).sorted()
            guard let selected = LyricChineseTarget.choose(options, prefersQuality: mode != .quick) else {
                return .init(source: source, target: nil, support: .unsupported, supportedTaiwanTargets: taiwan)
            }
            return .init(source: source, target: selected.target, support: selected.support, strategy: selected.strategy,
                         supportedTaiwanTargets: taiwan)
        }
    }

    /// Checks actual support per pair. A Locale existing does not imply a
    /// compatible model or installed language pack.
    @concurrent
    private static func supportedRoutes(_ sources: [String], strategy: AppleLyricDiagnostics.Strategy) async
        -> [AppleLyricDiagnostics.LanguageRoute] {
        let availability: LanguageAvailability
        #if compiler(>=6.3)
        if #available(iOS 26.4, macCatalyst 26.4, *) {
            availability = LanguageAvailability(preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
        } else { availability = LanguageAvailability() }
        #else
        availability = LanguageAvailability()
        #endif
        let supported = await availability.supportedLanguages
        let chinese = supported.filter { ["zh", "yue"].contains($0.languageCode?.identifier ?? "") }
        let targets = LyricChineseTarget.ordered(chinese.map(\.minimalIdentifier))
        var results: [AppleLyricDiagnostics.LanguageRoute] = []
        for source in sources {
            for target in targets {
                guard !Task.isCancelled else { return [] }
                let status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
                switch status {
                case .installed: results.append(.init(source: source, target: target, support: .available, strategy: strategy))
                case .supported: results.append(.init(source: source, target: target, support: .download, strategy: strategy))
                case .unsupported: break
                @unknown default: break
                }
            }
        }
        return results
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
        VStack(alignment: .leading, spacing: 6) {
            if let status = result.strategyStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
            progress
        }
    }

    @ViewBuilder private var progress: some View {
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
            if result.playbackSessionFinished {
                Text("The listening session has ended. Play music to resume translation. Saved translations are kept.")
            } else {
                Text("Translation is paused. Saved translations are kept and remaining lines resume when the app is active.")
            }
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
