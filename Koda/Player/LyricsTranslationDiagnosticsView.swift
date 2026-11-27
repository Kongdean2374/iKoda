import KodaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ImmersiveLyricStatus {
    var title: LocalizedStringKey {
        switch self {
        case .preparing: "Preparing…"
        case .baseTranslation: "Translating Base Lyrics…"
        case .polishing: "AI Context Translation…"
        case .completed: "Context Polish Complete"
        case .partial: "Context Polish Partially Complete"
        case .modelUnavailable: "AI Model Unavailable"
        case .languageUnsupported: "AI Language Unsupported"
        case .paused: "Context Polish Paused"
        case .fallback: "Showing Base Translation"
        case .failed: "Context Polish Failed"
        case .unnecessary: "No Semantic Translation Needed"
        }
    }
}

struct LyricsTranslationSourceSection: View {
    let lines: [LyricsTranslationText]
    let imported: [Int: String]
    let result: AutomaticLyricsResult
    @Environment(AppModel.self) private var app

    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        if let candidate = versions.current {
            Section("Translation Sources") {
                let available = candidate.embeddedTranslations ?? []
                let selected = versions.translationSelection
                Picker(selection: Binding(get: { selected }, set: { choice in
                    Task { await versions.selectTranslation(choice) }
                })) {
                    Text("Automatic").tag(LyricTranslationSelection.automatic)
                    Text("Apple Translation").tag(LyricTranslationSelection.appleTranslation)
                    if !imported.isEmpty || selected == .imported {
                        Text("Imported Translation").tag(LyricTranslationSelection.imported)
                    }
                    if app.settings.lyricsTranslationMode == .immersive || selected == .foundationModels
                        || !app.lyricsTranslation.contextualLines(for: candidate).isEmpty {
                        Text("Apple Intelligence").tag(LyricTranslationSelection.foundationModels)
                    }
                    ForEach(available) { translation in
                        Text(translation.label).tag(LyricTranslationSelection.provider(translation.id))
                    }
                    if case .provider(let id) = selected, !available.contains(where: { $0.id == id }) {
                        Text("Saved Translation Unavailable").tag(selected)
                    }
                } label: {
                    Text("Preferred Translation Source")
                }
                .accessibilityIdentifier("lyrics.translation.source")
                NavigationLink("Compare Translations") {
                    LyricsTranslationComparison(candidate: candidate, rows: lines, imported: imported)
                }
                if let error = versions.error { Text(error).foregroundStyle(.secondary) }
            }
        }
    }
}

private extension LyricEmbeddedTranslation {
    var label: String {
        let languageName = Locale.current.localizedString(forIdentifier: language) ?? language
        return convertedToTraditional
            ? String(localized: "Lyrics Provider · \(languageName) · Script Converted")
            : String(localized: "Lyrics Provider · \(languageName)")
    }
}

private struct LyricsTranslationComparison: View {
    let candidate: LyricsCandidate
    let rows: [LyricsTranslationText]
    let imported: [Int: String]
    @Environment(AppModel.self) private var app
    @State private var cachedContext: [Int: String] = [:]

    var body: some View {
        let result = app.lyricsTranslation.result(songID: candidate.songID, lines: rows)
        let currentAI = app.lyricsTranslation.contextualLines(for: candidate)
        let contextual = cachedContext.merging(currentAI) { _, live in live }
        let edits = app.lyricsTranslation.versions.edits(for: candidate)
        List {
            ForEach(rows, id: \.id) { row in
                if !row.text.isEmpty {
                    Section {
                        if let translated = edits[row.id] { LabeledContent("Edited Translation", value: translated) }
                        ForEach(candidate.embeddedTranslations ?? []) { source in
                            if let translated = source.lines[row.id] { LabeledContent(source.label, value: translated) }
                        }
                        if let translated = imported[row.id] { LabeledContent("Imported Translation", value: translated) }
                        if let translated = result.baseDiagnostics.lines[row.id] { LabeledContent("Apple Translation", value: translated) }
                        if let translated = contextual[row.id] { LabeledContent("Apple Intelligence", value: translated) }
                    } header: {
                        Text(row.text)
                    }
                }
            }
        }
        .navigationTitle("Compare Translations")
        .task(id: candidate.id) {
            cachedContext = await app.lyricsTranslation.cachedContextualLines(for: candidate)
        }
    }
}

/// All copyable values come from typed counters and classifications. Lyric
/// text, account identifiers, song names and localized error descriptions are omitted.
struct LyricsTranslationDiagnosticsView: View {
    let lines: [LyricsTranslationText]
    let imported: [Int: String]
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var copies = 0

