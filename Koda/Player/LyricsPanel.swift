import KodaCore
import SwiftUI

/// Uses the app's selected version so reopening Now Playing doesn't reselect it.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var showsSources = false
    @State private var manualSong: Song?

    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        VStack(spacing: 0) {
            if let candidate = versions.current, candidate.songID == player.current?.id {
                switch candidate.lyrics {
                case .plain(let text):
                    PlainTranslatedLyricsView(text: text, openSources: { showsSources = true }).id(candidate.id)
                case .synced(let lines):
                    SyncedLyrics(lines: lines, openSources: { showsSources = true }).id(candidate.id)
                }
            } else if let song = player.current, app.library.instrumentalSongs[song.id] != nil {
                ContentUnavailableView {
                    Label("Instrumental", systemImage: "music.note")
                } description: {
                    Text("Automatic lyrics searches and translation are paused for this song.")
                } actions: {
                    InstrumentalTrackButton(song: song).buttonStyle(.glass)
                }
                sourceFooter
            } else if versions.searching {
                ProgressView("Searching for Lyrics").frame(maxHeight: .infinity)
                sourceFooter
            } else {
                ContentUnavailableView {
                    Label("No Lyrics", systemImage: "quote.bubble")
                } description: {
                    if versions.results.contains(where: { $0.state == .rateLimited }) {
                        Text("A lyrics source is cooling down. Other sources may still be available.")
                    } else if versions.results.contains(where: { [.failed, .timedOut].contains($0.state) }) {
                        Text("Some lyrics sources could not be reached. You can try again or search manually.")
                    } else {
                        Text("No matching lyrics were found. Check your connection or try another lyrics source.")
                    }
                } actions: {
                    ViewThatFits {
                        HStack { searchActions }
                        VStack { searchActions }
                    }
                }
                .foregroundStyle(Color.primary)
                sourceFooter
            }
        }
        .frame(maxHeight: .infinity)
        .sheet(isPresented: $showsSources) {
            NavigationStack {
                LyricsVersionsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { showsSources = false } }
                    }
            }
            .appEnvironment(app)
        }
    }

    @ViewBuilder private var searchActions: some View {
        Button("Search Lyrics Again", systemImage: "arrow.clockwise") {
            versions.search(force: true, userInitiated: true)
        }
        .disabled(!versions.canSearch)
        .buttonStyle(.glass)
        if let song = player.current {
            Button("Search Lyrics Manually", systemImage: "magnifyingglass") { manualSong = song }
                .buttonStyle(.glass)
            InstrumentalTrackButton(song: song).buttonStyle(.glass)
        }
    }

    private var sourceFooter: some View {
        HStack {
            LyricsSourceOrb { showsSources = true }
            Spacer()
        }
        .padding(.top, 6)
        .sheet(item: $manualSong) { song in
            NavigationStack {
                LyricsManualSearchView(song: song, scope: versions.profileScope)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { manualSong = nil } }
                    }
            }
            .appEnvironment(app)
        }
    }
}

struct LyricsSourceOrb: View {
    let action: () -> Void
    @State private var selections = 0

    var body: some View {
        Button {
            selections &+= 1
            action()
        } label: {
            LyricsOrbGlyph(symbol: "square.stack")
        }
        .buttonStyle(LyricsSourceOrbStyle())
        .sensoryFeedback(.selection, trigger: selections)
        .accessibilityLabel("Lyrics Sources")
        .accessibilityIdentifier("lyrics.sources.open")
    }
}

private struct LyricsSourceOrbStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(LyricsOrbAppearance(pressed: configuration.isPressed))
    }
}
