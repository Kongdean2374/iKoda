import KodaCore
import SwiftUI

/// The songs and artists the listener asked Koda to suggest less (`NotInterestedMenu`), each
/// with a way back. They stay out of Home, mixes, radio and autoplay; songs picked by hand play.
struct SuggestLessView: View {
    @Environment(Library.self) private var library

    var body: some View {
        let hidden = library.notInterested
        Form {
            if !hidden.artists.isEmpty {
                Section(String(localized: "Artists")) {
                    ForEach(hidden.artists, id: \.self) { artist in
                        Text(artist.name)
                            .swipeActions {
                                Button(String(localized: "Suggest Again"), systemImage: "hand.thumbsup") {
                                    withAnimation { library.unhide(artist: artist) }
                                }
                                .tint(.accentColor)
                            }
                    }
                }
            }
            if !hidden.songs.isEmpty {
                Section(String(localized: "Songs")) {
                    ForEach(hidden.songs) { song in
                        HStack(spacing: 12) {
                            ArtworkView(artwork: song.artwork, size: 40, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(song.title).lineLimit(1)
                                Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button(String(localized: "Suggest Again"), systemImage: "hand.thumbsup") {
                                withAnimation { library.unhide(song) }
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
        }
        .overlay {
            if hidden.isEmpty {
                ContentUnavailableView(String(localized: "Nothing Here"), systemImage: "hand.thumbsdown",
                                       description: Text(String(localized: "Choose Suggest Less on a song to keep it, or its artist, out of Home, mixes, radio and autoplay.")))
            }
        }
        .navigationTitle(String(localized: "Suggest Less"))
    }
}

/// The Mac's Settings list of the same, in the History & Privacy pane.
struct MacSuggestLessGroup: View {
    @Environment(Library.self) private var library

    var body: some View {
        let hidden = library.notInterested
        MacSettingsGroup(title: String(localized: "Suggest less"),
                         footer: hidden.isEmpty
                             ? String(localized: "Choose Suggest Less on a song to keep it, or its artist, out of Home, mixes, radio and autoplay.")
                             : String(localized: "Kept out of Home, mixes, radio and autoplay. Songs you pick yourself still play.")) {
            ForEach(hidden.artists, id: \.self) { artist in
                MacSettingsRow(title: artist.name, detail: String(localized: "Artist")) {
                    Button(String(localized: "Suggest Again")) { library.unhide(artist: artist) }
                }
            }
            ForEach(hidden.songs) { song in
                MacSettingsRow(title: song.title, detail: song.artistLine) {
                    Button(String(localized: "Suggest Again")) { library.unhide(song) }
                }
            }
            if hidden.isEmpty {
                MacSettingsRow(title: String(localized: "Nothing here yet")) { EmptyView() }
            }
        }
    }
}
