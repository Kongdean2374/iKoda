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
        case .unavailable: "Unavailable"
        }
    }
}

struct LyricsTranslationSourceSection: View {
    let lines: [LyricsTranslationText]
    let imported: [Int: String]
    let result: AutomaticLyricsResult
    @Environment(AppModel.self) private var app
    @State private var availableModes: Set<LyricsTranslationMode> = []
    @State private var isKept = false
    @State private var storageNotice: String?
    @State private var confirmsRemoval = false

    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        if let candidate = versions.current {
            Section("Translation Sources") {
                let available = candidate.embeddedTranslations ?? []
                let selected = versions.translationSelection
                Picker(selection: Binding(get: { selected }, set: { choice in
                    Task { await app.lyricsTranslation.selectTranslation(choice) }
                })) {
                    Text("Automatic").tag(LyricTranslationSelection.automatic)
                    if app.settings.lyricsTranslationMode != .pureAI || selected == .appleTranslation {
                        Text("Apple Translation").tag(LyricTranslationSelection.appleTranslation)
                    }
                    if !imported.isEmpty || selected == .imported {
                        Text("Imported Translation").tag(LyricTranslationSelection.imported)
                    }
                    if app.settings.lyricsTranslationMode.usesContextModel || selected == .foundationModels {
                        Text("Apple Intelligence").tag(LyricTranslationSelection.foundationModels)
                    }
                    ForEach(LyricsTranslationMode.allCases) { mode in
                        if availableModes.contains(mode) || selected == mode.sourceChoice {
                            Text(mode.title).tag(mode.sourceChoice)
                        }
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
                if result.polishDiagnostics.validated > 0 {
                    Button("Keep AI Translation on This Device", systemImage: "bookmark") {
                        let scope = versions.profileScope
                        Task {
                            do {
                                try await app.lyricsTranslation.retainAI(candidate)
                                guard versions.profileScope == scope, versions.current?.id == candidate.id else { return }
                                storageNotice = String(localized: "AI Translation Saved")
                                isKept = true
                            } catch {
                                if versions.profileScope == scope { storageNotice = String(localized: "Could Not Save AI Translation") }
                            }
                        }
                    }
                }
                if isKept {
                    Button("Remove Kept AI Translation", role: .destructive) { confirmsRemoval = true }
                }
                if let storageNotice { Text(storageNotice).foregroundStyle(.secondary) }
                if let error = versions.error { Text(error).foregroundStyle(.secondary) }
            }
            .task(id: [candidate.id.cacheNamespace, versions.profileScope.uuidString, app.settings.lyricsTranslationMode.rawValue]) {
                let scope = versions.profileScope
                let coordinator = app.lyricsTranslation
                let currentMode = coordinator.currentAIMode
                storageNotice = nil
                availableModes = []
                isKept = false
                for mode in LyricsTranslationMode.allCases {
                    let values = await coordinator.cachedTranslation(for: candidate, mode: mode)
                    guard !Task.isCancelled, scope == versions.profileScope, candidate.id == versions.current?.id else { return }
                    if !values.isEmpty { availableModes.insert(mode) }
                }
                do {
                    let kept = try await coordinator.retainedAI(candidate, mode: currentMode)
                    guard !Task.isCancelled, scope == versions.profileScope, candidate.id == versions.current?.id else { return }
                    isKept = kept != nil
                    let bytes = try await coordinator.retainedAIUsage()
                    if bytes > 0 {
                        guard !Task.isCancelled, scope == versions.profileScope, candidate.id == versions.current?.id else { return }
                        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                        storageNotice = String(localized: "Kept AI Translations: \(size)")
                    }
                } catch {
                    if !Task.isCancelled, scope == versions.profileScope { storageNotice = String(localized: "Could Not Read Kept AI Translations") }
                }
            }
            .confirmationDialog("Remove Kept AI Translation?", isPresented: $confirmsRemoval) {
                Button("Remove Kept AI Translation", role: .destructive) {
                    let scope = versions.profileScope
                    let mode = app.lyricsTranslation.currentAIMode
                    Task {
                        do {
                            try await app.lyricsTranslation.forgetAI(candidate, mode: mode)
                            guard versions.profileScope == scope, versions.current?.id == candidate.id else { return }
                            isKept = false
                            storageNotice = nil
                        } catch {
                            if versions.profileScope == scope { storageNotice = String(localized: "Could Not Remove Kept AI Translation") }
                        }
                    }
                }
            }
        }
    }
}

private extension LyricsTranslationMode {
    var sourceChoice: LyricTranslationSelection {
        switch self {
        case .quick: .quickApple
        case .quality: .qualityApple
        case .immersive: .immersiveAI
        case .pureAI: .pureAI
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
    @Environment(\.dismiss) private var dismiss
    @State private var cached: [LyricsTranslationMode: [Int: String]] = [:]
    @State private var filter = Filter.all
    @State private var selectedRows: Set<Int> = []

    private enum Filter: String, CaseIterable, Identifiable {
        case all, differences, unfinished
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All Lines"
            case .differences: "Different Translations"
            case .unfinished: "Unfinished Lines"
            }
        }
    }

