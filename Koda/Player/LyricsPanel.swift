import KodaCore
import SwiftUI

/// Uses the app's selected version so reopening Now Playing doesn't reselect it.
struct LyricsPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var showsSources = false

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
            } else if versions.searching || (versions.song?.id != player.current?.id && player.current != nil) {
                LyricsLoading()
                sourceFooter
            } else {
                ContentUnavailableView {
                    Label("No Lyrics", systemImage: "quote.bubble")
                } description: {
                    Text("No matching lyrics were found. Check your connection or try another lyrics source.")
                } actions: {
                    Button("Search Lyrics Again", systemImage: "arrow.clockwise") {
                        versions.search(force: true, userInitiated: true)
                    }
                    .disabled(!versions.canSearch)
                    .buttonStyle(.glass)
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

    private var sourceFooter: some View {
        HStack {
            LyricsTranslationControl(lines: [], openSources: { showsSources = true })
            Spacer()
        }
        .padding(.top, 6)
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
