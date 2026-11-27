#if !targetEnvironment(macCatalyst)
import ActivityKit
import Foundation
import KodaCore
import Observation

/// One manually started activity. Time comes from the existing media clock;
/// one-shot wake-ups target the next boundary only while the player advances.
@MainActor @Observable
final class CarPlayLyricsActivity {
    typealias State = KodaLyricsActivityAttributes.ContentState
    private typealias LiveActivity = Activity<KodaLyricsActivityAttributes>

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var activity: LiveActivity?
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var owner: Owner?
    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var prepared: Prepared?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var stateObserver: Task<Void, Never>?
    @ObservationIgnored private var boundary: Task<Void, Never>?
    @ObservationIgnored private var update: Task<Void, Never>?
    @ObservationIgnored private var pending: Publication?
    @ObservationIgnored private var sentState: State?
    @ObservationIgnored private var lastPublication: ContinuousClock.Instant?

    private(set) var isActive = false
    private(set) var isEnding = false
    private(set) var showsLyrics = false
    var errorMessage: String?

    private struct Owner: Equatable {
        var profileID: UUID
        var accountID: String?

        init(_ app: AppModel) {
            profileID = app.roster.activeID
            accountID = app.roster.active.datasyncId
        }
    }

    private struct Request: Equatable {
        let song: Song
        let candidate: LyricsCandidate?
        let importRevision: Int
    }

    private struct Prepared {
        var lines: [LyricLine] = []
        var translationInput: [LyricsTranslationText] = []
        var imported: [Int: String] = [:]
    }

    private struct Publication: Equatable {
        var state: State
        var staleDate: Date?
    }

    init(app: AppModel) { self.app = app }

    func discardOrphanedActivities() {
        let activityIDs = LiveActivity.activities.map(\.id)
        guard !activityIDs.isEmpty else { return }
        isEnding = true
        Task { [weak self] in
            for id in activityIDs { await Self.endActivity(id) }
            self?.isEnding = false
        }
    }