    private struct Value: Identifiable {
        let label: String
        let text: String
        var choice: LyricTranslationSelection?
        var id: String { label }
    }

    var body: some View {
        let coordinator = app.lyricsTranslation
        let versions = coordinator.versions
        let result = coordinator.result(songID: candidate.songID, lines: rows)
        let currentAI = coordinator.currentAIMode
        let liveBase = app.settings.lyricsTranslationMode == .quick ? LyricsTranslationMode.quick : .quality
        let edits = versions.edits(for: candidate)
        let canTranslate = versions.current?.id == candidate.id && app.settings.lyricsTranslationMode.usesContextModel
            && !coordinator.isAIWorking
        List {
            Section {
                Picker("Show Translation Lines", selection: $filter) {
                    ForEach(Filter.allCases) { filter in Text(filter.title).tag(filter) }
                }
                if canTranslate {
                    Button("Translate Selected Lines Again", systemImage: "arrow.clockwise") {
                        let requested = selectedRows
                        let scope = versions.profileScope
                        selectedRows.removeAll()
                        Task { await coordinator.regenerateContext(requested, for: candidate, scope: scope) }
                    }
                    .disabled(selectedRows.isEmpty)
                }
            }
            ForEach(rows, id: \.id) { row in
                let values = values(for: row.id, result: result, edits: edits, activeAI: currentAI, activeBase: liveBase)
                let phase = result.polishDiagnostics.rows[row.id]
                if !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   includes(values, phase: phase) {
                    Section {
                        ForEach(values) { value in
                            LabeledContent(value.label, value: value.text)
                                .contextMenu {
                                    if let choice = value.choice {
                                        Button("Prefer This Translation") {
                                            Task { await coordinator.selectTranslation(choice) }
                                        }
                                    }
                                }
                        }
                        if canTranslate && phase != .unnecessary {
                            Button {
                                if !selectedRows.insert(row.id).inserted { selectedRows.remove(row.id) }
                            } label: {
                                Label("Select Line for Retranslation",
                                      systemImage: selectedRows.contains(row.id) ? "checkmark.circle.fill" : "circle")
                            }
                            .accessibilityAddTraits(selectedRows.contains(row.id) ? .isSelected : [])
                        }
                    } header: {
                        Text(row.text)
                    }
                }
            }
        }
        .navigationTitle("Compare Translations")
        .onChange(of: versions.profileScope) { _, _ in dismiss() }
        .onChange(of: versions.current?.id) { _, id in if id != candidate.id { dismiss() } }
        .task(id: candidate.id) {
            for mode in LyricsTranslationMode.allCases {
                let values = await coordinator.cachedTranslation(for: candidate, mode: mode)
                guard !Task.isCancelled else { return }
                cached[mode] = values
            }
        }
    }

