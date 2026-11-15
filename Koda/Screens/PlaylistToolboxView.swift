import KodaCore
import SwiftUI

/// Selection belongs to a complete immutable source. Only service-provided row IDs
/// permit deletion; copying never removes source entries as an implicit second write.
struct PlaylistToolboxRequest: Identifiable {
    enum Source {
        case local(UUID)
        case songs(title: String, songs: [Song])
        case online(PlaylistSummary, PlaylistQueueLoader.Checkpoint)
        case cloud(PlaylistSummary)
    }
    let id = UUID()
    let source: Source
    var checksDuplicates = false
    var onCheckpoint: (@MainActor (PlaylistQueueLoader.Checkpoint) -> Void)?
}

struct PlaylistToolboxView: View {
    let request: PlaylistToolboxRequest
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var songs: [Song] = []
    @State private var selection = PlaylistSongSelection(count: 0)
    @State private var cloudSnapshot: CloudPlaylistSnapshot?
    @State private var checkpoint = PlaylistQueueLoader.Checkpoint()
    @State private var visibleIndices: [Int] = []
    @State private var query = ""
    @State private var revision = 0
    @State private var busy = false
    @State private var operationLabel: LocalizedStringKey = "Preparing Songs…"
    @State private var prepared = false
    @State private var loadingCount = 0
    @State private var errorMessage: String?
    @State private var statusMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var duplicates: [PlaylistDuplicateGroup] = []
    @State private var showsDuplicates = false
    @State private var removesAfterDuplicateReview = false
    @State private var choosingDestination = false
    @State private var pendingRemoval = false
    @State private var successes = 0
    @State private var profileID: UUID?

