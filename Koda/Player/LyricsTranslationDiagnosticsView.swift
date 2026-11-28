import KodaCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct LyricsTranslationSourceSection: View {
    let imported: [Int: String]
    @Environment(AppModel.self) private var app

    var body: some View {
        let versions = app.lyricsTranslation.versions
        if let candidate = versions.current {
            Section("Translation Sources") {
                Picker("Preferred Translation Source", selection: Binding(
                    get: { versions.translationSelection },
                    set: { choice in Task { await versions.selectTranslation(choice) } }
                )) {
                    Text("Automatic").tag(LyricTranslationSelection.automatic)
                    Text("Apple Translation").tag(LyricTranslationSelection.appleTranslation)
                    if !imported.isEmpty || versions.translationSelection == .imported {
                        Text("Imported Translation").tag(LyricTranslationSelection.imported)
                    }
                    ForEach(candidate.embeddedTranslations ?? []) { translation in
                        let language = Locale.current.localizedString(forIdentifier: translation.language) ?? translation.language
                        Text("Lyrics Provider · \(language)").tag(LyricTranslationSelection.provider(translation.id))
                    }
                    if case .provider(let id) = versions.translationSelection,
                       candidate.embeddedTranslations?.contains(where: { $0.id == id }) != true {
                        Text("Saved Translation Unavailable").tag(versions.translationSelection)
                    }
                }
                .accessibilityIdentifier("lyrics.translation.source")
            }
        }
    }
}

struct LyricsTranslationDiagnosticsView: View {
    let lines: [LyricsTranslationText]
    let imported: [Int: String]
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        let result = app.lyricsTranslation.result(songID: player.current?.id, lines: lines, imported: imported)
        let snapshot = result.baseDiagnostics
        let unavailable = String(localized: "Unavailable")
        let routes = snapshot.apple.languages.map { route in
            let target = route.reportedTarget ?? route.target ?? "—"
            return "\(route.source) → \(target) · \(route.support.label)"
        }
        let origins = Dictionary(grouping: result.origins.values, by: \.label)
            .map { "\($0.key) (\($0.value.count))" }.sorted().joined(separator: ", ")
        let fields: [(String, String)] = [
            (String(localized: "Primary Lyric Language"), result.languageProfile?.primary?.language ?? unavailable),
            (String(localized: "Apple Translation Language Pairs"), routes.isEmpty ? unavailable : routes.joined(separator: "\n")),
            (String(localized: "Base Lines Completed"), "\(snapshot.completedRows) / \(snapshot.sourceRows)"),
            (String(localized: "Apple Translation Time"), snapshot.translationSeconds.map {
                $0.formatted(.number.precision(.fractionLength(0...3))) + " s"
            } ?? unavailable),
            (String(localized: "Base Translation Cache"), snapshot.cacheUse.label),
            (String(localized: "Most Recent Error Type"), snapshot.apple.lastError?.label ?? String(localized: "None")),
            (String(localized: "Base Translation Status"), status(result)),
            (String(localized: "Displayed Translation Sources"), origins)
        ]
        List {
            ForEach(fields.indices, id: \.self) { i in LabeledContent(fields[i].0, value: fields[i].1) }
            Button("Copy Diagnostic Summary", systemImage: "doc.on.doc") {
                let summary = fields.map { $0.0 + " · " + $0.1 }.joined(separator: "\n")
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: summary]], options: [.localOnly: true])
            }
            .accessibilityIdentifier("lyrics.diagnostics.copy")
        }
        .navigationTitle("Translation Diagnostics")
    }

    private func status(_ result: AutomaticLyricsResult) -> String {
        if !app.settings.showsLyricsTranslation { return String(localized: "Off") }
        if result.instrumental { return String(localized: "Instrumental") }
        if !result.originalReady {
            return result.originalSearching ? String(localized: "Searching Lyrics…") : String(localized: "No Lyrics")
        }
        if result.unnecessary { return String(localized: "No Translation Needed") }
        return result.baseDiagnostics.phase.label
    }
}

struct LyricsTranslationLanguagesView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        let coordinator = app.lyricsTranslation
        let snapshot = coordinator.translationSnapshot
        List {
            Section("Apple Translation Language Pairs") {
                if snapshot.apple.languages.isEmpty {
                    Text("Language pairs appear after Koda prepares the current song’s lyrics.").foregroundStyle(.secondary)
                }
                ForEach(snapshot.apple.languages) { pair in
                    LabeledContent {
                        Text(pair.support.label).foregroundStyle(.secondary)
                    } label: {
                        let source = Locale.current.localizedString(forIdentifier: pair.source) ?? pair.source
                        let code = pair.reportedTarget ?? pair.target ?? "—"
                        let target = Locale.current.localizedString(forIdentifier: code) ?? code
                        Text([source, target].joined(separator: " → "))
                    }
                }
                if snapshot.phase == .needsLanguage {
                    Button("Retry Language Download") { coordinator.retry(songID: player.current?.id) }
                }
            }
        }
        .navigationTitle("Translation Language Packs")
        .background { LyricsTranslationDownloadHost(coordinator: coordinator) }
    }
}

private extension AutomaticLyricTranslationPipeline.Phase {
    var label: String {
        switch self {
        case .idle: String(localized: "Waiting to Translate")
        case .preparing: String(localized: "Preparing…")
        case .translating: String(localized: "Translating…")
        case .ready: String(localized: "Translated")
        case .needsLanguage: String(localized: "Language Needed")
        case .unavailable: String(localized: "Unavailable")
        case .failed: String(localized: "Translation Failed")
        case .paused: String(localized: "Translation Paused")
        }
    }
}

private extension AppleLyricDiagnostics.Support {
    var label: String {
        switch self {
        case .available: String(localized: "Available")
        case .download: String(localized: "Language Needed")
        case .unsupported, .unknown: String(localized: "Unavailable")
        }
    }
}

private extension LyricCacheUse {
    var label: String {
        switch self {
        case .hit, .legacy: String(localized: "Cache Hit")
        case .miss: String(localized: "Cache Miss")
        case .partial: String(localized: "Partial Cache Hit")
        case .unchecked: String(localized: "Not Measured")
        }
    }
}

private extension LyricWorkError {
    var label: String {
        switch self {
        case .timeout: String(localized: "Timed Out")
        case .language: String(localized: "Language Needed")
        default: String(localized: "Translation Failed")
        }
    }
}

private extension LyricTranslationOrigin {
    var label: String {
        switch self {
        case .appleTranslation: String(localized: "Apple Translation")
        case .imported: String(localized: "Imported Translation")
        case .provider: String(localized: "Lyrics Provider Translation")
        case .edited: String(localized: "Edited Translation")
        }
    }
}
