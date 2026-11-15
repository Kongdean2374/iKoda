#if DEBUG
import KodaCore
import SwiftUI

/// Only the UI-test launch argument selects this host. It mounts the production views
/// against an in-memory library, without playing audio or requesting translation models.
/// Release builds do not contain this host or the launch-argument branch.
struct KodaUITestFixture: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var prepared = false
    @State private var firstPlaylist: UUID?
    @State private var sheet: FixtureSheet?

    private enum FixtureSheet: String, Identifiable {
        case selection, merge
        var id: Self { self }
    }

    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("-KodaUITestDark") }
    private var largeText: Bool { ProcessInfo.processInfo.arguments.contains("-KodaUITestLargeText") }

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    translation
                } label: {
                    Text(verbatim: "Translation control")
                }
                .accessibilityIdentifier("fixture.translation")
                NavigationLink {
                    AudioCenterView()
                } label: {
                    Text(verbatim: "Sound center")
                }
                .accessibilityIdentifier("fixture.sound")
                NavigationLink {
                    SleepTimerSettingsView()
                } label: {
                    Text(verbatim: "Sleep timer")
                }
                .accessibilityIdentifier("fixture.sleep")
                Button { sheet = .selection } label: {
                    Text(verbatim: "Select local songs")
                }
                .accessibilityIdentifier("fixture.selection")
                Button { sheet = .merge } label: {
                    Text(verbatim: "Merge local playlists")
                }
                .accessibilityIdentifier("fixture.merge")
                ForEach(app.library.userPlaylists) { playlist in
                    Text(verbatim: "\(playlist.name): \(playlist.songs.count)")
                        .accessibilityIdentifier("fixture.playlist.\(playlist.name)")
                }
                Text(verbatim: reduceMotion ? "enabled" : "disabled")
                    .accessibilityIdentifier("fixture.accessibility.reduceMotion")
                Text(verbatim: reduceTransparency ? "enabled" : "disabled")
                    .accessibilityIdentifier("fixture.accessibility.reduceTransparency")
            }
            .navigationTitle(Text(verbatim: "Koda UI validation"))
            .disabled(!prepared)
        }
        .dynamicTypeSize(largeText ? .accessibility3 : .large)
        .preferredColorScheme(dark ? .dark : .light)
        .sheet(item: $sheet) { value in
            Group {
                switch value {
                case .selection:
                    if let firstPlaylist {
                        PlaylistToolboxView(request: PlaylistToolboxRequest(source: .local(firstPlaylist)))
                    }
                case .merge:
                    PlaylistMergeView()
                }
            }
            .appEnvironment(app)
            .dynamicTypeSize(largeText ? .accessibility3 : .large)
            .preferredColorScheme(dark ? .dark : .light)
        }
        .task { prepare() }
    }

    private var translation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(verbatim: "原文歌詞 Original lyrics\n繁體中文譯文")
                .font(.title2)
            Spacer()
            LyricsTranslationControl(lines: [], importedCount: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .navigationTitle(Text(verbatim: "Translation control"))
    }

    private func prepare() {
        guard !prepared else { return }
        app.onboarding = nil
        app.settings.automaticLyricsTranslation = false
        app.settings.importedLyricsEnabled = true
        app.settings.showsLyricsTranslation = false
        app.player.deviceSoundSettings.enabled = false
        app.sleepTimer.cancel()
        app.sleepTimer.action = .finishPlaybackSession
        // No queued/current song exists in the fresh Simulator install. The coordinator
        // consequently has no source to translate even while the display toggle is tested.
        app.library.open(directory: nil)
        let first = Song(id: "ui-smoke-a", title: "星光與海洋 — 測試歌曲", artistLine: "Fixture Artist", duration: 180)
        let second = Song(id: "ui-smoke-b", title: "Second Song", artistLine: "Fixture Artist", duration: 210)
        let third = Song(id: "ui-smoke-c", title: "Third Song (Live)", artistLine: "Fixture Artist", duration: 240)
        firstPlaylist = app.library.createPlaylist(named: "Fixture Alpha", songs: [first, second]).id
        _ = app.library.createPlaylist(named: "Fixture Beta", songs: [second, third])
        prepared = true
    }
}
#endif