    private var title: String {
        switch request.source {
        case .local(let id): library.userPlaylist(id)?.name ?? String(localized: "Playlist")
        case .songs(let title, _): title
        case .online(let summary, _), .cloud(let summary): cloudSnapshot?.title ?? summary.title
        }
    }
    private var isOnline: Bool {
        switch request.source { case .online, .cloud: true; default: false }
    }
    private var canRemove: Bool { cloudSnapshot?.capabilities.canRemove == true }
    private var preparationCount: Int {
        switch request.source {
        case .online(let summary, _), .cloud(let summary):
            app.cloudPlaylists.readProgress[String(summary.id.trimmingPrefix("VL"))] ?? loadingCount
        default: loadingCount
        }
    }
    private var selectedRows: [CloudPlaylistRow] {
        guard let cloudSnapshot else { return [] }
        return cloudSnapshot.rows.enumerated().compactMap { selection.selectedIndices.contains($0.offset) ? $0.element : nil }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                feedback
                if prepared { selectionList }
                else if !busy {
                    ContentUnavailableView {
                        Label("Songs Not Prepared", systemImage: "music.note.list")
                    } description: {
                        Text("Load the complete list before selecting or checking songs.")
                    } actions: { Button("Retry", action: prepare).buttonStyle(.glass) }
                } else { Spacer() }
            }
            .navigationTitle("Select Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { if !app.cloudPlaylists.isBusy { operation?.cancel() }; dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu("Selection", systemImage: "checklist") {
                        Button("Select All", systemImage: "checkmark.circle") { selection.selectAll() }
                            .accessibilityIdentifier("playlist.selectAll")
                        Button("Deselect All", systemImage: "circle") { selection.clear() }
                            .accessibilityIdentifier("playlist.deselectAll")
                        Divider()
                        Button("Check Duplicate Songs", systemImage: "square.on.square") { checkDuplicates() }
                    }
                    .disabled(!prepared || busy)
                    .accessibilityIdentifier("playlist.selection.menu")
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(selection.selectedIndices.count) selected").font(.subheadline).monospacedDigit()
                        .accessibilityIdentifier("playlist.selection.count")
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
                ToolbarItem(placement: .bottomBar) {
                    Menu("Actions", systemImage: "ellipsis.circle") {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(next: true) }
                        Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(next: false) }
                        Divider()
                        Button("Copy to Cloud Playlist", systemImage: "text.badge.plus") { choosingDestination = true }
                        if canRemove {
                            Button("Remove Selected Songs", systemImage: "trash", role: .destructive) { pendingRemoval = true }
                                .disabled(selectedRows.contains { $0.setVideoID == nil })
                        }
                    }
                    .disabled(selection.selectedIndices.isEmpty || !prepared || busy || app.cloudPlaylists.isBusy)
                    .accessibilityIdentifier("playlist.actions.menu")
                }
            }
            .searchable(text: $query, prompt: "Find in Playlist")
            .task { profileID = app.roster.activeID; prepare() }
            .task(id: "\(revision):\(query)") { await filterSongs() }
            .sheet(isPresented: $choosingDestination) {
                CloudAddToPlaylistView(songs: selectedSongs(), excludingID: cloudSnapshot?.id, onAdded: { destination in
                    statusMessage = String(localized: "Copied to “\(destination.title)”. Source entries were kept. To move them, separately confirm Remove Selected Songs.")
                    successes += 1; choosingDestination = false
                }).appEnvironment(app)
            }
            .sheet(isPresented: $showsDuplicates, onDismiss: {
                if removesAfterDuplicateReview { removesAfterDuplicateReview = false; pendingRemoval = true }
            }) {
                PlaylistDuplicateReview(songs: songs, groups: duplicates, canRemove: canRemove) { offsets in
                    selection.clear()
                    for offset in offsets { selection.toggle(offset) }
                    removesAfterDuplicateReview = canRemove
                    showsDuplicates = false
                }
            }
            .confirmationDialog("Remove Selected Songs from YouTube Music?", isPresented: $pendingRemoval, titleVisibility: .visible) {
                Button("Remove Selected Songs", role: .destructive, action: removeSelected)
            } message: {
                Text("Only the selected cloud entries will be removed. Downloads and other playlists are kept. Cloud removal cannot be undone here.")
            }
        }
        .sensoryFeedback(.success, trigger: successes)
        .onDisappear { if !app.cloudPlaylists.isBusy { operation?.cancel() } }
        .onChange(of: app.roster.activeID) { _, _ in operation?.cancel(); dismiss() }
    }

    private var selectionList: some View {
        List {
            Section {
                ForEach(visibleIndices, id: \.self) { index in
                    PlaylistSelectionRow(song: songs[index], selected: selection.selectedIndices.contains(index)) {
                        selection.toggle(index)
                    }.accessibilityIdentifier("playlist.row.\(index)")
                }
            } header: { Text(title) } footer: {
                if !query.isEmpty { Text("Select All includes songs outside the current search.") }
                if isOnline, !canRemove {
                    Text("This account cannot safely remove entries from this playlist. You can copy selected songs to an editable cloud playlist.")
                }
                if let missing = cloudSnapshot?.unavailableCount, missing > 0 {
                    Text("\(missing) unavailable entries were omitted from this view. They remain unchanged on YouTube Music.")
                }
            }
        }
        .listStyle(.plain).disabled(busy)
        .overlay { if visibleIndices.isEmpty, !busy { ContentUnavailableView.search(text: query) } }
    }

    @ViewBuilder private var feedback: some View {
        if app.cloudPlaylists.operation != nil { CloudPlaylistOperationView().padding() }
        if busy {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operationLabel)
                    if !prepared { Text("\(preparationCount) songs loaded").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                Button("Cancel") { operation?.cancel(); if app.cloudPlaylists.isBusy { app.cloudPlaylists.cancel() } }
            }.padding()
        }
        if let errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                Label(errorMessage, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                if !busy { Button("Reload Songs") { prepared = false; prepare() } }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        if let statusMessage { Text(statusMessage).font(.footnote).foregroundStyle(.secondary).padding() }
    }

    private func prepare() {
        guard !busy else { return }
        let expectedProfile = profileID, scope = app.cloudPlaylists.captureScope()
        operation?.cancel(); busy = true; operationLabel = "Preparing Songs…"; errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                try Task.checkCancellation()
                guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                switch request.source {
                case .local(let id):
                    guard let local = library.userPlaylist(id) else { throw PlaylistEditError.playlistMissing }
                    songs = local.songs
                case .songs(_, let supplied): songs = supplied
                case .cloud(let summary):
                    let loaded = try await app.cloudPlaylists.loadSnapshot(id: summary.id, expectedScope: scope)
                    try Task.checkCancellation()
                    guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                    cloudSnapshot = loaded; songs = loaded.songs
                case .online(let summary, let initial):
                    if app.cloudPlaylists.hasSession {
                        let loaded = try await app.cloudPlaylists.loadSnapshot(id: summary.id, expectedScope: scope)
                        try Task.checkCancellation()
                        guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                        cloudSnapshot = loaded; songs = loaded.songs
                        request.onCheckpoint?(.init(firstPage: .init(songs: songs, continuation: nil)))
                    } else {
                        if !checkpoint.hasFirstPage { checkpoint = initial }
                        let music = app.music
                        let completed = try await PlaylistQueueLoader.load(from: checkpoint, fetchFirst: {
                            let page = try await music.playlist(summary.id)
                            return .init(songs: page.songs, continuation: page.continuation)
                        }, fetchMore: { token in
                            let page = try await music.playlistMoreForPlayback(token)
                            return .init(songs: page.songs, continuation: page.continuation)
                        }, didLoadPage: { page in
                            await MainActor.run {
                                guard !Task.isCancelled, expectedProfile == app.roster.activeID else { return }
                                checkpoint = page; loadingCount = page.songs.count; request.onCheckpoint?(page)
                            }
                        })
                        songs = completed.songs
                    }
                }
                try Task.checkCancellation()
                guard expectedProfile == app.roster.activeID else { throw PlaylistEditError.wrongProfile }
                selection = PlaylistSongSelection(count: songs.count); visibleIndices = Array(songs.indices)
                prepared = true; revision += 1
                if request.checksDuplicates {
                    duplicates = try await PlaylistTools.duplicateGroups(in: songs)
                    try Task.checkCancellation(); showsDuplicates = true
                }
            } catch is CancellationError { statusMessage = String(localized: "Operation Cancelled") }
            catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }

    private func filterSongs() async {
        let source = songs, search = query, version = revision
        let task = Task.detached(priority: .userInitiated) {
            let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if needle.isEmpty { return Array(source.indices) }
            return source.indices.filter { index in
                guard !Task.isCancelled else { return false }
                let song = source[index]
                return song.title.localizedStandardContains(needle) || song.artistLine.localizedStandardContains(needle)
                    || (song.album?.title.localizedStandardContains(needle) ?? false)
            }
        }
        let indices = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, version == revision, search == query else { return }
        visibleIndices = indices
    }
    private func selectedSongs() -> [Song] { selection.selectedSongs(from: songs) }
    private func enqueue(next: Bool) {
        guard profileID == app.roster.activeID else { dismiss(); return }
        let chosen = selectedSongs()
        if next { player.playNext(chosen) } else { player.addToQueue(chosen) }
        statusMessage = String(localized: "Added \(String(localized: "\(chosen.count) songs")) to the queue.")
        successes += 1
    }
    private func checkDuplicates() {
        guard prepared, !busy else { return }
        busy = true; operationLabel = "Checking Duplicates…"; errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                duplicates = try await PlaylistTools.duplicateGroups(in: songs)
                try Task.checkCancellation(); showsDuplicates = true
            } catch is CancellationError { statusMessage = String(localized: "Operation Cancelled") }
            catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }
    private func removeSelected() {
        guard !busy, let source = cloudSnapshot, source.capabilities.canRemove,
              profileID == app.roster.activeID else { return }
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        let rows = selectedRows, expectedProfile = profileID
        guard !rows.isEmpty, rows.allSatisfy({ $0.setVideoID != nil }) else { return }
        busy = true; operationLabel = "Saving Changes…"; errorMessage = nil
        operation = Task {
            defer { busy = false }
            do {
                try Task.checkCancellation()
                guard expectedProfile == app.roster.activeID else { throw CloudAccountAccessError.changed }
                let confirmed = try await app.cloudPlaylists.remove(rows: rows, from: source.id, expectedScope: scope)
                guard expectedProfile == app.roster.activeID else { return }
                cloudSnapshot = confirmed; songs = confirmed.songs
                selection = PlaylistSongSelection(count: songs.count); visibleIndices = []; revision += 1
                statusMessage = String(localized: "Confirmed on YouTube Music"); successes += 1
            } catch { errorMessage = playlistToolboxErrorMessage(error) }
        }
    }
}

