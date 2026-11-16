import KodaCore
import SwiftUI

/// How saved albums, playlists and artists are ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, artist

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: String(localized: "Recently Added")
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist")
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .title: "textformat"
        case .artist: "music.mic"
        }
    }
}

/// What the listener saved on this phone.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @AppStorage("koda.library.sort") private var sort: LibrarySort = .recent
    @State private var showsProfile = false
    @State private var showsMerge = false

    private var isEmpty: Bool {
        library.liked.isEmpty && library.albums.isEmpty && app.cloudPlaylists.catalog.isEmpty && library.artists.isEmpty
            && library.recent.isEmpty && library.userPlaylists.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let error = app.accountSyncError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("library.sync.error")
                        Button("Try Again") { Task { await app.refreshAccount() } }
                    }
                    .padding(.horizontal, 20)
                }
                if library.pins.contains(where: { if case .userPlaylist = $0 { return false }; return true }) {
                    PinnedGrid()
                }
                VStack(spacing: 0) {
                    LibraryLink(title: String(localized: "Liked Songs"), systemImage: "heart.fill", tint: .pink, count: library.liked.count,
                                route: .songs(title: String(localized: "Liked Songs"), source: .liked))
                        .contextMenu { PinMenuItem(pin: .liked) }
                    Divider().padding(.leading, 56)
                    LibraryLink(title: String(localized: "Downloads"), systemImage: "arrow.down.circle.fill", tint: .blue, count: downloads.songs.count,
                                route: .songs(title: String(localized: "Downloads"), source: .downloaded))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: String(localized: "Ready Offline"), systemImage: "airplane", tint: .green, count: downloads.readyOfflineSongs.count,
                                route: .songs(title: String(localized: "Ready Offline"), source: .offline))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: String(localized: "Recently Played"), systemImage: "clock.fill", tint: .orange, count: library.recent.count,
                                route: .songs(title: String(localized: "Recently Played"), source: .recent))
                    Divider().padding(.leading, 56)
                    LibraryLink(title: String(localized: "History"), systemImage: "clock.arrow.circlepath", tint: .orange, count: 0, route: .history)
                    Divider().padding(.leading, 56)
                    LibraryLink(title: String(localized: "Listening Stats"), systemImage: "chart.bar.fill", tint: .teal, count: 0, route: .stats)
                }
                .padding(.horizontal, 20)

                yourPlaylists

                if !library.userPlaylists.isEmpty {
                    NavigationLink { LegacyPlaylistArchiveView().appEnvironment(app) } label: {
                        Label("Legacy Playlist Archive", systemImage: "archivebox")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("library.legacy.archive")
                }
                if !library.albums.isEmpty {
                    grid(String(localized: "Albums"), items: sorted(library.albums).map(MusicItem.album))
                }
                if !library.artists.isEmpty {
                    ShelfView(title: String(localized: "Artists")) {
                        ForEach(sortedArtists) { artist in
                            NavigationLink(value: Route.artist(artist)) { ArtistCard(artist: artist, width: 100) }
                                .buttonStyle(.plain)
                                .contextMenu { PinMenuItem(pin: .artist(artist)) }
                        }
                    }
                }
                if isEmpty {
                    ContentUnavailableView(String(localized: "Your Library Is Empty"), systemImage: "square.stack",
                                           description: Text(String(localized: "Like songs, make playlists, and add albums, playlists and artists with the + button on their pages.")))
                        .padding(.top, 20)
                }
            }
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("library.scroll")
        .navigationTitle(String(localized: "Library"))
        // A signed-in profile's pull brings in what changed on the account elsewhere.
        .refreshable {
            if app.roster.active.isSignedIn { await app.refreshAccount() }
            else { await app.cloudPlaylists.refresh(force: true) }
        }
        // Re-entering the tab uses the shared cache and freshness policy. Only the
        // explicit pull/retry paths bypass it, so navigation never restarts a refresh.
        .task(id: app.roster.activeID) { await app.cloudPlaylists.refresh(force: false) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Playlist Tools", systemImage: "ellipsis") {
                    Button("Merge Playlists", systemImage: "square.stack.3d.up") { showsMerge = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu(String(localized: "Sort"), systemImage: "arrow.up.arrow.down") {
                    Picker(String(localized: "Sort By"), selection: $sort) {
                        ForEach(LibrarySort.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option)
                        }
                    }
                }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                ProfileToolbarButton { showsProfile = true }
            }
        }
        .sheet(isPresented: $showsProfile) { ProfileView().appEnvironment(app) }
        .sheet(isPresented: $showsMerge) { PlaylistMergeView().appEnvironment(app) }
    }

    // MARK: Your playlists

    private var yourPlaylists: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "My YouTube Music Playlists"))
                .padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 12) {
                CloudPlaylistSessionNotice()
                CloudPlaylistOperationView()
                if let error = app.cloudPlaylists.refreshError, error != app.accountSyncError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Refresh Cloud Playlists") { Task { await app.cloudPlaylists.refresh(force: true) } }
                }
                if app.cloudPlaylists.isFromCache {
                    Text("Cached cloud playlists. Pull to refresh.").font(.footnote).foregroundStyle(.secondary)
                }
                if app.cloudPlaylists.isRefreshing {
                    if app.cloudPlaylists.catalog.isEmpty {
                        ProgressView("Loading Playlists…")
                    } else {
                        Label("Refreshing Cloud Playlists…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    NewPlaylistTile()
                    ForEach(sortedCloudPlaylists) { playlist in
                        NavigationLink(value: Route.playlist(playlist)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(artwork: playlist.artwork, size: 140, cornerRadius: 10)
                                Text(playlist.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                if let subtitle = playlist.subtitle {
                                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(width: 140, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { PinMenuItem(pin: .playlist(playlist)) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 20, for: .scrollContent)
            if app.cloudPlaylists.hasSession, app.cloudPlaylists.catalog.isEmpty, !app.cloudPlaylists.isRefreshing,
               app.cloudPlaylists.refreshError == nil {
                Text("Your YouTube Music playlists will appear here. Create a cloud playlist to get started.")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
        }
    }

    private var sortedCloudPlaylists: [PlaylistSummary] {
        switch sort {
        case .recent: app.cloudPlaylists.catalog
        case .title: app.cloudPlaylists.catalog.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: app.cloudPlaylists.catalog.sorted { localizedLess(($0.subtitle ?? "", $0.title), ($1.subtitle ?? "", $1.title)) }
        }
    }

    private func sorted(_ albums: [AlbumSummary]) -> [AlbumSummary] {
        switch sort {
        case .recent: albums
        case .title: albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: albums.sorted { localizedLess(($0.artistLine, $0.title), ($1.artistLine, $1.title)) }
        }
    }

    private func sorted(_ playlists: [PlaylistSummary]) -> [PlaylistSummary] {
        switch sort {
        case .recent: playlists
        case .title: playlists.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .artist: playlists.sorted { localizedLess(($0.subtitle ?? "", $0.title), ($1.subtitle ?? "", $1.title)) }
        }
    }

    private var sortedArtists: [ArtistSummary] {
        sort == .recent ? library.artists : library.artists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func grid(_ title: String, items: [MusicItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16, alignment: .top), GridItem(.flexible(), spacing: 16, alignment: .top)], spacing: 20) {
                ForEach(items) { item in
                    if let route = Route(item) {
                        NavigationLink(value: route) {
                            GeometryReader { geometry in
                                CoverCard(artwork: item.artwork, title: item.title, subtitle: subtitle(item), width: geometry.size.width)
                            }
                            .aspectRatio(0.78, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { if let pin = Pin(item) { PinMenuItem(pin: pin) } }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func subtitle(_ item: MusicItem) -> String? {
        switch item {
        case .album(let a): a.cardSubtitle
        case .playlist(let p): p.subtitle
        default: nil
        }
    }
}

/// What the listener pinned, as tiles at the top of Library, as Music shows its pins: three
/// across, a song playing at a tap and everything else opening its page.
private struct PinnedGrid: View {
    @Environment(Library.self) private var library
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: String(localized: "Pinned"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3), spacing: 16) {
                ForEach(library.pins.filter { if case .userPlaylist = $0 { return false }; return true }) { pin in
                    tile(pin)
                        .contextMenu {
                            PinMenuItem(pin: pin)
                            Button(String(localized: "Move Earlier"), systemImage: "arrow.left") { withAnimation(.smooth) { library.movePin(pin, by: -1) } }
                                .disabled(library.pins.first == pin)
                            Button(String(localized: "Move Later"), systemImage: "arrow.right") { withAnimation(.smooth) { library.movePin(pin, by: 1) } }
                                .disabled(library.pins.last == pin)
                        }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func tile(_ pin: Pin) -> some View {
        switch pin {
        case .song(let song):
            Button { player.play([song]) } label: {
                card(title: song.title, subtitle: song.artistLine) { side in
                    ArtworkView(artwork: song.artwork, size: side, cornerRadius: 10)
                }
            }
            .buttonStyle(.plain)
        case .album(let album):
            link(.album(album), title: album.title, subtitle: album.artistLine) { ArtworkView(artwork: album.artwork, size: $0, cornerRadius: 10) }
        case .playlist(let playlist):
            link(.playlist(playlist), title: playlist.title, subtitle: playlist.subtitle) { ArtworkView(artwork: playlist.artwork, size: $0, cornerRadius: 10) }
        case .artist(let artist):
            link(.artist(artist), title: artist.name, subtitle: String(localized: "Artist")) { side in
                ArtworkView(artwork: artist.artwork, size: side, cornerRadius: side / 2)
            }
        case .userPlaylist(let id):
            if let playlist = library.userPlaylist(id) {
                link(.userPlaylist(id), title: playlist.name, subtitle: String(localized: "Playlist")) { PlaylistCover(playlist: playlist, size: $0, cornerRadius: 10) }
            }
        case .liked:
            link(.songs(title: String(localized: "Liked Songs"), source: .liked), title: String(localized: "Liked Songs"), subtitle: String(localized: "Playlist")) { side in
                JumpBackIn.cover(.liked(count: library.liked.count, songs: library.liked), size: side)
            }
        }
    }

    private func link(_ route: Route, title: String, subtitle: String?, @ViewBuilder cover: @escaping (CGFloat) -> some View) -> some View {
        NavigationLink(value: route) { card(title: title, subtitle: subtitle, cover: cover) }
            .buttonStyle(.plain)
    }

    /// The cover fills the column's width; its size comes from the column, never the image.
    private func card(title: String, subtitle: String?, @ViewBuilder cover: @escaping (CGFloat) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { GeometryReader { cover($0.size.width) } }
            Text(title).font(.footnote.weight(.medium)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Orders by the first string, then the second, as Finder would.
private func localizedLess(_ a: (String, String), _ b: (String, String)) -> Bool {
    switch a.0.localizedStandardCompare(b.0) {
    case .orderedAscending: true
    case .orderedDescending: false
    case .orderedSame: a.1.localizedStandardCompare(b.1) == .orderedAscending
    }
}

/// The first tile among the listener's playlists: makes a new one.
private struct NewPlaylistTile: View {
    @Environment(AppModel.self) private var app
    @State private var creating = false

    var body: some View {
        Button { creating = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary).frame(width: 140, height: 140)
                    .overlay { Image(systemName: "plus").font(.system(size: 34, weight: .medium)).foregroundStyle(Color.accentColor) }
                Text("New Cloud Playlist").font(.subheadline.weight(.medium)).lineLimit(2)
            }
            .frame(width: 140, alignment: .leading).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("library.cloud.create")
        .sheet(isPresented: $creating) { CloudPlaylistCreateView().appEnvironment(app) }
    }
}

private struct LibraryLink: View {
    let title: String
    let systemImage: String
    let tint: Color
    let count: Int
    let route: Route

    var body: some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(tint.gradient, in: .rect(cornerRadius: 9, style: .continuous))
                Text(title).font(.body)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
