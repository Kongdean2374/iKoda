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

    var body: some View {
        Group {
            if Platform.isMac { macBody } else { phoneBody }
        }
        .sheet(item: $toolbox) { PlaylistToolboxView(request: $0).appEnvironment(app) }
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
        .task { if state.value == nil { await load() } }
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
                AddToPlaylistMenu(songs: songs)
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
                        AddToPlaylistMenu(songs: songs)
                    }
                    PinMenuItem(pin: .playlist(summary))
                    ShareLink(item: URL(string: "https://music.youtube.com/playlist?list=\(summary.id)")!) {
                        Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task { await palette.load(summary.artwork) }
        .task { if state.value == nil { await load() } }
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

    private func load() async {
        state = .loading
        do {
            let page = try await app.music.playlist(summary.id)
            songs = page.songs
            continuation = page.continuation
            loadedContinuations = []
            state = .loaded(page)
            if summary.artwork == nil { await palette.load(page.playlist.artwork) }
        } catch {
            state = .failed(error.friendlyMessage)
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
        return Task.isCancelled ? [] : songs
    }

    private func loadMore() async {
        guard toolbox == nil, !loadingMore, let token = continuation, !loadedContinuations.contains(token) else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await app.music.playlistMoreForPlayback(token), !Task.isCancelled,
              continuation == token else { return }
        // A repeated cursor is a failed page, never proof of a complete playlist. Keep the
        // valid prefix/cursor so playback preparation can report the failure without truncation.
        if let next = page.continuation, next == token || loadedContinuations.contains(next) { return }
        songs += page.songs
        loadedContinuations.insert(token)
        continuation = page.continuation
    }
}
