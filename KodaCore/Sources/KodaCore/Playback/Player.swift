import AVFoundation
import AudioToolbox
import Foundation
import MediaPlayer
import Observation
import os

private let traceEnabled = ProcessInfo.processInfo.environment["KODA_TRACE"] == "1"
private let log = Logger(subsystem: "Koda", category: "Player")

/// Engine events, printed only under `KODA_TRACE=1`.
func trace(_ message: @autoclosure () -> String) {
    guard traceEnabled else { return }
    let line = message()
    print("TRACE", String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)), line)
    log.debug("\(line, privacy: .public)")
}

/// The music player: the queue, the AVFoundation pipeline under it, and the
/// system's Now Playing surfaces.
///
/// `AVQueuePlayer` holds at most two items, the current song and the one the
/// queue says comes next, so a song that ends runs straight into the next
/// without a gap. With crossfade on, the next song waits instead on a player of
/// its own (`standby`); as the current song nears its end that player fades in
/// and becomes the main one, while the old one fades out and is let go. Every load is tagged with the queue occurrence it is for and
/// a generation; anything that comes back after the queue has moved on is
/// dropped rather than applied to whatever is current by then.
@MainActor
@Observable
public final class Player {
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// Not observed as a whole: any change to it, a repeat tap included, would redraw every
    /// view showing the playing song, which is every song row in the app. Views watch the
    /// parts below instead, each published only when it actually changes.
    @ObservationIgnored public private(set) var queue = PlayQueue() {
        didSet { publishQueue() }
    }
    public private(set) var current: Song?
    /// What plays after the current song, in order.
    public private(set) var upcoming: [QueueItem] = []
    public private(set) var isShuffled = false
    public private(set) var repeatMode: RepeatMode = .off
    public private(set) var flowSourceID: String?
    public private(set) var phase: Phase = .idle
    /// Whether the listener wants sound: true while loading or buffering a song they pressed play on.
    public private(set) var wantsToPlay = false
    /// The shared app session remains owned while music intends to play or any audible
    /// transition player is running/waiting. A paused, merely preloaded standby does not.
    public var ownsAudioSession: Bool {
        func needsSession(_ player: AVPlayer?) -> Bool {
            guard let player else { return false }
            return player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        }
        return wantsToPlay || needsSession(avPlayer) || needsSession(tail) || needsSession(standby?.player)
    }
    /// True while the player waits on the network with the intent to play.
    public private(set) var isBuffering = false
    public private(set) var duration: TimeInterval = 0
    /// A finished music session keeps its queue, but owns no playing assets or background work.
    /// Only an explicit music transport request opens it again; scene/network events do not.
    public private(set) var isPlaybackSessionFinished = false
    public private(set) var sleepTimerState = SleepTimerState()
    @ObservationIgnored private var sleepTimerPolicy = SleepTimerPolicy()
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
    @ObservationIgnored private var sleepEndItem: ObjectIdentifier?
    @ObservationIgnored public var onPlaybackSessionFinished: (() -> Void)?
    /// The app coordinates the shared session with MV/PiP and voice search. Missing consent
    /// is deliberately conservative: removing music assets is safe without deactivation.
    @ObservationIgnored public var canDeactivateAudioSession: (() -> Bool)?
    @ObservationIgnored var audioSessionDeactivator: (() -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var preloadTask: Task<Void, Never>?
    @ObservationIgnored private var autoMixPlanningTask: Task<Void, Never>?
    @ObservationIgnored private var manualHandoverTask: Task<Void, Never>?
    @ObservationIgnored private var formatTask: Task<Void, Never>?
    @ObservationIgnored private var channelTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var animatedArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var preparedItems: [ObjectIdentifier: AVPlayerItem] = [:]
    @ObservationIgnored private var publicationEpoch: UInt64 = 0
    @ObservationIgnored private var pipelineAttached = true
    @ObservationIgnored private var needsPlayerRebuild = false
    var hasScheduledSleepTimer: Bool { sleepTimerTask != nil }
    /// Metadata preparation is independent of the visible playlist and the audio pipeline.
    /// A failed page keeps this count and its checkpoint until Retry or Cancel.
    public private(set) var playlistLoadingCount: Int?
    public private(set) var playlistLoadingError: String?
    public private(set) var playlistLoadCanRetry = false
    public private(set) var playlistLoadingSourceID: String?
    private enum PlaylistOperation: Sendable { case replace, next, append }
    private struct PlaylistRequest: Sendable {
        var checkpoint: PlaylistQueueLoader.Checkpoint
        var sourceID: String?
        var startAt: Int?
        var shuffled: Bool
        var operation: PlaylistOperation
        var requestedRepeat: RepeatMode? = nil
    }
    @ObservationIgnored private var playlistRequest: PlaylistRequest?
    @ObservationIgnored private var playlistLoadingTask: Task<Bool, Never>?
    @ObservationIgnored private var playlistRequestGeneration = 0
    @ObservationIgnored public private(set) var playbackIntentRevision: UInt64 = 0
    /// Metadata-only test seams; no audio URLs are resolved while preparing the source.
    @ObservationIgnored var playlistFirstPageLoader: (@Sendable (String) async throws -> PlaylistQueueLoader.Page)?
    @ObservationIgnored var playlistPageLoader: (@Sendable (String) async throws -> PlaylistQueueLoader.Page)?
    @ObservationIgnored var playlistRandomIndex: ((Int) -> Int)?
    /// Keep playing related songs when the queue runs out.
    public var autoplay = true {
        didSet {
            persistSettings()
            if !autoplay { cancelRadioLoading() }
        }
    }
    /// Bring loud masters down to YouTube's loudness target, so songs play at a similar volume.
    public var normalizesVolume = true {
        didSet {
            persistSettings()
            applyLoudness(currentLoudnessDb)
        }
    }
    /// Keep songs on the phone as they stream, so they start at once next time.
    public var cachesWhileStreaming = true {
        didSet { persistSettings() }
    }
    /// Songs overlap as one ends and the next begins, the old fading out as the new fades in.
    /// Skips get a short fade too, so changing songs never cuts off mid-note.
    public var crossfades = true {
        didSet {
            persistSettings()
            guard crossfades != oldValue else { return }
            // The next song moves between the queue player and the standby player.
            prepareNext()
            armCrossfade()
        }
    }
    /// How long songs overlap when one runs into the next, in seconds.
    public var crossfadeDuration: TimeInterval = 5 {
        didSet {
            persistSettings()
            armCrossfade()
        }
    }
    /// AutoMix: each song's audio is measured (where the music starts and ends, how it ends,
    /// its tempo and beats) and every handover is planned like a DJ would: beats lined up with
    /// the bass swapped mid-way, a fade-out ridden, or a short blend on a hard ending. Takes
    /// the place of crossfade while on.
    public var autoMix = false {
        didSet {
            persistSettings()
            guard autoMix != oldValue else { return }
            AutoMixLog.note("AutoMix \(autoMix ? "on" : "off")")
            endTransition()
            autoMixPlan = nil
            // The next song is loaded again, with or without its mixer channel.
            discardStandby()
            prepareNext()
            armCrossfade()
        }
    }

    /// The equalizer preset every song plays through. Songs get a mixer channel while it is on;
    /// turning it on mid-song gives the playing song one at once rather than from the next.
    public var equalizer: EqualizerPreset = .off {
        didSet {
            guard !applyingSoundSelection else { return }
            persistSettings()
            guard equalizer != oldValue else { return }
            noteManualSoundChange()
            if soundSettings.customEnabled { soundSettings.customEnabled = false }
            else { applySoundSettings() }
        }
    }

    /// Nil until a playing item's audio tap has been checked. The output cap is independent.
    public private(set) var soundProcessingAvailable: Bool?
    /// Sound Center values are independent of the legacy preset key.
    public var soundSettings = SoundSettings() {
        didSet {
            guard !applyingSoundSelection else { return }
            noteManualSoundChange()
            SoundSettingsStore.save(soundSettings, defaults: preferenceDefaults)
            applySoundSettings()
        }
    }

    public private(set) var audioOutputRoute = AudioOutputRoute()
    public private(set) var soundProfiles: [SoundProfile] = []
    public private(set) var appliedDeviceSound: DeviceSoundTarget?
    public private(set) var deviceSoundManuallyOverridden = false
    public private(set) var deviceSoundProfileMissing = false
    public var deviceSoundSettings = DeviceSoundSettings() {
        didSet {
            guard !restoringSoundSettings else { return }
            DeviceSoundStore.save(deviceSoundSettings, defaults: preferenceDefaults)
            scheduleDeviceSoundApplication(resetOverride: deviceSoundSettings.enabled && !oldValue.enabled)
        }
    }
    @ObservationIgnored private var soundRoutePolicy = DeviceSoundPolicy()
    @ObservationIgnored private var deviceSoundTask: Task<Void, Never>?
    @ObservationIgnored private var soundOutputRampTask: Task<Void, Never>?
    @ObservationIgnored private var routedOutputLimit: Float?
    @ObservationIgnored private var applyingSoundSelection = false
    @ObservationIgnored private var restoringSoundSettings = true

    public var smartShuffleSettings = SmartShuffleSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(smartShuffleSettings.validated) {
                preferenceDefaults.set(data, forKey: "koda.smartShuffle.settings.v1")
            }
        }
    }
    /// Opt-in only: a cold launch does not unexpectedly start audio by default.
    public var resumePlaybackOnLaunch = false {
        didSet { preferenceDefaults.set(resumePlaybackOnLaunch, forKey: "koda.playback.resumeOnLaunch") }
    }
    @ObservationIgnored private var restoredPlaybackWasActive = false
    @ObservationIgnored private var mayResumeRestoredQueue = false
    public private(set) var isSmartShuffled = false
    @ObservationIgnored public var smartShuffleContext: (() -> SmartShuffleContext)?
    public var savesSmartShuffleHistory = true {
        didSet { if !savesSmartShuffleHistory { clearSmartShuffleHistory() } }
    }
    @ObservationIgnored private var smartHistory = SmartShuffleHistory()

    /// Stream quality on Wi‑Fi and other unmetered networks.
    public var unmeteredQuality: StreamQuality = .high {
        didSet { persistSettings() }
    }
    /// Stream quality on mobile data or a personal hotspot. Low Data Mode always streams the lighter format.
    public var meteredQuality: StreamQuality = .high {
        didSet { persistSettings() }
    }

    /// The quality for a stream asked for now, on whatever network the device is on.
    private var streamQuality: StreamQuality {
        let path = NetworkPath.shared
        if path.isConstrained { return .dataSaver }
        return path.isExpensive ? meteredQuality : unmeteredQuality
    }

    /// How songs change over: the three choices of Settings' Song Transitions.
    public enum Transitions: String, CaseIterable, Sendable {
        case autoMix, crossfade, off
    }

    public var transitions: Transitions {
        get { autoMix ? .autoMix : crossfades ? .crossfade : .off }
        set {
            switch newValue {
            case .autoMix:
                autoMix = true
            case .crossfade:
                autoMix = false
                crossfades = true
            case .off:
                autoMix = false
                crossfades = false
            }
        }
    }

    /// An AutoMix transition under way, for the "Mixing" badge on Now Playing and the player bar.
    public struct Mixing: Equatable, Sendable {
        public var style: TransitionPlan.Style
        public var from: String
        public var to: String
        /// The outgoing song's cover, for Now Playing to dissolve into the new one.
        public var fromArtwork: Artwork?
        /// When the two songs start to overlap, and for how long.
        public var started: Date
        public var overlap: TimeInterval
        /// Where the outgoing song was at that moment, and its length, for its fading bar.
        public var fromPosition: TimeInterval
        public var fromDuration: TimeInterval
        /// The shared beat while beats are locked: one beat's moment and the period.
        public var beat: Date?
        public var beatPeriod: TimeInterval?

        /// How far through the overlap, 0 to 1.
        public func progress(at date: Date) -> Double {
            guard overlap > 0 else { return 1 }
            return min(1, max(0, date.timeIntervalSince(started) / overlap))
        }

        /// The outgoing song's progress through itself at `date`.
        public func outgoingFraction(at date: Date) -> Double {
            guard fromDuration > 0 else { return 1 }
            return min(1, (fromPosition + max(0, date.timeIntervalSince(started))) / fromDuration)
        }
    }

    public private(set) var mixing: Mixing?

    /// The fade a skip gets with crossfade on: long enough not to click, short enough to feel instant.
    public static let skipFade: TimeInterval = 0.6
    /// Where songs' audio is kept on the phone. A song held whole plays from its file, with
    /// no request to YouTube; nil plays everything from YouTube.
    @ObservationIgnored public var audioStore: AudioStore?

    /// The last known position and when it was sampled; `position(at:)` runs it forward.
    public private(set) var timeAnchor = TimeAnchor(position: 0, date: .distantPast, rate: 0)

    public struct TimeAnchor: Equatable, Sendable {
        public var position: TimeInterval
        public var date: Date
        public var rate: Double
    }

    /// Pause when the current song ends instead of going on, with the next song loaded and ready; for the sleep timer.
    public var stopsAtEndOfSong = false {
        didSet { avPlayer.actionAtItemEnd = stopsAtEndOfSong ? .pause : .advance }
    }

    /// Called when a song starts playing, for history.
    public var onSongStarted: ((Song) -> Void)?
    /// An explicit music intent is accepted, before metadata or audio loading suspends.
    /// The app uses this boundary to pause its video player even while music is buffering.
    @ObservationIgnored public var onPlaybackRequested: (() -> Void)?
    /// A positively identified corrupt local file was invalidated; update download UI state.
    @ObservationIgnored public var onLocalAudioInvalidated: ((String) -> Void)?
    /// Called every few seconds of actual sound with the seconds heard since the last call, for listening stats.
    public var onListened: ((Song, TimeInterval) -> Void)?
    /// The same two moments for one occurrence in the queue, so a song repeated is a new play: for scrobbling.
    public var onItemStarted: ((QueueItem) -> Void)?
    public var onItemHeard: ((QueueItem, TimeInterval) -> Void)?
    /// Songs the listener asked not to be offered; radio and autoplay leave them out.
    public var isUnwanted: ((Song) -> Bool)?
    /// Loads artwork for the lock screen; set by the app, which owns image decoding.
    public var artworkLoader: (@MainActor (URL) async -> MPMediaItemArtwork?)?
    /// The song's animated covers for the Lock Screen, keyed by Now Playing property
    /// (`MPNowPlayingInfoProperty1x1AnimatedArtwork`, …); set by the app, which owns the setting.
    public var animatedArtworkLoader: (@MainActor (Song) async -> [String: MPMediaItemAnimatedArtwork])?

    public let music: YouTubeMusic
    /// The player the current song plays on. Replaced when a crossfade or a faded skip hands
    /// over to another one; `attach` moves the observers along with it.
    private var avPlayer = AVQueuePlayer()
    /// With crossfade on, the next song loaded and paused on a player of its own.
    private var standby: (player: AVQueuePlayer, item: AVPlayerItem, id: UUID, stream: ResolvedStream)?
    /// The stream the main player's song came from, for AutoMix to measure.
    private var currentStream: ResolvedStream?
    private let storage: URL?
    private let preferenceDefaults: UserDefaults

    /// The occurrence each loaded AVPlayerItem plays.
    private var occurrences: [ObjectIdentifier: UUID] = [:]
    /// Items put behind the current one; becoming current means a song changed at its start.
    private var preloaded: Set<ObjectIdentifier> = []
    /// The item AVFoundation played last, to tell a song that finished from one it dropped.
    private var lastAVItem: AVPlayerItem?
    private var itemStatusObservation: NSKeyValueObservation?
    private var stallWatchdog: Task<Void, Never>?
    /// How long the player may wait on the network, wanting to play, before the song is reloaded.
    var stallTimeout: Duration = .seconds(15)
    /// Test seam: rewrite a stream before it is played.
    var streamRewriter: ((ResolvedStream) -> ResolvedStream)?
    /// Test seams for deterministic load failures without network access or real audio.
    var streamLoader: ((Song, StreamQuality) async throws -> ResolvedStream)?
    @ObservationIgnored var remoteStreamLoader: ((Song, StreamQuality) async throws -> ResolvedStream)?
    @ObservationIgnored var radioLoader: (@Sendable (String) async throws -> [Song])?
    @ObservationIgnored var audioSessionActivator: (() -> Bool)?
    var networkSnapshotOverride: NetworkSnapshot?
    private var recoveryNetwork: NetworkSnapshot { networkSnapshotOverride ?? latestNetwork }
    var engineIdentifier: ObjectIdentifier { ObjectIdentifier(avPlayer) }
    /// Internal integration-test seam for real AVFoundation item transitions.
    var playbackEngine: AVQueuePlayer { avPlayer }
    var currentPlayerItem: AVPlayerItem? { avPlayer.currentItem }
    var standbyPlayer: AVQueuePlayer? { standby?.player }
    private var generation = 0
    private var nextGeneration = 0
    @ObservationIgnored private var recovery = PlaybackRecovery()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    @ObservationIgnored private var interruption = PlaybackInterruptionState()
    @ObservationIgnored private var recoveryWasAttempted = false
    @ObservationIgnored private var latestNetwork = NetworkPath.shared.snapshot
    @ObservationIgnored private var streamByItem: [ObjectIdentifier: ResolvedStream] = [:]
    @ObservationIgnored private var attachingChannels: Set<ObjectIdentifier> = []
    @ObservationIgnored private var invalidatedLocalOccurrence: UUID?
    @ObservationIgnored private var measuredCodec: String?
    @ObservationIgnored private var measuredSampleRate: Double?
    @ObservationIgnored private var measuredChannels: Int?
    public private(set) var audioInformation = AudioPlaybackInformation()
    public private(set) var diagnosticEvents: [PlaybackDiagnosticEvent] = []
    @ObservationIgnored private var diagnosticStore: PlaybackDiagnosticStore!
    private struct RadioRequest {
        var generation: Int
        var anchor: UUID
        var advanceWhenReady: Bool
    }
    @ObservationIgnored private var radioRequest: RadioRequest?
    @ObservationIgnored private var radioTask: Task<Void, Never>?
    @ObservationIgnored private var radioRequestGeneration = 0
    private var startedReported: UUID?
    private var observations: [NSKeyValueObservation] = []
    private var timeObserver: Any?
    private var nowPlayingArtworkFor: URL?
    private var nowPlayingAnimatedFor: String?
    private var lastListenedTick: Date?
    /// The playing song's loudness above target, kept so normalization can be switched mid-song.
    private var currentLoudnessDb: Double?
    /// The queue player's volume before any fade: Koda's level with normalization applied.
    private var baseVolume: Float = 1
    /// How far the current song has faded in, 0 to 1; multiplies `baseVolume`.
    private var fadeGain: Float = 1
    private var fadeIn: Task<Void, Never>?
    /// The last main player, playing on by itself while its song fades out.
    private var tail: AVQueuePlayer?
    /// Desired outgoing gain is stored separately from its allocated AVPlayer volume.
    /// Feeding an already capped volume into the next allocation would compound attenuation.
    private var tailLoudnessDb: Double?
    private var tailFadeGain: Float = 0
    private var tailFade: Task<Void, Never>?
    /// Smoothly returns the conservative overlap budget after an AutoMix tail is released.
    private var outputReleaseGain: Float = 1
    @ObservationIgnored private var outputReleaseTask: Task<Void, Never>?
    /// Fires when the playing song is `crossfadeDuration` from its end.
    private var crossfadeObserver: Any?
    private var lastPersisted = Date.distantPast

    // AutoMix
    private struct PlanKey: Equatable {
        var from: UUID
        var to: UUID
        /// The rate the outgoing song plays at, which the plan's tempo match is made for.
        var outgoingRate: Double
    }

    /// The rate the playing song was started at: not 1 after an AutoMix transition matched a
    /// tempo, until the song next starts from a standstill (a playing player's rate is never
    /// changed; see `follow`).
    private var heardRate: Double = 1

    /// The planned handover from the current occurrence to the standby one.
    private var autoMixPlan: (key: PlanKey, plan: TransitionPlan)?
    private var planning: PlanKey?
    private var analyzer: AutoMixAnalyzer?
    /// Follows a transition under way: checks the timing, logs levels, ends it.
    private var transitionTask: Task<Void, Never>?
    /// Until then the new main player is waiting for its scheduled start, not buffering.
    private var scheduledStart: Date?
    @ObservationIgnored private var scheduledPlaybackTask: Task<Void, Never>?
    /// How long before its cue a transition is set up; the next song is then scheduled on the clock.
    static let autoMixLead: TimeInterval = 0.3
    /// Crossfade or AutoMix: the next song waits on the standby player.
    private var usesStandby: Bool { crossfades || autoMix }
    /// Songs play through a mixer channel (`TransitionDSP`) for AutoMix's moves or the equalizer.
    private var usesChannels: Bool { autoMix || soundSettings.requiresProcessing(preset: equalizer) }

    public init(music: YouTubeMusic, storageDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.music = music
        storage = storageDirectory
        preferenceDefaults = defaults
        diagnosticStore = PlaybackDiagnosticStore(storage: storageDirectory?.appending(path: "playback-diagnostics.json"))
        diagnosticEvents = diagnosticStore.events
        AutoMixLog.configure(directory: storageDirectory)
        avPlayer.actionAtItemEnd = .advance
        attach(avPlayer)
        observePlayer()
        configureRemoteCommands()
        sleepTimerPolicy = SleepTimerPolicy(state: SleepTimerStore.load(defaults: defaults))
        _ = sleepTimerPolicy.evaluate(at: Date())
        sleepTimerState = sleepTimerPolicy.state
        _ = SleepTimerStore.save(sleepTimerState, defaults: defaults)
        isPlaybackSessionFinished = sleepTimerState.completion?.action == .finishPlaybackSession
        restore()
        if isPlaybackSessionFinished { releaseFinishedSessionResources(notifyApp: false) }
        synchronizeSleepTimer()
        soundProfiles = SoundSettingsStore.profiles(defaults: preferenceDefaults)
        deviceSoundSettings = DeviceSoundStore.load(defaults: preferenceDefaults)
        restoringSoundSettings = false
        refreshAudioOutputRoute()
        observeNetwork()
        refreshAudioInformation()
    }

    deinit {
        sleepTimerTask?.cancel()
        loadTask?.cancel()
        preloadTask?.cancel()
        autoMixPlanningTask?.cancel()
        manualHandoverTask?.cancel()
        formatTask?.cancel()
        artworkTask?.cancel()
        animatedArtworkTask?.cancel()
        for task in channelTasks.values { task.cancel() }
        networkTask?.cancel()
        recoveryTask?.cancel()
        playlistLoadingTask?.cancel()
        outputReleaseTask?.cancel()
        radioTask?.cancel()
        scheduledPlaybackTask?.cancel()
        deviceSoundTask?.cancel()
        soundOutputRampTask?.cancel()
    }

    // MARK: - Reading

    /// Copy into the observed parts what changed in the queue, and nothing else, so a
    /// view is told only when the part it shows is different.
    private func publishQueue() {
        let song = queue.current?.song
        if current != song { current = song }
        if sleepTimerPolicy.selectionChanged(to: queue.current?.id) { synchronizeSleepTimer() }
        if isShuffled != queue.isShuffled { isShuffled = queue.isShuffled }
        if isSmartShuffled != queue.isSmartShuffled { isSmartShuffled = queue.isSmartShuffled }
        if repeatMode != queue.repeatMode { repeatMode = queue.repeatMode }
        if flowSourceID != queue.flowContext?.sourceID { flowSourceID = queue.flowContext?.sourceID }
        let next = queue.upcoming
        if !upcoming.elementsEqual(next) { upcoming = Array(next) }
    }

    public var isMuted = false {
        didSet {
            avPlayer.isMuted = isMuted
            standby?.player.isMuted = isMuted
            tail?.isMuted = isMuted
        }
    }

    /// Koda's own level, 0 to 1, under the system's. The Mac has no system slider an app can
    /// drive, so its volume control sets this; normalization still applies on top.
    public var volume: Float = 1 {
        didSet { applyLoudness(currentLoudnessDb) }
    }

    /// How many songs AVFoundation holds right now: 2 when the next one is preloaded.
    var loadedItemCount: Int { avPlayer.items().count + (standby == nil ? 0 : 1) }
    /// Test seam for the actual AVPlayer output gain, independent of system volume.
    var outputVolume: Float { avPlayer.volume }
    /// A song is fading out on the side, for tests.
    var isFadingOut: Bool { tail != nil }

    /// The playhead at `date`, run forward from the last sample at the playing rate.
    public func position(at date: Date = Date()) -> TimeInterval {
        let elapsed = timeAnchor.rate > 0 ? date.timeIntervalSince(timeAnchor.date) * timeAnchor.rate : 0
        let value = timeAnchor.position + max(0, elapsed)
        return duration > 0 ? min(value, duration) : value
    }

    // MARK: - Persistent sleep timer

    public func scheduleSleepTimer(minutes: Int) throws {
        try sleepTimerPolicy.start(minutes: minutes, action: sleepTimerState.preferredAction, at: Date())
        synchronizeSleepTimer()
    }

    public func scheduleSleepTimerAtEndOfSong() throws {
        guard let id = queue.current?.id else { throw SleepTimerValidationError.notRunning }
        sleepEndItem = nil
        try sleepTimerPolicy.stopAtEndOfSong(occurrenceID: id, action: sleepTimerState.preferredAction, at: Date())
        synchronizeSleepTimer()
    }

    public func setSleepTimerAction(_ action: SleepTimerAction) {
        sleepTimerPolicy.setAction(action)
        synchronizeSleepTimer()
    }

    public func extendSleepTimer(minutes: Int) throws {
        try sleepTimerPolicy.extend(minutes: minutes, at: Date())
        synchronizeSleepTimer()
    }

    public func resetSleepTimer() throws {
        try sleepTimerPolicy.reset(at: Date())
        synchronizeSleepTimer()
    }

    public func cancelSleepTimer() {
        sleepTimerPolicy.cancel()
        synchronizeSleepTimer()
    }

    private func synchronizeSleepTimer(rearm: Bool = true) {
        sleepTimerState = sleepTimerPolicy.state
        _ = SleepTimerStore.save(sleepTimerState, defaults: preferenceDefaults)
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        guard rearm else { return }
        if let plan = sleepTimerState.plan, case .endOfSong = plan.schedule {
            stopsAtEndOfSong = true
            bindSleepEndItem(avPlayer.currentItem)
        } else {
            stopsAtEndOfSong = false
            sleepEndItem = nil
        }
        // A changed end-of-song setting also invalidates a previously armed mixing cue.
        armCrossfade()
        guard let plan = sleepTimerState.plan, case .countdown(let deadline) = plan.schedule else { return }
        let revision = plan.revision
        sleepTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(0.05, deadline.timeIntervalSinceNow))) }
                catch { return }
                guard !Task.isCancelled, let self, self.sleepTimerState.plan?.revision == revision else { return }
                if self.evaluateSleepTimer(at: Date(), revision: revision) { return }
                // The wall clock may have moved backwards while the monotonic sleep ran.
                // Keep this revision armed rather than losing a paused player's countdown.
            }
        }
    }

    private func bindSleepEndItem(_ item: AVPlayerItem?) {
        guard sleepEndItem == nil, let item, let plan = sleepTimerState.plan,
              case .endOfSong(let target) = plan.schedule,
              occurrences[ObjectIdentifier(item)] == target else { return }
        sleepEndItem = ObjectIdentifier(item)
    }

    /// All automatic entry points check the wall-clock deadline as well as the timer task:
    /// iOS may suspend a task while offline or during an audio interruption.
    @discardableResult
    func evaluateSleepTimer(at date: Date = Date(), revision: UUID? = nil) -> Bool {
        let effect = sleepTimerPolicy.evaluate(at: date, revision: revision)
        guard case .fire(let action) = effect else { return false }
        completeSleepTimer(action)
        return true
    }

    @discardableResult
    func sleepTimerSongEnded(occurrenceID: UUID, at date: Date = Date()) -> Bool {
        guard let revision = sleepTimerState.plan?.revision else { return false }
        let effect = sleepTimerPolicy.songEnded(occurrenceID: occurrenceID, revision: revision, at: date)
        guard case .fire(let action) = effect else { return false }
        completeSleepTimer(action)
        return true
    }

    private func completeSleepTimer(_ action: SleepTimerAction) {
        // Persist the consumed revision before touching audio/queue state. A termination
        // between these operations must never restore the older wasPlaying snapshot.
        synchronizeSleepTimer(rearm: false)
        switch action {
        case .pause:
            pause(from: "the sleep timer")
            stopsAtEndOfSong = false
            sleepEndItem = nil
            persistQueueNow()
        case .finishPlaybackSession:
            releaseFinishedSessionResources(notifyApp: true)
        }
    }

    /// Ends this music session without deleting its queue or resetting the last position.
    /// General pause remains separate and keeps the ready AVPlayerItem for instant resume.
    public func finishPlaybackSession() {
        sleepTimerPolicy.recordCompletion(action: .finishPlaybackSession, at: Date())
        synchronizeSleepTimer(rearm: false)
        releaseFinishedSessionResources(notifyApp: true)
    }

    private func releaseFinishedSessionResources(notifyApp: Bool) {
        let wasFinished = isPlaybackSessionFinished
        let measured = avPlayer.currentTime().seconds
        let ownsClock = avPlayer.currentItem.map { occurrences[ObjectIdentifier($0)] == queue.current?.id && $0.status == .readyToPlay } ?? false
        let heldPosition = ownsClock && measured.isFinite ? max(0, duration > 0 ? min(measured, duration) : measured) : position()
        isPlaybackSessionFinished = true
        publicationEpoch &+= 1
        restoredPlaybackWasActive = false
        mayResumeRestoredQueue = false
        interruption.userPaused()
        wantsToPlay = false
        isBuffering = false
        generation += 1
        nextGeneration += 1
        cancelPlaylistLoading()
        cancelRadioLoading()
        cancelRecovery()
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        loadTask?.cancel(); loadTask = nil
        preloadTask?.cancel(); preloadTask = nil
        autoMixPlanningTask?.cancel(); autoMixPlanningTask = nil
        manualHandoverTask?.cancel(); manualHandoverTask = nil
        formatTask?.cancel(); formatTask = nil
        for task in channelTasks.values { task.cancel() }
        channelTasks.removeAll()
        artworkTask?.cancel(); artworkTask = nil
        animatedArtworkTask?.cancel(); animatedArtworkTask = nil
        stallWatchdog?.cancel(); stallWatchdog = nil
        deviceSoundTask?.cancel(); deviceSoundTask = nil
        soundOutputRampTask?.cancel(); soundOutputRampTask = nil
        _ = soundRoutePolicy.invalidate(resetOverride: false)
        routedOutputLimit = nil
        // Detach this analyzer before cancelling it: a fresh explicit play gets a new
        // instance and cannot race the actor hop that cancels the old instance's jobs.
        if let retiredAnalyzer = analyzer { Task { await retiredAnalyzer.cancelAll() } }
        analyzer = nil
        planning = nil
        autoMixPlan = nil
        var players = [avPlayer]
        if let standby { players.append(standby.player) }
        if let tail { players.append(tail) }
        for item in preparedItems.values {
            item.cancelPendingSeeks()
            item.asset.cancelLoading()
            CachingLoader.stop(asset: item.asset)
        }
        preparedItems.removeAll()
        for player in players {
            player.pause()
            player.cancelPendingPrerolls()
            for item in player.items() {
                item.cancelPendingSeeks()
                item.asset.cancelLoading()
                CachingLoader.stop(asset: item.asset)
            }
        }
        endTransition()
        finishTail()
        cancelFadeIn()
        disarmCrossfade()
        discardStandby()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if pipelineAttached { detach(avPlayer); pipelineAttached = false }
        avPlayer.removeAllItems()
        stopsAtEndOfSong = false
        sleepEndItem = nil
        occurrences.removeAll()
        preloaded.removeAll()
        streamByItem.removeAll()
        attachingChannels.removeAll()
        currentStream = nil
        lastAVItem = nil
        soundProcessingAvailable = nil
        measuredCodec = nil
        measuredSampleRate = nil
        measuredChannels = nil
        silentSince = nil
        lastListenedTick = nil
        heardRate = 1
        phase = .idle
        timeAnchor = TimeAnchor(position: heldPosition, date: Date(), rate: 0)
        nowPlayingArtworkFor = nil
        nowPlayingAnimatedFor = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        persistQueueNow()
        refreshAudioInformation()
        if notifyApp && !wasFinished { onPlaybackSessionFinished?() }
        // Another Koda feature may now own this process's shared session. Clearing music
        // never turns off MV/PiP/AirPlay or a voice-search recording owned by that feature.
        if notifyApp && !wasFinished, canDeactivateAudioSession?() == true {
            if let audioSessionDeactivator { audioSessionDeactivator() }
            else {
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
            }
        }
    }

    private func acceptExplicitPlayback() {
        // An overdue timer is consumed before accepting a genuinely newer user intention.
        _ = evaluateSleepTimer()
        sleepTimerPolicy.acknowledgeManualPlayback()
        sleepTimerState = sleepTimerPolicy.state
        _ = SleepTimerStore.save(sleepTimerState, defaults: preferenceDefaults)
        if isPlaybackSessionFinished {
            publicationEpoch &+= 1
            isPlaybackSessionFinished = false
            if needsPlayerRebuild {
                needsPlayerRebuild = false
                adopt(AVQueuePlayer())
                pipelineAttached = true
            } else if !pipelineAttached {
                attach(avPlayer)
                pipelineAttached = true
            }
            scheduleDeviceSoundApplication(resetOverride: false)
        }
    }

    // MARK: - Starting playback

    /// Replace the queue and play from `index`.
    public func play(_ songs: [Song], startAt index: Int = 0, shuffled: Bool = false) {
        replacePlaybackQueue(songs, startAt: index, shuffled: shuffled, flowSourceID: nil)
    }

    /// Flow is an explicitly prepared queue, never a history-weighted shuffle or radio.
    /// A preparation token is rejected if transport, queue edits or a sleep deadline won.
    @discardableResult
    public func playFlow(_ songs: [Song], sourceID: String, expectedIntentRevision: UInt64? = nil) -> Bool {
        guard !songs.isEmpty, !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !Task.isCancelled else { return false }
        if let expectedIntentRevision {
            guard playbackIntentRevision == expectedIntentRevision else { return false }
            guard !evaluateSleepTimer(), playbackIntentRevision == expectedIntentRevision else { return false }
        }
        replacePlaybackQueue(songs, startAt: 0, shuffled: false, flowSourceID: sourceID)
        return true
    }

    private func replacePlaybackQueue(_ songs: [Song], startAt index: Int, shuffled: Bool, flowSourceID: String?) {
        cancelPlaylistLoading()
        guard !songs.isEmpty else { return }
        acceptExplicitPlayback()
        onPlaybackRequested?()
        cancelRadioLoading()
        restoredPlaybackWasActive = false
        mayResumeRestoredQueue = false
        cancelRecovery()
        let smart = shuffled && smartShuffleSettings.enabled
        if let flowSourceID { queue.replaceFlow(with: songs, sourceID: flowSourceID) }
        else if smart { queue.replaceSmart(with: songs, startAt: index, settings: smartShuffleSettings, context: shuffleContext()) }
        else { queue.replace(with: songs, startAt: index, shuffled: shuffled) }
        queue.retainCurrentCollection()
        wantsToPlay = true
        loadCurrent(at: 0, fadeIn: fadeOutForSkip())
    }

    /// Prepare the complete ordered source before replacing or shuffling the queue. `songs`
    /// must be an unmodified source prefix paired with its next cursor, not filtered UI rows.
    /// A nil index chooses a random first song from the FULL source when shuffled.
    /// The returned task may be awaited by Siri; views can ignore it and navigate away.
    @discardableResult
    public func playPlaylist(_ songs: [Song], continuation: String?, startAt: Int? = nil,
                             shuffled: Bool = false, sourceID: String? = nil,
                             completedPageTokens: Set<String> = []) -> Task<Bool, Never> {
        acceptExplicitPlayback()
        cancelPlaylistLoading()
        let checkpoint = PlaylistQueueLoader.Checkpoint(firstPage: .init(songs: songs, continuation: continuation),
                                                        completedTokens: completedPageTokens)
        let limits = PlaylistQueueLoader.Limits()
        if checkpoint.isComplete, songs.count <= limits.maxSongs, checkpoint.pagesLoaded <= limits.maxPages {
            guard !songs.isEmpty else { return Task { false } }
            play(songs, startAt: playlistStartIndex(count: songs.count, requested: startAt, shuffled: shuffled), shuffled: shuffled)
            return Task { true }
        }
        playlistRequest = PlaylistRequest(checkpoint: checkpoint, sourceID: sourceID, startAt: startAt, shuffled: shuffled, operation: .replace)
        return beginPlaylistLoading()
    }

    /// Collection and Siri entry points use this overload so even the first page belongs to
    /// the same cancellable user intent, rather than to an untracked view or intent task.
    @discardableResult
    public func playPlaylist(id: String, shuffled: Bool = false, repeatMode: RepeatMode? = nil) -> Task<Bool, Never> {
        acceptExplicitPlayback()
        cancelPlaylistLoading()
        playlistRequest = PlaylistRequest(checkpoint: .init(), sourceID: id, startAt: nil, shuffled: shuffled,
                                          operation: .replace, requestedRepeat: repeatMode)
        return beginPlaylistLoading()
    }

    /// Collection queue actions share the same all-pages boundary, retaining the existing
    /// play-next/append rules and deliberate duplicate occurrences in the source playlist.
    @discardableResult
    public func enqueuePlaylist(_ songs: [Song], continuation: String?, playNext: Bool,
                                sourceID: String? = nil, completedPageTokens: Set<String> = []) -> Task<Bool, Never> {
        cancelPlaylistLoading()
        let checkpoint = PlaylistQueueLoader.Checkpoint(firstPage: .init(songs: songs, continuation: continuation),
                                                        completedTokens: completedPageTokens)
        let limits = PlaylistQueueLoader.Limits()
        if checkpoint.isComplete, songs.count <= limits.maxSongs, checkpoint.pagesLoaded <= limits.maxPages {
            guard !songs.isEmpty else { return Task { false } }
            if playNext { self.playNext(songs) } else { addToQueue(songs) }
            return Task { true }
        }
        playlistRequest = PlaylistRequest(checkpoint: checkpoint, sourceID: sourceID, startAt: nil, shuffled: false,
                                          operation: playNext ? .next : .append)
        return beginPlaylistLoading()
    }

    @discardableResult
    public func enqueuePlaylist(id: String, playNext: Bool) -> Task<Bool, Never> {
        cancelPlaylistLoading()
        playlistRequest = PlaylistRequest(checkpoint: .init(), sourceID: id, startAt: nil, shuffled: false,
                                          operation: playNext ? .next : .append)
        return beginPlaylistLoading()
    }

    @discardableResult
    public func retryPlaylistLoading() -> Task<Bool, Never> {
        guard playlistLoadCanRetry, playlistRequest != nil, playlistLoadingTask == nil else { return Task { false } }
        return beginPlaylistLoading()
    }

    /// Explicit queue/transport edits also call this: a late metadata response must never
    /// overwrite a queue the listener has edited since requesting the playlist.
    public func cancelPlaylistLoading() {
        playbackIntentRevision &+= 1
        playlistRequestGeneration += 1
        playlistLoadingTask?.cancel()
        playlistLoadingTask = nil
        playlistRequest = nil
        playlistLoadingCount = nil
        playlistLoadingError = nil
        playlistLoadCanRetry = false
        playlistLoadingSourceID = nil
    }

    /// A link may need metadata before it can select a song. Claim its intent now and let
    /// the caller reject a late response if any newer transport/queue request changes revision.
    @discardableResult
    public func beginExternalPlaybackRequest() -> UInt64 {
        acceptExplicitPlayback()
        cancelPlaylistLoading()
        cancelRadioLoading()
        restoredPlaybackWasActive = false
        mayResumeRestoredQueue = false
        onPlaybackRequested?()
        return playbackIntentRevision
    }

    private func playlistStartIndex(count: Int, requested: Int?, shuffled: Bool) -> Int {
        if let requested { return min(max(requested, 0), count - 1) }
        guard shuffled else { return 0 }
        return min(max(playlistRandomIndex?(count) ?? Int.random(in: 0..<count), 0), count - 1)
    }

    private func beginPlaylistLoading() -> Task<Bool, Never> {
        guard let request = playlistRequest else { return Task { false } }
        if request.operation == .replace || queue.isEmpty { onPlaybackRequested?() }
        playlistRequestGeneration += 1
        let token = playlistRequestGeneration
        playlistLoadingCount = request.checkpoint.songs.count
        playlistLoadingSourceID = request.sourceID
        playlistLoadingError = nil
        playlistLoadCanRetry = false
        restoredPlaybackWasActive = false
        mayResumeRestoredQueue = false
        let music = music
        let firstLoader = playlistFirstPageLoader
        let moreLoader = playlistPageLoader
        let task = Task { [weak self] in
            await withTaskCancellationHandler {
            do {
                let completed = try await PlaylistQueueLoader.load(from: request.checkpoint,
                    fetchFirst: {
                        guard let id = request.sourceID else { throw PlaylistQueueLoader.LoadingError.invalidCheckpoint }
                        if let firstLoader { return try await firstLoader(id) }
                        let page = try await music.playlistFreshForPlayback(id)
                        return .init(songs: page.songs, continuation: page.continuation)
                    }, fetchMore: { cursor in
                        if let moreLoader { return try await moreLoader(cursor) }
                        let page = try await music.playlistMoreForPlayback(cursor)
                        return .init(songs: page.songs, continuation: page.continuation)
                    }, didLoadPage: { [weak self] checkpoint in
                        await self?.receivedPlaylistPage(checkpoint, token: token)
                    })
                try Task.checkCancellation()
                guard let self, self.playlistRequestGeneration == token else { return false }
                guard !completed.songs.isEmpty else {
                    self.playlistLoadingTask = nil
                    self.playlistLoadingError = NSLocalizedString("This playlist has no playable songs.", bundle: KodaLocalization.bundle, comment: "")
                    self.playlistLoadCanRetry = false
                    return false
                }
                // Detach before play() invalidates preparation; do not cancel this successful task.
                self.playlistLoadingTask = nil
                switch request.operation {
                case .replace:
                    let index = self.playlistStartIndex(count: completed.songs.count, requested: request.startAt, shuffled: request.shuffled)
                    self.play(completed.songs, startAt: index, shuffled: request.shuffled)
                    if let mode = request.requestedRepeat { self.setRepeat(mode) }
                case .next: self.playNext(completed.songs)
                case .append: self.addToQueue(completed.songs)
                }
                return true
            } catch {
                guard let self, self.playlistRequestGeneration == token else { return false }
                self.playlistLoadingTask = nil
                if error is CancellationError || Task.isCancelled {
                    self.cancelPlaylistLoading()
                } else {
                    // Only fixed local messages are displayed. Response bodies, cursors, account
                    // details and arbitrary server errors must not reach the UI or diagnostics.
                    self.playlistLoadingError = (error as? PlaylistQueueLoader.LoadingError)?.errorDescription
                        ?? NSLocalizedString("The complete playlist could not be loaded. Your current queue was kept. Retry to continue loading.", bundle: KodaLocalization.bundle, comment: "")
                    self.playlistLoadCanRetry = !(error is PlaylistQueueLoader.LoadingError)
                }
                return false
            }
            } onCancel: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.playlistRequestGeneration == token else { return }
                    self.cancelPlaylistLoading()
                }
            }
        }
        playlistLoadingTask = task
        return task
    }

    private func receivedPlaylistPage(_ checkpoint: PlaylistQueueLoader.Checkpoint, token: Int) {
        guard playlistRequestGeneration == token, playlistRequest != nil else { return }
        playlistRequest?.checkpoint = checkpoint
        playlistLoadingCount = checkpoint.songs.count
    }

    /// Play `song` and follow it with its radio.
    public func startRadio(from song: Song) {
        play([song])
        extendWithRadio(thenAdvance: false, explicitlyRequested: true)
    }

    // MARK: - Transport

    /// `source` names who asked, for the log: a pause nobody remembers asking for has to be traced.
    public func togglePlayPause(from source: String = "unnamed caller") {
        AutoMixLog.note("\(wantsToPlay ? "pause" : "play") asked by \(source)")
        wantsToPlay ? pause(from: source) : resume()
    }

    public func resume() {
        cancelPlaylistLoading()
        guard queue.current != nil else { return }
        acceptExplicitPlayback()
        onPlaybackRequested?()
        restoredPlaybackWasActive = false
        mayResumeRestoredQueue = false
        AutoMixLog.note("play at \(position().s1) s")
        let activated = activateAudioSession()
        guard interruption.explicitResume(activationSucceeded: activated) else {
            wantsToPlay = false
            isBuffering = false
            phase = .failed(NSLocalizedString("The audio session could not be activated. Try playing again.", bundle: KodaLocalization.bundle, comment: ""))
            updateNowPlaying()
            refreshAudioInformation()
            return
        }
        cancelRecovery()
        let failedItem = avPlayer.currentItem?.status == .failed
            || (avPlayer.currentItem == nil && lastAVItem?.status == .failed)
        if failedItem { _ = invalidateFailedLocalAudio(error: avPlayer.currentItem?.error ?? lastAVItem?.error) }
        if invalidatedLocalOccurrence == queue.current?.id, recoveryNetwork.status != .online,
           let song = queue.current?.song, audioStore?.completeStream(song.id) == nil {
            wantsToPlay = false
            isBuffering = false
            phase = .failed(PlaybackFailureReason.unavailable.message)
            updateNowPlaying()
            refreshAudioInformation()
            return
        }
        let failedPhase: Bool
        if case .failed = phase { failedPhase = true } else { failedPhase = false }
        if failedItem || failedPhase, let id = queue.current?.id { recovery.restart(for: id) }
        wantsToPlay = true
        if avPlayer.currentItem == nil || phase != .ready || failedItem {
            loadCurrent(at: timeAnchor.position, refreshStream: failedItem || failedPhase)
        } else {
            restoreStallWaiting()
            // From a standstill it plays at its own tempo again (`play` is rate 1), which is safe
            // where changing it while playing isn't; the coming transition is planned anew for it.
            let wasStretched = heardRate != 1
            heardRate = 1
            avPlayer.play()
            if wasStretched { armCrossfade() }
        }
        updateNowPlaying()
        prepareNext()
    }

    public func pause(from source: String = "unnamed caller") {
        cancelPlaylistLoading()
        cancelRadioLoading()
        pauseCurrentPlayback(from: source)
    }

    private func pauseCurrentPlayback(from source: String) {
        AutoMixLog.note("paused at \(position().s1) s by \(source)")
        silentSince = nil
        interruption.userPaused()
        restoredPlaybackWasActive = false
        mayResumeRestoredQueue = false
        cancelRecovery()
        stallWatchdog?.cancel()
        wantsToPlay = false
        isBuffering = false
        endTransition()
        finishTail()
        cancelFadeIn()
        avPlayer.pause()
        sampleTime()
        updateNowPlaying()
        persistQueue()
        refreshAudioInformation()
    }

    public func next() {
        cancelPlaylistLoading()
        guard let item = queue.current else { return }
        acceptExplicitPlayback()
        onPlaybackRequested?()
        wantsToPlay = true
        if savesSmartShuffleHistory { smartHistory.recordSkip(item.song) }
        cancelRecovery()
        if queue.peekNext(automatic: false) == nil {
            extendWithRadio(thenAdvance: true)
            return
        }
        cancelRadioLoading()
        move(to: queue.advance(automatic: false))
    }

    /// Back to the start of the song, or to the song before when already near the start.
    public func previous() {
        let wasFinished = isPlaybackSessionFinished
        cancelPlaylistLoading()
        cancelRadioLoading()
        guard queue.current != nil else { return }
        if queue.current != nil { acceptExplicitPlayback(); onPlaybackRequested?() }
        cancelRecovery()
        if wasFinished { wantsToPlay = true }
        if wasFinished, position() > 3 || queue.history.isEmpty && queue.repeatMode == .off {
            loadCurrent(at: 0)
            return
        }
        if position() > 3 || queue.history.isEmpty && queue.repeatMode == .off {
            seek(to: 0)
            return
        }
        let before = queue.current?.id
        queue.retreat()
        if queue.current?.id == before {
            seek(to: 0)
        } else {
            loadCurrent(at: 0, fadeIn: fadeOutForSkip())
        }
    }

    public func jump(to id: UUID) {
        cancelPlaylistLoading()
        guard id != queue.current?.id, queue.items.contains(where: { $0.id == id }) else { return }
        acceptExplicitPlayback()
        guard queue.jump(to: id) else { return }
        onPlaybackRequested?()
        cancelRadioLoading()
        cancelRecovery()
        wantsToPlay = true
        loadCurrent(at: 0, fadeIn: fadeOutForSkip())
    }

    public func seek(to seconds: TimeInterval) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        seekCurrentPlayback(to: seconds)
    }

    private func seekCurrentPlayback(to seconds: TimeInterval) {
        guard seconds.isFinite else { return }
        let wasRecovering = recovery.pending != nil || recovery.waitingForNetwork
        cancelRecovery()
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        if mixing != nil {
            // A seek mid-transition ends it: the old song goes, the new one plays plainly.
            endTransition()
            finishTail()
        }
        timeAnchor = TimeAnchor(position: target, date: Date(), rate: timeAnchor.rate)
        if isPlaybackSessionFinished { persistQueue(); return }
        if (wasRecovering || phase == .loading), wantsToPlay {
            loadCurrent(at: target)
            return
        }
        let seekEpoch = publicationEpoch
        let seekGeneration = generation
        avPlayer.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaybackSessionFinished, self.publicationEpoch == seekEpoch,
                      self.generation == seekGeneration else { return }
                self.sampleTime()
                self.updateNowPlaying()
            }
        }
    }

    /// Jump back (negative) or ahead within the song, held inside its length.
    public func skip(by seconds: TimeInterval) {
        guard queue.current != nil, phase == .ready else { return }
        seek(to: position() + seconds)
    }

    // MARK: - Queue editing

    public func setShuffle(_ on: Bool) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        smartShuffleSettings.enabled = false
        queue.setShuffle(on)
        queueChanged()
    }

    public func setSmartShuffle(_ on: Bool) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        smartShuffleSettings.enabled = on
        queue.setSmartShuffle(on, settings: smartShuffleSettings, context: shuffleContext())
        queueChanged()
    }

    public func clearSmartShuffleHistory() {
        smartHistory = SmartShuffleHistory()
        persistQueue()
    }

    private func shuffleContext() -> SmartShuffleContext {
        let external = smartShuffleContext?() ?? SmartShuffleContext()
        guard savesSmartShuffleHistory else { return SmartShuffleContext(likedSongIDs: external.likedSongIDs) }
        var context = smartHistory.context(likedSongIDs: external.likedSongIDs)
        if !external.recentSongIDs.isEmpty { context.recentSongIDs = Array(external.recentSongIDs.suffix(50)) }
        context.playCounts.merge(external.playCounts, uniquingKeysWith: max)
        context.skipCounts.merge(external.skipCounts, uniquingKeysWith: max)
        return context
    }

    public func cycleRepeat() {
        cancelPlaylistLoading()
        cancelRadioLoading()
        queue.repeatMode = queue.repeatMode.next
        queueChanged()
    }

    public func setRepeat(_ mode: RepeatMode) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        queue.repeatMode = mode
        queueChanged()
    }

    public func playNext(_ songs: [Song]) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        let wasEmpty = queue.isEmpty
        queue.playNext(songs)
        if wasEmpty {
            queue.retainCurrentCollection()
            if !songs.isEmpty { acceptExplicitPlayback(); onPlaybackRequested?() }
            wantsToPlay = true
            loadCurrent(at: 0)
        } else {
            queueChanged()
        }
    }

    public func addToQueue(_ songs: [Song]) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        let wasEmpty = queue.isEmpty
        queue.append(songs)
        if wasEmpty {
            queue.retainCurrentCollection()
            if !songs.isEmpty { acceptExplicitPlayback(); onPlaybackRequested?() }
            wantsToPlay = true
            loadCurrent(at: 0)
        } else {
            queueChanged()
        }
    }

    public func remove(_ id: UUID) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        if queue.remove(id) { queueChanged() }
    }

    public func moveUpcoming(fromOffsets source: IndexSet, toOffset destination: Int) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        queue.moveUpcoming(fromOffsets: source, toOffset: destination)
        queueChanged()
    }

    public func clearUpcoming() {
        cancelPlaylistLoading()
        cancelRadioLoading()
        queue.clearUpcoming()
        queueChanged()
    }

    public func restoreClearedUpcoming(_ songs: [Song]) {
        cancelPlaylistLoading()
        cancelRadioLoading()
        queue.restoreClearedUpcoming(songs)
        queueChanged()
    }

    /// Stop and empty the queue.
    public func stop() {
        finishPlaybackSession()
        queue.clear()
        duration = 0
        timeAnchor = TimeAnchor(position: 0, date: Date(), rate: 0)
        persistQueueNow()
    }

    private func queueChanged() {
        persistQueue()
        prepareNext()
        updateRemoteCommandState()
    }

    // MARK: - Loading

    /// Make the queue's current song the one AVFoundation plays, from `position`, fading it
    /// in over `fadeIn` seconds when a skip faded the last one out.
    private func loadCurrent(at position: TimeInterval, fadeIn: TimeInterval = 0, refreshStream: Bool = false) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        loadTask?.cancel()
        preloadTask?.cancel()
        autoMixPlanningTask?.cancel()
        manualHandoverTask?.cancel()
        formatTask?.cancel()
        generation += 1
        nextGeneration += 1
        let token = generation
        stallWatchdog?.cancel()
        endTransition()
        disarmCrossfade()
        discardStandby()
        autoMixPlan = nil
        planning = nil
        sleepEndItem = nil
        heardRate = 1
        avPlayer.removeAllItems()
        occurrences = [:]
        preloaded = []
        streamByItem = [:]
        currentStream = nil
        soundProcessingAvailable = nil
        measuredCodec = nil
        measuredSampleRate = nil
        measuredChannels = nil
        lastAVItem = nil
        queue.trimHistory(keeping: Self.historyLimit)
        guard let item = queue.current else {
            phase = .idle
            return
        }
        recovery.begin(for: item.id)
        // A song shown as playing from the old position would jump; show the new one at once.
        phase = .loading
        isBuffering = wantsToPlay
        duration = item.song.duration ?? 0
        timeAnchor = TimeAnchor(position: position, date: Date(), rate: 0)
        updateNowPlaying()
        persistQueue()
        if wantsToPlay && !interruption.isInterrupted && !activateAudioSession() {
            recordDiagnostic(.streamInitializationFailed, reason: .serviceUnavailable)
            applyRecovery(.stop(.serviceUnavailable), position: position)
            return
        }
        refreshAudioInformation()

        loadTask?.cancel()
        loadTask = Task {
            do {
                if refreshStream {
                    await music.invalidateStream(item.song.id)
                    guard !Task.isCancelled, token == generation, queue.current?.id == item.id,
                          !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
                }
                let stream = try await audio(for: item.song)
                guard !Task.isCancelled, token == generation, queue.current?.id == item.id,
                          !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
                let playerItem = makeItem(stream, song: item.song)
                preparedItems[ObjectIdentifier(playerItem)] = playerItem
                defer { preparedItems[ObjectIdentifier(playerItem)] = nil }
                if usesChannels {
                    // Its channel goes on before it plays; adding one to a playing item can glitch.
                    let channel = await TransitionDSP.attach(to: playerItem, label: item.song.title)
                    guard !Task.isCancelled, token == generation, queue.current?.id == item.id,
                          !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
                    soundProcessingAvailable = channel != nil
                }
                currentStream = stream
                invalidatedLocalOccurrence = nil
                streamByItem[ObjectIdentifier(playerItem)] = stream
                occurrences[ObjectIdentifier(playerItem)] = item.id
                // Watch before insertion: AVQueuePlayer can reject and remove a bad local
                // item before its asynchronous currentItem KVO callback reaches this actor.
                lastAVItem = playerItem
                watchStatus(of: playerItem, id: item.id)
                bindSleepEndItem(playerItem)
                avPlayer.insert(playerItem, after: nil)
                if position > 1 {
                    await avPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, token == generation, !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
                }
                // A rejected local item can complete its seek before its status observer
                // reaches this actor. Never publish that item's empty clock as a successful
                // resume: recovery still belongs at the requested position.
                if playerItem.status == .failed {
                    recover(item.id, at: position, error: playerItem.error)
                    return
                }
                if let total = stream.duration, total > 0 { duration = total }
                applyLoudness(stream)
                if fadeIn > 0 { startFadeIn(over: fadeIn) } else { cancelFadeIn() }
                phase = .ready
                restoreStallWaiting()
                if wantsToPlay && !interruption.isInterrupted { avPlayer.play() }
                sampleTime()
                refreshAudioInformation()
                measureAudioFormat(of: playerItem, occurrence: item.id, generation: token)
                updateNowPlaying()
                prepareNext()
                armCrossfade()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, token == generation, queue.current?.id == item.id,
                          !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
                handleLoadFailure(error, for: item)
            }
        }
    }

    private func handleLoadFailure(_ error: Error, for item: QueueItem) {
        guard queue.current?.id == item.id else { return }
        recordDiagnostic(.streamInitializationFailed, reason: PlaybackFailureReason.classify(error))
        recover(item.id, at: position(), error: error)
    }

    /// Keep the next song loaded, matching what the queue says plays next: behind the current
    /// one in AVFoundation's queue, or with crossfade on, on the standby player.
    private func prepareNext() {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard phase == .ready, let currentItem = avPlayer.currentItem,
              let currentId = occurrences[ObjectIdentifier(currentItem)], currentId == queue.current?.id else { return }
        let wanted = queue.peekNext(automatic: true)
        let queued = avPlayer.items().dropFirst()
        if usesStandby {
            removeFromQueuePlayer(queued)
            if let wanted, standby?.id == wanted.id { return }
        } else {
            discardStandby()
            if let wanted, queued.count == 1, let loaded = queued.first, occurrences[ObjectIdentifier(loaded)] == wanted.id {
                return
            }
            removeFromQueuePlayer(queued)
        }
        discardStandby()
        nextGeneration += 1
        let token = nextGeneration
        guard let wanted else {
            if autoplay, queue.upcoming.isEmpty, queue.repeatMode == .off { extendWithRadio(thenAdvance: false) }
            return
        }
        let onStandby = usesStandby
        let withMix = autoMix
        let withChannel = usesChannels
        preloadTask?.cancel()
        preloadTask = Task {
            guard let stream = try? await audio(for: wanted.song), !Task.isCancelled,
                  token == nextGeneration, !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
            let item = makeItem(stream, song: wanted.song)
            preparedItems[ObjectIdentifier(item)] = item
            defer { preparedItems[ObjectIdentifier(item)] = nil }
            // Checked again after the stream: the equalizer may have gone on while it loaded.
            if withChannel || usesChannels { _ = await TransitionDSP.attach(to: item, label: wanted.song.title) }
            guard !Task.isCancelled, !isPlaybackSessionFinished, !evaluateSleepTimer(),
                  token == nextGeneration, queue.current?.id == currentId,
                  queue.peekNext(automatic: true)?.id == wanted.id,
                  let playing = avPlayer.currentItem, occurrences[ObjectIdentifier(playing)] == currentId,
                  avPlayer.items().count == 1, standby == nil, usesStandby == onStandby, autoMix == withMix else { return }
            occurrences[ObjectIdentifier(item)] = wanted.id
            streamByItem[ObjectIdentifier(item)] = stream
            preloaded.insert(ObjectIdentifier(item))
            trace("preloaded \(wanted.song.title)\(onStandby ? " on standby" : "")")
            if onStandby {
                // Paused, it still buffers, so it can start the moment the fade does.
                let player = AVQueuePlayer()
                player.isMuted = isMuted
                player.volume = 0
                // AutoMix starts it at a set moment on the clock, which needs it not to wait on its own.
                if withMix { player.automaticallyWaitsToMinimizeStalling = false }
                player.insert(item, after: nil)
                standby = (player, item, wanted.id, stream)
                if withMix { planAutoMix() }
            } else {
                avPlayer.insert(item, after: playing)
            }
        }
    }

    /// Channels for the songs already loaded, so the equalizer is heard on the playing one now.
    private func giveLoadedSongsChannels() {
        var items = avPlayer.items()
        if let standby { items.append(standby.item) }
        for item in items where TransitionDSP.of(item) == nil {
            let id = ObjectIdentifier(item)
            guard attachingChannels.insert(id).inserted else { continue }
            let title = occurrences[id].flatMap { id in queue.items.first { $0.id == id }?.song.title } ?? "song"
            channelTasks[id] = Task { [weak self] in
                defer { self?.attachingChannels.remove(id); self?.channelTasks[id] = nil }
                let channel = await TransitionDSP.attach(to: item, label: title)
                guard !Task.isCancelled, let self, !self.isPlaybackSessionFinished else { return }
                if self.avPlayer.currentItem === item { self.soundProcessingAvailable = channel != nil }
            }
        }
    }

    private func removeFromQueuePlayer(_ items: some Sequence<AVPlayerItem>) {
        for stale in items {
            occurrences[ObjectIdentifier(stale)] = nil
            streamByItem[ObjectIdentifier(stale)] = nil
            preloaded.remove(ObjectIdentifier(stale))
            avPlayer.remove(stale)
        }
    }

    private func discardStandby() {
        guard let standby else { return }
        occurrences[ObjectIdentifier(standby.item)] = nil
        streamByItem[ObjectIdentifier(standby.item)] = nil
        preloaded.remove(ObjectIdentifier(standby.item))
        standby.player.removeAllItems()
        self.standby = nil
        applyOutputBudget()
    }

    /// The song's audio: its file when the phone holds all of it, else a stream from YouTube.
    private func audio(for song: Song) async throws -> ResolvedStream {
        if let streamLoader { return try await streamLoader(song, streamQuality) }
        if let file = audioStore?.completeStream(song.id) { return file }
        if let remoteStreamLoader { return try await remoteStreamLoader(song, streamQuality) }
        return try await music.stream(for: song.id, quality: streamQuality)
    }

    private func makeItem(_ original: ResolvedStream, song: Song) -> AVPlayerItem {
        let stream = streamRewriter?(original) ?? original
        let asset: AVURLAsset
        // A Data Saver stream isn't kept: the song's file should be the best it can be.
        if !stream.url.isFileURL, cachesWhileStreaming, !stream.isDataSaver, streamRewriter == nil, let audioStore,
           let loader = CachingLoader(stream: stream, song: song, store: audioStore) {
            asset = loader.makeAsset()
        } else {
            asset = AVURLAsset(url: stream.url, options: [AVURLAssetHTTPUserAgentKey: stream.userAgent])
        }
        let item = AVPlayerItem(asset: asset)
        // AVFoundation reads YouTube's fragmented M4A as twice its real length
        // and plays silence for the second half instead of ending. [verified
        // October 2026: 403.1 s reported for a 201.6 s track] YouTube's own
        // duration is exact, so the item is told where it ends.
        if let duration = stream.duration, duration > 0 {
            item.forwardPlaybackEndTime = CMTime(seconds: duration, preferredTimescale: 1000)
        }
        item.preferredForwardBufferDuration = 30
        // AutoMix plays songs a few percent faster or slower to meet a tempo; spectral keeps that clean.
        item.audioTimePitchAlgorithm = autoMix ? .spectral : .timeDomain
        return item
    }

    private func applySoundSettings() {
        TransitionDSP.setSoundSettings(soundSettings, preset: equalizer)
        if usesChannels { giveLoadedSongsChannels() }
        applyLoudness(currentLoudnessDb)
    }

    /// A complete profile reaches every current/standby/tail channel as one configuration.
    /// Neither selecting a preset nor changing outputs replaces a player or seeks a song.
    public func applySoundProfile(_ settings: SoundSettings, preset: EqualizerPreset) {
        noteManualSoundChange()
        installSoundProfile(settings, preset: preset, automatically: false)
    }

    public func saveSoundProfiles(_ profiles: [SoundProfile]) {
        SoundSettingsStore.saveProfiles(profiles, defaults: preferenceDefaults)
        soundProfiles = SoundSettingsStore.profiles(defaults: preferenceDefaults)
        // Editing a saved profile updates its binding; deleting it never silently picks
        // another profile. A manual override still wins over a background store refresh.
        scheduleDeviceSoundApplication(resetOverride: false)
    }

    public func useDeviceSoundBinding() { scheduleDeviceSoundApplication(resetOverride: true) }
    public func keepCurrentDeviceSound() {
        noteManualSoundChange(cancelOutputRamp: false)
        applyLoudness(currentLoudnessDb)
    }

    private func noteManualSoundChange(cancelOutputRamp: Bool = true) {
        guard !restoringSoundSettings else { return }
        soundRoutePolicy.override()
        deviceSoundTask?.cancel()
        deviceSoundTask = nil
        if cancelOutputRamp {
            soundOutputRampTask?.cancel()
            soundOutputRampTask = nil
            routedOutputLimit = nil
        }
        deviceSoundManuallyOverridden = deviceSoundSettings.enabled
        appliedDeviceSound = nil
        deviceSoundProfileMissing = false
    }

    private func installSoundProfile(_ settings: SoundSettings, preset: EqualizerPreset, automatically: Bool) {
        let previousLimit = routedOutputLimit ?? soundSettings.normalized.outputLimit
        let normalized = settings.normalized
        soundOutputRampTask?.cancel()
        soundOutputRampTask = nil
        routedOutputLimit = automatically ? min(previousLimit, normalized.outputLimit) : nil
        applyingSoundSelection = true
        equalizer = preset
        soundSettings = normalized
        applyingSoundSelection = false
        persistSettings()
        SoundSettingsStore.save(normalized, defaults: preferenceDefaults)
        applySoundSettings()
        if automatically, normalized.outputLimit > previousLimit {
            soundOutputRampTask = Task { [weak self] in
                await Self.ramp(over: 0.25) { progress in
                    guard let self else { return }
                    self.routedOutputLimit = DeviceSoundOutputRamp.limit(from: previousLimit, to: normalized.outputLimit, progress: progress)
                    self.applyLoudness(self.currentLoudnessDb)
                }
                guard !Task.isCancelled, let self else { return }
                self.routedOutputLimit = nil
                self.applyLoudness(self.currentLoudnessDb)
                self.soundOutputRampTask = nil
            }
        } else { routedOutputLimit = nil }
    }

    /// Exposed for refreshing Settings; route notifications use the same debounced path.
    public func refreshAudioOutputRoute() {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { port in
            let kind: AudioOutputDevice.Kind
            switch port.portType {
            case .builtInSpeaker, .builtInReceiver: kind = .speaker
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: kind = .bluetooth
            case .usbAudio: kind = .usb
            case .headphones, .lineOut: kind = .wired
            case .airPlay: kind = .airPlay
            case .HDMI, .displayPort, .carAudio: kind = .other
            default: kind = .unknown
            }
            return AudioOutputDevice(kind: kind, name: port.portName, identifier: port.uid)
        }
        receiveAudioOutputRoute(AudioOutputRoute(outputs: outputs))
        #endif
    }

    /// Test seam supplies the exact metadata that AVAudioSession reports, without touching
    /// the shared system route. Duplicate notifications cannot undo a manual override.
    func receiveAudioOutputRoute(_ route: AudioOutputRoute) {
        audioOutputRoute = route
        guard soundRoutePolicy.observe(route) != nil else { return }
        deviceSoundManuallyOverridden = false
        appliedDeviceSound = nil
        deviceSoundProfileMissing = false
        scheduleDeviceSoundApplication(resetOverride: false)
    }

    private func scheduleDeviceSoundApplication(resetOverride: Bool) {
        guard !isPlaybackSessionFinished else { return }
        deviceSoundTask?.cancel()
        let ticket = soundRoutePolicy.invalidate(resetOverride: resetOverride)
        if resetOverride { deviceSoundManuallyOverridden = false }
        if !deviceSoundSettings.enabled {
            // Switching automation off keeps the profile already installed. Let its
            // bounded 250 ms gain easing finish rather than jumping or freezing halfway.
            appliedDeviceSound = nil
            deviceSoundProfileMissing = false
            deviceSoundManuallyOverridden = false
            return
        }
        deviceSoundTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self, !Task.isCancelled, self.soundRoutePolicy.accepts(ticket) else { return }
            self.applyCurrentDeviceSound()
            self.deviceSoundTask = nil
        }
    }

    func applyCurrentDeviceSound() {
        appliedDeviceSound = nil
        deviceSoundProfileMissing = false
        let selection = soundRoutePolicy.selection(settings: deviceSoundSettings.normalized)
        deviceSoundManuallyOverridden = selection == .manual
        guard case .apply(let target) = selection else { return }
        guard let selected = target.resolve(profiles: soundProfiles, current: soundSettings) else {
            appliedDeviceSound = nil
            deviceSoundProfileMissing = true
            return
        }
        deviceSoundProfileMissing = false
        deviceSoundManuallyOverridden = false
        appliedDeviceSound = target
        guard soundSettings != selected.settings || equalizer != selected.preset else { return }
        installSoundProfile(selected.settings, preset: selected.preset, automatically: true)
    }

    private var limitedOutputGain: Float {
        min(soundSettings.outputGain(for: volume), routedOutputLimit ?? 1)
    }

    /// Bring loud masters down to YouTube's -14 LUFS target; quiet ones are left alone rather than boosted.
    private func applyLoudness(_ stream: ResolvedStream) {
        applyLoudness(stream.loudnessDb)
    }

    private func applyLoudness(_ loudnessDb: Double?) {
        currentLoudnessDb = loudnessDb
        let gain = limitedOutputGain
        baseVolume = gain * normalizationGain(for: loudnessDb)
        applyOutputBudget()
    }

    private func normalizationGain(for loudnessDb: Double?) -> Float {
        guard normalizesVolume, let db = loudnessDb, db.isFinite, db > 0 else { return 1 }
        return Float(max(0.4, pow(10, -db / 20)))
    }

    /// All concurrently audible players share one cap, including the old song during a
    /// crossfade/AutoMix handover. Per-channel DSP bounds samples before this mix budget.
    private func applyOutputBudget() {
        let limit = limitedOutputGain
        var players = [avPlayer]
        var desired: [Float] = [tail != nil && avPlayer.currentItem == nil ? 0 : baseVolume * fadeGain * outputReleaseGain]
        if let tail, tail !== avPlayer {
            players.append(tail)
            desired.append(limit * normalizationGain(for: tailLoudnessDb) * tailFadeGain)
        }
        if let standby, !players.contains(where: { $0 === standby.player }) {
            players.append(standby.player)
            desired.append(0) // Its budget is assigned before it becomes audible.
        }
        let target = OutputGainBudget.allocate(requested: desired, limit: limit)
        for index in OutputGainBudget.updateOrder(current: players.map(\.volume), target: target) {
            players[index].volume = target[index]
        }
    }

    // MARK: - Crossfade

    /// Watch for the moment the playing song is `crossfadeDuration` from its end. A boundary
    /// observer fires only when playback runs across that moment, so seeking past it doesn't.
    private func armCrossfade() {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        disarmCrossfade()
        guard !stopsAtEndOfSong, usesStandby, phase == .ready, let item = avPlayer.currentItem,
              let id = occurrences[ObjectIdentifier(item)], item.forwardPlaybackEndTime.isValid else { return }
        let end = item.forwardPlaybackEndTime.seconds
        if autoMix {
            if let entry = autoMixPlan, entry.key.from == id, standby?.id == entry.key.to, entry.key.outgoingRate == heardRate,
               item.currentTime().seconds < entry.plan.cue - Self.autoMixLead {
                let moment = max(0.1, entry.plan.cue - Self.autoMixLead)
                let at = NSValue(time: CMTime(seconds: moment, preferredTimescale: 600))
                crossfadeObserver = avPlayer.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
                    MainActor.assumeIsolated { self?.startAutoMix(from: id) }
                }
                trace("AutoMix armed at \(moment)")
                return
            }
            // Until the plan is ready a plain crossfade stands in.
            planAutoMix()
        }
        // A short song keeps most of itself unfaded.
        guard end.isFinite, end > crossfadeDuration * 2 + 10 else { return }
        let at = NSValue(time: CMTime(seconds: end - crossfadeDuration, preferredTimescale: 600))
        crossfadeObserver = avPlayer.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.crossfade(from: id) }
        }
    }

    private func disarmCrossfade() {
        if let crossfadeObserver { avPlayer.removeTimeObserver(crossfadeObserver) }
        crossfadeObserver = nil
    }

    /// The song `id` is about to end: fade it out over what's left while the next song fades
    /// in on the standby player. Only when that is the song the queue will play anyway, which
    /// under repeat one is the same song again, waiting from its start.
    private func crossfade(from id: UUID) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard usesStandby, wantsToPlay, !stopsAtEndOfSong,
              let item = avPlayer.currentItem, occurrences[ObjectIdentifier(item)] == id, queue.current?.id == id,
              let standby, standby.id == queue.peekNext(automatic: true)?.id else { return }
        if autoMix { AutoMixLog.note("no plan in time for \(queue.current?.song.title ?? "?"): plain \(crossfadeDuration.s1) s crossfade") }
        let left = item.forwardPlaybackEndTime.seconds - item.currentTime().seconds
        let fade = min(crossfadeDuration, max(1, left))
        trace("crossfade over \(fade)s")
        switchToStandby(fading: fade)
    }

    /// Make the standby player the main one and play its song, fading the old song out and
    /// the new one in over `fade` seconds (none: straight on).
    private func switchToStandby(fading fade: TimeInterval) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard let next = standby else { return }
        standby = nil
        autoMixPlan = nil
        // `play` below starts it at its own tempo.
        heardRate = 1
        retireMain(fading: fade)
        adopt(next.player)
        currentStream = next.stream
        applyLoudness(next.stream)
        // A standby set up for a scheduled start goes back to riding out network waits.
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        if fade > 0 { startFadeIn(over: fade) } else { cancelFadeIn() }
        if wantsToPlay && !interruption.isInterrupted { avPlayer.play() }
        // The new player's item was current from the start, so no change is observed; say it.
        currentItemChanged(ObjectIdentifier(next.item))
    }

    /// A skip with crossfade on: the playing song fades out quickly on the side while a fresh
    /// player loads the next. Returns the fade-in the song that replaces it should get.
    private func fadeOutForSkip() -> TimeInterval {
        guard usesStandby, avPlayer.timeControlStatus == .playing else { return 0 }
        retireMain(fading: Self.skipFade)
        adopt(AVQueuePlayer())
        return Self.skipFade
    }

    /// Let the main player go: fading its song out over `fade` seconds when it is playing,
    /// otherwise silenced at once. Its songs stop counting as the queue's.
    /// With `hold`, it plays on for that long after any fade before being let go: AutoMix's
    /// outgoing song, whose fade is in its mixer channel.
    private func retireMain(fading fade: TimeInterval, hold: TimeInterval? = nil) {
        let old = avPlayer
        detach(old)
        for item in old.items() {
            occurrences[ObjectIdentifier(item)] = nil
            streamByItem[ObjectIdentifier(item)] = nil
            preloaded.remove(ObjectIdentifier(item))
        }
        lastAVItem = nil
        itemStatusObservation = nil
        stallWatchdog?.cancel()
        finishTail()
        guard fade > 0 || hold != nil, old.timeControlStatus == .playing else {
            old.pause()
            old.removeAllItems()
            return
        }
        fadeIn?.cancel()
        fadeIn = nil
        let outgoingFade = fadeGain
        old.actionAtItemEnd = .pause
        tail = old
        tailLoudnessDb = currentLoudnessDb
        tailFadeGain = outgoingFade
        tailFade = Task { [weak self] in
            if fade > 0 {
                await Self.ramp(over: fade) { progress in
                    guard let self, self.tail === old else { return }
                    self.tailFadeGain = outgoingFade * Float(cos(progress * .pi / 2))
                    self.applyOutputBudget()
                }
            }
            if let hold { try? await Task.sleep(for: .seconds(max(0, hold - fade))) }
            guard !Task.isCancelled else { return }
            if hold != nil { AutoMixLog.note("old song's player released") }
            self?.finishTail(smoothRelease: hold != nil && fade == 0)
        }
    }

    /// `player` becomes the main player, with the observers and settings the main one has.
    private func adopt(_ player: AVQueuePlayer) {
        player.volume = 0
        outputReleaseTask?.cancel()
        outputReleaseTask = nil
        outputReleaseGain = 1
        avPlayer = player
        fadeGain = 0
        player.isMuted = isMuted
        player.actionAtItemEnd = stopsAtEndOfSong ? .pause : .advance
        attach(player)
        applyOutputBudget()
    }

    /// Silence and release the song fading out, if there is one.
    private func finishTail(smoothRelease: Bool = false) {
        let previousGain = avPlayer.volume
        let shouldSmooth = smoothRelease && tail != nil && tail !== avPlayer
        tailFade?.cancel()
        tailFade = nil
        tail?.pause()
        tail?.removeAllItems()
        tail = nil
        tailLoudnessDb = nil
        tailFadeGain = 0
        outputReleaseTask?.cancel()
        outputReleaseTask = nil
        outputReleaseGain = 1
        let desired = baseVolume * fadeGain
        if shouldSmooth, desired > 0 {
            let start = min(1, max(0, previousGain / desired))
            outputReleaseGain = start
            outputReleaseTask = Task { [weak self] in
                await Self.ramp(over: 0.08) { progress in
                    guard let self else { return }
                    self.outputReleaseGain = start + (1 - start) * Float(progress)
                    self.applyOutputBudget()
                }
            }
        }
        applyOutputBudget()
    }

    private func startFadeIn(over fade: TimeInterval, after delay: TimeInterval = 0) {
        fadeIn?.cancel()
        fadeGain = 0
        applyOutputBudget()
        fadeIn = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            await Self.ramp(over: fade) { progress in
                guard let self else { return }
                self.fadeGain = Float(sin(progress * .pi / 2))
                self.applyOutputBudget()
            }
        }
    }

    /// Back to full volume at once.
    private func cancelFadeIn() {
        fadeIn?.cancel()
        fadeIn = nil
        fadeGain = 1
        applyOutputBudget()
    }

    /// Calls `step` with progress from 0 to 1, about 30 times a second, for `duration` seconds.
    private static func ramp(over duration: TimeInterval, _ step: @MainActor (Double) -> Void) async {
        guard duration.isFinite, duration > 0 else { step(1); return }
        let clock = ContinuousClock()
        let start = clock.now
        while !Task.isCancelled {
            let elapsed = start.duration(to: clock.now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let progress = min(1, max(0, seconds / duration))
            step(progress)
            if progress >= 1 { return }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    // MARK: - AutoMix

    private func autoMixAnalyzer() -> AutoMixAnalyzer {
        if let analyzer { return analyzer }
        let made = AutoMixAnalyzer(store: audioStore, directory: storage)
        analyzer = made
        return made
    }

    /// Measure the current song and the one on standby, then plan the handover between them
    /// and arm it. Until it's ready the plain crossfade stays armed.
    private func planAutoMix() {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard autoMix, phase == .ready, let item = avPlayer.currentItem,
              let fromId = occurrences[ObjectIdentifier(item)], let from = queue.current, from.id == fromId,
              let next = standby, let to = queue.peekNext(automatic: true), to.id == next.id,
              let fromStream = currentStream, fromStream.videoId == from.song.id else { return }
        let key = PlanKey(from: fromId, to: next.id, outgoingRate: heardRate)
        if autoMixPlan?.key == key || planning == key { return }
        planning = key
        let analyzer = autoMixAnalyzer()
        let neighbours = !queue.isShuffled && from.song.album != nil && from.song.album?.id == to.song.album?.id
            && from.song.id != to.song.id
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : duration
        let toStream = next.stream
        autoMixPlanningTask?.cancel()
        autoMixPlanningTask = Task {
            async let outgoing = analyzer.analysis(for: fromStream, title: from.song.title)
            async let incoming = analyzer.analysis(for: toStream, title: to.song.title)
            let (a, b) = await (outgoing, incoming)
            if planning == key { planning = nil }
            guard !Task.isCancelled, !isPlaybackSessionFinished, !evaluateSleepTimer(),
                  autoMix, queue.current?.id == fromId, standby?.id == next.id else { return }
            guard let a, let b else {
                AutoMixLog.note("plan \(from.song.title) → \(to.song.title): no measurements, plain crossfade")
                return
            }
            guard let plan = TransitionPlanner.plan(from: a, to: b, context: .init(outgoingEnd: end, albumNeighbours: neighbours,
                                                                                    outgoingRate: key.outgoingRate)) else {
                AutoMixLog.note("plan \(from.song.title) → \(to.song.title): too short to mix, plain crossfade")
                return
            }
            AutoMixLog.note("plan \(from.song.title) → \(to.song.title): \(plan.summary)")
            // The next song waits at its entry point, decoded and ready to start on the instant.
            let player = next.player
            if plan.inStart > 0.01 {
                await player.seek(to: CMTime(seconds: plan.inStart, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            guard !Task.isCancelled, !isPlaybackSessionFinished, !evaluateSleepTimer(),
                  autoMix, queue.current?.id == fromId, standby?.id == next.id else { return }
            if player.status == .readyToPlay, player.rate == 0 {
                player.preroll(atRate: Float(plan.rate * key.outgoingRate)) { ready in
                    if !ready { AutoMixLog.note("preroll of \(to.song.title) didn't finish") }
                }
            }
            autoMixPlan = (key, plan)
            if position() > plan.cue - Self.autoMixLead {
                AutoMixLog.note("plan came after its cue (at \(position().s1) s); plain crossfade this time")
            }
            armCrossfade()
        }
    }

    /// The plan's moment is a breath away: hand the moves to both mixer channels, schedule the
    /// next song to start exactly when the playing one reaches the cue, and make it the main player.
    private func startAutoMix(from id: UUID) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard autoMix, wantsToPlay, !stopsAtEndOfSong, let item = avPlayer.currentItem,
              occurrences[ObjectIdentifier(item)] == id, queue.current?.id == id,
              let next = standby, let to = queue.peekNext(automatic: true), next.id == to.id,
              let entry = autoMixPlan, entry.key == PlanKey(from: id, to: next.id, outgoingRate: heardRate) else {
            AutoMixLog.note("cue reached but the queue moved on; no transition")
            return
        }
        let plan = entry.plan
        // The plan is in the songs' own seconds; the outgoing one may be playing stretched.
        let outgoingRate = heardRate
        let playerRate = plan.rate * outgoingRate
        let overlap = plan.overlap / outgoingRate
        let fromTitle = queue.current?.song.title ?? "?"
        let fromArtwork = queue.current?.song.artwork
        let fromDuration = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : duration
        let outgoing = avPlayer
        let outgoingDSP = TransitionDSP.of(item)
        let incomingDSP = TransitionDSP.of(next.item)

        // When the playing song reaches the cue, on the host clock both players run on.
        let host = CMClockGetHostTimeClock()
        let cueTime = CMTime(seconds: plan.cue, preferredTimescale: 48_000)
        var hostCue = CMTime.invalid
        if let timebase = item.timebase {
            hostCue = CMSyncConvertTime(cueTime, from: timebase, to: host)
        }
        let wait = hostCue.isValid ? (hostCue - CMClockGetTime(host)).seconds : Self.autoMixLead
        let scheduled = hostCue.isValid && wait > 0.01 && wait < 2 && next.item.status == .readyToPlay
            && !next.player.isExternalPlaybackActive && outgoing.rate > 0

        outgoingDSP?.set(plan.outgoing)
        incomingDSP?.set(plan.incoming)
        autoMixPlan = nil
        standby = nil
        // Without a channel the old song falls back to a volume fade.
        retireMain(fading: outgoingDSP == nil ? max(1, overlap) : 0, hold: max(0, wait) + overlap + 0.4)
        adopt(next.player)
        currentStream = next.stream
        applyLoudness(next.stream.loudnessDb)
        // A short outer edge fade keeps the shared budget continuous when DSP owns the
        // longer envelopes. Wait for the scheduled start instead of ducking the old song early.
        let incomingFade = incomingDSP == nil && plan.style != .gapless ? max(0.5, min(overlap, 3)) : 0.08
        startFadeIn(over: incomingFade, after: max(0, wait))
        scheduledStart = Date().addingTimeInterval(max(0, wait))
        // Set before the queue moves on, so the next transition is planned from this rate.
        heardRate = playerRate
        if scheduled {
            avPlayer.automaticallyWaitsToMinimizeStalling = false
            avPlayer.setRate(Float(playerRate), time: .invalid, atHostTime: hostCue)
        } else {
            let player = avPlayer
            let rate = Float(playerRate)
            scheduledPlaybackTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, wait))) } catch { return }
                guard !Task.isCancelled, let self, self.avPlayer === player, self.wantsToPlay,
                      !self.interruption.isInterrupted, !self.isPlaybackSessionFinished, !self.evaluateSleepTimer() else { return }
                player.rate = rate
                self.scheduledPlaybackTask = nil
            }
        }
        currentItemChanged(ObjectIdentifier(next.item))
        // It starts at its entry point, not at zero.
        timeAnchor = TimeAnchor(position: plan.inStart, date: Date().addingTimeInterval(max(0, wait)), rate: playerRate)
        updateNowPlaying()
        if plan.style != .gapless {
            let started = Date().addingTimeInterval(max(0, wait))
            mixing = Mixing(style: plan.style, from: fromTitle, to: to.song.title, fromArtwork: fromArtwork, started: started,
                            overlap: overlap, fromPosition: plan.cue, fromDuration: fromDuration,
                            beat: plan.firstBeat.map { started.addingTimeInterval(($0 - plan.cue) / outgoingRate) },
                            beatPeriod: plan.beatPeriod.map { $0 / outgoingRate })
        }
        AutoMixLog.note("start \(fromTitle) → \(to.song.title): \(plan.style.rawValue) at rate \(String(format: "%.4f", playerRate)), "
            + (scheduled ? "scheduled on the clock in \(wait.s2) s" : "NOT scheduled (timebase \(item.timebase != nil), ready \(next.item.status == .readyToPlay), airplay \(next.player.isExternalPlaybackActive)); started by timer")
            + ", channels out \(outgoingDSP != nil) in \(incomingDSP != nil)")
        let incoming = avPlayer
        let incomingItem = next.item
        transitionTask = Task { [weak self] in
            await self?.follow(plan, overlap: overlap, outgoing: outgoing, outgoingItem: item, incoming: incoming, incomingItem: incomingItem,
                               wait: max(0, wait), outgoingDSP: outgoingDSP, incomingDSP: incomingDSP)
        }
    }

    /// Watch a transition through: how close the two songs' clocks landed to the plan, both
    /// channels' levels as it goes, then the channel opened. `overlap` is in real seconds.
    private func follow(_ plan: TransitionPlan, overlap: TimeInterval, outgoing: AVQueuePlayer, outgoingItem: AVPlayerItem, incoming: AVQueuePlayer,
                        incomingItem: AVPlayerItem, wait: TimeInterval, outgoingDSP: TransitionDSP?, incomingDSP: TransitionDSP?) async {
        func db(_ level: Float) -> String { level > 0.00001 ? (20 * log10(Double(level))).s1 : "-inf" }
        try? await Task.sleep(for: .seconds(wait + min(0.6, max(0.1, overlap / 2))))
        guard !Task.isCancelled else { return }
        scheduledStart = nil
        let outNow = outgoingItem.currentTime().seconds
        let inNow = incomingItem.currentTime().seconds
        // With no overlap the old song has already stopped at its end; there is nothing to compare.
        if plan.overlap > 0, tail === outgoing, outNow.isFinite, inNow.isFinite {
            let expected = plan.incomingTime(outNow)
            let error = (inNow - expected) * 1000
            AutoMixLog.note("alignment: outgoing at \(outNow.s2), incoming at \(inNow.s2), expected \(expected.s2): "
                + "\(String(format: "%+.0f", error)) ms\(abs(error) > 30 ? "  <-- OFF" : "")")
        }
        sampleTime()
        updateNowPlaying()
        // Levels through the blend, every half second.
        let finish = Date().addingTimeInterval(max(0, overlap - min(0.6, max(0.1, overlap / 2))))
        while Date() < finish, !Task.isCancelled {
            var parts: [String] = []
            if let m = outgoingDSP?.meter, tail === outgoing {
                parts.append("out t=\(m.time.s2) peak \(db(m.peak)) dB gain \(String(format: "%.2f", m.gain)) hp \(Int(m.highPass)) lp \(Int(m.lowPass))")
            }
            if let m = incomingDSP?.meter {
                parts.append("in t=\(m.time.s2) peak \(db(m.peak)) dB gain \(String(format: "%.2f", m.gain)) hp \(Int(m.highPass)) rate \(String(format: "%.3f", incoming.rate))")
            }
            if !parts.isEmpty { AutoMixLog.note("  " + parts.joined(separator: " | ")) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard !Task.isCancelled else { return }
        if mixing != nil { mixing = nil }
        // Open the channel so seeking back over the entry doesn't play the moves again.
        if avPlayer === incoming { incomingDSP?.clear() }
        // The new song keeps its matched rate, and its scheduled-start buffering, until it next
        // stops. On iOS 27 a playing AVPlayer's rate or stalling mode changed under it makes
        // mediaplaybackd begin an interruption and rebuild the route each time, with no end: it
        // went on "playing" in silence until paused (Espresso looping into itself, eased from
        // 0.9995 to 1, October 2026). `resume` and `loadCurrent` restore both from a standstill.
        AutoMixLog.note("done \(plan.style.rawValue); rate stays \(String(format: "%.4f", incoming.rate)) until the song stops")
    }

    /// Stop following a transition and leave the new song playing plainly: its channel opened
    /// smoothly. Its rate is left alone while it plays (see `follow`).
    private func endTransition() {
        scheduledPlaybackTask?.cancel()
        scheduledPlaybackTask = nil
        transitionTask?.cancel()
        transitionTask = nil
        scheduledStart = nil
        guard mixing != nil else { return }
        mixing = nil
        if let item = avPlayer.currentItem, let dsp = TransitionDSP.of(item) {
            dsp.release(at: item.currentTime().seconds)
        }
        AutoMixLog.note("transition cut short")
    }

    /// Back to riding out network waits, from a standstill only (see `follow`): a standby set up
    /// for a scheduled start doesn't wait, and a playing player mustn't be switched.
    private func restoreStallWaiting() {
        guard avPlayer.timeControlStatus == .paused, !avPlayer.automaticallyWaitsToMinimizeStalling else { return }
        avPlayer.automaticallyWaitsToMinimizeStalling = true
    }

    /// For trying transitions out: jump to a few seconds before the planned one (or the end).
    public func jumpToTransition(lead: TimeInterval = 10) {
        guard phase == .ready, let id = queue.current?.id else { return }
        let target: TimeInterval
        if let entry = autoMixPlan, entry.key.from == id {
            target = entry.plan.cue - lead
            AutoMixLog.note("jump to \(target.s1) s, \(lead.s1) s before the \(entry.plan.style.rawValue) cue")
        } else {
            target = duration - crossfadeDuration - lead
            AutoMixLog.note("jump to \(target.s1) s; no AutoMix plan yet (planning \(planning != nil), standby \(standby != nil))")
        }
        seek(to: max(0, target))
    }

    /// Move to `item` after a skip: instantly when it is the preloaded one, otherwise by loading it.
    private func move(to item: QueueItem?) {
        guard let item else { return }
        wantsToPlay = true
        let queued = avPlayer.items()
        if phase == .ready, let standby, standby.id == item.id {
            // AutoMix may have parked the standby at a later musical entry point. A manual
            // skip always starts the requested track at zero, before making it audible.
            let token = generation
            let nextToken = nextGeneration
            standby.player.pause()
            manualHandoverTask?.cancel()
            manualHandoverTask = Task { [weak self] in
                let sought = await standby.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, let self, !isPlaybackSessionFinished, !evaluateSleepTimer(),
                      generation == token, nextGeneration == nextToken,
                      queue.current?.id == item.id, self.standby?.player === standby.player else { return }
                guard sought else {
                    loadCurrent(at: 0, fadeIn: fadeOutForSkip())
                    return
                }
                switchToStandby(fading: avPlayer.timeControlStatus == .playing ? Self.skipFade : 0)
            }
        } else if phase == .ready, queued.count == 2, occurrences[ObjectIdentifier(queued[1])] == item.id {
            occurrences[ObjectIdentifier(queued[0])] = nil
            avPlayer.advanceToNextItem()
            avPlayer.play()
            // currentItem's observer takes it from here.
        } else {
            loadCurrent(at: 0, fadeIn: fadeOutForSkip())
        }
    }

    private func cancelRadioLoading() {
        radioRequestGeneration += 1
        radioTask?.cancel()
        radioTask = nil
        radioRequest = nil
    }

    /// A prefetch and a later end-of-queue event share one request. The latter upgrades its
    /// demand to advance; a pause or a newer explicit queue intent invalidates both callbacks.
    func extendWithRadio(thenAdvance: Bool, explicitlyRequested: Bool = false) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard queue.flowContext == nil else {
            if thenAdvance { pauseCurrentPlayback(from: "the end of Koda Flow") }
            return
        }
        guard autoplay || explicitlyRequested, let last = queue.items.last,
              let anchor = queue.current?.id else {
            if thenAdvance, queue.repeatMode == .off { seekCurrentPlayback(to: 0); pauseCurrentPlayback(from: "the queue ending") }
            return
        }
        guard wantsToPlay else { return }
        if var pending = radioRequest, pending.anchor == anchor {
            pending.advanceWhenReady = pending.advanceWhenReady || thenAdvance
            radioRequest = pending
            return
        }
        cancelRadioLoading()
        let token = radioRequestGeneration
        radioRequest = RadioRequest(generation: token, anchor: anchor, advanceWhenReady: thenAdvance)
        let music = music
        let loader = radioLoader
        radioTask = Task { [weak self] in
            do {
                let songs: [Song]
                if let loader { songs = try await loader(last.song.id) }
                else { songs = try await music.radio(for: last.song.id).songs }
                guard let self else { return }
                defer { self.finishRadioLoading(generation: token) }
                guard !Task.isCancelled, !isPlaybackSessionFinished, !evaluateSleepTimer(), let request = radioRequest,
                      request.generation == token, request.anchor == queue.current?.id, wantsToPlay else { return }
                radioRequest = nil
                radioTask = nil
                let known = Set(queue.items.suffix(100).map(\.song.id))
                let fresh = songs.filter { !known.contains($0.id) && isUnwanted?($0) != true }
                guard !fresh.isEmpty else {
                    if request.advanceWhenReady { pauseCurrentPlayback(from: "the queue ending with no radio") }
                    return
                }
                queue.append(fresh, protectingOrder: false)
                persistQueue()
                if request.advanceWhenReady { move(to: queue.advance(automatic: false)) }
                else { prepareNext() }
            } catch {
                guard let self else { return }
                defer { self.finishRadioLoading(generation: token) }
                guard !Task.isCancelled, !isPlaybackSessionFinished, !evaluateSleepTimer(), let request = radioRequest,
                      request.generation == token, request.anchor == queue.current?.id, wantsToPlay else { return }
                radioRequest = nil
                radioTask = nil
                if request.advanceWhenReady { pauseCurrentPlayback(from: "the queue ending with no radio") }
            }
        }
    }

    private func finishRadioLoading(generation token: Int) {
        guard radioRequest?.generation == token else { return }
        radioRequest = nil
        radioTask = nil
    }

    // MARK: - Observing AVFoundation

    /// Watch `player` as the main player. Events from a player that is no longer main are
    /// dropped, so a late callback from one fading out never moves the queue.
    private func attach(_ player: AVQueuePlayer) {
        observations.append(player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] player, _ in
            let item = player.currentItem.map(ObjectIdentifier.init)
            let source = ObjectIdentifier(player)
            Task { @MainActor in
                guard let self, ObjectIdentifier(self.avPlayer) == source else { return }
                self.currentItemChanged(item)
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let status = player.timeControlStatus
            let source = ObjectIdentifier(player)
            Task { @MainActor in
                guard let self, ObjectIdentifier(self.avPlayer) == source else { return }
                self.timeControlChanged(status)
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.periodicTick() }
        }
    }

    private func detach(_ player: AVQueuePlayer) {
        disarmCrossfade()
        observations.forEach { $0.invalidate() }
        observations = []
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    private func observePlayer() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let failed = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
            trace("FAILED item category=\(PlaybackFailureReason.classify(err).rawValue)")
            MainActor.assumeIsolated { self?.itemFailed(failed, error: err) }
        }
        center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemEnded(ended) }
        }
        center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: nil, queue: .main) { note in
            let at = (note.object as? AVPlayerItem)?.currentTime().seconds ?? .nan
            AutoMixLog.note("an item ran out of audio at \(at.s1) s")
        }
        observeAudioSession()
    }

    /// AVQueuePlayer moved on by itself: the preloaded song is now playing.
    private func currentItemChanged(_ item: ObjectIdentifier?) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard let item else {
            if avPlayer.currentItem == nil, let failed = lastAVItem, failed.status == .failed,
               let id = occurrences[ObjectIdentifier(failed)], queue.current?.id == id {
                recover(id, at: position(), error: failed.error)
            }
            return
        }
        guard let id = occurrences[item], avPlayer.currentItem.map(ObjectIdentifier.init) == item else { return }
        if stopsAtEndOfSong, let previous = lastAVItem, ObjectIdentifier(previous) != item,
           ObjectIdentifier(previous) == sleepEndItem, !stoppedEarly(previous),
           let target = queue.current?.id, sleepTimerSongEnded(occurrenceID: target) { return }
        // Its first time reading can still be the previous item's, so a preloaded song starts its clock at zero.
        let startsFresh = preloaded.remove(item) != nil
        // A preloaded copy of the song already current is repeat one coming round again:
        // a new play for history, stats and Last.fm, though the queue stays where it is.
        let loops = startsFresh && queue.current?.id == id && startedReported == id
        if loops {
            startedReported = nil
            // The same song again: iOS's Lock Screen keeps its own clock per song and, given the
            // same song with a new elapsed time, can stay at its end (-0:00). A fresh entry
            // makes it start over, as for a new song; `updateNowPlaying` below fills it.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            nowPlayingArtworkFor = nil
            nowPlayingAnimatedFor = nil
            AutoMixLog.note("repeat one came round: Now Playing restarted")
        }
        trace("currentItemChanged fresh=\(startsFresh) loops=\(loops) queueMatches=\(queue.current?.id == id) t=\(avPlayer.currentTime().seconds)")
        let previous = lastAVItem
        let changedItem = previous.map(ObjectIdentifier.init) != item
        lastAVItem = avPlayer.currentItem
        watchStatus(of: avPlayer.currentItem, id: id)
        // AVQueuePlayer drops a song that fails and moves on to the preloaded one.
        // That is not the song finishing, so the queue must not follow it.
        if let previous, ObjectIdentifier(previous) != item,
           let droppedId = occurrences[ObjectIdentifier(previous)], droppedId == queue.current?.id,
           stoppedEarly(previous) {
            let at = previous.currentTime().seconds
            trace("dropped early at \(at)")
            recover(droppedId, at: at.isFinite ? at : position(), error: previous.error)
            return
        }
        if queue.current?.id != id {
            if let currentID = queue.current?.id, stopsAtEndOfSong,
               previous.map(ObjectIdentifier.init) == sleepEndItem,
               sleepTimerSongEnded(occurrenceID: currentID) { return }
            if queue.peekNext(automatic: true)?.id == id {
                queue.advance(automatic: true)
            } else if !queue.jump(to: id) {
                return
            }
            cancelRecovery()
            recovery.begin(for: id)
        }
        // Manual next already advances PlayQueue before AVQueuePlayer changes its item.
        // Metadata belongs to the actual AV item, not to whether that queue mutation was needed.
        if changedItem || startsFresh {
            recovery.begin(for: id)
            queue.trimHistory(keeping: Self.historyLimit)
            duration = queue.current?.song.duration ?? 0
            soundProcessingAvailable = avPlayer.currentItem.map { TransitionDSP.of($0) != nil }
            if let stream = streamByItem[item] {
                currentStream = stream
                if let total = stream.duration, total.isFinite, total > 0 { duration = total }
                applyLoudness(stream)
            }
            measuredCodec = nil
            measuredSampleRate = nil
            measuredChannels = nil
            if let currentItem = avPlayer.currentItem {
                measureAudioFormat(of: currentItem, occurrence: id, generation: generation)
            }
        }
        if startsFresh {
            timeAnchor = TimeAnchor(position: 0, date: Date(), rate: Double(avPlayer.rate))
        } else {
            // Our own load of the current song; it may be seeking to a resume position.
            sampleTime()
        }
        // The saved occurrence, duration and position must describe the same AV item.
        // Persisting before the fresh clock reset saved the outgoing song's position.
        if changedItem || startsFresh { persistQueue() }
        updateNowPlaying()
        prepareNext()
        armCrossfade()
        // Running straight on from the last song, the player never stops being "playing",
        // so the new song's start is reported here rather than on a status change.
        if avPlayer.timeControlStatus == .playing { reportStart() }
    }

    /// Every five seconds while playing, and when playback starts or stops.
    private func periodicTick() {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        sampleTime()
        let now = Date()
        let playing = avPlayer.timeControlStatus == .playing
        if playing, let last = lastListenedTick, let song = current {
            // A gap longer than the tick means the app was suspended; that time was not heard.
            let heard = min(now.timeIntervalSince(last), 6)
            onListened?(song, heard)
            if let item = queue.current { onItemHeard?(item, heard) }
        }
        lastListenedTick = playing ? now : nil
        // iOS can end the app in the background without warning; keep the saved position recent.
        if playing, now.timeIntervalSince(lastPersisted) > 20 { persistQueue() }
        refreshAudioInformation()
    }

    /// A song ended with nothing preloaded behind it, so AVQueuePlayer stopped.
    /// When something was preloaded, AVQueuePlayer moves on by itself and
    /// `currentItemChanged` advances the queue; doing it here too would skip a song.
    private func itemEnded(_ item: ObjectIdentifier?) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        trace("itemEnded known=\(item.flatMap { occurrences[$0] } != nil) items=\(avPlayer.items().count)")
        guard phase == .ready, recovery.pending == nil, !recovery.waitingForNetwork,
              let item, let id = occurrences[item], id == queue.current?.id else { return }
        if item == sleepEndItem, sleepTimerSongEnded(occurrenceID: id) { return }
        if sleepTimerState.plan != nil, stopsAtEndOfSong { return }
        if stopsAtEndOfSong {
            // actionAtItemEnd was .pause, so AVQueuePlayer stayed on this song; move the queue on, paused.
            stopsAtEndOfSong = false
            wantsToPlay = false
            occurrences[item] = nil
            if queue.advance(automatic: true) != nil {
                loadCurrent(at: 0)
            } else {
                seek(to: 0)
                pause(from: "the sleep timer's end of song")
            }
            return
        }
        if avPlayer.items().contains(where: { ObjectIdentifier($0) != item && occurrences[ObjectIdentifier($0)] != nil }) { return }
        // Ended without a crossfade (seeked past it, or a short song): the standby song goes straight on.
        if let standby, standby.id == queue.peekNext(automatic: true)?.id {
            occurrences[item] = nil
            switchToStandby(fading: 0)
            return
        }
        occurrences[item] = nil
        if queue.advance(automatic: true) != nil {
            loadCurrent(at: 0)
        } else {
            extendWithRadio(thenAdvance: true)
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        // KVO callbacks hop to the main actor; ignore a status superseded before delivery.
        guard status == avPlayer.timeControlStatus else { return }
        trace("timeControl \(status.rawValue) t=\(avPlayer.currentTime().seconds)")
        // An AutoMix start scheduled on the clock waits by design, a moment; that isn't buffering.
        let awaitingStart = scheduledStart.map { Date() < $0.addingTimeInterval(0.25) } ?? false
        // Stopped or stuck while the listener wants sound is what a silence is; the log says
        // why, and for how long, since nothing on screen does.
        if wantsToPlay, status != .playing, !awaitingStart, phase == .ready {
            silentSince = silentSince ?? Date()
            AutoMixLog.note("player \(status == .paused ? "stopped" : "waiting") while playing, at \(avPlayer.currentTime().seconds.s1) s: "
                + "rate \(avPlayer.rate), waiting reason \(avPlayer.reasonForWaitingToPlay?.rawValue ?? "none"), "
                + "item status \(avPlayer.currentItem?.status.rawValue ?? -1), likely to keep up \(avPlayer.currentItem?.isPlaybackLikelyToKeepUp ?? false)")
        } else if status == .playing, let since = silentSince {
            silentSince = nil
            AutoMixLog.note("playing again after \(Date().timeIntervalSince(since).s1) s")
        }
        isBuffering = wantsToPlay && !awaitingStart && (status == .waitingToPlayAtSpecifiedRate || phase == .loading)
        if !awaitingStart { armStallWatchdog(status) }
        if status == .playing, phase == .ready,
           let item = avPlayer.currentItem, occurrences[ObjectIdentifier(item)] == queue.current?.id {
            reportStart()
            if recoveryWasAttempted, recovery.pending == nil, !recovery.waitingForNetwork {
                recoveryWasAttempted = false
                recovery.markRecovered()
                recordDiagnostic(.recovered, attempt: recovery.attempts)
            }
        }
        sampleTime()
        updateNowPlaying()
        refreshAudioInformation()
    }

    /// Tell history and Last.fm the current song started, once per occurrence.
    private func reportStart() {
        guard let item = queue.current, startedReported != item.id else { return }
        startedReported = item.id
        if savesSmartShuffleHistory { smartHistory.recordPlay(item.song) }
        onSongStarted?(item.song)
        onItemStarted?(item)
    }

    /// A failure of the song AVFoundation is still on. When it has already moved
    /// past it to the preloaded song, `currentItemChanged` sees that instead.
    private func itemFailed(_ item: ObjectIdentifier?, error: Error? = nil) {
        trace("itemFailed known=\(item.flatMap { occurrences[$0] } != nil) isCurrent=\(item.flatMap { occurrences[$0] } == queue.current?.id)")
        guard let item, let id = occurrences[item], id == queue.current?.id,
              avPlayer.currentItem.map(ObjectIdentifier.init) == item
                || (avPlayer.currentItem == nil && lastAVItem.map(ObjectIdentifier.init) == item) else { return }
        recover(id, at: position(), error: error ?? avPlayer.currentItem?.error)
    }

    /// A broken URL does not always post a failure; the item's status turns failed and the player waits forever.
    private func watchStatus(of item: AVPlayerItem?, id: UUID) {
        let token = generation
        let source = ObjectIdentifier(avPlayer)
        itemStatusObservation = item?.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.generation == token, ObjectIdentifier(self.avPlayer) == source,
                      self.queue.current?.id == id,
                      self.avPlayer.currentItem === item || self.avPlayer.currentItem == nil,
                      self.occurrences[ObjectIdentifier(item)] == id else { return }
                trace("current item status failed")
                self.recover(id, at: self.position(), error: item.error)
            }
        }
    }

    /// Waiting on the network for too long while the listener wants sound: reload the song where it was.
    private func armStallWatchdog(_ status: AVPlayer.TimeControlStatus) {
        stallWatchdog?.cancel()
        guard status == .waitingToPlayAtSpecifiedRate, wantsToPlay, !interruption.isInterrupted,
              recovery.pending == nil, !recovery.waitingForNetwork, phase == .ready, let id = queue.current?.id else { return }
        // A song that never got going is broken sooner than one that stalled mid-way on a slow network.
        let timeout = avPlayer.currentItem?.status == .readyToPlay ? stallTimeout : stallTimeout * 0.5
        stallWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.wantsToPlay, self.queue.current?.id == id,
                  self.avPlayer.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            trace("stalled, reloading")
            self.recover(id, at: self.position())
        }
    }

    /// Whether `item` stopped short of its end rather than finishing.
    private func stoppedEarly(_ item: AVPlayerItem) -> Bool {
        if item.status == .failed { return true }
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime.seconds : item.duration.seconds
        let reached = item.currentTime().seconds
        guard end.isFinite, reached.isFinite, end > 0 else { return false }
        return reached < end - 2
    }

    /// Recovery never changes the queue occurrence or creates another AVQueuePlayer.
    /// Only transient failures get a fresh stream URL; authorization failures stop here.
    private func recover(_ id: UUID, at seconds: TimeInterval, error: Error? = nil) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard queue.current?.id == id else { return }
        let rejectedLocalFile = invalidateFailedLocalAudio(error: error)
        let isRejectedLocalItem = rejectedLocalFile
            || (invalidatedLocalOccurrence == id && currentStream?.url.isFileURL == true)
        guard wantsToPlay, !interruption.isInterrupted else {
            recordDiagnostic(.playbackFailed, reason: isRejectedLocalItem ? .unavailable : PlaybackFailureReason.classify(error))
            refreshAudioInformation()
            return
        }
        let decision = isRejectedLocalItem
            ? recovery.requestLocalReplacement(for: id, at: seconds, wantsToPlay: true, network: recoveryNetwork)
            : recovery.request(for: id, at: seconds, error: error, wantsToPlay: true, network: recoveryNetwork)
        guard decision != .ignore else { return }
        recordDiagnostic(.playbackFailed, reason: isRejectedLocalItem ? .unavailable : PlaybackFailureReason.classify(error))
        applyRecovery(decision, position: seconds)
    }

    /// Only the store can prove that this exact local file/version failed to decode or read.
    /// Network, authorization, interruption and unrelated old-item failures leave bytes intact.
    private func invalidateFailedLocalAudio(error: Error?) -> Bool {
        guard let stream = currentStream,
              audioStore?.discardInvalidLocalStream(stream, error: error) == true else { return false }
        invalidatedLocalOccurrence = queue.current?.id
        onLocalAudioInvalidated?(stream.videoId)
        return true
    }

    private func applyRecovery(_ decision: PlaybackRecovery.Decision, position: TimeInterval) {
        guard !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        guard decision != .ignore else { return }
        // Invalidate any resolution or seek already in flight before stopping sound.
        generation += 1
        let token = generation
        let held = position.isFinite ? max(0, position) : self.position()
        phase = .loading
        timeAnchor = TimeAnchor(position: held, date: Date(), rate: 0)
        stallWatchdog?.cancel()
        endTransition()
        finishTail()
        cancelFadeIn()
        disarmCrossfade()
        discardStandby()
        avPlayer.pause()
        switch decision {
        case .ignore: break
        case .waitForNetwork:
            isBuffering = true
            recordDiagnostic(.waitingForNetwork, reason: recovery.lastFailure, attempt: recovery.attempts)
        case .stop(let reason):
            cancelRecovery()
            phase = .failed(reason.message)
            isBuffering = false
            wantsToPlay = false
            recordDiagnostic(.recoveryStopped, reason: reason, attempt: recovery.attempts)
        case .retry(let ticket):
            recoveryWasAttempted = true
            isBuffering = true
            recordDiagnostic(.retryScheduled, reason: recovery.lastFailure, attempt: ticket.attempt)
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(ticket.delay)) } catch { return }
                guard let self, !Task.isCancelled, self.generation == token,
                      self.queue.current?.id == ticket.occurrenceID, self.wantsToPlay,
                      !self.interruption.isInterrupted, self.recovery.isCurrent(ticket),
                      !self.isPlaybackSessionFinished, !self.evaluateSleepTimer() else { return }
                self.recoveryTask = nil
                if self.recoveryNetwork.status != .online {
                    if self.recovery.suspendForNetwork(ticket) {
                        self.applyRecovery(.waitForNetwork, position: ticket.position)
                    }
                    return
                }
                // Forget the expired/failed URL, not the identity or a valid offline file.
                guard let song = self.queue.current?.song else { return }
                await self.music.invalidateStream(song.id)
                guard !Task.isCancelled, self.generation == token,
                      self.queue.current?.id == ticket.occurrenceID, self.wantsToPlay,
                      !self.interruption.isInterrupted, self.recovery.isCurrent(ticket),
                      !self.isPlaybackSessionFinished, !self.evaluateSleepTimer() else { return }
                // Network may have changed during URL invalidation. A scheduled timer is not
                // an attempt: charge the budget only immediately before this actual reload.
                guard self.recoveryNetwork.status == .online else {
                    if self.recovery.suspendForNetwork(ticket) {
                        self.applyRecovery(.waitForNetwork, position: ticket.position)
                    }
                    return
                }
                guard self.recovery.consume(ticket) else { return }
                self.recordDiagnostic(.retryStarted, attempt: ticket.attempt)
                self.loadCurrent(at: ticket.position)
            }
        }
        refreshAudioInformation()
        updateNowPlaying()
        persistQueue()
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recovery.cancel()
        recoveryWasAttempted = false
    }

    private func observeNetwork() {
        networkTask = Task { [weak self] in
            for await snapshot in NetworkPath.shared.updates() {
                guard !Task.isCancelled, let self else { return }
                self.networkChanged(snapshot)
            }
        }
    }

    func networkChanged(_ snapshot: NetworkSnapshot) {
        let snapshot = networkSnapshotOverride ?? snapshot
        let previous = latestNetwork
        latestNetwork = snapshot
        guard !evaluateSleepTimer(), !isPlaybackSessionFinished else { return }
        if previous != snapshot { recordDiagnostic(.networkChanged, network: snapshot) }
        refreshAudioInformation()
        resumeRestoredQueueIfAllowed()
        // A healthy buffered or offline-file stream keeps playing through interface changes.
        guard snapshot.status == .online, wantsToPlay, !interruption.isInterrupted,
              let id = queue.current?.id else { return }
        let decision = recovery.networkRestored(for: id, at: position(), wantsToPlay: wantsToPlay)
        applyRecovery(decision, position: position())
    }

    /// Foregrounding never overrides a pause or an exhausted/permanent failure.
    public func applicationBecameActive() {
        guard !evaluateSleepTimer(), !isPlaybackSessionFinished else { return }
        mayResumeRestoredQueue = true
        networkChanged(networkSnapshotOverride ?? NetworkPath.shared.snapshot)
        refreshAudioInformation()
    }

    /// Only cold-launch restoration needs a foreground scene. Existing background audio and
    /// an explicitly requested stream recovery continue normally when the scene deactivates.
    public func applicationBecameInactive() {
        _ = evaluateSleepTimer()
        mayResumeRestoredQueue = false
    }

    private func resumeRestoredQueueIfAllowed() {
        guard !sleepTimerPolicy.suppressesAutomaticResume, !isPlaybackSessionFinished, !evaluateSleepTimer() else { return }
        let hasLocalAudio = queue.current.map { audioStore?.completeStream($0.song.id) != nil } ?? false
        guard RestoredPlaybackPolicy.shouldResume(enabled: resumePlaybackOnLaunch,
            wasPlaying: restoredPlaybackWasActive, foregroundActivated: mayResumeRestoredQueue,
            isInterrupted: interruption.isInterrupted, isIdle: phase == .idle && !wantsToPlay,
            hasSong: queue.current != nil, isOnline: latestNetwork.status == .online, hasLocalAudio: hasLocalAudio) else { return }
        resume()
    }

    private func recordDiagnostic(_ kind: PlaybackDiagnosticEvent.Kind, reason: PlaybackFailureReason? = nil,
                                  attempt: Int? = nil, network: NetworkSnapshot? = nil) {
        diagnosticStore.record(kind, reason: reason, attempt: attempt, network: network)
        diagnosticEvents = diagnosticStore.events
    }

    public func clearDiagnostics() {
        diagnosticStore.clear()
        diagnosticEvents = []
        // Clearing records does not reset retry budgets or change playback.
        audioInformation.lastFailure = nil
    }

    private func refreshAudioInformation() {
        var metadata = currentStream?.metadata
        if let rate = measuredSampleRate, let channels = measuredChannels {
            var measured = metadata ?? AudioStreamMetadata()
            measured.sampleRate = rate
            measured.channels = channels
            if measured.codec == nil { measured.mimeType = measuredCodec ?? measured.mimeType }
            metadata = measured
        }
        let state: AudioPlaybackState
        switch phase {
        case .idle: state = .idle
        case .loading: state = .loading
        case .failed: state = .failed
        case .ready:
            state = avPlayer.timeControlStatus == .playing ? .playing : wantsToPlay ? .ready : .paused
        }
        var buffered: TimeInterval?
        if let item = avPlayer.currentItem {
            let at = position()
            let ranges = item.loadedTimeRanges.map(\.timeRangeValue)
            buffered = ranges.compactMap { range -> Double? in
                let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
                guard start.isFinite, end.isFinite, at >= start - 0.1, at <= end else { return nil }
                return max(0, end - at)
            }.max()
        }
        let lastFailure = diagnosticEvents.last(where: { $0.reason != nil })?.reason
        let info = AudioPlaybackInformation(metadata: metadata, hasStream: currentStream != nil, isLocal: currentStream?.url.isFileURL ?? false,
                                            bufferedSeconds: buffered, isBuffering: isBuffering,
                                            network: latestNetwork, state: state, lastFailure: lastFailure,
                                            retryAttempt: recovery.attempts)
        if audioInformation != info { audioInformation = info }
    }

    /// Format descriptions are read once per item asynchronously, never at animation rate.
    private func measureAudioFormat(of item: AVPlayerItem, occurrence: UUID, generation token: Int) {
        formatTask?.cancel()
        formatTask = Task { [weak self] in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
                  let formats = try? await track.load(.formatDescriptions),
                  let description = formats.first,
                  let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return }
            let format = pointer.pointee
            guard !Task.isCancelled, let self, !self.isPlaybackSessionFinished, self.generation == token, self.queue.current?.id == occurrence,
                  self.avPlayer.currentItem === item else { return }
            self.measuredSampleRate = format.mSampleRate.isFinite && format.mSampleRate > 0 ? format.mSampleRate : nil
            self.measuredChannels = format.mChannelsPerFrame > 0 ? Int(format.mChannelsPerFrame) : nil
            switch format.mFormatID {
            case kAudioFormatMPEG4AAC: self.measuredCodec = "audio/mp4; codecs=\"mp4a.40.2\""
            case kAudioFormatMPEG4AAC_HE: self.measuredCodec = "audio/mp4; codecs=\"mp4a.40.5\""
            case kAudioFormatMPEG4AAC_HE_V2: self.measuredCodec = "audio/mp4; codecs=\"mp4a.40.29\""
            case kAudioFormatOpus: self.measuredCodec = "audio/ogg; codecs=opus"
            default: self.measuredCodec = nil
            }
            self.refreshAudioInformation()
        }
    }

    private func sampleTime() {
        let seconds = avPlayer.currentTime().seconds
        trace("sample t=\(seconds) phase=\(phase) status=\(avPlayer.timeControlStatus.rawValue)")
        // AVQueuePlayer reports zero while an item is preparing, after rejecting an item,
        // and briefly when moving to another occurrence. None is the current song's clock.
        // In particular, preserve a restored seek position until its actual item is ready.
        guard seconds.isFinite, phase == .ready,
              let item = avPlayer.currentItem, item.status == .readyToPlay,
              occurrences[ObjectIdentifier(item)] == queue.current?.id else {
            if timeAnchor.rate != 0 {
                timeAnchor = TimeAnchor(position: position(), date: Date(), rate: 0)
                updateNowPlaying()
            }
            return
        }
        let rate = avPlayer.timeControlStatus == .playing ? Double(avPlayer.rate) : 0
        let fresh = TimeAnchor(position: seconds, date: Date(), rate: rate)
        let drifted = fresh.rate != timeAnchor.rate || abs(position(at: fresh.date) - fresh.position) > 1
        timeAnchor = fresh
        // The Lock Screen runs its own clock from the last published sample. A periodic sample
        // that corrects the rate or the position has to reach it too, or it stays frozen (a
        // rate 0 caught as repeat one came round) while the app's own bar has moved on.
        if drifted { updateNowPlaying() }
    }

    // MARK: - Audio session

    @discardableResult
    private func activateAudioSession() -> Bool {
        if let audioSessionActivator { return audioSessionActivator() }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            return true
        } catch {
            return false
        }
        #else
        return true
        #endif
    }

    /// Media-server resets invalidate AVFoundation objects. Rebuild the one main pipeline
    /// without treating the reset as a next-song request or as permission to resume a pause.
    func handleMediaServicesReset() {
        _ = evaluateSleepTimer()
        if isPlaybackSessionFinished {
            // The server invalidated even an empty player. Rebuild only when the listener
            // next asks for music, without waking this completed session in the meantime.
            needsPlayerRebuild = true
            return
        }
        let savedPosition = position()
        let savedIntent = wantsToPlay
        generation += 1
        nextGeneration += 1
        cancelRecovery()
        cancelRadioLoading()
        stallWatchdog?.cancel()
        stallWatchdog = nil
        endTransition()
        finishTail()
        cancelFadeIn()
        discardStandby()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        detach(avPlayer)
        avPlayer.pause()
        avPlayer.removeAllItems()
        occurrences = [:]
        preloaded = []
        streamByItem = [:]
        attachingChannels = []
        lastAVItem = nil
        currentStream = nil
        soundProcessingAvailable = nil
        measuredCodec = nil
        measuredSampleRate = nil
        measuredChannels = nil
        adopt(AVQueuePlayer())
        wantsToPlay = savedIntent
        isBuffering = false
        phase = .idle
        timeAnchor = TimeAnchor(position: savedPosition, date: Date(), rate: 0)
        // A reset can occur in the background; the interrupted/paused intention still wins.
        if let id = queue.current?.id, savedIntent, !interruption.isInterrupted {
            if activateAudioSession() {
                loadCurrent(at: savedPosition)
            } else {
                // This notification itself is evidence of a reset, not an inferred HTTP or
                // decoder failure. Existing bounded recovery may try the new pipeline again.
                recover(id, at: savedPosition,
                        error: NSError(domain: AVFoundationErrorDomain, code: -11819)) // AVErrorMediaServicesWereReset
            }
        }
        updateNowPlaying()
        refreshAudioInformation()
        persistQueueNow()
    }

    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "none"
            MainActor.assumeIsolated {
                guard let self, !self.isPlaybackSessionFinished, !self.evaluateSleepTimer() else { return }
                AutoMixLog.note("audio interruption \(type == .began ? "began" : type == .ended ? "ended" : "?"), reason \(reason), "
                    + "should resume \(options.contains(.shouldResume)), wanted to play \(self.wantsToPlay)")
                switch type {
                case .began:
                    self.cancelPlaylistLoading()
                    self.cancelRadioLoading()
                    // A call or another app took the audio; remember the intent so it can come back.
                    self.interruption.began(wantsToPlay: self.wantsToPlay)
                    self.cancelRecovery()
                    self.stallWatchdog?.cancel()
                    self.recordDiagnostic(.interruptionBegan)
                    self.endTransition()
                    self.finishTail()
                    self.avPlayer.pause()
                    self.sampleTime()
                    self.persistQueueNow()
                case .ended:
                    // Explicit resume may already have reactivated a stale interruption.
                    // Its delayed/duplicate ended event must not pause the new intention.
                    guard self.interruption.isInterrupted else { break }
                    let shouldResume = self.interruption.ended(shouldResume: options.contains(.shouldResume))
                    self.recordDiagnostic(.interruptionEnded)
                    if shouldResume { self.resume() }
                    else { self.pause(from: "an interruption ending without resume") }
                default: break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue) \($0.portName)" }
            AutoMixLog.note("audio route changed, reason \(reason.map { String($0.rawValue) } ?? "?"), now \(outputs.joined(separator: ", "))")
            MainActor.assumeIsolated {
                // Headphones out: stop rather than play out loud.
                if reason == .oldDeviceUnavailable { self?.pause(from: "headphones disconnecting") }
                self?.refreshAudioOutputRoute()
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
                self?.refreshAudioOutputRoute()
            }
        }
        #endif
    }

    /// When the player last stopped making sound while the listener wanted it, for the log.
    private var silentSince: Date?

    // MARK: - Now Playing and remote commands

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { @Sendable [weak self] _ in
            AutoMixLog.note("play asked by the system (Lock Screen, Control Center, headphones)")
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { @Sendable [weak self] _ in
            AutoMixLog.note("pause asked by the system (Lock Screen, Control Center, headphones)")
            Task { @MainActor in self?.pause(from: "the system's pause command") }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.togglePlayPause(from: "the system (Lock Screen, Control Center, headphones)") }
            return .success
        }
        center.nextTrackCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { @Sendable [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in self?.seek(to: time) }
            return .success
        }
        center.changeShuffleModeCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            let on = event.shuffleType != .off
            Task { @MainActor in self?.setShuffle(on) }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            let mode: RepeatMode = switch event.repeatType { case .one: .one; case .all: .all; default: .off }
            Task { @MainActor in self?.setRepeat(mode) }
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func updateRemoteCommandState() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = queue.isShuffled ? .items : .off
        center.changeRepeatModeCommand.currentRepeatType = switch queue.repeatMode { case .off: .off; case .all: .all; case .one: .one }
    }

    private func updateNowPlaying() {
        guard !isPlaybackSessionFinished else { return }
        let infoCenter = MPNowPlayingInfoCenter.default()
        guard let song = queue.current?.song else {
            infoCenter.nowPlayingInfo = nil
            return
        }
        var info = infoCenter.nowPlayingInfo ?? [:]
        if info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String != song.id {
            info = [:]
            nowPlayingArtworkFor = nil
            nowPlayingAnimatedFor = nil
        }
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = song.id
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artistLine
        info[MPMediaItemPropertyAlbumTitle] = song.album?.title
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position()
        info[MPNowPlayingInfoPropertyPlaybackRate] = timeAnchor.rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = wantsToPlay ? .playing : .paused
        updateRemoteCommandState()

        if let url = song.artwork?.url(pixels: 600), nowPlayingArtworkFor != url, let loader = artworkLoader {
            nowPlayingArtworkFor = url
            let songId = song.id
            let epoch = publicationEpoch
            artworkTask?.cancel()
            artworkTask = Task {
                guard let artwork = await loader(url) else { return }
                guard !Task.isCancelled, !isPlaybackSessionFinished, publicationEpoch == epoch,
                      queue.current?.song.id == songId else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
        if nowPlayingAnimatedFor != song.id, let loader = animatedArtworkLoader {
            nowPlayingAnimatedFor = song.id
            let songId = song.id
            let epoch = publicationEpoch
            animatedArtworkTask?.cancel()
            animatedArtworkTask = Task {
                let animated = await loader(song)
                guard !Task.isCancelled, !isPlaybackSessionFinished, publicationEpoch == epoch,
                      !animated.isEmpty, queue.current?.song.id == songId else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                for (key, artwork) in animated where MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys.contains(key) {
                    info[key] = artwork
                }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }

    // MARK: - Persistence

    private struct Saved: Codable, Sendable {
        var queue: PlayQueue
        var position: TimeInterval
        var smartHistory: SmartShuffleHistory
        var wasPlaying: Bool
        var schemaVersion = 2

        init(queue: PlayQueue, position: TimeInterval, smartHistory: SmartShuffleHistory, wasPlaying: Bool) {
            self.queue = queue
            self.position = position.isFinite ? max(0, position) : 0
            self.smartHistory = smartHistory
            self.wasPlaying = wasPlaying
        }

        private enum CodingKeys: String, CodingKey { case queue, position, smartHistory, wasPlaying, schemaVersion }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            queue = try c.decode(PlayQueue.self, forKey: .queue)
            let storedPosition = try c.decodeIfPresent(TimeInterval.self, forKey: .position) ?? 0
            position = storedPosition.isFinite ? max(0, storedPosition) : 0
            smartHistory = try c.decodeIfPresent(SmartShuffleHistory.self, forKey: .smartHistory) ?? SmartShuffleHistory()
            wasPlaying = try c.decodeIfPresent(Bool.self, forKey: .wasPlaying) ?? false
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        }
    }

    private var queueFile: URL? { storage?.appending(path: "queue.json") }
    private let queueSnapshotWriter = QueueSnapshotWriter()

    /// Recent radio/history additions kept for going back; finite collection occurrences
    /// are retained separately so repeat-all and restored shuffle keep the complete source.
    static let historyLimit = 100

    /// Save the queue so the app reopens where it was. Encoding and writing happen off the
    /// main thread, a moment later, and only for the newest state: a run of taps on shuffle
    /// or repeat writes once and never holds up the screen.
    public func persistQueue() {
        lastPersisted = Date()
        guard let queueFile else { return }
        let version = queueSnapshotWriter.reserve()
        let saved = Saved(queue: queue, position: position(), smartHistory: smartHistory, wasPlaying: wantsToPlay)
        let writer = queueSnapshotWriter
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard writer.isCurrent(version), let data = try? JSONEncoder().encode(saved) else { return }
            _ = try? writer.write(data, version: version, to: queueFile)
        }
    }

    /// Save right now, on this thread: for when the app is leaving the screen and may be suspended.
    public func persistQueueNow() {
        lastPersisted = Date()
        guard let queueFile else { return }
        let version = queueSnapshotWriter.reserve()
        if let data = try? JSONEncoder().encode(Saved(queue: queue, position: position(), smartHistory: smartHistory, wasPlaying: wantsToPlay)) {
            _ = try? queueSnapshotWriter.write(data, version: version, to: queueFile)
        }
    }

    private func persistSettings() {
        preferenceDefaults.set(autoplay, forKey: "koda.autoplay")
        preferenceDefaults.set(normalizesVolume, forKey: "koda.normalizeVolume")
        preferenceDefaults.set(cachesWhileStreaming, forKey: "koda.cacheWhileStreaming")
        preferenceDefaults.set(crossfades, forKey: "koda.crossfade")
        preferenceDefaults.set(crossfadeDuration, forKey: "koda.crossfadeDuration")
        preferenceDefaults.set(autoMix, forKey: "koda.autoMix")
        preferenceDefaults.set(equalizer.rawValue, forKey: "koda.equalizer")
        preferenceDefaults.set(unmeteredQuality.rawValue, forKey: "koda.streaming.unmetered")
        preferenceDefaults.set(meteredQuality.rawValue, forKey: "koda.streaming.metered")
    }

    /// The last queue initially comes back paused; optional resume waits for foreground
    /// activation and an available stream or local file.
    private func restore() {
        // Both are read before either is set: setting one saves both.
        let defaults = preferenceDefaults
        let savedAutoplay = defaults.object(forKey: "koda.autoplay") as? Bool
        let savedNormalize = defaults.object(forKey: "koda.normalizeVolume") as? Bool
        let savedCaching = defaults.object(forKey: "koda.cacheWhileStreaming") as? Bool
        let savedCrossfade = defaults.object(forKey: "koda.crossfade") as? Bool
        let savedCrossfadeDuration = defaults.object(forKey: "koda.crossfadeDuration") as? Double
        let savedAutoMix = defaults.object(forKey: "koda.autoMix") as? Bool
        let savedEqualizer = defaults.string(forKey: "koda.equalizer").flatMap(EqualizerPreset.init(rawValue:))
        let savedUnmetered = defaults.string(forKey: "koda.streaming.unmetered").flatMap(StreamQuality.init(rawValue:))
        let savedMetered = defaults.string(forKey: "koda.streaming.metered").flatMap(StreamQuality.init(rawValue:))
        let savedSound = SoundSettingsStore.load(defaults: defaults)
        resumePlaybackOnLaunch = defaults.bool(forKey: "koda.playback.resumeOnLaunch")
        if let data = defaults.data(forKey: "koda.smartShuffle.settings.v1"),
           let settings = try? JSONDecoder().decode(SmartShuffleSettings.self, from: data) {
            smartShuffleSettings = settings.validated
        }
        if let savedEqualizer { equalizer = savedEqualizer }
        soundSettings = savedSound
        if let savedUnmetered { unmeteredQuality = savedUnmetered }
        if let savedMetered { meteredQuality = savedMetered }
        if let savedAutoMix { autoMix = savedAutoMix }
        if let savedAutoplay { autoplay = savedAutoplay }
        if let savedNormalize { normalizesVolume = savedNormalize }
        if let savedCaching { cachesWhileStreaming = savedCaching }
        if let savedCrossfade { crossfades = savedCrossfade }
        if let savedCrossfadeDuration { crossfadeDuration = min(12, max(1, savedCrossfadeDuration)) }
        guard let queueFile, let data = try? Data(contentsOf: queueFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.queue.current != nil else { return }
        queue = saved.queue
        smartHistory = saved.smartHistory
        restoredPlaybackWasActive = saved.wasPlaying && !sleepTimerPolicy.suppressesAutomaticResume
        // Old history stays bounded; retained finite collections keep all source occurrences.
        queue.trimHistory(keeping: Self.historyLimit)
        duration = queue.current?.song.duration ?? 0
        let restoredPosition = duration > 0 ? min(saved.position, max(0, duration - 0.5)) : saved.position
        timeAnchor = TimeAnchor(position: restoredPosition, date: Date(), rate: 0)
        phase = .idle
        updateNowPlaying()
    }
}

/// A cold launch is allowed to restore sound only with explicit opt-in, saved intent,
/// foreground activation and available audio. A user pause clears saved intent upstream.
enum RestoredPlaybackPolicy {
    static func shouldResume(enabled: Bool, wasPlaying: Bool, foregroundActivated: Bool,
                             isInterrupted: Bool, isIdle: Bool, hasSong: Bool,
                             isOnline: Bool, hasLocalAudio: Bool) -> Bool {
        enabled && wasPlaying && foregroundActivated && !isInterrupted && isIdle && hasSong
            && (isOnline || hasLocalAudio)
    }
}
