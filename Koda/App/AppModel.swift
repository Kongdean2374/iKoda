import KodaCore
import MediaPlayer
import SwiftUI

/// The app's long-lived objects, shared through the environment.
@MainActor
@Observable
final class AppModel {
    let music: YouTubeMusic
    let player: Player
    let library: Library
    let lyrics = LyricsClient()
    /// Translation and look-ahead preparation outlive the player and lyrics views.
    let lyricsTranslation: LyricsTranslationCoordinator
    let lyricsPreparation: LyricsPreparationLifecycle
    #if !targetEnvironment(macCatalyst)
    @ObservationIgnored lazy var carPlay = CarPlayLyricsActivity(app: self)
    @ObservationIgnored private var carPlayPlayerPublisher: CarPlayPlayerPublisher?
    #endif
    /// Animated album covers; the loops live in Caches, which the system may clear.
    let motionArtwork: MotionArtwork
    let sleepTimer: SleepTimer
    /// The cloud account is authoritative; operation receipts survive navigation and restart.
    @ObservationIgnored lazy var cloudPlaylists = CloudPlaylistCoordinator(app: self)
    /// Everyone who uses Koda on this device; the library is the active profile's.
    let roster: ProfileRoster
    let profilePhotos: ProfilePhotos
    /// The active profile's Home, shared by the phone's tab and the Mac's page; a new one per profile.
    private(set) var home: HomeModel
    let settings = AppSettings()
    let downloads: Downloads
    let lastFM: LastFM
    /// The video player, beside the songs' (Koda/Video).
    let videos: VideoPlayback
    /// The playing song on Discord; the Mac only, where the Discord app takes it from Koda directly.
    let discord: DiscordPresence?

