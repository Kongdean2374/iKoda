import KodaCore
import SwiftUI

@MainActor
@Observable
final class HomeModel {
    nonisolated struct Content: Codable, Sendable {
        var quickPicks: [Song] = []
        var quickPicksTitle = "Quick picks"
        var shelves: [Shelf] = []
        /// YouTube Music's chart playlists: global, the listener's region, then its genres or languages.
        /// The one row on Home that isn't built from the listener's own listening.
        var charts: [PlaylistSummary] = []
        var trending: [Song] = []
        /// Signed in, the account's own shelves from YouTube Music's Home (Listen again, mixes,
        /// albums for you), Quick picks aside. Optional so a snapshot from before still loads.
        var accountShelves: [Shelf]?

        /// The shape of a loaded Home, for drawing it redacted while the real one loads.
        static let placeholder: Content = {
            var content = Content()
            content.quickPicks = Song.placeholders(8)
            content.charts = (0..<6).map { PlaylistSummary(id: "placeholder-\($0)", title: String(localized: "Top 100 Chart")) }
            return content
        }()
    }

    /// Artists fans of one of the listener's top artists also like.
    nonisolated struct SimilarArtists: Codable, Sendable, Identifiable {
        var artist: String
        var artists: [ArtistSummary]
        var id: String { artist }
    }

    /// Songs woven from the radios of what the listener plays most.
    nonisolated struct Mix: Equatable, Codable, Sendable {
        var artists: [String]
        var songs: [Song]
        /// Built from listening; otherwise trending songs for someone new.
        var isPersonal: Bool

        static let placeholder = Mix(artists: [String(localized: "Artist name"), String(localized: "Artist")], songs: Song.placeholders(3), isPersonal: true)
    }

    var recommendationsRequested = false
    private(set) var isLoading = false
    private var lastLoadAttempt: Date?
    private(set) var state: LoadState<Content> = .loading
    private(set) var mix: Mix?
    /// Your Mix is still to come: its card keeps its place, redacted, until it does.
    private(set) var mixPending = true
    /// Portraits for the listener's top artists, by channel id; fetched after the page shows.
    private(set) var artistPhotos: [String: Artwork] = [:]
    /// The listener's most-played artists, as of the last load.
    private(set) var yourArtists: [ArtistRef] = []
    /// This year's and last year's releases by those artists.
    private(set) var latestReleases: [AlbumSummary] = []
    /// Artists like the top two.
    private(set) var similar: [SimilarArtists] = []
    /// Songs played often, but not for a month.
    private(set) var forgotten: [Song] = []
    /// When Home last loaded, so a window coming back to it after a long while can refresh it.
    private(set) var loadedAt: Date?
    /// What's shown came from the last launch's snapshot and hasn't been refreshed yet.
    private(set) var isFromSnapshot = false

    /// Home as it was last shown, saved to disk so a cold launch opens on it.
    nonisolated private struct Saved: Codable, Sendable {
        var content: Content
        var mix: Mix?
        var artistPhotos: [String: Artwork]
        var loadedAt: Date
        var latestReleases: [AlbumSummary]?
        var similar: [SimilarArtists]?
    }

    /// Whose Home this is: each profile's is its own, and so is its snapshot.
    let profile: UUID
    private var snapshotName: String { "home-\(profile.uuidString)" }

    init(profile: UUID) {
        self.profile = profile
        guard let saved = Snapshot.load(Saved.self, "home-\(profile.uuidString)") else { return }
        state = .loaded(saved.content)
        mix = saved.mix
        mixPending = saved.mix == nil
        artistPhotos = saved.artistPhotos
        loadedAt = saved.loadedAt
        latestReleases = saved.latestReleases ?? []
        similar = saved.similar ?? []
        isFromSnapshot = true
    }

