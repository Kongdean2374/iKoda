import KodaCore
import SwiftUI

/// Custom services receive only the metadata named in the listener's URL template.
struct CustomLyricsSourcesView: View {
    @Environment(AppModel.self) private var app
    @State private var editor: EditorRequest?
    @State private var message: String?

    private struct EditorRequest: Identifiable {
        let source: CustomLyricsSource
        let isNew: Bool
        var id: UUID { source.id }
    }

    var body: some View {
        Form {
            Section {
                ForEach(app.settings.customLyricsSources) { source in
                    sourceRow(source)
                }
                Button("Add Lyrics Source", systemImage: "plus") {
                    editor = EditorRequest(source: CustomLyricsSource(name: "", urlTemplate: ""), isNew: true)
                }
                .disabled(app.settings.customLyricsSources.count >= CustomLyricsSource.maximumCount)
            } footer: {
                Text("Add up to five HTTPS sources. Enabled custom sources are checked alongside the built-in sources. At least one source must stay enabled.")
            }
            Section("How Custom Sources Work") {
                Text("The song title, artist, album and duration in your URL template are sent to the server you choose. Koda does not send lyrics, account cookies or login tokens.")
                Text("The endpoint must return LRC, TTML, plain lyrics, or compatible JSON containing lyrics. A normal webpage is not a lyrics endpoint.")
            }
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Custom Lyrics Sources")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { request in
            NavigationStack {
                CustomLyricsSourceEditor(source: request.source,
                                         canDisable: request.isNew || !request.source.isEnabled || app.settings.enabledLyricsSourceCount > 1) { source in
                    save(source, isNew: request.isNew)
                }
            }
        }
    }

    private func sourceRow(_ source: CustomLyricsSource) -> some View {
        HStack(spacing: 12) {
            Button {
                editor = EditorRequest(source: source, isNew: false)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).foregroundStyle(.primary).lineLimit(2)
                    if let host = try? source.requestURL(title: "", artist: "", album: nil, duration: nil).host {
                        Text(host).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Toggle("Enabled", isOn: Binding(get: {
                app.settings.customLyricsSources.first(where: { $0.id == source.id })?.isEnabled ?? false
            }, set: { enabled in
                guard enabled || app.settings.enabledLyricsSourceCount > 1,
                      let index = app.settings.customLyricsSources.firstIndex(where: { $0.id == source.id }) else { return }
                app.settings.customLyricsSources[index].isEnabled = enabled
            }))
            .labelsHidden()
            .accessibilityLabel(Text(source.name))
            .disabled(source.isEnabled && app.settings.enabledLyricsSourceCount == 1)
        }
        .swipeActions {
            Button("Delete", role: .destructive) { remove(source) }
                .disabled(source.isEnabled && app.settings.enabledLyricsSourceCount == 1)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") { editor = EditorRequest(source: source, isNew: false) }
            Button("Delete", systemImage: "trash", role: .destructive) { remove(source) }
                .disabled(source.isEnabled && app.settings.enabledLyricsSourceCount == 1)
        }
    }

    private func remove(_ source: CustomLyricsSource) {
        guard !source.isEnabled || app.settings.enabledLyricsSourceCount > 1 else { return }
        app.settings.customLyricsSources.removeAll { $0.id == source.id }
        message = nil
    }

    private func save(_ source: CustomLyricsSource, isNew: Bool) {
        if isNew {
            guard app.settings.customLyricsSources.count < CustomLyricsSource.maximumCount else { return }
            app.settings.customLyricsSources.append(source)
        } else if let index = app.settings.customLyricsSources.firstIndex(where: { $0.id == source.id }) {
            let old = app.settings.customLyricsSources[index]
            guard source.isEnabled || !old.isEnabled || app.settings.enabledLyricsSourceCount > 1 else {
                message = String(localized: "Keep at least one lyrics source enabled.")
                return
            }
            app.settings.customLyricsSources[index] = source
        }
        message = nil
        editor = nil
    }
}

private struct CustomLyricsSourceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var source: CustomLyricsSource
    @State private var message: String?
    let canDisable: Bool
    let save: (CustomLyricsSource) -> Void

    init(source: CustomLyricsSource, canDisable: Bool, save: @escaping (CustomLyricsSource) -> Void) {
        _source = State(initialValue: source)
        self.canDisable = canDisable
        self.save = save
    }

    var body: some View {
        Form {
            Section("Source") {
                TextField("Name", text: $source.name)
                Toggle("Enabled", isOn: $source.isEnabled)
                    .disabled(!canDisable)
            }
            Section {
                TextField("HTTPS URL Template", text: $source.urlTemplate, axis: .vertical)
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(3...6)
            } header: {
                Text("Request URL")
            } footer: {
                Text("Use {title}, {artist}, {album}, and {duration} in the path or query. Include at least {title} or {artist}. Duration is rounded seconds; missing values are empty.")
            }
            Section("Example") {
                Text(verbatim: "https://example.com/lyrics?title={title}&artist={artist}")
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Lyrics Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do { save(try source.validated()) }
                    catch { message = error.localizedDescription }
                }
            }
        }
    }
}