    var isNowPlayingPresented = false
    /// The panel Now Playing should show when it next opens or is already open: the Mac's
    /// player bar and menu bar open lyrics and the queue directly.
    var requestedPanel: NowPlayingView.Panel?
    /// The Mac's lyrics or queue beside the page, as Music shows them; nil when closed.
    var sidePanel: MacSidePanel?
    /// Profile and Settings, opened from Home or from the Mac's Settings menu item.
    var isProfilePresented = false
    /// A sidebar place for the Mac's window to go to, asked for from elsewhere, e.g. Settings.
    var requestedMacSection: MacSection?
    /// The playing song's colours, kept ready for Now Playing while it is closed.
    let nowPlayingPalette = PaletteModel()
    /// Set to switch tabs from anywhere, e.g. "Go to artist" inside Now Playing.
    var selectedTab: AppTab = .home
    /// A page to open on the current tab's stack.
    var pendingRoute: Route?
    /// Songs waiting for the listener to pick a playlist for them.
    var playlistTarget: PlaylistTarget?
    /// A shared link that could not be opened, shown as an alert.
    var linkError: String?
    /// Only the newest album-card or shared-song lookup may replace the queue.
    @ObservationIgnored private var playbackLookupTask: Task<Void, Never>?
    /// Views include this admission generation in their task identity, even when a stop
    /// and manual resume happen in the same UI update and the Boolean ends unchanged.
    private(set) var artworkSessionRevision: UInt64 = 0
    @ObservationIgnored private var artworkSessionFinished: Bool?
    @ObservationIgnored private var artworkSessionTask: Task<Void, Never>?
    /// The sheet that adds a profile, asked for from a toolbar menu, the profile page or the Mac's sidebar.
    var isAddingProfile = false
    /// The pane the Mac's Settings window should show when it next opens or is already open.
    var requestedSettingsPane: MacSettingsPane?
    /// Onboarding over the app: the whole welcome on a first launch, or only taste setup when
    /// asked for again from Settings.
    var onboarding: OnboardingView.Start?
    /// Signed-in profiles' cookies (see Accounts.swift).
    let keychain: AccountKeychain
    /// The active profile's library is being brought in step with its account.
    var isSyncingAccount = false
    var accountSyncError: String?
    /// Session changes and writes to the account, one at a time and in the order asked, so a
    /// like is always sent as the profile it was made in, even after a quick switch.
    @ObservationIgnored var accountWork: Task<Void, Never>?
    /// The Keychain was locked when the active profile's session was read; read it again when the app comes back.
    @ObservationIgnored var needsSessionRead = false
    @ObservationIgnored var lastAccountSync: [UUID: Date] = [:]
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var syncScope: CloudPlaylistAccountScope?
    @ObservationIgnored var syncMutationBoundary: UUID?
    @ObservationIgnored var syncNeedsFollowUp = false
    #if DEBUG
    @ObservationIgnored var testingAccountLibraryRead: (@MainActor @Sendable () async throws -> AccountLibrary)?
    @ObservationIgnored var testingAccountCatalogRead: (@MainActor @Sendable (UUID) async throws -> CloudPlaylistCatalogResult)?
    @ObservationIgnored var testingAccountPlaylistTransport: (@MainActor @Sendable (UUID) -> any CloudPlaylistTransport)?
    @ObservationIgnored var testingAccountSessionActivation: (@MainActor @Sendable (KodaProfile) async -> Void)?
    @ObservationIgnored var testingAccountVisitorRenewal: (@MainActor @Sendable () async -> Void)?
    var accountSyncReadCount = 0
    #endif
    @ObservationIgnored var homeLoadTask: Task<Void, Never>?
    @ObservationIgnored var homeLoadID: UUID?
    /// Numbers each sync, so one that was overtaken doesn't clear `isSyncingAccount` for the next.
    @ObservationIgnored var syncRound = 0
    /// A cloud read-back must not override a newer local like/save intent.
    @ObservationIgnored var libraryIntentRevision: UInt64 = 0
    /// Each signed-in profile's `AccountMirror`, read from its folder on first use.
    @ObservationIgnored var mirrors: [UUID: AccountMirror] = [:]
    /// When a play has been heard long enough to go to the account's YouTube history.
    @ObservationIgnored var historyThreshold = HeardThreshold()
    /// Channels subscribed to or left from Koda this run, by id: newer than any page loaded
    /// before the change, so every page shows the same answer.
    var subscriptions: [String: Bool] = [:]
    /// The channels the active account subscribes to (the Mac's sidebar, the iPhone's Library);
    /// nil until asked for, empty signed out.
    var subscribedChannels: [ChannelRef]?
    var channelsByUpload: [ChannelRef] = []
    /// The active profile's video feeds, kept while the app runs: switching modes or sidebar
    /// places shows them at once instead of asking YouTube again.
    @ObservationIgnored private var videoFeeds: [VideoFeedModel.Kind: VideoFeedModel] = [:]
    /// Videos rated from Koda this run, by id, for the same reason.
    var videoRatings: [String: LikeStatus] = [:]
    /// The video being reported to the account's YouTube history, and whose account it is.
    @ObservationIgnored var videoHistory: (session: VideoWatchSession, profile: UUID)?

