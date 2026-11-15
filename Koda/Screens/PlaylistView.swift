import KodaCore
import SwiftUI

struct PlaylistView: View {
    let summary: PlaylistSummary

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @State private var state: LoadState<PlaylistPage> = .loading
    @State private var songs: [Song] = []
    @State private var continuation: String?
    @State private var loadedContinuations: Set<String> = []
    @State private var loadingMore = false
    @State private var palette = PaletteModel()
    @State private var toolbox: PlaylistToolboxRequest?
    @State private var showsFlow = false
    @State private var showsManagement = false
    @State private var cloudSnapshot: CloudPlaylistSnapshot?
    @State private var loadError: String?
    @State private var refreshing = false
    @State private var loadGeneration = UUID()
    @State private var displayedProfileID: UUID?
    @State private var lastLoadStarted = Date.distantPast

    private var cloudID: String { String(summary.id.trimmingPrefix("VL")) }
    private var supportsFlow: Bool { !["LM", "WL", "SE"].contains(cloudID) && !cloudID.hasPrefix("RD") && !cloudID.hasPrefix("OLAK") }


    var body: some View {
        Group {
            if Platform.isMac { macBody } else { phoneBody }
        }
        .sheet(item: $toolbox) { PlaylistToolboxView(request: $0).appEnvironment(app) }
        .sheet(isPresented: $showsFlow) { KodaFlowView(playlist: cloudSnapshot?.playlist ?? summary).appEnvironment(app) }
        .sheet(isPresented: $showsManagement) { CloudPlaylistManagementView(playlist: cloudSnapshot?.playlist ?? summary).appEnvironment(app) }
        .refreshable { await load() }
        .onAppear { hydrateCachedSnapshot() }
        .onChange(of: app.cloudPlaylists.snapshots[cloudID]?.fetchedAt) { _, _ in
            if let confirmed = app.cloudPlaylists.cachedSnapshot(id: cloudID) {
                apply(confirmed)
                if confirmed.fetchedAt >= lastLoadStarted { loadError = nil }
            }
        }
        .onChange(of: app.roster.activeID) { _, profileID in
            resetForProfileIfNeeded(profileID)
        }
    }

