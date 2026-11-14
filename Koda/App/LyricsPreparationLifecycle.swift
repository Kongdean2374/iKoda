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
    private var foreground = false
    private var background = false

    init(player: Player, settings: AppSettings, coordinator: LyricsTranslationCoordinator) {
        self.player = player
        self.settings = settings
        self.coordinator = coordinator
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    func setScenePhase(_ phase: ScenePhase) {
        foreground = phase == .active
        background = phase == .background
    }

    private func observe() {
        let input = withObservationTracking {
            let current = player.current
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
                showsTranslation: settings.showsLyricsTranslation, foreground: foreground,
                background: background, hasCurrentWork: coordinator.hasCurrentWork)
        } onChange: { [weak self] in
            // Observation fires before the property mutation. Read the committed values
            // on the next main-actor turn and rearm the one-shot observation once.
            Task { @MainActor [weak self] in self?.observe() }
        }
        coordinator.update(current: input.current, upcoming: input.upcoming, sources: input.sources,
            customSources: input.customSources, automaticEnabled: input.automaticEnabled,
            showsTranslation: input.showsTranslation, isForeground: input.foreground)
        updateBackgroundTask(isBackground: input.background, hasWork: coordinator.hasCurrentWork)
    }

    /// Acquire time while current-song work is active, before suspension can begin.
    /// No speculative job gets an assertion; the OS still decides the time available.
    private func updateBackgroundTask(isBackground: Bool, hasWork: Bool) {
        #if !targetEnvironment(macCatalyst)
        if !hasWork {
            endBackgroundTask()
            return
        }
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish current lyrics translation") { [weak self] in
            // UIKit calls this synchronously on the main actor. End the assertion here,
            // rather than enqueueing cleanup after the expiration window has closed.
            guard let self else { return }
            self.coordinator.suspendForBackgroundExpiration()
            self.endBackgroundTask()
        }
        if backgroundTask != .invalid {
            coordinator.setBackgroundExecutionAllowed(true)
        } else {
            coordinator.setBackgroundExecutionAllowed(false)
            if isBackground { coordinator.suspendForBackgroundExpiration() }
        }
        #endif
    }

    private func endBackgroundTask() {
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
    }
}
