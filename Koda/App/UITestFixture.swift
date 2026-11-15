#if DEBUG
import KodaCore
import SwiftUI

/// Only the UI-test launch argument selects this host. It mounts the production views
/// against an in-memory library, without playing audio or requesting translation models.
/// Release builds do not contain this host or the launch-argument branch.
struct KodaUITestFixture: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var prepared = false
    @State private var firstPlaylist: PlaylistSummary?
    @State private var songs: [Song] = []
    @State private var sheet: FixtureSheet?

    private enum FixtureSheet: String, Identifiable {
        case selection, merge, cloudCreate, catcher, flow
        var id: Self { self }
    }

    private var dark: Bool { ProcessInfo.processInfo.arguments.contains("-KodaUITestDark") }
    private var largeText: Bool { ProcessInfo.processInfo.arguments.contains("-KodaUITestLargeText") }

    var body: some View {
        NavigationStack {
            List {
                Text(verbatim: colorScheme == .dark ? "dark" : "light")
                    .accessibilityIdentifier("fixture.appearance")
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
                NavigationLink { HomeView() } label: { Text(verbatim: "Cloud home") }
                    .accessibilityIdentifier("fixture.home")
                Button { sheet = .flow } label: { Text(verbatim: "Koda Flow preview") }
                    .accessibilityIdentifier("fixture.flow")
                Button { sheet = .selection } label: {
                    Text(verbatim: "Select cloud songs")
                }
                .accessibilityIdentifier("fixture.selection")
                Button { sheet = .merge } label: {
                    Text(verbatim: "Merge cloud playlists")
                }
                .accessibilityIdentifier("fixture.merge")
                Button { sheet = .cloudCreate } label: { Text(verbatim: "Create cloud playlist") }
                    .accessibilityIdentifier("fixture.cloud.create")
                Button { sheet = .catcher } label: { Text(verbatim: "Music recognition") }
                    .accessibilityIdentifier("fixture.catcher")
                Text(verbatim: "\(app.library.userPlaylists.count)")
                    .accessibilityIdentifier("fixture.localPlaylistCount")
                ForEach(app.cloudPlaylists.catalog) { playlist in
                    Text(verbatim: "\(playlist.title): \(app.cloudPlaylists.snapshots[playlist.id]?.songs.count ?? 0)")
                        .accessibilityIdentifier("fixture.playlist.\(playlist.title)")
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
                        PlaylistToolboxView(request: PlaylistToolboxRequest(source: .online(firstPlaylist, .init())))
                    }
                case .flow:
                    if let firstPlaylist { KodaFlowView(playlist: firstPlaylist) }
                case .merge:
                    PlaylistMergeView()
                case .cloudCreate:
                    CloudPlaylistCreateView(songs: Array(songs.prefix(1)))
                case .catcher:
                    if let song = songs.first {
                        MusicCatcherView(provider: recognizer(for: song), search: { _ in songs }) { _ in }
                    }
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
        // KodaApp applies this setting at the window, above the fixture. Set the
        // real preference so dark-mode screenshots cannot silently remain light.
        app.settings.theme = dark ? .dark : .light
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
        songs = [first, second, third]
        func snapshot(_ id: String, _ title: String, _ songs: [Song], editable: Bool = true) -> CloudPlaylistSnapshot {
            .init(playlist: .init(id: id, title: title), rows: songs.enumerated().map {
                let row = "\(id)-\($0.offset)"
                return .init(id: row, song: $0.element, setVideoID: row)
            }, capabilities: .init(canAdd: editable, canRemove: editable, canRename: editable))
        }
        let largePlaylist = ProcessInfo.processInfo.arguments.contains("-KodaUITestLargePlaylist")
        let sourceSongs = largePlaylist ? (0..<600).map {
            Song(id: "ui-large-\($0)", title: "Cloud Song \($0)", artistLine: "Fixture Artist", duration: 30)
        } : [first, second]
        let snapshots = [snapshot("PLui-alpha", "Fixture Alpha", sourceSongs),
                         snapshot("PLui-beta", "Fixture Beta", [second, third]),
                         snapshot("PLui-read-only", "Fixture Read Only", [first], editable: false)]
        firstPlaylist = snapshots[0].playlist
        app.cloudPlaylists.installUITestData(catalog: snapshots.map(\.playlist), snapshots: snapshots,
            transport: UITestCloudTransport(snapshots: snapshots, songs: songs + (largePlaylist ? sourceSongs : []),
                failFirstReadAfterAdd: ProcessInfo.processInfo.arguments.contains("-KodaUITestCloudReadbackFailure")), like: { $0 })
        prepared = true
    }

    private func recognizer(for song: Song) -> UITestMusicRecognizer {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-KodaUITestRecognitionDenied") { return UITestMusicRecognizer(.denied) }
        if arguments.contains("-KodaUITestRecognitionWaiting") { return UITestMusicRecognizer(.waiting) }
        if arguments.contains("-KodaUITestRecognitionNoMatch") { return UITestMusicRecognizer(.noMatch) }
        return UITestMusicRecognizer(.match(.init(title: song.title, artist: song.artistLine, duration: song.duration)))
    }
}
#endif