    /// A fresh snapshot is immediately usable. A failed request has a short cooldown
    /// so moving between tabs does not repeatedly ask the same unavailable services.
    var needsRefresh: Bool {
        guard !isLoading, lastLoadAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return false }
        return state.value == nil || loadedAt.map { Date().timeIntervalSince($0) > 1800 } == true
    }

    /// `signedIn`: the profile has a YouTube Music account, whose own Home then gives Quick picks.
    func load(music: YouTubeMusic, library: Library, signedIn: Bool,
              isCurrent: @escaping @MainActor @Sendable () -> Bool = { true }) async {
        guard !isLoading, !Task.isCancelled, isCurrent() else { return }
        isLoading = true
        lastLoadAttempt = Date()
        defer {
            isLoading = false
            if Task.isCancelled { lastLoadAttempt = nil }
        }
        // Worked out here, not in the view's body: the body is drawn again every few seconds
        // while music plays, as listening time is added, and this ranks every song ever played.
        yourArtists = topArtists(library)
        if state.value == nil { state = .loading }
        if mix == nil { mixPending = true }
        let recent = library.recent
        let taste = Taste(library: library)
        // What the listener asked not to be offered stays out of everything Home suggests.
        let hidden = library.notInterested
        forgotten = HomePicks.forgottenFavourites(library.songStats.values, hidden: hidden)
        // Liked first, then what was kept in taste setup: Quick picks' seed when nothing's been played.
        let liked = library.liked + library.taste.songs
        let pickedArtists = library.taste.artists
        // Home is the listener's own: Your Mix, Quick picks, what they go back to and play. From
        // YouTube it takes the charts, as one row, trending songs for someone new, and signed in,
        // the account's own Quick picks.
        async let explore = try? music.explore()
        async let charts = try? music.chartPlaylists()
        async let picks = quickPicks(music: music, recent: recent, liked: liked, signedIn: signedIn)
        let explorePage = await explore
        let chartPlaylists = await charts ?? []
        let (title, songs, accountShelves) = await picks
        guard !Task.isCancelled, isCurrent() else { return }
        var content = Content()
        content.trending = trending(explorePage).filter { !hidden.hides($0) }
        content.charts = chartPlaylists
        content.quickPicksTitle = title
        let offered = songs.filter { !hidden.hides($0) }
        content.quickPicks = offered.isEmpty ? content.trending : offered
        content.accountShelves = accountShelves.compactMap { shelf in
            var shelf = shelf
            shelf.items = shelf.items.filter { item in
                if case .song(let song) = item { return !hidden.hides(song) }
                return true
            }
            return shelf.items.count >= 3 ? shelf : nil
        }
        // Explore, charts and the account Home are independent. Keep the successful
        // sources even when one endpoint is unavailable, and keep an older snapshot
        // if none returned useful content.
        if !content.quickPicks.isEmpty || !content.charts.isEmpty || !(content.accountShelves ?? []).isEmpty {
            state = .loaded(content)
            loadedAt = Date()
            if mix == nil, taste.isEmpty, !content.trending.isEmpty {
                mix = Mix(artists: Array(Set(content.trending.map(Taste.leadArtist))).sorted().prefix(3).map { $0 },
                          songs: content.trending, isPersonal: false)
            }
        } else if state.value == nil {
            state = .failed(String(localized: "Recommendations are temporarily unavailable. Your saved music is still available."))
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.buildMix(music: music, taste: taste, picks: pickedArtists, recent: recent, hidden: hidden, isCurrent: isCurrent) }
            group.addTask { await self.loadArtists(music: music, picks: pickedArtists, library: library, hidden: hidden, isCurrent: isCurrent) }
        }
        guard !Task.isCancelled, isCurrent() else { return }
        // Radios that all failed still leave a card: trending songs, as for someone new.
        if mix == nil, let trending = state.value?.trending, !trending.isEmpty {
            mix = Mix(artists: Array(Set(trending.map(Taste.leadArtist))).sorted().prefix(3).map { $0 }, songs: trending, isPersonal: false)
        }
        withAnimation(.smooth) { mixPending = false }
        if let content = state.value, let loadedAt {
            isFromSnapshot = false
            Snapshot.save(Saved(content: content, mix: mix, artistPhotos: artistPhotos, loadedAt: loadedAt,
                                latestReleases: latestReleases, similar: similar), snapshotName)
        }
    }

    /// Your Mix: a radio from each top artist's favourite song, woven together.
    private func buildMix(music: YouTubeMusic, taste: Taste, picks: [ArtistSummary], recent: [Song], hidden: NotInterested,
                          isCurrent: @escaping @MainActor @Sendable () -> Bool) async {
        guard !Task.isCancelled, isCurrent() else { return }
        var taste = taste
        if taste.isEmpty, !picks.isEmpty {
            // Nothing played, liked or kept yet: start from the artists picked in taste setup.
            let chosen = Array(picks.filter { $0.id.hasPrefix("UC") }.prefix(4))
            let tops = await withTaskGroup(of: (Int, Song?).self) { group in
                for (index, artist) in chosen.enumerated() {
                    group.addTask { (index, try? await music.artist(artist.id).topSongs.first(where: { !hidden.hides($0) })) }
                }
                var byIndex: [Int: Song] = [:]
                for await (index, song) in group { if let song { byIndex[index] = song } }
                return chosen.indices.compactMap { byIndex[$0] }
            }
            guard !Task.isCancelled, isCurrent() else { return }
            taste = Taste(artists: chosen.map(\.name), seeds: tops)
        }
        guard !taste.isEmpty else { return }
        let radios = await withTaskGroup(of: (Int, [Song]).self) { group in
            for (index, seed) in taste.seeds.enumerated() {
                group.addTask { (index, (try? await music.radio(for: seed.id).songs) ?? []) }
            }
            var byIndex: [Int: [Song]] = [:]
            for await (index, songs) in group { byIndex[index] = songs }
            return taste.seeds.indices.map { byIndex[$0] ?? [] }
        }
        // The seeds and the last few songs played are left out, so the mix is something to go on to.
        let skip = Set(taste.seeds.map(\.id) + recent.prefix(10).map(\.id))
        let songs = Taste.weave(radios.map { $0.filter { !hidden.hides($0) } }, excluding: skip)
        guard !Task.isCancelled, isCurrent(), !songs.isEmpty else { return }
        withAnimation(.smooth) { mix = Mix(artists: Array(taste.artists.prefix(3)), songs: songs, isPersonal: true) }
    }

    /// The top artists' pages: their portraits, and from the first few, their latest releases
    /// and the artists like them. Pages come through the page cache, and only the first
    /// `pagesForPicks` are asked every load; further portraits only while missing.
    private func loadArtists(music: YouTubeMusic, picks: [ArtistSummary], library: Library, hidden: NotInterested,
                             isCurrent: @escaping @MainActor @Sendable () -> Bool) async {
        guard !Task.isCancelled, isCurrent() else { return }
        let played = yourArtists.compactMap(\.id)
        // With nothing played yet, the artists picked in taste setup stand in.
        let leading = Array((played.isEmpty ? picks.map(\.id).filter { $0.hasPrefix("UC") } : played).prefix(Self.pagesForPicks))
        let portraitsOnly = played.filter { !leading.contains($0) && artistPhotos[$0] == nil }
        let pages = await withTaskGroup(of: (String, ArtistPage?).self) { group in
            for id in leading + portraitsOnly {
                group.addTask { (id, try? await music.artist(id)) }
            }
            var found: [String: ArtistPage] = [:]
            for await (id, page) in group { if let page { found[id] = page } }
            return found
        }
        guard !Task.isCancelled, isCurrent() else { return }
        for (id, page) in pages {
            if let artwork = page.artist.artwork { artistPhotos[id] = artwork }
        }
        let ordered = leading.compactMap { pages[$0] }
        // A failed load keeps what was there rather than emptying the rows.
        guard !ordered.isEmpty else { return }
        let known = Set(played + library.artists.map(\.id) + picks.map(\.id))
        var likes: [SimilarArtists] = []
        for page in ordered where likes.count < 2 {
            let artists = HomePicks.similar(to: page, excluding: known.union(likes.flatMap { $0.artists.map(\.id) }), hidden: hidden)
            if artists.count >= 4 { likes.append(SimilarArtists(artist: page.artist.name, artists: Array(artists.prefix(12)))) }
        }
        withAnimation(.smooth) {
            latestReleases = HomePicks.latestReleases(ordered)
            similar = likes
        }
    }

    static func latestShelf(_ releases: [AlbumSummary]) -> Shelf {
        Shelf(title: String(localized: "New from your artists"), strapline: String(localized: "Out this year and last"), items: releases.map(MusicItem.album))
    }

    static func similarShelf(_ likes: SimilarArtists) -> Shelf {
        Shelf(title: String(localized: "More like \(likes.artist)"), strapline: String(localized: "Fans also like"), items: likes.artists.map(MusicItem.artist))
    }

    /// Artist pages asked for on every load, for New from your artists and the artists like them.
    private static let pagesForPicks = 6

    /// The listener's most-played artists that can be opened, strongest first.
    func topArtists(_ library: Library, limit: Int = 10) -> [ArtistRef] {
        let taste = Taste(library: library, maxSeeds: 0)
        var refs: [String: ArtistRef] = [:]
        for stats in library.songStats.values {
            if let ref = stats.song.artists.first, ref.id != nil { refs[ref.name] = ref }
        }
        return taste.artists.compactMap { refs[$0] }.prefix(limit).map { $0 }
    }

    /// Signed in, the account's Quick picks from YouTube Music's own Home, as Koda for Android
    /// takes them. Otherwise, or when that comes back short, songs like the last one played or,
    /// with nothing played yet, the newest liked; with neither, nothing (trending fills in).
    /// The account's other shelves come back with them, from the same pages.
    private func quickPicks(music: YouTubeMusic, recent: [Song], liked: [Song], signedIn: Bool) async -> (String, [Song], [Shelf]) {
        var shelves: [Shelf] = []
        if signedIn, let home = try? await music.home() {
            shelves = home.shelvesBesideQuickPicks
            let songs = home.quickPicks
            if songs.count >= 3 { return ("Quick picks", Array(songs.prefix(20)), shelves) }
        }
        guard let seed = recent.first ?? liked.first, let radio = try? await music.radio(for: seed.id) else { return ("Quick picks", [], shelves) }
        let songs = Array(radio.songs.filter { $0.id != seed.id }.prefix(20))
        return ("Quick picks", songs, shelves)
    }

    private func trending(_ explore: ShelfPage?) -> [Song] {
        explore?.shelves.first { $0.title == "Trending" }?.items.compactMap {
            if case .song(let s) = $0 { return s }
            return nil
        } ?? []
    }
}

