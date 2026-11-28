import AppIntents
import KodaCore
import SwiftUI

@main
struct KodaApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// Keeps rotation scoped to the music and video players.
    @UIApplicationDelegateAdaptor(KodaAppDelegate.self) private var appDelegate

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // Siri and Shortcuts reach the app's objects through this, also when an intent starts
        // the app in the background.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-KodaUISmokeTests") {
                    KodaUITestFixture()
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
                .appEnvironment(model)
                .background {
                    if !model.isNowPlayingPresented {
                        LyricsTranslationDownloadHost(coordinator: model.lyricsTranslation)
                    }
                }
                // Pausing listening history pauses scrobbling with it.
                .onChange(of: model.settings.savesListeningHistory) { _, saves in
                    model.lastFM.isPaused = !saves
                    model.player.savesSmartShuffleHistory = saves
                }
                .onChange(of: model.settings.mode) { _, mode in
                    if mode == .music { model.videos.pause() }
                }
                .preferredColorScheme(model.settings.theme.colorScheme)
                .frame(minWidth: Platform.isMac ? 700 : nil, minHeight: Platform.isMac ? 520 : nil)
                // Spotlight and Siri learn the liked songs and playlists, and again when they change.
                .task(id: IntentsIndexKey(model)) { IntentsIndex.update(model) }
        }
        // The root view's frame sets the smallest window and nothing sets a largest. No
        // `defaultSize`: on Catalyst it pins the scene's maximum size to the default size, so the
        // window could never grow past 1180×820; the first window is the system's own size.
        .windowResizability(.contentMinSize)
        .commands { KodaCommands(model: model) }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.lyricsPreparation.setScenePhase(phase)
            // Inactive also covers Control Center and system sheets. Only a real
            // background transition pauses inline video; returning never starts it.
            if phase == .background { model.videos.applicationDidEnterBackground() }
            // The queue and position survive the app being closed from the switcher.
            if phase != .active {
                model.player.applicationBecameInactive()
                model.saveState()
            }
            if phase == .active {
                model.videos.applicationDidBecomeActive()
                model.player.applicationBecameActive()
                model.downloads.refreshStoredDownloads()
                model.lastFM.syncSoon()
                model.accountsBecameActive()
            }
        }

        #if targetEnvironment(macCatalyst)
        // Keyed by one value, so asking again brings the open Settings window forward.
        WindowGroup("Settings", id: MacSettingsView.windowID, for: String.self) { _ in
            MacSettingsView()
                .appEnvironment(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        .defaultSize(width: 820, height: 600)

        // A full-screen video: its own window, keyed by one value so there is only ever one.
        WindowGroup("Video", id: MacVideoWindow.windowID, for: String.self) { _ in
            MacVideoWindow()
                .appEnvironment(model)
        }
        #endif
    }
}

/// Changes when what Siri and Spotlight are told about does.
private struct IntentsIndexKey: Equatable {
    var profileID: UUID
    var hasCloudSession: Bool
    var liked: [String]
    var playlists: [String]

    @MainActor
    init(_ app: AppModel) {
        profileID = app.roster.activeID
        hasCloudSession = app.cloudPlaylists.hasSession
        liked = app.library.liked.map(\.id)
        playlists = app.cloudPlaylists.catalog.map { "\($0.id)\u{0}\($0.title)" }
    }
}

extension View {
    /// The app's shared objects. Given again to anything presented full screen: the Mac shows a
    /// presented view in its own hosting controller, which doesn't inherit them.
    func appEnvironment(_ model: AppModel) -> some View {
        environment(model)
            .environment(model.player)
            .environment(model.library)
            .environment(model.downloads)
            .environment(model.lastFM)
    }
}