    private struct Field: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    var body: some View {
        let result = app.lyricsTranslation.result(songID: player.current?.id, lines: lines, imported: imported,
                                                importsEnabled: app.settings.importedLyricsEnabled)
        let fields = diagnostics(result)
        List {
            Section {
                ForEach(fields) { value in
                    LabeledContent(value.title) {
                        Text(value.value).multilineTextAlignment(.trailing)
                    }
                }
            }
            Section {
                Button("Copy Diagnostic Summary", systemImage: "doc.on.doc") {
                    let summary = fields.map { $0.title + " · " + $0.value }.joined(separator: "\n")
                    UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: summary]], options: [.localOnly: true])
                    copies += 1
                }
                .accessibilityIdentifier("lyrics.diagnostics.copy")
                .sensoryFeedback(.success, trigger: copies)
            }
        }
        .navigationTitle("Translation Diagnostics")
    }

    private func diagnostics(_ result: AutomaticLyricsResult) -> [Field] {
        let base = result.baseDiagnostics
        let ai = result.polishDiagnostics
        let unavailable = String(localized: "Not Measured")
        func time(_ seconds: TimeInterval?) -> String {
            seconds.map { $0.formatted(.number.precision(.fractionLength(0...3))) + " s" } ?? unavailable
        }
        func yesNo(_ value: Bool?) -> String {
            value.map { $0 ? String(localized: "Yes") : String(localized: "No") } ?? unavailable
        }
        func count(_ value: Int) -> String { value.formatted() }
        let strategies = base.apple.strategies.map(\.label).sorted().joined(separator: ", ")
        let routes = base.apple.languages.sorted { $0.source < $1.source }.map {
            $0.source + " → " + ($0.target ?? "—") + " · " + $0.support.label
        }
        let modelRoute = ai.sources.keys.sorted().map { $0 + " · " + yesNo(ai.sources[$0]) }
        let origins = Dictionary(grouping: result.origins.values, by: \.label)
            .map { $0.key + " (" + count($0.value.count) + ")" }.sorted()
        let restrictions = result.limits.union(ai.limits).map(\.label).sorted()
        let latestError = ai.lastError?.label ?? base.apple.lastError?.label ?? String(localized: "None")
        return [
            .init(title: String(localized: "Selected Translation Mode"), value: app.settings.lyricsTranslationMode.title),
            .init(title: String(localized: "Displayed Translation Sources"), value: origins.isEmpty ? String(localized: "None") : origins.joined(separator: "\n")),
            .init(title: String(localized: "Original Lyrics Status"), value: result.originalReady ? String(localized: "Ready") : (result.originalSearching ? String(localized: "Searching Lyrics…") : String(localized: "Unavailable"))),
            .init(title: String(localized: "Base Translation Status"), value: base.phase.label),
            .init(title: String(localized: "Requested Translation Strategies"), value: strategies.isEmpty ? unavailable : strategies),
            .init(title: String(localized: "Compatible Translation Used"), value: yesNo(base.apple.usedCompatibility)),
            .init(title: String(localized: "Apple Translation Language Pairs"), value: routes.isEmpty ? unavailable : routes.joined(separator: "\n")),
            .init(title: String(localized: "Base Source Lines"), value: count(base.sourceRows)),
            .init(title: String(localized: "Base Lines Completed"), value: count(base.completedRows)),
            .init(title: String(localized: "Foundation Models Availability"), value: ai.availability.label),
            .init(title: String(localized: "Context Translation Status"), value: result.immersiveStatus.map { String(localized: $0.diagnosticTitle) } ?? unavailable),
            .init(title: String(localized: "Model Source Language Support"), value: modelRoute.isEmpty ? unavailable : modelRoute.joined(separator: "\n")),
            .init(title: String(localized: "Model Target Language Support"), value: ai.target.map { $0 + " · " + yesNo(ai.targetSupported) } ?? unavailable),
            .init(title: String(localized: "AI Lines Pending"), value: count(max(0, ai.total - ai.validated))),
            .init(title: String(localized: "AI Lines Processed This Run"), value: count(ai.processed)),
            .init(title: String(localized: "AI Lines Validated"), value: count(ai.validated)),
            .init(title: String(localized: "AI Lines Changed"), value: count(ai.changed)),
            .init(title: String(localized: "AI Lines Verified Unchanged"), value: count(ai.unchanged)),
            .init(title: String(localized: "Incomplete or Failed AI Batches"), value: count(ai.failedBatches)),
            .init(title: String(localized: "AI Batches Rejected by the Model"), value: count(ai.rejectedBatches)),
            .init(title: String(localized: "Original Lyrics Cache"), value: result.originalCacheUse.label),
            .init(title: String(localized: "Base Translation Cache"), value: base.cacheUse.label),
            .init(title: String(localized: "AI Translation Cache"), value: ai.cache.label + " (" + count(ai.cachedRows) + ")"),
            .init(title: String(localized: "Original Lyrics Preparation Time"), value: time(result.originalLookupSeconds)),
            .init(title: String(localized: "Base Preparation Time"), value: time(base.planningSeconds)),
            .init(title: String(localized: "Base Cache Read Time"), value: time(base.cacheSeconds)),
            .init(title: String(localized: "Apple Translation Time"), value: time(base.translationSeconds)),
            .init(title: String(localized: "AI Cache Read Time"), value: time(ai.cacheSeconds)),
            .init(title: String(localized: "AI Overview Time"), value: time(ai.summarySeconds)),
            .init(title: String(localized: "AI Context Translation Time"), value: time(ai.generationSeconds)),
            .init(title: String(localized: "AI Validation Time"), value: time(ai.validationSeconds)),
            .init(title: String(localized: "Most Recent Error Type"), value: latestError),
            .init(title: String(localized: "Current Processing Limits"), value: restrictions.isEmpty ? String(localized: "None") : restrictions.joined(separator: ", "))
        ]
    }
}