/// A small real listening shelf is useful even if the cloud directory cannot refresh.
/// This is only a presentation of the active library / Home snapshot, never a new store.
@MainActor
struct HomeListeningSelection {
    enum Source: Equatable { case recent, liked, recommendations }
    let source: Source
    let songs: [Song]
    let title: String
    let seeAll: Route

    static func make(library: Library, model: HomeModel) -> Self? {
        if !library.recent.isEmpty {
            return .init(source: .recent, songs: Array(library.recent.prefix(50)),
                         title: String(localized: "Recently played"),
                         seeAll: .songs(title: String(localized: "Recently Played"), source: .recent))
        }
        if !library.liked.isEmpty {
            return .init(source: .liked, songs: Array(library.liked.prefix(50)),
                         title: String(localized: "Liked Songs"),
                         seeAll: .songs(title: String(localized: "Liked Songs"), source: .liked))
        }
        guard let content = model.state.value, !content.quickPicks.isEmpty else { return nil }
        let songs = content.quickPicks
        let title = content.quickPicksTitle == "Quick picks" ? String(localized: "Quick picks") : content.quickPicksTitle
        return .init(source: .recommendations, songs: songs, title: title,
                     seeAll: .songList(title: title, subtitle: nil, songs: songs))
    }

    var accessibilityID: String {
        switch source {
        case .recent: "home.recent"
        case .liked: "home.liked"
        case .recommendations: "home.recommendations.preview"
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    private var model: HomeModel { app.home }

    @State private var preferences = HomePlaylistPreferences()
    @State private var showsRecommendations = false
    @State private var showsCreatePlaylist = false

    private var cloudPlaylists: [PlaylistSummary] { preferences.sorted(app.cloudPlaylists.catalog) }
    private var listeningSelection: HomeListeningSelection? { .make(library: library, model: model) }
    private var needsRecommendationPreview: Bool {
        app.cloudPlaylists.catalog.isEmpty && library.recent.isEmpty && library.liked.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                cloudSection
                PlaylistQueueLoadingView().padding(.horizontal, 20)
                CloudPlaylistOperationView().padding(.horizontal, 20)
                listeningPreview
                DisclosureGroup("Recommendations", isExpanded: $showsRecommendations) {
                    recommendations
                        .padding(.top, 16)
                        .task(id: showsRecommendations) {
                            guard showsRecommendations, !Task.isCancelled else { return }
                            model.recommendationsRequested = true
                            if model.needsRefresh { await load() }
                        }
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("home.recommendations")
            }
            .padding(.vertical, 12)
        }
        .navigationTitle(greeting)
        .toolbar {
            if app.settings.videoModeEnabled {
                ToolbarItem(placement: .topBarLeading) { ModeToggle() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { app.isProfilePresented = true }
            }
        }
        .refreshable {
            await app.cloudPlaylists.refresh(force: true)
            if showsRecommendations || needsRecommendationPreview {
                await app.music.clearPageCache()
                await load()
            }
        }
        .task(id: app.roster.activeID) {
            preferences = HomePlaylistPreferences.load(profileID: app.roster.activeID)
            await app.cloudPlaylists.refresh(force: false)
        }
        .task(id: "\(model.profile)-\(needsRecommendationPreview)") {
            model.recommendationsRequested = showsRecommendations || needsRecommendationPreview
            if needsRecommendationPreview, model.needsRefresh { await load() }
        }
        .onChange(of: app.roster.activeID) { _, _ in showsRecommendations = false }
        .onChange(of: showsRecommendations) { _, shown in
            model.recommendationsRequested = shown || needsRecommendationPreview
        }
        .onAppear { model.recommendationsRequested = showsRecommendations || needsRecommendationPreview }
        .onDisappear { model.recommendationsRequested = false }
        .sheet(isPresented: $showsCreatePlaylist) {
            CloudPlaylistCreateView().appEnvironment(app)
        }
    }

    private var cloudSection: some View {
        let playlists = cloudPlaylists
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("My YouTube Music Playlists").font(.title2.bold())
                    .accessibilityIdentifier("home.cloud.title")
                Spacer(minLength: 8)
                if app.cloudPlaylists.hasSession {
                    Button { showsCreatePlaylist = true } label: {
                        Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("New Cloud Playlist")
                    .accessibilityIdentifier("home.cloud.create")
                }
            }
            CloudPlaylistSessionNotice()
            if app.cloudPlaylists.hasSession {
                if app.cloudPlaylists.isRefreshing {
                    ProgressView("Refreshing Cloud Playlists…")
                        .font(.subheadline)
                }
                if let error = app.cloudPlaylists.refreshError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("home.cloud.error")
                    Button("Try Again") { Task { await app.cloudPlaylists.refresh(force: true) } }
                        .accessibilityIdentifier("home.cloud.retry")
                }
                if app.cloudPlaylists.isFromCache {
                    Label("Showing Cached Cloud Playlists", systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if playlists.isEmpty, !app.cloudPlaylists.isRefreshing,
                   app.cloudPlaylists.refreshError == nil {
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
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                        let pinned = preferences.isPinned(playlist.id)
                        HomeCloudPlaylistCard(playlist: playlist, isPinned: pinned,
                            canMoveEarlier: index > 0 && preferences.isPinned(playlists[index - 1].id) == pinned,
                            canMoveLater: index + 1 < playlists.count && preferences.isPinned(playlists[index + 1].id) == pinned,
                            play: { playCloudPlaylist(playlist) },
                            shuffle: { playCloudPlaylist(playlist, shuffled: true) },
                            pin: { updatePreference { $0.togglePin(playlist.id) } },
                            move: { offset in updatePreference { $0.move(playlist.id, by: offset, in: app.cloudPlaylists.catalog) } })
                    }
                }
                if !playlists.isEmpty {
                    Text("Touch and hold a playlist to pin it or change its Home order. This does not change YouTube Music.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private var listeningPreview: some View {
        if let selection = listeningSelection {
            if selection.source == .recommendations {
                if !showsRecommendations {
                    SongColumnsShelf(title: selection.title, strapline: String(localized: "Start with these"),
                                     songs: Array(selection.songs.prefix(8))) { index in
                        player.play(selection.songs, startAt: index)
                    }
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
            .padding(.horizontal, 20)
            .accessibilityIdentifier("home.recommendations.preview")
        }
    }

    private func listeningShelf(_ selection: HomeListeningSelection) -> some View {
        ShelfView(title: selection.title, seeAll: selection.seeAll) {
            ForEach(Array(selection.songs.prefix(8).enumerated()), id: \.element.id) { index, song in
                Button { player.play(selection.songs, startAt: index) } label: {
                    CoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine, width: 140)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.listening.song.\(song.id)")
                .contextMenu { SongMenuItems(song: song) } preview: { SongPreview(song: song) }
            }
        }
        .accessibilityIdentifier(selection.accessibilityID)
    }

    @ViewBuilder
    private var recommendations: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity)
        case .failed(let message):
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("Try Again") { Task { await load() } }
        case .loaded(let content):
            LazyVStack(alignment: .leading, spacing: 24) { sections(content) }
                .font(.body)
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

    @ViewBuilder
    private func sections(_ content: HomeModel.Content) -> some View {
        if let mix = model.mix {
            MixHero(mix: mix)
                .padding(.horizontal, 20)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        } else if model.mixPending {
            MixHero(mix: .placeholder)
                .loadingPlaceholder()
                .padding(.horizontal, 20)
        }

        JumpBackIn()

        if !content.quickPicks.isEmpty {
            SongColumnsShelf(title: content.quickPicksTitle == "Quick picks" ? String(localized: "Quick picks") : content.quickPicksTitle, strapline: content.quickPicks == content.trending ? String(localized: "Trending now") : String(localized: "Start with these"), songs: content.quickPicks) { index in
                player.play(content.quickPicks, startAt: index)
            }
        }
        // Signed in, the account's own shelves from YouTube Music's Home.
        ForEach(Array((content.accountShelves ?? []).prefix(3))) { shelf in
            ItemShelf(shelf: shelf) { player.startRadio(from: $0) }
        }
        if model.latestReleases.count >= 3 {
            ItemShelf(shelf: HomeModel.latestShelf(model.latestReleases)) { player.startRadio(from: $0) }
        }
        let yours = model.yourArtists
        if yours.count >= 3 {
            ShelfView(title: String(localized: "Your top artists"), strapline: String(localized: "Based on your listening")) {
                ForEach(yours, id: \.name) { ref in
                    if let id = ref.id {
                        let artist = ArtistSummary(id: id, name: ref.name, artwork: model.artistPhotos[id])
                        NavigationLink(value: Route.artist(artist)) { ArtistCard(artist: artist, width: 112) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        ForEach(model.similar) { likes in
            ItemShelf(shelf: HomeModel.similarShelf(likes)) { player.startRadio(from: $0) }
        }
        if model.forgotten.count >= 4 {
            ShelfView(title: String(localized: "Forgotten favourites"), strapline: String(localized: "Played often, not lately")) {
                ForEach(Array(model.forgotten.enumerated()), id: \.element.id) { index, song in
                    Button { player.play(model.forgotten, startAt: index) } label: {
                        CoverCard(artwork: song.artwork, title: song.title, subtitle: song.artistLine, width: 140)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SongMenuItems(song: song) } preview: { SongPreview(song: song) }
                }
            }
        }
        if app.settings.showsChartsOnHome, !content.charts.isEmpty {
            ShelfView(title: String(localized: "Charts"), strapline: String(localized: "Global and near you")) {
                ForEach(content.charts) { chart in
                    NavigationLink(value: Route.playlist(chart)) {
                        CoverCard(artwork: chart.artwork, title: chart.title, subtitle: chart.subtitle)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func play(_ song: Song) {
        player.startRadio(from: song)
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

struct HomeCloudPlaylistCard: View {
    let playlist: PlaylistSummary
    let isPinned: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let play: () -> Void
    let shuffle: () -> Void
    let pin: () -> Void
    let move: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.playlist(playlist)) {
                HStack(alignment: .top, spacing: 12) {
                    ArtworkView(artwork: playlist.artwork, size: 64, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(playlist.title).font(.headline).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let subtitle = playlist.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if isPinned {
                            Label("Pinned", systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.cloud.open.\(playlist.id)")
            HStack(spacing: 12) {
                Button(action: play) { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityLabel(String(localized: "Play \(playlist.title)"))
                    .accessibilityIdentifier("home.cloud.play.\(playlist.id)")
                Button(action: shuffle) { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityLabel(String(localized: "Shuffle \(playlist.title)"))
                    .accessibilityIdentifier("home.cloud.shuffle.\(playlist.id)")
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glass)
        }
        .padding(14)
        .background(.background, in: .rect(cornerRadius: 18))
        .contextMenu {
            Button(isPinned ? String(localized: "Unpin from Home") : String(localized: "Pin on Home"),
                   systemImage: isPinned ? "pin.slash" : "pin") { pin() }
            Button("Move Earlier", systemImage: "arrow.up") { move(-1) }.disabled(!canMoveEarlier)
            Button("Move Later", systemImage: "arrow.down") { move(1) }.disabled(!canMoveLater)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Your Mix

/// The first thing on Home: the listener's mix as a card in its covers' colours, three
/// of its covers along the top and a button that plays it.
struct MixHero: View {
    let mix: HomeModel.Mix
    @Environment(Player.self) private var player
    /// One palette per cover; the background weaves all three together.
    @State private var palettes = [PaletteModel(), PaletteModel(), PaletteModel()]
    @State private var taps = 0
    @State private var isPressed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var coverSize: CGFloat = 100

    private static let cornerRadius: CGFloat = 26
    private static let padding: CGFloat = 20
    private static let playSize: CGFloat = 52

    private var covers: [Artwork] {
        var seen = Set<URL>()
        return mix.songs.compactMap(\.artwork).filter { seen.insert($0.url(pixels: 120)).inserted }.prefix(3).map { $0 }
    }

    private var title: String { mix.isPersonal ? String(localized: "Your Mix") : String(localized: "Start Here") }

    /// A 3×3 mesh from the three covers: the first cover's colours to the top left, the
    /// second's along the top right and right edge, the third's along the bottom and in
    /// the middle, so the card reads as all of them rather than one. Fewer covers repeat.
    private var meshColors: [Color] {
        let count = max(min(covers.count, 3), 1)
        let a = palettes[0].palette.mesh, b = palettes[1 % count].palette.mesh, c = palettes[2 % count].palette.mesh
        return [
            a[0], a[1], b[2],
            a[3], c[4], b[5],
            c[6], c[7], b[8],
        ]
    }
    private var caption: String {
        guard mix.isPersonal else { return String(localized: "Trending songs to get Koda to know you") }
        switch mix.artists.count {
        case 0: return String(localized: "Made from what you play")
        case 1: return String(localized: "\(mix.artists[0]) and more")
        default: return String(localized: "\(ListFormatter.localizedString(byJoining: Array(mix.artists.prefix(2)))) and more")
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        NavigationLink(value: Route.songList(title: title, subtitle: caption, songs: mix.songs)) {
            VStack(alignment: .leading, spacing: 0) {
                coverRow
                    .padding(.bottom, 24)
                Text(mix.isPersonal ? String(localized: "Made for you") : String(localized: "New here"))
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.7))
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                HStack(spacing: 16) {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Room for the play button, which sits over the card rather than inside the link.
                    Color.clear.frame(width: Self.playSize, height: Self.playSize)
                }
            }
            .padding(Self.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { MixBackground(colors: meshColors, isAnimating: !reduceMotion) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(PressReporting(isPressed: $isPressed))
        .overlay(alignment: .bottomTrailing) {
            Button {
                taps += 1
                player.play(mix.songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.title3.weight(.semibold))
                    .frame(width: Self.playSize, height: Self.playSize)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(Self.padding)
            .accessibilityLabel(String(localized: "Play \(title)"))
            .sensoryFeedback(.impact(weight: .medium), trigger: taps)
        }
        // The card and its play button press down together, as one object.
        .scaleEffect(isPressed ? 0.97 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
        .environment(\.colorScheme, .dark)
        .task(id: covers) {
            // The covers are already loaded for the row, so these come from the cache.
            for (index, cover) in covers.enumerated() where index < palettes.count {
                await palettes[index].load(cover)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Up to three covers overlapping left to right, the first on top; empty slots while
    /// there are none, so the card keeps its height.
    @ViewBuilder
    private var coverRow: some View {
        let covers = covers
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: -coverSize * 0.3) {
            if covers.isEmpty {
                // One flat shape, each slot cut out of the one behind it, so the overlaps
                // don't stack translucent grey and shadows into darker patches.
                ForEach(0..<3, id: \.self) { index in
                    shape.fill(.white)
                        .frame(width: coverSize, height: coverSize)
                        .background { shape.padding(-3).blendMode(.destinationOut) }
                        .zIndex(Double(-index))
                }
            } else {
                ForEach(covers.indices, id: \.self) { index in
                    // Opaque under the image, so a cover still loading hides the one behind it.
                    ArtworkView(artwork: covers[index], size: coverSize, cornerRadius: 12)
                        .background(Color(white: 0.22), in: shape)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                        .zIndex(Double(-index))
                }
            }
        }
        .compositingGroup()
        .opacity(covers.isEmpty ? 0.16 : 1)
        .accessibilityHidden(true)
    }
}

/// The mix card's colours, their inner points drifting slowly so the colours move.
private struct MixBackground: View {
    let colors: [Color]
    let isAnimating: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let a = Float(sin(t * 0.3)) * 0.1, b = Float(cos(t * 0.23)) * 0.1
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + a * 0.6, 0], [1, 0],
                [0, 0.5 + b * 0.6], [0.55 + a, 0.45 + b], [1, 0.5 - a * 0.6],
                [0, 1], [0.5 - b * 0.6, 1], [1, 1],
            ], colors: colors)
        }
        .animation(.easeInOut(duration: 0.8), value: colors)
    }
}

/// Reports the press instead of drawing it, so a view around the button (the mix card
/// with its play button) can press down as a whole.
private struct PressReporting: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in isPressed = pressed }
    }
}

// MARK: - Jump back in

/// Up to eight things the listener keeps going back to, as a row of covers.
struct JumpBackIn: View {
    @Environment(Library.self) private var library

    private static let limit = 8
    private static let width: CGFloat = 156

    enum Item: Identifiable {
        case liked(count: Int, songs: [Song])
        case userPlaylist(UserPlaylist)
        case album(AlbumSummary)
        case playlist(PlaylistSummary)

        var id: String {
            switch self {
            case .liked: "liked"
            case .userPlaylist(let p): "user-\(p.id)"
            case .album(let a): "album-\(a.id)"
            case .playlist(let p): "playlist-\(p.id)"
            }
        }
    }

    private var items: [Item] { Self.items(in: library) }

    /// What the listener keeps going back to, for the phone's row and the Mac's shelf alike.
    static func items(in library: Library) -> [Item] {
        let limit = Self.limit
        var items: [Item] = []
        if !library.liked.isEmpty { items.append(.liked(count: library.liked.count, songs: library.liked)) }
        // Albums of songs played lately, newest first, one each.
        var seenAlbums = Set<String>()
        for song in library.recent {
            guard let album = song.album, seenAlbums.insert(album.id).inserted else { continue }
            items.append(.album(AlbumSummary(id: album.id, title: album.title, artistLine: song.artistLine, artists: song.artists, artwork: song.artwork)))
            if items.count >= limit { break }
        }
        for album in library.albums where items.count < limit && seenAlbums.insert(album.id).inserted {
            items.append(.album(album))
        }
        items += library.playlists.prefix(max(0, limit - items.count)).map(Item.playlist)
        return Array(items.prefix(limit))
    }

    var body: some View {
        let items = items
        if items.count >= 2 {
            ShelfView(title: String(localized: "Jump back in")) {
                ForEach(items) { item in
                    NavigationLink(value: Self.route(item)) { card(item) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    static func route(_ item: Item) -> Route {
        switch item {
        case .liked: .songs(title: String(localized: "Liked Songs"), source: .liked)
        case .userPlaylist(let p): .userPlaylist(p.id)
        case .album(let a): .album(a)
        case .playlist(let p): .playlist(p)
        }
    }

    static func title(_ item: Item) -> String {
        switch item {
        case .liked: String(localized: "Liked Songs")
        case .userPlaylist(let p): p.name
        case .album(let a): a.title
        case .playlist(let p): p.title
        }
    }

    static func subtitle(_ item: Item) -> String? {
        switch item {
        case .liked(let count, _): songCount(count)
        case .userPlaylist(let p): songCount(p.songs.count)
        case .album(let a): a.artistLine.isEmpty ? nil : a.artistLine
        case .playlist(let p): p.subtitle
        }
    }

    /// The item's cover alone, at `size`: liked songs and the listener's playlists as mosaics.
    @ViewBuilder
    static func cover(_ item: Item, size: CGFloat) -> some View {
        switch item {
        case .liked(_, let songs):
            PlaylistMosaic(songs: songs, size: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.45), in: .circle)
                        .padding(8)
                }
        case .userPlaylist(let p):
            PlaylistCover(playlist: p, size: size)
        case .album(let a):
            ArtworkView(artwork: a.artwork, size: size, cornerRadius: 10)
        case .playlist(let p):
            ArtworkView(artwork: p.artwork, size: size, cornerRadius: 10)
        }
    }

    @ViewBuilder
    private func card(_ item: Item) -> some View {
        let width = Self.width
        switch item {
        case .liked(let count, let songs):
            // The listener's own liked covers, marked with a heart, rather than a stock colour.
            CoverCard(title: String(localized: "Liked Songs"), subtitle: Self.songCount(count), width: width) {
                PlaylistMosaic(songs: songs, size: width)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.black.opacity(0.45), in: .circle)
                            .padding(8)
                    }
            }
        case .userPlaylist(let p):
            CoverCard(title: p.name, subtitle: Self.songCount(p.songs.count), width: width) {
                PlaylistCover(playlist: p, size: width)
            }
        case .album(let a):
            CoverCard(artwork: a.artwork, title: a.title, subtitle: a.artistLine.isEmpty ? nil : a.artistLine, width: width)
        case .playlist(let p):
            CoverCard(artwork: p.artwork, title: p.title, subtitle: p.subtitle, width: width)
        }
    }

    private static func songCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
    }
}