    struct PlaylistTarget: Identifiable {
        let id = UUID()
        let songs: [Song]
    }

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "Koda")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keychain = AccountKeychain(directory: directory)
        self.keychain = keychain
        music = YouTubeMusic(accounts: AccountSessions(store: keychain))
        // A song that reached the player without its album is asked about once, so it can have its cover too.
        motionArtwork = MotionArtwork(directory: URL.cachesDirectory.appending(path: "MotionArtwork")) { [music] id in
            try await music.songDetails(id)?.album
        }
        player = Player(music: music, storageDirectory: directory)
        lyricsTranslation = LyricsTranslationCoordinator(client: lyrics,
            directory: URL.cachesDirectory.appending(path: "KodaAutomaticLyrics", directoryHint: .isDirectory))
        lyricsPreparation = LyricsPreparationLifecycle(player: player, settings: settings,
                                                       coordinator: lyricsTranslation)
        videos = VideoPlayback(music: music)
        // Before profiles the name lived in the defaults and the library at the top of the folder;
        // the roster moves both into the first profile.
        roster = ProfileRoster(root: directory, legacyName: UserDefaults.standard.string(forKey: "koda.profile.name"))
        profilePhotos = ProfilePhotos(roster: roster)
        library = Library(directory: roster.folder(for: roster.activeID))
        home = HomeModel(profile: roster.activeID)
        sleepTimer = SleepTimer(player: player)
        let settings = settings
        // Songs can be gigabytes; they come back from YouTube, so they stay out of iCloud backups.
        var audioDirectory = directory.appending(path: "Audio")
        try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? audioDirectory.setResourceValues(values)
        let audio = AudioStore(directory: audioDirectory, cacheLimit: settings.cacheLimit.rawValue)
        player.audioStore = audio
        downloads = Downloads(store: audio, music: music)
        player.onLocalAudioInvalidated = { [downloads] id in
            downloads.refreshInvalidatedDownload(id)
        }
        // Music intent wins immediately, including time spent loading a playlist or stream.
        // Waiting for onSongStarted would let an old video load/countdown reclaim playback.
        player.onSongStarted = { [library, videos] song in
            // A song and a video never play over each other.
            videos.pause()
            if settings.savesListeningHistory { library.recordPlay(song) }
        }
        videos.onWatch = { [library] video in
            if settings.savesListeningHistory { library.recordWatch(video) }
        }
        videos.resumePosition = { [library] id in library.videoProgress[id]?.resumeAt }
        videos.onProgress = { [library] id, position, duration in
            if settings.savesListeningHistory { library.setProgress(position, of: duration, for: id) }
        }
        videos.autoplays = { settings.autoplaysVideos }
        videos.defaultQuality = { settings.videoQuality }
        videos.pauseMusic = { [player] in
            MusicCatcher.cancelActiveRecognition()
            player.pause(from: "a video starting")
        }
        player.onListened = { [library] song, seconds in
            if settings.savesListeningHistory { library.addListening(seconds, to: song) }
        }
        player.isUnwanted = { [library] song in library.isHidden(song) }
        player.savesSmartShuffleHistory = settings.savesListeningHistory
        player.smartShuffleContext = { [library, settings] in
            SmartShuffleContext(
                recentSongIDs: settings.savesListeningHistory ? library.history.prefix(50).reversed().map { $0.song.id } : [],
                playCounts: settings.savesListeningHistory ? library.songStats.mapValues(\.plays) : [:],
                skipCounts: [:],
                likedSongIDs: Set(library.liked.map(\.id))
            )
        }
        let lastFM = LastFM(directory: directory)
        self.lastFM = lastFM
        player.onItemStarted = { [lastFM, player] item in
            let song = item.song
            lastFM.started(item.id, artist: song.scrobbleArtist, track: song.title, album: song.album?.title ?? "",
                           duration: song.duration ?? player.duration, isVideo: song.isVideo)
        }
        lastFM.isPaused = !settings.savesListeningHistory
        // Plays that waited out a network failure or a rate limit go when it's over.
        Task { [lastFM] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                lastFM.syncSoon()
            }
        }
        player.onItemHeard = { [lastFM, player] item, seconds in
            let song = item.song
            lastFM.heard(seconds, of: item.id, artist: song.scrobbleArtist, track: song.title, album: song.album?.title ?? "",
                         duration: song.duration ?? player.duration, isVideo: song.isVideo)
        }
        // Paused listening history keeps the song off Discord too, as it does Last.fm.
        discord = Platform.isMac
            ? DiscordPresence(isAllowed: { [settings] in settings.sharesOnDiscord && settings.savesListeningHistory }, player: player)
            : nil
        if Platform.isMac, UserDefaults.standard.object(forKey: "volume") != nil {
            player.volume = UserDefaults.standard.float(forKey: "volume")
        }
        player.artworkLoader = { @MainActor url in
            guard let image = await ImagePipeline.shared.image(url, pixels: 600) else { return nil }
            return ImagePipeline.nowPlayingArtwork(image)
        }
        player.animatedArtworkLoader = { @MainActor [weak self] song in
            guard let self else { return [:] }
            return await LockScreenAnimatedArt.artwork(for: song, app: self)
        }
        connectAccounts()
        if settings.mode == .video { selectedTab = .videos }
        // Someone upgrading already has a library; the welcome is for a new install.
        if !settings.hasSeenOnboarding {
            if library.liked.isEmpty, library.recent.isEmpty, roster.profiles.count == 1, !roster.active.isSignedIn {
                onboarding = .welcome
            } else {
                settings.hasSeenOnboarding = true
            }
        }
        // A deliberate listening-session finish closes background preparation before
        // Player considers releasing AVAudioSession. Foregrounding never reopens it.
        player.onPlaybackRequested = { [weak self] in
            guard let self, !self.player.isPlaybackSessionFinished else { return }
            MusicCatcher.cancelActiveRecognition()
            self.videos.pause()
            self.lyricsPreparation.resumePlaybackSession()
            self.setArtworkSessionFinished(false)
        }
        player.onPlaybackSessionFinished = { [weak self] in
            guard let self else { return }
            MusicCatcher.cancelActiveRecognition()
            self.cancelPlaybackLookup()
            self.lyricsPreparation.finishPlaybackSession()
            #if !targetEnvironment(macCatalyst)
            self.carPlay.stop()
            #endif
            self.setArtworkSessionFinished(true)
        }
        player.canDeactivateAudioSession = { [videos] in
            !videos.ownsAudioSession && !VoiceSearch.ownsAudioSession && !MusicCatcher.ownsAudioSession
        }
        VoiceSearch.canDeactivateAfterRecording = { [weak player, weak videos] in
            guard let player, let videos else { return false }
            return !player.ownsAudioSession && !videos.ownsAudioSession && !MusicCatcher.ownsAudioSession
        }
        MusicCatcher.canDeactivateAfterRecording = { [weak player, weak videos] in
            guard let player, let videos else { return false }
            return !player.ownsAudioSession && !videos.ownsAudioSession && !VoiceSearch.ownsAudioSession
        }
        setArtworkSessionFinished(player.isPlaybackSessionFinished)
        lyricsPreparation.start()
        #if !targetEnvironment(macCatalyst)
        carPlay.discardOrphanedActivities()
        player.onPlaybackQueueEnded = { [weak self] in self?.carPlay.stop() }
        if let file = CarPlayPlayerSnapshot.file {
            carPlayPlayerPublisher = CarPlayPlayerPublisher(app: self, file: file)
            carPlayPlayerPublisher?.observe()
        }
        #endif
    }

    private func setArtworkSessionFinished(_ finished: Bool) {
        guard artworkSessionFinished != finished else { return }
        artworkSessionFinished = finished
        artworkSessionRevision &+= 1
        let revision = artworkSessionRevision
        artworkSessionTask = Task { [motionArtwork] in
            await motionArtwork.setPlaybackSessionFinished(finished, revision: revision)
        }
    }

    /// AV/SwiftUI callers await the actor's admission before asking for artwork. Without
    /// this barrier an immediate manual resume could read the still-closed actor once,
    /// then keep a missing cover because no later view input had changed.
    func waitForArtworkSession(expectedRevision: UInt64) async -> Bool {
        guard !Task.isCancelled, !player.isPlaybackSessionFinished,
              artworkSessionRevision == expectedRevision else { return false }
        let admission = artworkSessionTask
        await admission?.value
        return !Task.isCancelled && !player.isPlaybackSessionFinished
            && artworkSessionRevision == expectedRevision
    }

    /// Make another profile the active one: its library replaces this one's everywhere at once,
    /// with no network, so a switch works offline and lands on the next frame. The queue keeps
    /// playing; what is listened to from here on counts for the new profile. Its account, if it
    /// has one, signs requests from here on and its library is brought in step behind.
    func switchProfile(to id: UUID) {
        guard id != roster.activeID, let profile = roster.profile(id) else { return }
        #if !targetEnvironment(macCatalyst)
        carPlay.stop()
        #endif
        cancelHomeLoading()
        player.cancelPlaylistLoading()
        cancelPlaybackLookup()
        MusicCatcher.cancelActiveRecognition()
        cloudPlaylists.invalidateSession()
        let leaving = roster.active
        player.clearSmartShuffleHistory()
        forgetVideoState()
        library.open(directory: roster.folder(for: id))
        home = HomeModel(profile: id)
        roster.setActive(id)
        moveSession(from: leaving, to: profile)
    }

    /// Delete a profile and what it keeps on this device; another takes over if it was active.
    func deleteProfile(_ id: UUID) {
        guard let profile = roster.profile(id) else { return }
        if roster.activeID == id {
            cancelHomeLoading()
            player.cancelPlaylistLoading()
        }
        var next: KodaProfile?
        let deleted = roster.delete(id) { nextID in
            library.open(directory: roster.folder(for: nextID))
            home = HomeModel(profile: nextID)
            next = roster.profile(nextID)
        }
        guard deleted else { return }
        if next != nil {
            MusicCatcher.cancelActiveRecognition()
            cloudPlaylists.invalidateSession()
            cancelPlaybackLookup()
            player.clearSmartShuffleHistory()
        }
        forgetVideoState()
        Snapshot.remove("home-\(id.uuidString)")
        forgetAccount(of: id)
        if let next { moveSession(from: profile, to: next) }
    }

    /// A video feed, made once per profile and kept.
    func videoFeed(_ kind: VideoFeedModel.Kind) -> VideoFeedModel {
        if let feed = videoFeeds[kind] { return feed }
        let feed = VideoFeedModel(kind: kind)
        videoFeeds[kind] = feed
        return feed
    }

    /// The channels the account subscribes to, from YouTube's sidebar (A to Z); none signed out.
    /// `channelsByUpload` is the same list with those that posted lately first, for the Mac sidebar.
    func loadSubscribedChannels() async {
        let profile = roster.active
        guard profile.isSignedIn, !profile.isExpired else {
            channelsByUpload = []
            return subscribedChannels = []
        }
        await accountWork?.value
        // The Subscriptions page's feed when it's loaded, so opening it costs nothing more.
        let shown = videoFeeds[.subscriptions]?.videos ?? []
        async let guide = try? music.subscribedChannels()
        async let fetched = shown.isEmpty ? try? music.videoSubscriptions() : nil
        let found = await guide
        let channels = found ?? subscribedChannels ?? []
        let page = await fetched
        let feed = shown.isEmpty ? page?.videos ?? [] : shown
        guard roster.activeID == profile.id else { return }
        subscribedChannels = channels
        channelsByUpload = ChannelRef.byLatestUpload(channels, feed: feed)
    }

    /// Another profile's feeds, subscriptions and ratings aren't this one's.
    private func forgetVideoState() {
        videoFeeds = [:]
        subscribedChannels = nil
        channelsByUpload = []
        subscriptions = [:]
        videoRatings = [:]
    }

    /// Open a page from outside a navigation stack: closes Now Playing and pushes it on the current tab.
    func open(_ route: Route) {
        isNowPlayingPresented = false
        pendingRoute = route
    }

    /// Open Now Playing on one of its panels.
    func showNowPlaying(_ panel: NowPlayingView.Panel) {
        guard player.current != nil else { return }
        requestedPanel = panel
        isNowPlayingPresented = true
    }

    /// Lyrics or the queue: beside the page on the Mac (the same one again closes it), in Now
    /// Playing on the iPhone.
    func toggleLyricsOrQueue(_ panel: MacSidePanel) {
        guard player.current != nil else { return }
        if Platform.isMac {
            sidePanel = sidePanel == panel ? nil : panel
        } else {
            showNowPlaying(panel == .lyrics ? .lyrics : .queue)
        }
    }

    /// Switch tabs from the menu bar, closing Now Playing if it covers them.
    func go(to tab: AppTab) {
        isNowPlayingPresented = false
        settings.mode = tab.mode
        selectedTab = tab
    }

    enum Collection {
        case album(AlbumSummary)
        case playlist(PlaylistSummary)
    }

    /// Play an album or playlist from its card, without opening its page.
    func playCollection(_ collection: Collection) {
        cancelPlaybackLookup()
        linkError = nil
        switch collection {
        case .playlist(let playlist):
            // Player owns the first request and every continuation, so a later selection
            // can cancel preparation before this collection replaces the current queue.
            player.playPlaylist(id: playlist.id)
        case .album(let album):
            let revision = player.beginExternalPlaybackRequest()
            let profile = roster.activeID
            let music = music
            playbackLookupTask = Task { [weak self] in
                guard !Task.isCancelled, self?.roster.activeID == profile,
                      self?.player.playbackIntentRevision == revision else { return }
                do {
                    let songs = try await music.album(album.id).songs
                    guard !Task.isCancelled, let self, self.roster.activeID == profile,
                          self.player.playbackIntentRevision == revision else { return }
                    self.playbackLookupTask = nil
                    guard !songs.isEmpty else { return }
                    self.player.play(songs)
                } catch {
                    guard !Task.isCancelled, let self, self.roster.activeID == profile,
                          self.player.playbackIntentRevision == revision else { return }
                    self.playbackLookupTask = nil
                    self.linkError = error.friendlyMessage
                }
            }
        }
    }

    func addToPlaylist(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        playlistTarget = PlaylistTarget(songs: songs)
    }

    /// Open a YouTube, YouTube Music or koda:// link: a song plays with its radio, anything else opens its page.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = YouTubeLink(url) else { return false }
        openLink(link)
        return true
    }

    func openLink(_ link: YouTubeLink) {
        // Even a new navigation-only link supersedes the earlier song request.
        cancelPlaybackLookup()
        linkError = nil
        switch link {
        case .song(let videoId):
            playLinkedSong(videoId)
        case .album(let browseId):
            open(.album(AlbumSummary(id: browseId, title: "", artistLine: "")))
        case .playlist(let id):
            open(.playlist(PlaylistSummary(id: id, title: "")))
        case .artist(let channelId):
            open(.artist(ArtistSummary(id: channelId, name: "")))
        }
    }

    private func cancelPlaybackLookup() {
        playbackLookupTask?.cancel()
        playbackLookupTask = nil
    }

    /// A video id alone carries no title or artist; its radio starts with the song itself, which has both.
    private func playLinkedSong(_ videoId: String) {
        let request = LinkedSongRequest(songID: videoId, intentRevision: player.beginExternalPlaybackRequest())
        let profile = roster.activeID
        let music = music
        playbackLookupTask = Task { [weak self] in
            guard !Task.isCancelled, self?.roster.activeID == profile,
                  self?.player.playbackIntentRevision == request.intentRevision else { return }
            do {
                let radio = try await music.radio(for: videoId)
                guard let self, self.roster.activeID == profile,
                      request.isCurrent(revision: self.player.playbackIntentRevision, isCancelled: Task.isCancelled) else { return }
                self.playbackLookupTask = nil
                switch request.selection(from: radio.songs, currentRevision: self.player.playbackIntentRevision) {
                case .superseded:
                    return
                case .unavailable:
                    self.linkError = String(localized: "That song isn't available.")
                case .queue(let songs):
                    self.player.play(songs)
                    self.isNowPlayingPresented = true
                }
            } catch {
                guard let self, self.roster.activeID == profile,
                      request.isCurrent(revision: self.player.playbackIntentRevision, isCancelled: Task.isCancelled) else { return }
                self.playbackLookupTask = nil
                self.linkError = error.friendlyMessage
            }
        }
    }

    /// The app is leaving the screen: write what is only kept in memory.
    func saveState() {
        player.persistQueueNow()
        library.flush()
        downloads.store.flush()
        if Platform.isMac { UserDefaults.standard.set(player.volume, forKey: "volume") }
    }
}

/// The iPhone's tabs: Home, Library and Search in music mode; Videos, Subscriptions, the
/// watched list and Search in video mode.
enum AppTab: Hashable {
    case home, radio, library, search
    case videos, subscriptions, watched, videoSearch

    var mode: AppSettings.Mode {
        switch self {
        case .home, .radio, .library, .search: .music
        case .videos, .subscriptions, .watched, .videoSearch: .video
        }
    }
}
