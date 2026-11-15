import KodaCore
import SwiftUI

/// A merge prepares complete cloud snapshots and creates one new remote playlist.
/// Source playlists are never rewritten, removed or used as local look-alikes.
struct PlaylistMergeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIDs: [String] = []
    @State private var name = ""
    @State private var excludesExact = true
    @State private var sources: [CloudPlaylistSnapshot] = []
    @State private var mergedSongs: [Song]?
    @State private var sourceSongCount = 0
    @State private var unavailableCount = 0
    @State private var busy = false
    @State private var processedSources = 0
    @State private var errorMessage: String?
    @State private var resultMessage: String?
    @State private var preparation: Task<Void, Never>?
    @State private var confirmsCreate = false
    @State private var profileID: UUID?
    @State private var successes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section { CloudPlaylistSessionNotice(); CloudPlaylistOperationView() }
                Section("New Cloud Playlist") {
                    TextField("Name", text: $name).accessibilityIdentifier("playlist.merge.name")
                    Toggle("Exclude Exact Duplicates", isOn: $excludesExact)
                        .disabled(busy)
                        .accessibilityIdentifier("playlist.merge.excludeExact")
                    Text("Source order is preserved. Only identical song IDs may be excluded; different versions remain separate.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Choose Source Playlists") {
                    if app.cloudPlaylists.isRefreshing { ProgressView("Loading Playlists…") }
                    ForEach(app.cloudPlaylists.catalog) { playlist in
                        Button { toggle(playlist.id) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selectedIDs.contains(playlist.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedIDs.contains(playlist.id) ? Color.accentColor : .secondary)
                                Text(playlist.title).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                        .accessibilityAddTraits(selectedIDs.contains(playlist.id) ? .isSelected : [])
                        .accessibilityIdentifier("playlist.merge.choice.\(playlist.id)")
                    }
                    if let error = app.cloudPlaylists.refreshError { Text(error).foregroundStyle(.secondary) }
                    Button("Refresh Cloud Playlists") { Task { await app.cloudPlaylists.refresh(force: true) } }
                        .disabled(busy)
                }
                if !selectedIDs.isEmpty {
                    Section("Source Order") {
                        ForEach(Array(selectedIDs.enumerated()), id: \.element) { index, id in
                            HStack {
                                Text(app.cloudPlaylists.catalog.first { $0.id == id }?.title ?? id).lineLimit(2)
                                Spacer()
                                Button("Move Earlier", systemImage: "arrow.up") { move(id, by: -1) }
                                    .labelStyle(.iconOnly).disabled(index == 0 || busy)
                                Button("Move Later", systemImage: "arrow.down") { move(id, by: 1) }
                                    .labelStyle(.iconOnly).disabled(index == selectedIDs.count - 1 || busy)
                            }
                        }
                    }
                }
                Section {
                    if busy {
                        ProgressView("Preparing Merge…")
                        Text("\(processedSources) of \(selectedIDs.count) playlists prepared")
                            .font(.footnote).monospacedDigit()
                        Button("Cancel") { preparation?.cancel(); if app.cloudPlaylists.isBusy { app.cloudPlaylists.cancel() } }
                    } else {
                        Button("Preview Merge", action: prepare)
                            .disabled(selectedIDs.count < 2 || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || !app.cloudPlaylists.hasSession || app.cloudPlaylists.isBusy)
                            .accessibilityIdentifier("playlist.merge.prepare")
                    }
                    if let mergedSongs {
                        Text("\(sourceSongCount) source songs → \(mergedSongs.count) songs")
                            .accessibilityIdentifier("playlist.merge.preview")
                        if unavailableCount > 0 {
                            Text("\(unavailableCount) unavailable entries cannot be copied. They remain in the source playlists.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Create Cloud Playlist") { confirmsCreate = true }
                            .disabled(busy || app.cloudPlaylists.isBusy)
                            .accessibilityIdentifier("playlist.merge.create")
                    }
                } footer: {
                    Text("The merge creates a private YouTube Music playlist. All source playlists and their order are kept.")
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
                if let resultMessage { Section { Text(resultMessage).accessibilityIdentifier("playlist.merge.result") } }
            }
            .navigationTitle("Merge Playlists")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { if !app.cloudPlaylists.isBusy { preparation?.cancel() }; dismiss() } } }
            .task { profileID = app.roster.activeID; await app.cloudPlaylists.refresh(force: true) }
            .onChange(of: excludesExact) { _, _ in invalidatePreview() }
            .onChange(of: app.roster.activeID) { _, _ in preparation?.cancel(); dismiss() }
            .onDisappear { if !app.cloudPlaylists.isBusy { preparation?.cancel() } }
            .confirmationDialog("Create Merged Cloud Playlist?", isPresented: $confirmsCreate, titleVisibility: .visible) {
                Button("Create Cloud Playlist", action: create).accessibilityIdentifier("playlist.merge.confirm")
            } message: {
                Text("The preview will be saved to your YouTube Music account after the sources are checked again.")
            }
        }
        .sensoryFeedback(.success, trigger: successes)
    }

    private func toggle(_ id: String) {
        if let index = selectedIDs.firstIndex(of: id) { selectedIDs.remove(at: index) }
        else { selectedIDs.append(id) }
        invalidatePreview()
    }
    private func move(_ id: String, by offset: Int) {
        guard let index = selectedIDs.firstIndex(of: id), selectedIDs.indices.contains(index + offset) else { return }
        selectedIDs.swapAt(index, index + offset); invalidatePreview()
    }
    private func invalidatePreview() { mergedSongs = nil; sources = []; resultMessage = nil }

    private func prepare() {
        guard !busy, selectedIDs.count >= 2, profileID == app.roster.activeID else { return }
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        let ids = selectedIDs, expected = profileID, exclude = excludesExact
        busy = true; errorMessage = nil; resultMessage = nil; mergedSongs = nil; sources = []; processedSources = 0
        preparation = Task {
            defer { busy = false }
            do {
                var snapshots: [CloudPlaylistSnapshot] = []
                for id in ids {
                    try Task.checkCancellation()
                    let snapshot = try await app.cloudPlaylists.loadSnapshot(id: id, expectedScope: scope)
                    try Task.checkCancellation()
                    guard expected == app.roster.activeID else { throw CloudAccountAccessError.changed }
                    snapshots.append(snapshot); processedSources += 1
                }
                let result = try await PlaylistTools.merge(snapshots.map(\.songs), excludingExactDuplicates: exclude)
                try Task.checkCancellation()
                guard expected == app.roster.activeID, selectedIDs == ids else { throw CloudPlaylistError.externalChange }
                sources = snapshots
                sourceSongCount = snapshots.reduce(0) { $0 + $1.songs.count }
                unavailableCount = snapshots.reduce(0) { $0 + $1.unavailableCount }
                mergedSongs = result
            } catch is CancellationError { resultMessage = String(localized: "Operation Cancelled") }
            catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }

    private func create() {
        guard !busy, let mergedSongs, profileID == app.roster.activeID else { return }
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        let expected = profileID, snapshots = sources
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        busy = true; errorMessage = nil; processedSources = 0
        // The preflight is cancellable. Once a write starts, its durable coordinator owns completion.
        preparation = Task {
            defer { busy = false }
            do {
                try Task.checkCancellation()
                guard expected == app.roster.activeID else { throw CloudAccountAccessError.changed }
                for previous in snapshots {
                    try Task.checkCancellation()
                    let current = try await app.cloudPlaylists.loadSnapshot(id: previous.id, expectedScope: scope)
                    try Task.checkCancellation()
                    guard expected == app.roster.activeID else { throw CloudAccountAccessError.changed }
                    guard current.rows == previous.rows, current.unavailableCount == previous.unavailableCount else {
                        self.mergedSongs = nil
                        throw CloudPlaylistError.externalChange
                    }
                    processedSources += 1
                }
                guard expected == app.roster.activeID else { throw CloudAccountAccessError.changed }
                try Task.checkCancellation()
                let result = try await app.cloudPlaylists.create(title: trimmed, songs: mergedSongs, expectedScope: scope)
                guard expected == app.roster.activeID else { return }
                let count = String(localized: "\(result.songs.count) songs")
                resultMessage = String(localized: "Created “\(result.title)” with \(count).")
                self.mergedSongs = nil; successes += 1
            } catch is CancellationError { resultMessage = String(localized: "Operation Cancelled") }
            catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }
}
