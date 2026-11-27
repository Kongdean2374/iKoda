import KodaCore
import Observation
import SwiftUI
import UIKit

/// Observes playback/settings independently of a SwiftUI page. Covering or dismissing
/// Now Playing cannot cancel the song's translation or discard its shared snapshot.
@MainActor
@Observable
final class LyricsPreparationLifecycle {
    @ObservationIgnored private let player: Player
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let coordinator: LyricsTranslationCoordinator
    @ObservationIgnored private var started = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var backgroundGeneration = UUID()
    @ObservationIgnored private var finishedSession = false
    @ObservationIgnored private var finishingCache = false
    @ObservationIgnored private var finishGeneration = UUID()
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    /// The activity opts into preparing translations independently of the phone view.
    var preparesCarPlayLyrics = false
    private var foreground = false
    private var network = NetworkPath.shared.snapshot
    private var resourceRevision = 0
    private var memoryPressure = false
    @ObservationIgnored private var resourceObservers: [Task<Void, Never>] = []
    private var background = false

    init(player: Player, settings: AppSettings, coordinator: LyricsTranslationCoordinator) {
        self.player = player
        self.settings = settings
        self.coordinator = coordinator
    }

    func start() {
        guard !started else { return }
        started = true
        resourceObservers.append(Task { [weak self] in
            for await network in NetworkPath.shared.updates() {
                guard let self else { return }
                self.network = network
            }
        })
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification,
                     UIApplication.didReceiveMemoryWarningNotification] {
            resourceObservers.append(Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let self else { return }
                    if name == UIApplication.didReceiveMemoryWarningNotification { self.memoryPressure = true }
                    self.resourceRevision &+= 1
                }
            })
        }
        observe()
    }

    deinit {
        for observer in resourceObservers { observer.cancel() }
    }

    func setScenePhase(_ phase: ScenePhase) {
        if phase == .active { memoryPressure = false }
        foreground = phase == .active
        background = phase == .background
    }

    /// Called synchronously before music releases its audio session. Stop admission now;
    /// use only the already granted finite assertion to finish the saved text checkpoint.
    func finishPlaybackSession() {
        guard !finishedSession else { return }
        finishedSession = true
        finishingCache = true
        let generation = UUID()
        finishGeneration = generation
        coordinator.setPlaybackSessionFinished(true)
        finishTask = Task { [weak self, coordinator] in
            await coordinator.flush()
            guard let self, self.finishGeneration == generation, self.finishedSession else { return }
            self.finishingCache = false
            self.finishTask = nil
            self.endBackgroundTask()
        }
    }

    /// A manual Player command is the only event that reopens this gate. Reconciliation
    /// on the next actor turn sees that command's final song/queue rather than the old one.
    func resumePlaybackSession() {
        guard finishedSession else { return }
        finishedSession = false
        finishGeneration = UUID()
        finishingCache = false
        finishTask = nil // An already queued durable write may finish; it cannot end a new assertion.
        coordinator.setPlaybackSessionFinished(false)
    }

    private func observe() {
        let input = withObservationTracking {
            let current = player.current
            _ = resourceRevision
            _ = coordinator.polishTrigger
            _ = coordinator.lyricsRevision
            _ = coordinator.versions.editRevision
            let constrained = network.isConstrained || network.isExpensive
            var limits = Set<LyricWorkLimit>()
            if ProcessInfo.processInfo.isLowPowerModeEnabled { limits.insert(.lowPower) }
            if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue { limits.insert(.thermal) }
            if memoryPressure { limits.insert(.memory) }
            let headroom = limits.isEmpty
            if !foreground { limits.insert(.background) }
            if player.isBuffering { limits.insert(.buffering) }
            // The queue itself intentionally is not observable; these projections are.
            _ = player.upcoming
            _ = player.repeatMode
            var queue = player.queue
            var upcoming: [Song] = []
            var seen = Set(current.map { [$0.id] } ?? [])
            for _ in 0..<min(queue.items.count, 6) {
                guard let next = queue.advance(automatic: false) else { break }
                if seen.insert(next.song.id).inserted { upcoming.append(next.song) }
                if upcoming.count == 5 { break }
            }
            return Input(current: current, upcoming: upcoming, sources: settings.lyricsSources,
                customSources: settings.customLyricsSources, automaticEnabled: settings.automaticLyricsTranslation,
                showsTranslation: settings.showsLyricsTranslation || preparesCarPlayLyrics, foreground: foreground,
                background: background, hasCurrentWork: coordinator.hasCurrentWork,
                sessionFinished: player.isPlaybackSessionFinished, mode: settings.lyricsTranslationMode,
                prefetchLimit: settings.lyricsPrefetchLimit, cacheMegabytes: settings.lyricsCacheMegabytes, online: network.status != .offline,
                headroom: headroom, constrained: constrained, buffering: player.isBuffering, limits: limits,
                permitsForegroundLookup: foreground || (player.wantsToPlay && preparesCarPlayLyrics))
        } onChange: { [weak self] in
            // Observation fires before the property mutation. Read the committed values
            // on the next main-actor turn and rearm the one-shot observation once.
            Task { @MainActor [weak self] in self?.observe() }
        }
        if input.sessionFinished { finishPlaybackSession() } else { resumePlaybackSession() }
        coordinator.update(current: input.current, upcoming: input.upcoming, sources: input.sources,
            customSources: input.customSources, automaticEnabled: input.automaticEnabled,
            showsTranslation: input.showsTranslation, isForeground: input.foreground, mode: input.mode,
            prefetchLimit: input.prefetchLimit, allowed: input.permitsForegroundLookup && input.online,
            hasHeadroom: input.headroom, constrained: input.constrained, buffering: input.buffering)
        coordinator.setCacheCapacity(megabytes: input.cacheMegabytes)
        coordinator.adjustPolish(limits: input.limits)
        updateBackgroundTask(isBackground: input.background, hasWork: coordinator.hasCurrentWork)
    }

    /// Acquire time while current-song work is active, before suspension can begin.
    /// No speculative job gets an assertion; the OS still decides the time available.
    private func updateBackgroundTask(isBackground: Bool, hasWork: Bool) {
        #if !targetEnvironment(macCatalyst)
        if finishedSession {
            if !finishingCache { endBackgroundTask() }
            return
        }
        if !hasWork {
            endBackgroundTask()
            return
        }
        guard backgroundTask == .invalid else { return }
        let generation = UUID()
        backgroundGeneration = generation
        let granted = UIApplication.shared.beginBackgroundTask(withName: "Finish current lyrics translation") { [weak self] in
            // UIKit calls this synchronously on the main actor. End the assertion here,
            // rather than enqueueing cleanup after the expiration window has closed.
            guard let self, self.backgroundGeneration == generation else { return }
            self.coordinator.suspendForBackgroundExpiration()
            self.endBackgroundTask()
        }
        // A synchronous expiration cannot leave the just-returned identifier installed
        // after its owner has already ended. A late old expiration cannot touch a new one.
        guard backgroundGeneration == generation else {
            if granted != .invalid { UIApplication.shared.endBackgroundTask(granted) }
            return
        }
        backgroundTask = granted
        if backgroundTask != .invalid {
            coordinator.setBackgroundExecutionAllowed(true)
        } else {
            coordinator.setBackgroundExecutionAllowed(false)
            if isBackground { coordinator.suspendForBackgroundExpiration() }
        }
        #endif
    }

    private func endBackgroundTask() {
        backgroundGeneration = UUID()
        coordinator.setBackgroundExecutionAllowed(false)
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask
        backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }

    private struct Input {
        let current: Song?
        let upcoming: [Song]
        let sources: [LyricsSource]
        let customSources: [CustomLyricsSource]
        let automaticEnabled: Bool
        let showsTranslation: Bool
        let foreground: Bool
        let background: Bool
        let hasCurrentWork: Bool
        let sessionFinished: Bool
        let mode: LyricsTranslationMode
        let prefetchLimit: Int
        let cacheMegabytes: Int
        let online: Bool
        let headroom: Bool
        let constrained: Bool
        let buffering: Bool
        let limits: Set<LyricWorkLimit>
        let permitsForegroundLookup: Bool
    }
}