    private func includes(_ values: [Value], phase: LyricAIRowState?) -> Bool {
        switch filter {
        case .all: true
        case .differences: Set(values.map { $0.text.precomposedStringWithCanonicalMapping }).count > 1
        case .unfinished:
            phase.map { [.pending, .processing, .unsupported, .invalid, .timedOut, .cancelled].contains($0) }
                ?? values.isEmpty
        }
    }

    private func values(for id: Int, result: AutomaticLyricsResult, edits: [Int: String],
                        activeAI: LyricsTranslationMode, activeBase: LyricsTranslationMode) -> [Value] {
        var values: [Value] = []
        if let edit = edits[id] { values.append(.init(label: String(localized: "Edited Translation"), text: edit)) }
        for provider in candidate.embeddedTranslations ?? [] {
            if let text = provider.lines[id] { values.append(.init(label: provider.label, text: text, choice: .provider(provider.id))) }
        }
        if let text = imported[id] {
            values.append(.init(label: String(localized: "Imported Translation"), text: text, choice: .imported))
        }
        for mode in LyricsTranslationMode.allCases {
            let live: String?
            if mode == activeAI { live = app.lyricsTranslation.contextualLines(for: candidate)[id] }
            else if mode == activeBase { live = result.baseDiagnostics.lines[id] }
            else { live = nil }
            if let text = live ?? cached[mode]?[id] {
                values.append(.init(label: mode.title, text: text, choice: mode.sourceChoice))
            }
        }
        return values
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
        let isFallback = result.immersiveStatus != nil && result.selectedSource != .appleTranslation
            && result.origins.values.contains(.appleTranslation)
        let latestError = ai.lastError?.label ?? base.apple.lastError?.label ?? String(localized: "None")
        let validation: String
        if ai.validated > 0 {
            validation = ai.validated == ai.total ? String(localized: "All AI Rows Validated") : String(localized: "Some AI Rows Validated")
        } else if ai.failedBatches > 0 {
            validation = String(localized: "AI Validation Failed")
        } else { validation = String(localized: "Validation Pending") }
        return [
            .init(title: String(localized: "Selected Translation Mode"), value: app.settings.lyricsTranslationMode.title),
            .init(title: String(localized: "Displayed Translation Sources"), value: origins.isEmpty ? String(localized: "None") : origins.joined(separator: "\n")),
            .init(title: String(localized: "Primary Lyric Language"), value: ai.language?.primary.map {
                $0.language + " · " + $0.confidence.formatted(.percent.precision(.fractionLength(0)))
            } ?? unavailable),
            .init(title: String(localized: "Paragraph Languages"), value: ai.language.map { profile in
                profile.paragraphs.prefix(30).map { $0.language ?? "—" }.joined(separator: ", ")
            } ?? unavailable),
            .init(title: String(localized: "Corrected Language Guesses"), value: count(ai.language?.corrected ?? 0)),
            .init(title: String(localized: "Ignored Vocalization Lines"), value: count(ai.language?.vocalizations.count ?? 0)),
            .init(title: String(localized: "Untranslated by Design"), value: count(ai.noTranslation)),
            .init(title: String(localized: "Taiwan Chinese Pairs Reported by Apple"), value: base.apple.languages.compactMap { route in
                let targets = route.supportedTaiwanTargets ?? []
                return targets.isEmpty ? nil : route.source + " → " + targets.joined(separator: ", ")
            }.joined(separator: "\n").nilWhenEmpty ?? unavailable),
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
            .init(title: String(localized: "AI Validation Status"), value: validation),
            .init(title: String(localized: "AI Work Stage"), value: ai.phase.label),
            .init(title: String(localized: "AI Song Overview"), value: ai.summaryState.label),
            .init(title: String(localized: "AI Batches Submitted"), value: count(ai.currentBatch)),
            .init(title: String(localized: "AI Completed Batches"), value: count(ai.successfulBatches)),
            .init(title: String(localized: "AI Retry Batches"), value: count(ai.retryBatches)),
            .init(title: String(localized: "AI Lines with Base Reference"), value: count(ai.hinted)),
            .init(title: String(localized: "Pure AI Result Lines"), value: count(ai.pure ? ai.translatedWithoutBase : 0)),
            .init(title: String(localized: "AI Lines Reused from Chorus"), value: count(ai.reusedRows)),
            .init(title: String(localized: "AI Invalid Lines"), value: count(ai.rows.values.count { $0 == .invalid })),
            .init(title: String(localized: "AI Lines That Timed Out"), value: count(ai.rows.values.count { $0 == .timedOut })),
            .init(title: String(localized: "AI Unsupported Lines"), value: count(ai.rows.values.count { $0 == .unsupported })),
            .init(title: String(localized: "Total AI Work Time"), value: time(ai.elapsedSeconds)),
            .init(title: String(localized: "Last AI Progress"), value: ai.lastProgress?.formatted(date: .omitted, time: .standard) ?? unavailable),
            .init(title: String(localized: "Earlier AI Error"), value: ai.historicalError?.label ?? String(localized: "None")),
            .init(title: String(localized: "Base Fallback Displayed"),
                  value: yesNo(isFallback)),
            .init(title: String(localized: "AI Lines Pending"), value: count(ai.rows.values.count { $0 == .pending || $0 == .processing })),
            .init(title: String(localized: "AI Lines Processed This Run"), value: count(ai.processed)),
            .init(title: String(localized: "AI Lines Validated"), value: count(ai.validated)),
            .init(title: String(localized: "AI Lines Changed"), value: count(ai.changed)),
            .init(title: String(localized: "AI Lines Translated Without Base"), value: count(ai.translatedWithoutBase)),
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
        case .unavailable: "Unavailable"
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
        case .foundationModels: String(localized: "Immersive Translation")
        case .pureAI: String(localized: "Pure AI Translation (Experimental)")
        case .quickApple: String(localized: "Quick Translation")
        case .qualityApple: String(localized: "High Quality Translation")
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


private extension String {
    var nilWhenEmpty: String? { isEmpty ? nil : self }
}

private extension LyricAIWorkPhase {
    var label: String {
        switch self {
        case .queued: String(localized: "Waiting for AI Work")
        case .identifying: String(localized: "Identifying Lyric Languages…")
        case .preparing: String(localized: "Preparing Lyric Context…")
        case .summarizing: String(localized: "Summarizing Lyrics…")
        case .generating: String(localized: "AI Context Translation…")
        case .validating: String(localized: "Validating AI Translation")
        case .retrying: String(localized: "Retrying Unfinished Lines…")
        case .awaitingCancellation: String(localized: "AI Timed Out; Waiting for the Model to Stop")
        case .paused: String(localized: "Context Polish Paused")
        case .complete: String(localized: "Context Polish Complete")
        case .partial: String(localized: "Context Polish Partially Complete")
        case .unavailable: String(localized: "Unavailable")
        case .failed: String(localized: "Context Polish Failed")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}

private extension LyricAISummaryState {
    var label: String {
        switch self {
        case .waiting: String(localized: "Not Measured")
        case .running: String(localized: "Summarizing Lyrics…")
        case .complete: String(localized: "Song Overview Complete")
        case .shortContext: String(localized: "Full Lyrics Used as Context")
        case .unsupportedPrimary: String(localized: "Main Language Unavailable; Using Adjacent Lyrics")
        case .failed: String(localized: "Overview Failed; Using Adjacent Lyrics")
        case .cancelled: String(localized: "Cancelled")
        }
    }
}
