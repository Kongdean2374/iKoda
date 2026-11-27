import KodaCore
import SwiftUI
import UniformTypeIdentifiers

/// On-device translation and optional imports share the same presentation without editing source lyrics.
struct LyricsTranslationSettingsView: View {
    /// The player orb is the only display switch in its details/settings route.
    var showsDisplayToggle = true
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var importing = false
    @State private var importVersion: LyricsCandidate?
    @State private var importScope = UUID()
    @State private var hasImport = false
    @State private var message: String?
    @State private var isWorking = false
    @State private var pendingLegacy: LyricTranslationDocument?
    @State private var confirmsLegacy = false
    @State private var removesLegacy = false
    @State private var legacyRemovalSongID: String?
    @State private var legacyRemovalScope: UUID?
    @State private var storageBytes = 0
    @State private var confirmsClear = false
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                if showsDisplayToggle {
                    Toggle("Show Chinese Translation", isOn: $settings.showsLyricsTranslation)
                }
                Toggle("Automatically Translate to Traditional Chinese", isOn: $settings.automaticLyricsTranslation)
                Toggle("Use Imported Translations", isOn: $settings.importedLyricsEnabled)
                Picker("Translation Mode", selection: $settings.lyricsTranslationMode) {
                    ForEach(LyricsTranslationMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityValue(settings.lyricsTranslationMode.title)
                .accessibilityIdentifier("lyrics.translation.mode")
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Automatic translation uses Apple's on-device languages. The system may ask to download a language first; installed languages work offline. Chinese lyrics use local Simplified-to-Traditional conversion. Available imported lines take priority.")
                    Text("Translated sentences follow the original lyric lines without word-by-word animation. Missing translations keep the original text. Changing this setting does not change playback.")
                }
            }
            Section {
                Picker("Under Each Line", selection: $settings.lyricsExtra) {
                    Label(AppSettings.LyricsExtra.off.title, systemImage: AppSettings.LyricsExtra.off.systemImage).tag(AppSettings.LyricsExtra.off)
                    Label(AppSettings.LyricsExtra.pronunciation.title, systemImage: AppSettings.LyricsExtra.pronunciation.systemImage).tag(AppSettings.LyricsExtra.pronunciation)
                }
            } footer: {
                Text("Pronunciation appears when translation is off, for lyrics in supported scripts.")
            }
            Section("Lyrics Work and Storage") {
                Stepper(value: $settings.lyricsPrefetchLimit, in: 0...5) {
                    Text("Prefetch \(settings.lyricsPrefetchLimit) Upcoming Songs")
                }
                LabeledContent("Automatic Lyrics Cache", value: ByteCountFormatter.string(fromByteCount: Int64(storageBytes), countStyle: .file))
                Picker("Cache Limit", selection: $settings.lyricsCacheMegabytes) {
                    ForEach([25, 50, 100, 150, 250], id: \.self) { limit in
                        Text("\(limit) MB").tag(limit)
                    }
                }
                Button("Translate This Version Again") { Task { await app.lyricsTranslation.regenerate(clear: false) } }
                    .disabled(versions.current == nil || isWorking || !settings.automaticLyricsTranslation)
                    .accessibilityIdentifier("lyrics.translation.retry")
                if settings.lyricsTranslationMode == .immersive {
                    Button("Polish This Version Again") { Task { await app.lyricsTranslation.regenerate(clear: false, polishOnly: true) } }
                        .disabled(versions.current == nil)
                }
                Button("Clear This Mode’s Cached Translation", role: .destructive) { confirmsClear = true }
                    .disabled(versions.current == nil)
            }
            Section("Translation Appearance") {
                valueSlider("Translation Text Size", value: $settings.translationFontSize, range: 12...32, step: 1,
                            valueText: String(localized: "\(Int(settings.translationFontSize)) pt"))
                valueSlider("Translation Opacity", value: $settings.translationOpacity, range: 0.3...1, step: 0.05,
                            valueText: settings.translationOpacity.formatted(.percent.precision(.fractionLength(0))))
                valueSlider("Space Between Languages", value: $settings.translationSpacing, range: 2...20, step: 1,
                            valueText: String(localized: "\(Int(settings.translationSpacing)) pt"))
                Button("Reset Translation Appearance") {
                    settings.translationFontSize = 18
                    settings.translationOpacity = 0.75
                    settings.translationSpacing = 6
                }
            }
            Section {
                if let song = player.current {
                    LabeledContent("Current Song", value: song.title)
                    if let candidate = versions.current, candidate.songID == song.id, candidate.format != .plain {
                        Button("Import Translation…", systemImage: "square.and.arrow.down") {
                            importVersion = candidate
                            importScope = versions.profileScope
                            importing = true
                        }
                        .disabled(isWorking)
                        if hasImport {
                            Button("Remove This Translation", systemImage: "trash", role: .destructive) {
                                storeDocument(nil, candidate: candidate, scope: versions.profileScope)
                            }
                            .disabled(isWorking)
                        }
                        if pendingLegacy != nil {
                            Button("Attach Older Translation to This Version") {
                                importVersion = candidate
                                importScope = versions.profileScope
                                confirmsLegacy = true
                            }
                        }
                    } else { Text("Choose synced lyrics before attaching a translation.").foregroundStyle(.secondary) }
                    if pendingLegacy != nil {
                        Button("Remove Older Translation", role: .destructive) {
                            legacyRemovalSongID = song.id
                            legacyRemovalScope = versions.profileScope
                            removesLegacy = true
                        }
                            .disabled(isWorking)
                    }
                } else {
                    Text("Play a song to import its translation.").foregroundStyle(.secondary)
                }
                if isWorking { ProgressView() }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Translation File")
            } footer: {
                Text("Imported translations stay on this device. They are saved for the exact lyrics version and are kept when automatic caches are cleared.")
            }
            Section("Supported Formats") {
                Text("Use UTF-8 LRC with the original timestamps. A translated-only LRC or an original/translation pair at the same timestamp is supported. A timestamp must be within half a second of its original line.")
                Text(verbatim: "[00:10.00] Original line\n[00:10.00] 繁體中文譯文")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Text("For simultaneous singers, JSON can identify the original line and voice. Times are seconds; voice is lead, duet, or together.")
                Text(verbatim: "{\"version\":1,\"language\":\"zh-Hant\",\"lines\":[{\"time\":10,\"text\":\"繁體中文譯文\",\"original\":\"Original line\",\"voice\":\"lead\"}]}")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Chinese Lyrics")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: versions.current?.id) {
            message = nil
            pendingLegacy = nil
            hasImport = versions.current.flatMap { versions.importedDocument(for: $0) } != nil
            guard let songID = player.current?.id else { return }
            let scope = versions.profileScope
            let document = await LyricTranslationStore.shared.document(for: songID)
            guard !Task.isCancelled, player.current?.id == songID, versions.profileScope == scope else { return }
            pendingLegacy = document
        }
        .task(id: app.settings.lyricsCacheMegabytes) {
            app.lyricsTranslation.setCacheCapacity(megabytes: app.settings.lyricsCacheMegabytes)
            storageBytes = await app.lyricsTranslation.cacheUsage()
        }
        .confirmationDialog("Attach Older Translation to This Version", isPresented: $confirmsLegacy, titleVisibility: .visible) {
            Button("Attach Translation") {
                if let candidate = importVersion, let pendingLegacy {
                    storeDocument(pendingLegacy, candidate: candidate, scope: importScope)
                }
            }
        } message: { Text("Check that this version matches the original import before attaching it. The older file is kept.") }
        .confirmationDialog("Remove Older Translation", isPresented: $removesLegacy, titleVisibility: .visible) {
            Button("Remove Older Translation", role: .destructive) {
                guard let songID = legacyRemovalSongID, songID == player.current?.id,
                      let scope = legacyRemovalScope, scope == versions.profileScope else { return }
                Task {
                    do {
                        try await LyricTranslationStore.shared.remove(for: songID)
                        guard player.current?.id == songID, versions.profileScope == scope else { return }
                        pendingLegacy = nil
                    } catch {
                        guard player.current?.id == songID, versions.profileScope == scope else { return }
                        message = error.localizedDescription
                    }
                }
            }
        } message: { Text("This removes the older file. Copies attached to a specific version stay available.") }
        .confirmationDialog("Clear This Mode’s Cached Translation", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await app.lyricsTranslation.regenerate(clear: true)
                    storageBytes = await app.lyricsTranslation.cacheUsage()
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json, .data]) { result in
            guard let candidate = importVersion else { return }
            let scope = importScope
            switch result {
            case .success(let url): importFile(url, candidate: candidate, scope: scope)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private func valueSlider(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double, valueText: String) -> some View {
        VStack(alignment: .leading) {
            HStack { Text(title); Spacer(); Text(valueText).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step) { Text(title) }
        }
    }

    private func importFile(_ url: URL, candidate: LyricsCandidate, scope: UUID) {
        isWorking = true
        Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 1_000_001) ?? Data()
                    return try LyricTranslationDocument.parse(data)
                }.value
                try await store(document, candidate: candidate, scope: scope)
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func storeDocument(_ document: LyricTranslationDocument?, candidate: LyricsCandidate, scope: UUID) {
        isWorking = true
        Task {
            do { try await store(document, candidate: candidate, scope: scope) }
            catch { message = error.localizedDescription }
            isWorking = false
        }
    }

    private func store(_ document: LyricTranslationDocument?, candidate: LyricsCandidate, scope: UUID) async throws {
        try await versions.saveImport(document, candidate: candidate, expectedScope: scope)
        hasImport = document != nil
        if document != nil {
            app.settings.importedLyricsEnabled = true
            if app.settings.lyricsDisplayMode == .original { app.settings.lyricsDisplayMode = .bilingual }
            message = String(localized: "Translation Attached to This Version")
        } else { message = String(localized: "Translation removed. The original lyrics are unchanged.") }
    }
}
