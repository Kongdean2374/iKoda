import KodaCore
import SwiftUI

/// Search's Your Library scope on the iPhone: the listener's own songs, playlists, albums and
/// artists that match, updated as they type, as Music's Library scope is.
struct LibrarySearchResults: View {
    let query: String
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player
    @Environment(AppModel.self) private var app
    @State private var toolbox: PlaylistToolboxRequest?

    var body: some View {
        let found = cloudLibraryMatches(query, library: library, downloads: downloads, app: app)
        List {
            if !found.songs.isEmpty {
                Section(String(localized: "Songs")) {
                    ForEach(Array(found.songs.prefix(50).enumerated()), id: \.element.id) { index, song in
                        SongRow(song: song) { player.play(found.songs, startAt: index) }
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 12))
                    }
                }
            }
            if !found.albums.isEmpty {
                Section(String(localized: "Albums")) {
                    ForEach(found.albums) { album in
                        NavigationLink(value: Route.album(album)) {
                            row(title: album.title, subtitle: album.cardSubtitle) {
                                ArtworkView(artwork: album.artwork, size: 52, cornerRadius: 8)
                            }
                        }
                    }
                }
            }
            if !found.playlists.isEmpty {
                Section(String(localized: "Playlists")) {
                    ForEach(found.playlists) { playlist in
                        NavigationLink(value: Route.playlist(playlist)) {
                            row(title: playlist.title, subtitle: playlist.subtitle) {
                                ArtworkView(artwork: playlist.artwork, size: 52, cornerRadius: 8)
                            }
                        }
                    }
                }
            }
            if !found.artists.isEmpty {
                Section(String(localized: "Artists")) {
                    ForEach(found.artists) { artist in
                        NavigationLink(value: Route.artist(artist)) {
                            row(title: artist.name, subtitle: nil) {
                                ArtworkView(artwork: artist.artwork, size: 52, circle: true)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .task(id: app.roster.activeID) { await app.cloudPlaylists.refresh(force: false) }
        .toolbar {
            if !found.songs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select Songs", systemImage: "checklist") {
                        toolbox = PlaylistToolboxRequest(source: .songs(title: String(localized: "Search Results"), songs: found.songs))
                    }
                }
            }
        }
        .sheet(item: $toolbox) { PlaylistToolboxView(request: $0).appEnvironment(app) }
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if found.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "Not in Your Library"), systemImage: "magnifyingglass")
                } description: {
                    Text(String(localized: "Nothing you've liked, saved, downloaded or played matches “\(query)”. Switch to YouTube Music to search everything."))
                }
            }
        }
    }

    private func row<Cover: View>(title: String, subtitle: String?, @ViewBuilder cover: () -> Cover) -> some View {
        HStack(spacing: 14) {
            cover()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// The Mac's search results page in the Your Library scope.
struct MacLibrarySearchResults: View {
    let query: String
    @Environment(Library.self) private var library
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player
    @Environment(AppModel.self) private var app

    var body: some View {
        let found = cloudLibraryMatches(query, library: library, downloads: downloads, app: app)
        if found.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "Not in Your Library"), systemImage: "magnifyingglass")
            } description: {
                Text(String(localized: "Nothing you've liked, saved, downloaded or played matches “\(query)”."))
            }
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            if !found.songs.isEmpty {
                MacSectionTitle(title: String(localized: "Songs"))
                    .padding(.horizontal, MacMetrics.gutter)
                MacTrackList(songs: Array(found.songs.prefix(100))) { player.play(found.songs, startAt: $0) }
            }
            if !found.albums.isEmpty {
                MacShelf(title: String(localized: "Albums")) { ForEach(found.albums) { MacItemCard(item: .album($0)) } }
            }
            if !found.playlists.isEmpty {
                MacShelf(title: String(localized: "Playlists")) { ForEach(found.playlists) { MacItemCard(item: .playlist($0)) } }
            }
            if !found.artists.isEmpty {
                MacShelf(title: String(localized: "Artists")) { ForEach(found.artists) { MacArtistCard(artist: $0) } }
            }
        }
    }
}

@MainActor
private func cloudLibraryMatches(_ query: String, library: Library, downloads: Downloads, app: AppModel) -> LibraryMatches {
    var found = library.search(query, extra: downloads.store.completeSongs)
    // Old data and song lookup remain compatible; legacy playlist management lives
    // in its explicit archive instead of appearing as a second normal library.
    found.userPlaylists = []
    found.playlists = LibrarySearch.playlists(app.cloudPlaylists.catalog, matching: query)
    return found
}