    func start() {
        guard !isActive, !isEnding, let app else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            errorMessage = String(localized: "Allow Live Activities for Koda in iPhone Settings.")
            return
        }
        guard let song = app.player.current, !app.player.isPlaybackSessionFinished else {
            errorMessage = String(localized: "Start playing a song before starting Koda Lyrics.")
            return
        }
        do {
            let state = State(title: song.title, isPlaying: app.player.timeAnchor.rate > 0, status: .hidden)
            let started = try LiveActivity.request(attributes: KodaLyricsActivityAttributes(),
                                                   content: ActivityContent(state: state, staleDate: nil), pushType: nil)
            activity = started
            owner = Owner(app)
            sentState = state
            lastPublication = .now
            isActive = true
            let generation = epoch
            stateObserver = Task { [weak self] in
                for await state in started.activityStateUpdates {
                    guard let self, !Task.isCancelled, self.epoch == generation else { return }
                    if state == .dismissed || state == .ended {
                        self.stop()
                        return
                    }
                }
            }
            observe(generation)
        } catch {
            errorMessage = String(localized: "Koda could not start the lyrics activity.")
        }
    }

    func showLyrics(activityID: String) throws {
        guard let activity, activity.id == activityID,
              activity.activityState == .active || activity.activityState == .stale,
              let app, owner == Owner(app), !app.player.isPlaybackSessionFinished else {
            throw CarPlayIntentError.activityUnavailable
        }
        guard !showsLyrics else { return }
        showsLyrics = true
        app.lyricsPreparation.preparesCarPlayLyrics = true
    }

    func stop() {
        guard let id = activity?.id else { return }
        let previousUpdate = update
        epoch = UUID()
        self.activity = nil
        owner = nil
        isActive = false
        isEnding = true
        showsLyrics = false
        app?.lyricsPreparation.preparesCarPlayLyrics = false
        stateObserver?.cancel(); stateObserver = nil
        lookup?.cancel(); lookup = nil
        boundary?.cancel(); boundary = nil
        previousUpdate?.cancel(); update = nil
        request = nil
        prepared = nil
        pending = nil
        sentState = nil
        lastPublication = nil
        Task { [weak self] in
            await previousUpdate?.value
            await Self.endActivity(id)
            self?.isEnding = false
        }
    }

    private func observe(_ generation: UUID) {
        guard epoch == generation, isActive else { return }
        withObservationTracking {
            _ = preparedRevision
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe(generation) }
        }
    }

    private func refresh() {
        guard let app else { return }
        let player = app.player
        guard owner == Owner(app), !player.isPlaybackSessionFinished, let song = player.current else {
            stop()
            return
        }
        let settings = app.settings
        let anchor = player.timeAnchor
        let isPlaying = player.wantsToPlay && anchor.rate > 0
        let position = player.position()
        boundary?.cancel()
        boundary = nil

        var state = State(title: song.title, isPlaying: isPlaying, status: .hidden)
        var staleDate: Date?
        if showsLyrics {
            let versions = app.lyricsTranslation.versions
            let candidate = versions.current?.songID == song.id ? versions.current : nil
            let needed = Request(song: song, candidate: candidate, importRevision: versions.editRevision)
            if request != needed { load(needed, in: app) }
            state.status = candidate == nil && !versions.searching ? .unavailable : .loading
            if let prepared {
                if prepared.lines.isEmpty {
                    state.status = .unavailable
                } else {
                    let sample = CarPlayLyricsTiming.sample(at: position, offset: app.library.carPlayLyricsOffset(for: song.id), versionOffset: versions.offset(for: song.id),
                                                            in: prepared.lines)
                    let translatedLines = app.lyricsTranslation.result(songID: song.id, lines: prepared.translationInput,
                        imported: prepared.imported, importsEnabled: settings.importedLyricsEnabled).lines
                    state.status = .betweenLines
                    if let line = sample.line {
                        let translated = translatedLines[line.id]
                        state = State(title: song.title, isPlaying: isPlaying, status: .line,
                                      original: line.text, translation: translated)
                    }
                    if isPlaying, let next = sample.nextPosition, player.duration <= 0 || next <= player.duration {
                        let delay = max(0, anchor.date.timeIntervalSinceNow) + max(0.05, (next - position) / anchor.rate + 0.02)
                        let generation = epoch
                        let budget = lastPublication.map { ContinuousClock().now.duration(to: $0.advanced(by: .seconds(1))) } ?? .zero
                        let wait = max(Duration.seconds(delay), budget)
                        boundary = Task { [weak self] in
                            do { try await Task.sleep(for: wait) } catch { return }
                            guard let self, self.epoch == generation else { return }
                            self.refresh()
                        }
                        staleDate = Date().addingTimeInterval(delay + 15)
                    }
                }
            }
            if isPlaying, staleDate == nil {
                let remaining = player.duration > 0 ? max(0, player.duration - position) / anchor.rate : 45
                staleDate = Date().addingTimeInterval(remaining + 15)
            }
        }
        enqueue(Publication(state: state, staleDate: staleDate))
    }

    private func load(_ needed: Request, in app: AppModel) {
        lookup?.cancel()
        let sameOriginals = request.map {
            $0.song == needed.song && $0.candidate?.id == needed.candidate?.id
        } ?? false
        if !sameOriginals { prepared = nil }
        request = needed
        let generation = epoch
        lookup = Task { [weak self, weak app] in
            let lyrics = needed.candidate?.lyrics
            guard let self, let app, self.isCurrent(needed, in: app, generation: generation) else { return }
            guard case .synced(let lines)? = lyrics else {
                self.prepared = needed.candidate == nil ? nil : Prepared()
                self.observeAfterLoad()
                return
            }
            let input = lines.map { LyricsTranslationText(id: $0.id, text: $0.text) }
            let imported = self.prepared?.lines == lines ? (self.prepared?.imported ?? [:]) : [:]
            self.prepared = Prepared(lines: lines, translationInput: input, imported: imported)
            self.observeAfterLoad()
            let document = needed.candidate.flatMap { app.lyricsTranslation.versions.importedDocument(for: $0) }
            let saved = await Task.detached(priority: .utility) { document?.aligned(to: lines) ?? [:] }.value
            guard self.isCurrent(needed, in: app, generation: generation) else { return }
            self.prepared = Prepared(lines: lines, translationInput: input, imported: saved)
            self.observeAfterLoad()
        }
    }

    private func isCurrent(_ expected: Request, in app: AppModel, generation: UUID) -> Bool {
        !Task.isCancelled && epoch == generation && owner == Owner(app)
            && app.player.current == expected.song && request == expected && !app.player.isPlaybackSessionFinished
    }

    private func observeAfterLoad() {
        // A newly loaded set introduces new dependencies (translation snapshots and
        // the delay). Invalidate the old observation before registering those.
        preparedRevision &+= 1
    }

    private var preparedRevision = 0

    private func enqueue(_ publication: Publication) {
        guard let activity else { return }
        // Repeated clock samples for the same line need no ActivityKit update.
        // A stale estimate is refreshed only after a materially different prediction.
        if let pending, pending.state == publication.state, Self.sameDeadline(pending.staleDate, publication.staleDate) { return }
        if pending == nil, sentState == publication.state,
           Self.sameDeadline(activity.content.staleDate, publication.staleDate) { return }
        pending = publication
        guard update == nil else { return }
        let generation = epoch
        let id = activity.id
        update = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == generation { self.update = nil } }
            while !Task.isCancelled, self.epoch == generation, self.pending != nil {
                guard !Task.isCancelled, self.epoch == generation, let latest = self.pending else { return }
                self.pending = nil
                self.sentState = latest.state
                self.lastPublication = .now
                await Self.updateActivity(id, state: latest.state, staleDate: latest.staleDate)
            }
        }
    }

    // ActivityKit's handles are not Sendable. Reacquire a local handle at the
    // async call boundary instead of moving the controller's handle across it.
    private nonisolated static func updateActivity(_ id: String, state: State, staleDate: Date?) async {
        guard let activity = LiveActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.update(ActivityContent(state: state, staleDate: staleDate))
    }

    private nonisolated static func endActivity(_ id: String) async {
        guard let activity = LiveActivity.activities.first(where: { $0.id == id }) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    private static func sameDeadline(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 4
        default: false
        }
    }
}
#endif
