import KodaCore
import SwiftUI
import UniformTypeIdentifiers

/// User-controlled, local translation imports. The original lyric provider and timeline remain untouched.
struct LyricsTranslationSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var importing = false
    @State private var importSong: Song?
    @State private var hasImport = false
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Imported Chinese Translations", isOn: $settings.importedLyricsEnabled)
                Picker("Lyrics Display", selection: $settings.lyricsDisplayMode) {
                    ForEach(LyricsDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!settings.importedLyricsEnabled)
            } footer: {
                Text("Original lyrics keep their word timing. Missing translations fall back to the original line. Changing this setting does not change playback.")
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
                    Button("Import Translation…", systemImage: "square.and.arrow.down") {
                        importSong = song
                        importing = true
                    }
                    .disabled(isWorking)
                    if hasImport {
                        Button("Remove This Translation", systemImage: "trash", role: .destructive) { remove(for: song.id) }
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
                Text("Import only translations you have permission to use. Files stay on this device and are never sent to a translation service. The 100 most recent imports are kept, up to 10 MB.")
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
        .task(id: player.current?.id) {
            message = nil
            guard let songID = player.current?.id else { hasImport = false; return }
            let document = await LyricTranslationStore.shared.document(for: songID)
            guard !Task.isCancelled, player.current?.id == songID else { return }
            hasImport = document != nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .json, .data]) { result in
            guard let song = importSong else { return }
            switch result {
            case .success(let url): importFile(url, for: song)
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

    private func importFile(_ url: URL, for song: Song) {
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
                try await LyricTranslationStore.shared.save(document, for: song.id)
                app.settings.lyricsTranslationRevision += 1
                app.settings.importedLyricsEnabled = true
                if app.settings.lyricsDisplayMode == .original { app.settings.lyricsDisplayMode = .bilingual }
                if player.current?.id == song.id { hasImport = true }
                message = String(localized: "Translation imported for \(song.title).")
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func remove(for songID: String) {
        isWorking = true
        Task {
            do {
                try await LyricTranslationStore.shared.remove(for: songID)
                app.settings.lyricsTranslationRevision += 1
                if player.current?.id == songID { hasImport = false }
                message = String(localized: "Translation removed. The original lyrics are unchanged.")
            } catch { message = error.localizedDescription }
            isWorking = false
        }
    }
}
