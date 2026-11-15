import KodaCore
import SwiftUI

/// Keep the Mac's existing page and navigation, with the same cloud-first hierarchy
/// and playlist controls as the phone. A small listening shelf stays available offline.
struct MacHomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    /// Owned by the window, so Home is still there after a visit to another section.
    let model: HomeModel
    @State private var width: CGFloat = 1000
    @State private var refreshing = false
    @State private var showsRecommendations = false
    @State private var showsCreatePlaylist = false
    @State private var preferences = HomePlaylistPreferences()
    private var listeningSelection: HomeListeningSelection? { .make(library: library, model: model) }
    private var needsRecommendationPreview: Bool {
        app.cloudPlaylists.catalog.isEmpty && library.recent.isEmpty && library.liked.isEmpty
    }

    var body: some View {
        MacPage {
            header
            cloudPlaylists
            listeningPreview
            DisclosureGroup("Recommendations", isExpanded: $showsRecommendations) {
                recommendations
            }
            .padding(.horizontal, MacMetrics.gutter)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle(String(localized: "Home"))
        .task(id: app.roster.activeID) {
            preferences = HomePlaylistPreferences.load(profileID: app.roster.activeID)
            await app.cloudPlaylists.refresh(force: false)
        }
        .task(id: showsRecommendations) {
            model.recommendationsRequested = showsRecommendations || needsRecommendationPreview
            if showsRecommendations {
                if model.needsRefresh { await load() }
            }
        }
        .task(id: "\(model.profile)-\(needsRecommendationPreview)") {
            model.recommendationsRequested = showsRecommendations || needsRecommendationPreview
            if needsRecommendationPreview, model.needsRefresh { await load() }
        }
        .onChange(of: app.roster.activeID) { _, _ in showsRecommendations = false }
        .onAppear { model.recommendationsRequested = showsRecommendations || needsRecommendationPreview }
        .onDisappear { model.recommendationsRequested = false }
        .sheet(isPresented: $showsCreatePlaylist) {
            CloudPlaylistCreateView().appEnvironment(app)
        }
    }

    private var cloudPlaylists: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("My YouTube Music Playlists").font(.title2.bold())
                Spacer()
                if app.cloudPlaylists.hasSession {
                    Button("New Cloud Playlist", systemImage: "plus") { showsCreatePlaylist = true }
                        .buttonStyle(.glass)
                }
            }
            CloudPlaylistSessionNotice()
            CloudPlaylistOperationView()
            PlaylistQueueLoadingView()
            if app.cloudPlaylists.hasSession {
                if app.cloudPlaylists.isRefreshing { ProgressView("Refreshing Cloud Playlists…") }
                if let error = app.cloudPlaylists.refreshError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.cloud.error")
                    Button("Try Again") { Task { await app.cloudPlaylists.refresh(force: true) } }
                        .accessibilityIdentifier("home.cloud.retry")
                }
                if app.cloudPlaylists.isFromCache {
                    Text("Showing Cached Cloud Playlists").font(.footnote).foregroundStyle(.secondary)
                }
                let ordered = preferences.sorted(app.cloudPlaylists.catalog)
                if ordered.isEmpty, !app.cloudPlaylists.isRefreshing, app.cloudPlaylists.refreshError == nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Cloud Playlists Yet").font(.headline)
                        Text("Create a playlist in your YouTube Music account to see it here.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Create Cloud Playlist") { showsCreatePlaylist = true }
                            .buttonStyle(.glass)
                    }
                    .accessibilityIdentifier("home.cloud.empty")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(ordered) { playlist in
                        let group = ordered.filter { preferences.isPinned($0.id) == preferences.isPinned(playlist.id) }
                        HomeCloudPlaylistCard(playlist: playlist, isPinned: preferences.isPinned(playlist.id),
                            canMoveEarlier: group.first?.id != playlist.id, canMoveLater: group.last?.id != playlist.id,
                            play: { playCloudPlaylist(playlist) },
                            shuffle: { playCloudPlaylist(playlist, shuffled: true) },
                            pin: { updatePreference { $0.togglePin(playlist.id) } },
                            move: { offset in updatePreference { $0.move(playlist.id, by: offset, in: ordered) } })
                    }
                }
            }
        }
        .padding(.horizontal, MacMetrics.gutter)
    }

    @ViewBuilder
    private var listeningPreview: some View {
        if let selection = listeningSelection {
            if selection.source == .recommendations {
                if !showsRecommendations {
                    let columns = max(1, min(3, Int((width - MacMetrics.gutter * 2) / 230)))
                    VStack(alignment: .leading, spacing: 10) {
                        MacSectionTitle(title: selection.title, subtitle: String(localized: "Start with these"))
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 2) {
                            ForEach(Array(selection.songs.prefix(8).enumerated()), id: \.offset) { index, song in
                                MacSongTile(song: song) { player.play(selection.songs, startAt: index) }
                            }
                        }
                    }
                    .padding(.horizontal, MacMetrics.gutter)
                    .accessibilityIdentifier(selection.accessibilityID)
                }
            } else {
                listeningShelf(selection)
            }
        } else if needsRecommendationPreview, !showsRecommendations {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recommendations").font(.title3.bold())
                recommendations
                Text("Play a song to see your recent listening here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, MacMetrics.gutter)
            .accessibilityIdentifier("home.recommendations.preview")
        }
    }

    private func listeningShelf(_ selection: HomeListeningSelection) -> some View {
        MacShelf(title: selection.title, seeAll: selection.seeAll) {
            ForEach(Array(selection.songs.prefix(8).enumerated()), id: \.element.id) { index, song in
                Button { player.play(selection.songs, startAt: index) } label: {
                    MacCoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine,
                                 onPlay: { player.play(selection.songs, startAt: index) })
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.listening.song.\(song.id)")
                .contextMenu { SongMenuItems(song: song) }
            }
        }
        .accessibilityIdentifier(selection.accessibilityID)
    }

    @ViewBuilder
    private var recommendations: some View {
        switch model.state {
        case .loading: ProgressView("Loading…")
        case .failed(let message):
            Text(message).foregroundStyle(.secondary)
            Button("Try Again") { Task { await load() } }
        case .loaded(let content): sections(content)
        }
    }

    private func playCloudPlaylist(_ playlist: PlaylistSummary, shuffled: Bool = false) {
        if let snapshot = app.cloudPlaylists.cachedSnapshot(id: playlist.id) {
            // A complete source remains a complete shuffle pool, including after a
            // cold launch. Refresh only updates the cache for the next explicit play.
            player.playPlaylist(snapshot.songs, continuation: nil, shuffled: shuffled, sourceID: snapshot.id)
            guard let scope = app.cloudPlaylists.captureScope() else { return }
            Task {
                _ = try? await app.cloudPlaylists.loadSnapshot(id: snapshot.id, force: false, expectedScope: scope)
            }
        } else {
            player.playPlaylist(id: playlist.id, shuffled: shuffled)
        }
    }

    private func updatePreference(_ change: (inout HomePlaylistPreferences) -> Void) {
        change(&preferences)
        preferences.save(profileID: app.roster.activeID)
    }

    /// The greeting, with Refresh beside it as Last.fm's page has Sync Now: the window's
    /// toolbar keeps search.
    private var header: some View {
        MacPageTitle(title: greeting, subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
            if refreshing { ProgressView().controlSize(.small) }
            Button(String(localized: "Refresh"), systemImage: "arrow.clockwise") {
                Task {
                    refreshing = true
                    await app.cloudPlaylists.refresh(force: true)
                    if showsRecommendations || needsRecommendationPreview {
                        await app.music.clearPageCache()
                        await load()
                    }
                    refreshing = false
                }
            }
            .buttonStyle(.glass)
            .disabled(refreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help(String(localized: "Refresh Home (⌘R)"))
        }
    }

    @ViewBuilder
    private func sections(_ content: HomeModel.Content) -> some View {
        top(content)

        let jump = JumpBackIn.items(in: library)
        if jump.count >= 2 {
            MacShelf(title: String(localized: "Jump back in")) {
                ForEach(jump) { item in
                    NavigationLink(value: JumpBackIn.route(item)) {
                        MacCoverCard(title: JumpBackIn.title(item), subtitle: JumpBackIn.subtitle(item)) {
                            JumpBackIn.cover(item, size: MacMetrics.card)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // Signed in, the account's own shelves from YouTube Music's Home.
        ForEach(content.accountShelves ?? []) { MacItemShelf(shelf: $0) }
        if model.latestReleases.count >= 3 {
            MacItemShelf(shelf: HomeModel.latestShelf(model.latestReleases))
        }
        let yours = model.yourArtists
        if yours.count >= 3 {
            MacShelf(title: String(localized: "Your top artists"), subtitle: String(localized: "Based on your listening")) {
                ForEach(yours, id: \.name) { ref in
                    if let id = ref.id {
                        MacArtistCard(artist: ArtistSummary(id: id, name: ref.name, artwork: model.artistPhotos[id]))
                    }
                }
            }
        }
        ForEach(model.similar) { MacItemShelf(shelf: HomeModel.similarShelf($0)) }
        if model.forgotten.count >= 4 {
            MacShelf(title: String(localized: "Forgotten favourites"), subtitle: String(localized: "Played often, not lately")) {
                ForEach(Array(model.forgotten.enumerated()), id: \.element.id) { index, song in
                    Button { player.play(model.forgotten, startAt: index) } label: {
                        MacCoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine,
                                     onPlay: { player.play(model.forgotten, startAt: index) })
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SongMenuItems(song: song) }
                }
            }
        }
        if app.settings.showsChartsOnHome, !content.charts.isEmpty {
            MacShelf(title: String(localized: "Charts"), subtitle: String(localized: "Global and near you")) {
                ForEach(content.charts) { MacItemCard(item: .playlist($0)) }
            }
        }
    }

    /// Your Mix and Quick picks side by side; stacked when the window is too narrow for both.
    @ViewBuilder
    private func top(_ content: HomeModel.Content) -> some View {
        // Four rows, as tall as Your Mix beside them, in as many columns as the room allows.
        let room = width > 900 ? width - MacMetrics.gutter * 2 - 380 - 28 : width - MacMetrics.gutter * 2
        let columns = max(1, min(3, Int(room / 230)))
        let picks = Array(content.quickPicks.prefix(columns * 4))
        let layout = width > 900
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
        layout {
            mix
                .frame(width: width > 900 ? 380 : nil)
                .frame(maxWidth: width > 900 ? nil : 520, alignment: .leading)
            if !picks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    MacSectionTitle(title: content.quickPicksTitle == "Quick picks" ? String(localized: "Quick picks") : content.quickPicksTitle, subtitle: content.quickPicks == content.trending ? String(localized: "Trending now") : String(localized: "Start with these"))
                        .padding(.leading, 6)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: columns), spacing: 2) {
                        ForEach(Array(picks.enumerated()), id: \.offset) { index, song in
                            MacSongTile(song: song) { player.play(content.quickPicks, startAt: index) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, MacMetrics.gutter)
    }

    @ViewBuilder
    private var mix: some View {
        if let mix = model.mix {
            MixHero(mix: mix)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        } else if model.mixPending {
            MixHero(mix: .placeholder)
                .loadingPlaceholder()
        }
    }

    private func load() async {
        await app.loadHome(model)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: String(localized: "Good morning")
        case 12..<17: String(localized: "Good afternoon")
        case 17..<22: String(localized: "Good evening")
        default: String(localized: "Up late")
        }
    }
}
