import KodaCore
import SwiftUI

/// Merge reads existing playlists and writes one local playlist. No account mutation API
/// participates; online checkpoints survive a failed attempt within this presentation.
struct PlaylistMergeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: [String] = []
    @State private var name = ""
    @State private var excludesExact = true
    @State private var checkpoints: [String: PlaylistQueueLoader.Checkpoint] = [:]
    @State private var localSnapshots: [PlaylistSnapshot] = []
    @State private var mergedSongs: [Song]?
    @State private var sourceSongCount = 0
    @State private var busy = false
    @State private var operationLabel: LocalizedStringKey = "Preparing Merge…"
    @State private var processedSources = 0
    @State private var loadedSongs = 0
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var undoToken: PlaylistUndoToken?
    @State private var successes = 0
    @State private var profileID: UUID?

    private struct Choice: Identifiable {
        enum Source { case local(UUID), online(PlaylistSummary) }
        let id: String
        let title: String
        let count: Int?
        let source: Source
    }

    private var choices: [Choice] {
        library.userPlaylists.map { Choice(id: "local:\($0.id)", title: $0.name, count: $0.songs.count, source: .local($0.id)) }
            + library.playlists.map { Choice(id: "online:\($0.id)", title: $0.title, count: nil, source: .online($0)) }
    }

    var body: some View {
        NavigationStack {
            Form {
                if busy {
                    Section {
                        HStack {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(operationLabel)
                                Text("\(processedSources) of \(selectedIDs.count) playlists prepared")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(loadedSongs) songs loaded").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Cancel") { operation?.cancel() }
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let resultMessage {
                    Section {
                        Text(resultMessage)
                        if undoToken != nil { Button("Undo", action: undo).disabled(busy) }
                    }
                }
                settingsSection.disabled(busy)
                sourceSection.disabled(busy)
                if !selectedIDs.isEmpty { orderSection.disabled(busy) }
                previewSection.disabled(busy)
            }
            .navigationTitle("Merge Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { operation?.cancel(); dismiss() }
                }
            }
        }
        .sensoryFeedback(.success, trigger: successes)
        .onAppear { profileID = app.roster.activeID }
        .onChange(of: excludesExact) { _, _ in invalidatePreview() }
        .onDisappear { operation?.cancel() }
        .onChange(of: app.roster.activeID) { _, _ in operation?.cancel(); dismiss() }
    }

    private var settingsSection: some View {
        Section {
            TextField("New Playlist Name", text: $name)
                .accessibilityIdentifier("playlist.merge.name")
            Toggle("Exclude Exact Duplicates", isOn: $excludesExact)
        } header: {
            Text("New Local Playlist")
        } footer: {
            Text("Only matching song IDs are excluded. Live, remix, cover and other recordings are preserved. Source playlists are not changed.")
        }
    }

    private var sourceSection: some View {
        Section {
            ForEach(choices) { choice in
                Button {
                    if let index = selectedIDs.firstIndex(of: choice.id) { selectedIDs.remove(at: index) }
                    else { selectedIDs.append(choice.id) }
                    invalidatePreview()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selectedIDs.contains(choice.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedIDs.contains(choice.id) ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(choice.title).foregroundStyle(.primary).lineLimit(2)
                            if let count = choice.count {
                                Text("\(count) songs").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("YouTube Music · Read Only").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedIDs.contains(choice.id) ? .isSelected : [])
                .accessibilityIdentifier("playlist.merge.choice.\(choice.id)")
            }
            if choices.count < 2 {
                Text("Save or create at least two playlists to merge them.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Choose Two or More Playlists")
        } footer: {
            Text("Online playlists are loaded completely and copied locally. Nothing is written to YouTube Music.")
        }
    }

    private var orderSection: some View {
        let byID = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
        return Section {
            ForEach(Array(selectedIDs.enumerated()), id: \.element) { index, id in
                HStack {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                    Text(byID[id]?.title ?? String(localized: "Playlist Deleted")).lineLimit(2)
                    Spacer(minLength: 6)
                    Button {
                        selectedIDs.swapAt(index, index - 1)
                        invalidatePreview()
                    } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Move Earlier")
                    .disabled(index == 0)
                    Button {
                        selectedIDs.swapAt(index, index + 1)
                        invalidatePreview()
                    } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Move Later")
                    .disabled(index + 1 == selectedIDs.count)
                }
            }
        } header: {
            Text("Merge Order")
        } footer: {
            Text("Songs keep their original order inside each source playlist.")
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            Button("Prepare Merge", action: prepare)
                .disabled(selectedIDs.count < 2)
                .accessibilityIdentifier("playlist.merge.prepare")
            if let mergedSongs {
                LabeledContent("Source Song Entries") { Text("\(sourceSongCount)").monospacedDigit() }
                LabeledContent("Resulting Songs") { Text("\(mergedSongs.count)").monospacedDigit() }
                if excludesExact {
                    LabeledContent("Exact Duplicates Excluded") {
                        Text("\(sourceSongCount - mergedSongs.count)").monospacedDigit()
                    }
                }
                Button("Create Playlist", action: create)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("playlist.merge.create")
            } else {
                Text("Prepare all sources to preview the final song count before saving.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func invalidatePreview() { mergedSongs = nil; errorMessage = nil }

    private func prepare() {
        guard !busy, selectedIDs.count >= 2 else { return }
        guard profileID == app.roster.activeID else { dismiss(); return }
        let expectedProfile = profileID
        let byID = Dictionary(uniqueKeysWithValues: choices.map { ($0.id, $0) })
        let selected = selectedIDs.compactMap { byID[$0] }
        guard selected.count == selectedIDs.count else {
            errorMessage = String(localized: "A source playlist changed. Choose the playlists again.")
            return
        }
        busy = true
        operationLabel = "Preparing Merge…"
        mergedSongs = nil
        errorMessage = nil
        processedSources = 0
        loadedSongs = 0
        operation = Task {
            defer { busy = false }
            do {
                try Task.checkCancellation()
                guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                let music = app.music
                var sources: [[Song]] = []
                var snapshots: [PlaylistSnapshot] = []
                for choice in selected {
                    try Task.checkCancellation()
                    guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                    switch choice.source {
                    case .local(let id):
                        guard let snapshot = library.playlistSnapshot(id) else {
                            throw MergeError.sourceChanged
                        }
                        snapshots.append(snapshot)
                        sources.append(snapshot.songs)
                    case .online(let summary):
                        let choiceID = choice.id
                        let countBefore = sources.reduce(0) { $0 + $1.count }
                        let result = try await PlaylistQueueLoader.load(from: checkpoints[choiceID] ?? .init(),
                            fetchFirst: {
                                let page = try await music.playlist(summary.id)
                                return .init(songs: page.songs, continuation: page.continuation)
                            }, fetchMore: { token in
                                let page = try await music.playlistMoreForPlayback(token)
                                return .init(songs: page.songs, continuation: page.continuation)
                            }, didLoadPage: { page in
                                await MainActor.run {
                                    guard !Task.isCancelled, expectedProfile == app.roster.activeID else { return }
                                    checkpoints[choiceID] = page
                                    loadedSongs = countBefore + page.songs.count
                                }
                            })
                        guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                        sources.append(result.songs)
                    }
                    processedSources += 1
                    loadedSongs = sources.reduce(0) { $0 + $1.count }
                }
                sourceSongCount = loadedSongs
                let result = try await PlaylistTools.merge(sources, excludingExactDuplicates: excludesExact)
                try Task.checkCancellation()
                guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                localSnapshots = snapshots
                mergedSongs = result
            } catch is CancellationError {
                resultMessage = String(localized: "Operation Cancelled")
            } catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }

    private func create() {
        guard !busy, let mergedSongs else { return }
        guard profileID == app.roster.activeID else { dismiss(); return }
        let expectedProfile = profileID
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true
        operationLabel = "Saving Changes…"
        errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                try Task.checkCancellation()
                guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                let receipt = try await library.applyPlaylistEdit(
                    .create(name: trimmed, songs: mergedSongs, excludingExactDuplicates: false),
                    validating: localSnapshots)
                undoToken = receipt.undo
                let count = String(localized: "\(mergedSongs.count) songs")
                resultMessage = String(localized: "Created “\(trimmed)” with \(count).")
                self.mergedSongs = nil
                successes += 1
            } catch is CancellationError {
                resultMessage = String(localized: "Operation Cancelled")
            } catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }

    private func undo() {
        guard !busy, let token = undoToken else { return }
        busy = true
        operationLabel = "Restoring Changes…"
        errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                try await library.undoPlaylistEdit(token)
                undoToken = nil
                resultMessage = String(localized: "Changes Undone")
                successes += 1
            } catch is CancellationError {
                resultMessage = String(localized: "Operation Cancelled")
            } catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }
}

private nonisolated enum MergeError: LocalizedError {
    case sourceChanged
    var errorDescription: String? { String(localized: "A source playlist changed. Choose the playlists again.") }
}