func playlistToolboxErrorMessage(_ error: any Error) -> String {
    if let described = error as? any LocalizedError, let message = described.errorDescription { return message }
    if error is MusicError { return error.friendlyMessage }
    return error.localizedDescription
}

/// A selection row intentionally has no playback observer, download work or nested menu.
private struct PlaylistSelectionRow: View {
    let song: Song
    let selected: Bool
    var showsRecordingDetails = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected ? Color.accentColor : .secondary)
                ArtworkView(artwork: song.artwork, size: 44, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).foregroundStyle(.primary).lineLimit(2)
                    Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    if showsRecordingDetails {
                        if let album = song.album?.title {
                            Text(album).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let duration = song.duration, duration.isFinite, duration > 0, duration < Double(Int.max) {
                            Text("\(Int(duration)) sec").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct PlaylistDuplicateReview: View {
    let songs: [Song]
    let groups: [PlaylistDuplicateGroup]
    let canRemove: Bool
    let finish: (Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chosen = Set<Int>()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select only the entries you want to remove. Different recordings are never removed automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !canRemove {
                        Text("This source is read-only. Selected songs can be copied to an editable cloud playlist.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.indices, id: \.self) { index in
                            PlaylistSelectionRow(song: songs[index], selected: chosen.contains(index), showsRecordingDetails: true) {
                                if !chosen.insert(index).inserted { chosen.remove(index) }
                            }
                        }
                    } header: { Text(label(group.kind)) }
                }
            }
            .overlay {
                if groups.isEmpty {
                    ContentUnavailableView("No Duplicate Candidates", systemImage: "checkmark.circle",
                        description: Text("No exact or likely duplicate songs were found."))
                }
            }
            .navigationTitle("Duplicate Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(canRemove ? String(localized: "Review Removal") : String(localized: "Use Selection")) { finish(chosen) }
                        .disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func label(_ kind: PlaylistDuplicateGroup.Kind) -> LocalizedStringKey {
        switch kind {
        case .exact: "Exact Duplicates"
        case .possibleMatch: "Possible Matches"
        case .differentVersions: "Different Versions"
        }
    }
}