    /// The Mac's playlist: the cover beside its details, then songs with their artist and
    /// album columns, loading the next page as the end comes into view.
    private var macBody: some View {
        let title = state.value?.playlist.title ?? summary.title
        return MacPage(spacing: 28) {
            MacCollectionHeader(
                kind: String(localized: "Playlist"),
                title: title,
                byline: state.value?.author ?? summary.subtitle,
                detail: state.value?.detailLine,
                description: state.value?.description,
                accent: palette.palette.accent,
                canPlay: !songs.isEmpty || continuation != nil,
                play: { play(shuffled: false) },
                shuffle: { play(shuffled: true) }
            ) { side in
                ArtworkView(artwork: state.value?.playlist.artwork ?? summary.artwork, size: side, cornerRadius: 12)
            } actions: {
                macActions
            }
            cloudFeedback
            if player.current != nil { PlaylistQueueLoadingView(sourceID: summary.id) }
            AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                let rows = state.value == nil ? page.songs : songs
                VStack(spacing: 12) {
                    MacTrackList(songs: rows, play: { play(startAt: $0) },
                                 onRowAppear: { index in if index >= songs.count - 10 { Task { await loadMore() } } })
                    if loadingMore { ProgressView().controlSize(.small) }
                }
            }
        }
        .background { ArtworkGlow(palette: palette.palette) }
        .navigationTitle(title)
        .task { await palette.load(summary.artwork) }
        .task(id: app.roster.activeID) { await load(force: false) }
    }

    @ViewBuilder
    private var macActions: some View {
        let saved = library.isSaved(playlist: summary.id)
        Button(saved ? String(localized: "Remove from Library") : String(localized: "Add to Library"), systemImage: saved ? "checkmark" : "plus") {
            library.toggleSave(state.value?.playlist ?? summary)
        }
        .buttonStyle(MacIconButtonStyle())
        .help(saved ? String(localized: "Remove from Library") : String(localized: "Add to Library"))
        if !songs.isEmpty {
            DownloadButton(songs: songs, allSongs: allSongs)
                .buttonStyle(MacIconButtonStyle())
        }
        MacMoreMenu {
            toolboxActions
            if !songs.isEmpty {
                Button(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(playNext: true) }
                Button(String(localized: "Add to Queue"), systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(playNext: false) }
                Button("Add to Playlist…", systemImage: "text.badge.plus") { addAllToPlaylist() }
            }
            PinMenuItem(pin: .playlist(summary))
            ShareLink(item: URL(string: "https://music.youtube.com/playlist?list=\(summary.id)")!) {
                Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
            }
        }
    }

    private var phoneBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                CollectionHeader(
                    artwork: state.value?.playlist.artwork ?? summary.artwork,
                    title: state.value?.playlist.title ?? summary.title,
                    byline: state.value?.author ?? summary.subtitle,
                    detail: state.value?.detailLine,
                    description: state.value?.description,
                    accent: palette.palette.accent,
                    play: { play(shuffled: false) },
                    shuffle: { play(shuffled: true) })

                cloudFeedback.padding(.horizontal, 20)
                if player.current != nil {
                    PlaylistQueueLoadingView(sourceID: summary.id)
                        .padding(.horizontal, 20)
                }

                AsyncContent(state: state, retry: load, placeholder: .placeholder(summary)) { page in
                    // `songs` grows past the first page as the list scrolls; while loading it is empty.
                    let rows = state.value == nil ? page.songs : songs
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, song in
                            SongRow(song: song) { play(startAt: index) }
                                .accessibilityIdentifier("playlist.song.\(index)")
                                .onAppear { if index >= songs.count - 10 { Task { await loadMore() } } }
                        }
                        if loadingMore {
                            ProgressView().padding()
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 32)
        }
        .background { ArtworkGlow(palette: palette.palette) }
        .navigationBarTitleDisplayMode(.inline)
        .revealsTitle(state.value?.playlist.title ?? summary.title, after: 320)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let saved = library.isSaved(playlist: summary.id)
                Button(saved ? String(localized: "Remove from Library") : String(localized: "Add to Library"), systemImage: saved ? "checkmark" : "plus") {
                    library.toggleSave(state.value?.playlist ?? summary)
                }
                .sensoryFeedback(.success, trigger: saved)
            }
            if !songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    DownloadButton(songs: songs, allSongs: allSongs)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu(String(localized: "More"), systemImage: "ellipsis") {
                    toolboxActions
                    if !songs.isEmpty {
                        Button(String(localized: "Play Next"), systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(playNext: true) }
                        Button(String(localized: "Add to Queue"), systemImage: "text.line.last.and.arrowtriangle.forward") { enqueue(playNext: false) }
                        Button("Add to Playlist…", systemImage: "text.badge.plus") { addAllToPlaylist() }
                    }
                    PinMenuItem(pin: .playlist(summary))
                    ShareLink(item: URL(string: "https://music.youtube.com/playlist?list=\(summary.id)")!) {
                        Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await palette.load(summary.artwork) }
        .task(id: app.roster.activeID) { await load(force: false) }
    }

    private func play(shuffled: Bool) {
        guard state.value != nil else { return }
        // The player owns the remaining pages. Scrolling and this view's lifetime do not
        // determine the candidate pool; shuffle chooses its first song after all pages load.
        player.playPlaylist(songs, continuation: continuation, shuffled: shuffled, sourceID: summary.id,
                            completedPageTokens: loadedContinuations)
    }

    private var toolboxActions: some View {
        Group {
            if supportsFlow {
                Button("Koda Flow", systemImage: "waveform.path") { showsFlow = true }
                    .accessibilityIdentifier("playlist.flow")
            }
            if app.cloudPlaylists.hasSession {
                Button("Cloud Playlist Details", systemImage: "slider.horizontal.3") { showsManagement = true }
                    .accessibilityIdentifier("playlist.cloud.manage")
            }
            Button("Select Songs", systemImage: "checklist") { openToolbox(checksDuplicates: false) }
            Button("Check Duplicate Songs", systemImage: "square.on.square") { openToolbox(checksDuplicates: true) }
            Divider()
        }
        .disabled(state.value == nil || loadingMore)
    }

    private func openToolbox(checksDuplicates: Bool) {
        guard state.value != nil, !loadingMore else { return }
        let checkpoint = PlaylistQueueLoader.Checkpoint(
            firstPage: .init(songs: songs, continuation: continuation), completedTokens: loadedContinuations)
        toolbox = PlaylistToolboxRequest(source: .online(state.value?.playlist ?? summary, checkpoint),
            checksDuplicates: checksDuplicates, onCheckpoint: { loaded in
                // Keep the successful prefix after a cancelled/failed tool operation so
                // reopening it does not fetch already prepared pages again.
                songs = loaded.songs
                continuation = loaded.continuation
                loadedContinuations = loaded.completedPageTokens
            })
    }

    private func play(startAt index: Int) {
        guard state.value != nil else { return }
        player.playPlaylist(songs, continuation: continuation, startAt: index, sourceID: summary.id,
                            completedPageTokens: loadedContinuations)
    }

    private func enqueue(playNext: Bool) {
        guard state.value != nil else { return }
        player.enqueuePlaylist(songs, continuation: continuation, playNext: playNext, sourceID: summary.id,
                               completedPageTokens: loadedContinuations)
    }

    @ViewBuilder private var cloudFeedback: some View {
        if refreshing || app.cloudPlaylists.readProgress[cloudID] != nil {
            ProgressView("Refreshing Cloud Playlist…").font(.footnote)
            if let count = app.cloudPlaylists.readProgress[cloudID] {
                Text("\(count) songs loaded").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let error = loadError ?? app.cloudPlaylists.snapshotErrors[cloudID] {
            Text(error).font(.footnote).foregroundStyle(.secondary)
            Button("Refresh Cloud Playlist") { Task { await load() } }
                .disabled(refreshing || app.cloudPlaylists.readProgress[cloudID] != nil)
                .accessibilityIdentifier("playlist.cache.retry")
        }
        if let snapshot = cloudSnapshot {
            if snapshot.fetchedAt < lastLoadStarted {
                Text("Showing the cached playlist. Pull to refresh.")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("playlist.cache.notice")
            }
            Text(snapshot.capabilities.canRemove ? String(localized: "Editable Cloud Playlist") : String(localized: "Read-Only Cloud Playlist"))
                .font(.caption).foregroundStyle(.secondary)
            if snapshot.unavailableCount > 0 {
                Text("\(snapshot.unavailableCount) unavailable entries remain unchanged on YouTube Music.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if app.cloudPlaylists.operation != nil { CloudPlaylistOperationView() }
    }

    private func apply(_ snapshot: CloudPlaylistSnapshot) {
        cloudSnapshot = snapshot
        songs = snapshot.songs; continuation = nil; loadedContinuations = []
        state = .loaded(snapshot.page)
    }

    /// A cached snapshot always represents a previously completed cloud read, never
    /// the local mirror's first page. Playback can therefore keep its complete pool.
    private func hydrateCachedSnapshot() {
        resetForProfileIfNeeded(app.roster.activeID)
        if let cached = app.cloudPlaylists.cachedSnapshot(id: cloudID) {
            if cloudSnapshot == nil { lastLoadStarted = Date() }
            apply(cached)
        }
    }

    private func resetForProfileIfNeeded(_ profileID: UUID) {
        guard displayedProfileID != profileID else { return }
        displayedProfileID = profileID
        loadGeneration = UUID(); state = .loading; songs = []; cloudSnapshot = nil
        continuation = nil; loadedContinuations = []; loadingMore = false
        loadError = nil; refreshing = false
    }

    /// Error recovery and pull-to-refresh must wait for a complete fresh read.
    private func load() async { await load(force: true) }

    private func load(force: Bool) async {
        let expected = app.roster.activeID, token = UUID()
        let scope = app.cloudPlaylists.captureScope()
        hydrateCachedSnapshot()
        loadGeneration = token; lastLoadStarted = Date(); loadError = nil
        // Cache hits render without a loading phase. A real background read exposes
        // its progress through the coordinator while the existing rows stay visible.
        refreshing = force || state.value == nil
        if state.value == nil { state = .loading }
        defer { if loadGeneration == token { refreshing = false } }
        do {
            if let scope {
                let snapshot = try await app.cloudPlaylists.loadSnapshot(id: summary.id, force: force, expectedScope: scope)
                guard !Task.isCancelled, expected == app.roster.activeID, token == loadGeneration else { return }
                // A shared background read can finish before this cached return is
                // resumed. Prefer the coordinator's latest committed snapshot.
                let latest = app.cloudPlaylists.cachedSnapshot(id: cloudID) ?? snapshot
                apply(latest)
                if summary.artwork == nil { await palette.load(latest.playlist.artwork) }
            } else {
                // Public playlists can still browse without an account. Reappearing
                // does not throw away an already loaded public pagination checkpoint.
                if !force, state.value != nil { return }
                let page = try await app.music.playlistFreshForPlayback(summary.id)
                guard !Task.isCancelled, expected == app.roster.activeID, token == loadGeneration else { return }
                songs = page.songs; continuation = page.continuation; loadedContinuations = []; cloudSnapshot = nil
                state = .loaded(page)
                if summary.artwork == nil { await palette.load(page.playlist.artwork) }
            }
        } catch {
            guard !Task.isCancelled, expected == app.roster.activeID, token == loadGeneration else { return }
            let message = playlistToolboxErrorMessage(error)
            loadError = message
            if state.value == nil { state = .failed(message) }
        }
    }

    private func addAllToPlaylist() {
        let profile = app.roster.activeID, token = loadGeneration
        Task {
            let complete = await allSongs()
            guard !Task.isCancelled, profile == app.roster.activeID, token == loadGeneration, !complete.isEmpty else { return }
            app.addToPlaylist(complete)
        }
    }

    /// Every song, loading the pages not scrolled to yet, for downloading the whole playlist.
    private func allSongs() async -> [Song] {
        while continuation != nil, !Task.isCancelled {
            if loadingMore {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return [] }
                continue
            }
            let before = continuation
            await loadMore()
            guard !Task.isCancelled else { return [] }
            // A failed or repeated page leaves its cursor unchanged. An empty page can
            // still advance to more playable songs, so song count is not a completion test.
            if continuation == before { break }
        }
        if continuation != nil {
            loadError = CloudPlaylistError.incompleteResponse.localizedDescription
            return []
        }
        return Task.isCancelled ? [] : songs
    }

    private func loadMore() async {
        guard toolbox == nil, !loadingMore, let token = continuation, !loadedContinuations.contains(token) else { return }
        loadingMore = true
        let expected = app.roster.activeID, generation = loadGeneration
        defer { loadingMore = false }
        guard let page = try? await app.music.playlistMoreForPlayback(token), !Task.isCancelled,
              continuation == token, expected == app.roster.activeID, generation == loadGeneration else { return }
        // A repeated cursor is a failed page, never proof of a complete playlist. Keep the
        // valid prefix/cursor so playback preparation can report the failure without truncation.
        if let next = page.continuation, next == token || loadedContinuations.contains(next) { return }
        songs += page.songs
        loadedContinuations.insert(token)
        continuation = page.continuation
    }
}