private extension ImmersiveLyricStatus {
    var diagnosticTitle: LocalizedStringResource {
        switch self {
        case .preparing: "Preparing…"
        case .baseTranslation: "Translating Base Lyrics…"
        case .polishing: "AI Context Translation…"
        case .completed: "Context Polish Complete"
        case .partial: "Context Polish Partially Complete"
        case .modelUnavailable: "AI Model Unavailable"
        case .languageUnsupported: "AI Language Unsupported"
        case .paused: "Context Polish Paused"
        case .fallback: "Showing Base Translation"
        case .failed: "Context Polish Failed"
        case .unnecessary: "No Semantic Translation Needed"
        }
    }
}

private extension AutomaticLyricTranslationPipeline.Phase {
    var label: String {
        switch self {
        case .idle: String(localized: "Not Measured")
        case .preparing: String(localized: "Preparing…")
        case .translating: String(localized: "Translating Base Lyrics…")
        case .ready: String(localized: "Ready")
        case .needsLanguage: String(localized: "Language Needed")
        case .unavailable: String(localized: "Unavailable")
        case .failed: String(localized: "Translation Failed")
        case .paused: String(localized: "Translation Paused")
        }
    }
}

private extension LyricTranslationOrigin {
    var label: String {
        switch self {
        case .provider: String(localized: "Lyrics Provider Translation")
        case .imported: String(localized: "Imported Translation")
        case .appleTranslation: String(localized: "Apple Translation")
        case .foundationModels: String(localized: "Apple Intelligence")
        case .edited: String(localized: "Edited Translation")
        }
    }
}

private extension AppleLyricDiagnostics.Strategy {
    var label: String {
        switch self {
        case .standard: String(localized: "Standard Apple Strategy")
        case .lowLatency: String(localized: "Low Latency")
        case .highFidelity: String(localized: "High Fidelity")
        }
    }
}

private extension AppleLyricDiagnostics.Support {
    var label: String {
        switch self {
        case .available: String(localized: "Available")
        case .download: String(localized: "Language Needed")
        case .unsupported: String(localized: "Language Unsupported")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension LyricModelAvailability {
    var label: String {
        switch self {
        case .unchecked: String(localized: "Not Measured")
        case .available: String(localized: "Available")
        case .ineligible: String(localized: "Device Is Ineligible")
        case .disabled: String(localized: "Apple Intelligence Is Disabled")
        case .notReady: String(localized: "On-Device Model Not Ready")
        case .unknown: String(localized: "Unknown")
        }
    }
}

private extension LyricCacheUse {
    var label: String {
        switch self {
        case .unchecked: String(localized: "Not Measured")
        case .miss: String(localized: "Cache Miss")
        case .partial: String(localized: "Partial Cache Hit")
        case .hit: String(localized: "Cache Hit")
        case .legacy: String(localized: "Previous Cache Format")
        }
    }
}

private extension LyricWorkLimit {
    var label: String {
        switch self {
        case .lowPower: String(localized: "Low Power Mode")
        case .thermal: String(localized: "Thermal Limit")
        case .background: String(localized: "Background Execution Limit")
        case .buffering: String(localized: "Playback Buffering")
        case .memory: String(localized: "Memory Pressure")
        }
    }
}

private extension LyricWorkError {
    var label: String {
        switch self {
        case .translation: String(localized: "Translation Failed")
        case .language: String(localized: "Language Unsupported")
        case .timeout: String(localized: "Timed Out")
        case .model: String(localized: "Model Error")
        case .invalidOutput: String(localized: "Invalid Model Output")
        case .refused: String(localized: "Model Refusal")
        case .incompleteOutput: String(localized: "Incomplete Model Output")
        case .context: String(localized: "Model Context Limit")
        }
    }
}
