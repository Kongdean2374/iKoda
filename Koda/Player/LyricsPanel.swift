import KodaCore
import SwiftUI

/// Lyrics for the playing song: synced ones follow the song (word by word when the
/// provider has word timing) and a tap on a line seeks to it.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var state: LoadState<Lyrics?> = .loading
    @State private var refreshSongID: String?
    @State private var refreshRevision = 0
    @State private var showsSources = false
    @State private var activeRequest: LyricsRequest?

    private var request: LyricsRequest {
        LyricsRequest(song: player.current, sources: app.settings.lyricsSources,
                      customSources: app.settings.customLyricsSources,
                      refresh: refreshSongID == player.current?.id ? refreshRevision : 0)
    }

    var body: some View {
        Group {
            if activeRequest != request {
                LyricsLoading()
            } else {
                content
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: request) {
            let pending = request
            activeRequest = pending
            guard let song = pending.song else { state = .loaded(nil); return }
            state = .loading
            let found = await app.lyrics.lyrics(for: song, sources: pending.sources,
                                              customSources: pending.customSources, refresh: pending.refresh > 0)
            guard !Task.isCancelled, request == pending else { return }
            state = .loaded(found)
        }
        .sheet(isPresented: $showsSources) {
            NavigationStack {
                LyricsSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsSources = false }
                        }
                    }
            }
            .appEnvironment(app)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
            case .loading:
                LyricsLoading()
            case .failed, .loaded(nil):
                ContentUnavailableView {
                    Label("No Lyrics", systemImage: "quote.bubble")
                } description: {
                    Text("No matching lyrics were found. Check your connection or try another lyrics source.")
                } actions: {
                    Button("Search Lyrics Again", systemImage: "arrow.clockwise") { searchAgain() }
                        .buttonStyle(.glass)
                    Button("Lyrics Sources", systemImage: "list.bullet.rectangle") { showsSources = true }
                }
                .foregroundStyle(Color.primary)
            case .loaded(.plain(let text)?):
                VStack(spacing: 8) {
                    PlainTranslatedLyricsView(text: text)
                        .id(player.current?.id)
                    Button("Search Lyrics Again", systemImage: "arrow.clockwise") { searchAgain() }
                        .font(.footnote)
                        .buttonStyle(.glass)
                }
            case .loaded(.synced(let lines)?):
                SyncedLyrics(lines: lines)
                    .id(player.current?.id)
        }
    }

    private func searchAgain() {
        refreshSongID = player.current?.id
        refreshRevision += 1
    }
}

/// What the panel looks lyrics up for; a change of song or of sources looks again.
private struct LyricsRequest: Equatable {
    var song: Song?
    var sources: [LyricsSource]
    var customSources: [CustomLyricsSource]
    var refresh: Int
}
