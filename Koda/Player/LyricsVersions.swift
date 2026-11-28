import Foundation
import KodaCore
import Observation

/// App lifetime state for the currently playing recording. Views observe this
/// projection. They never own the network lookup or choose a different version.
@MainActor @Observable
final class LyricsVersions {
    private(set) var current: LyricsCandidate?
    private(set) var results: [LyricsSourceResult] = []
    private(set) var manualResults: [LyricsSourceResult] = []
    private(set) var searching = false
    private(set) var searchingManually = false
    private(set) var preference = LyricsVersionStore.Preference()
    private(set) var cacheBytes = 0
    private(set) var editRevision = 0
    private(set) var assessments: [LyricsCandidate.Identity: LyricsCandidateAssessment] = [:]
    @ObservationIgnored private let evaluator = LyricsCandidateEvaluator.Cache()
    @ObservationIgnored private var assessmentTask: Task<Void, Never>?
    @ObservationIgnored private var assessmentGeneration = UUID()
    @ObservationIgnored private var assessedIDs: [LyricsCandidate.Identity] = []
    private(set) var originalLookupSeconds: TimeInterval?
    private(set) var originalCacheUse: LyricCacheUse = .unchecked
    private(set) var profileScope = UUID()
    var error: String?

    @ObservationIgnored private let client: LyricsClient
    @ObservationIgnored let store: LyricsVersionStore
    @ObservationIgnored private var profile: URL?
    private var context: Context?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var manualLookup: Task<Void, Never>?
    @ObservationIgnored private var manualGeneration = UUID()
    #if DEBUG
    @ObservationIgnored private var fixtureResults: [LyricsSourceResult]?
    #endif
    private var allowed = false
    var canSearch: Bool { allowed }
    @ObservationIgnored private var constrained = false
    @ObservationIgnored private var attempted = false
    @ObservationIgnored var onSelection: ((LyricsCandidate?) -> Void)?

    nonisolated struct Context: Equatable, Sendable {
        var song: Song
        var sources: [LyricsSource]
        var custom: [CustomLyricsSource]
        var cacheKey: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let search = (try? encoder.encode(LyricsSearch(song: song)).base64EncodedString()) ?? ""
            let providers = (try? encoder.encode(custom).base64EncodedString()) ?? ""
            return ([song.id, search, providers] + sources.map(\.rawValue)).joined(separator: "|")
        }
    }

    init(client: LyricsClient, cache: URL) {
        self.client = client
        store = LyricsVersionStore(cache: cache)
    }

    private var instrumentals: Set<String> = []
    var isInstrumental: Bool { song.map { isInstrumental($0.id) } ?? false }
    func isInstrumental(_ id: String) -> Bool { instrumentals.contains(id) }

    func setInstrumentals(_ ids: Set<String>) {
        guard instrumentals != ids else { return }
        let wasMarked = isInstrumental
        instrumentals = ids
        if wasMarked != isInstrumental {
            let active = context
            resetContext(active)
            if !isInstrumental { search() }
        }
    }

    var song: Song? { context?.song }
    struct SourceOption: Identifiable {
        let id: String
        let name: String
    }

    var configuredSources: [SourceOption] {
        guard let context else { return [] }
        return context.sources.map { .init(id: $0.rawValue, name: $0.title) }
            + context.custom.filter(\.isEnabled).map { .init(id: $0.id.uuidString, name: $0.name) }
    }
    var candidates: [LyricsCandidate] { results.flatMap(\.candidates) }
    var recommendation: LyricsCandidate? {
        LyricsVersionSelection.recommended(candidates, allowLowConfidence: true, assessments: assessments)
    }

    func setProfile(_ directory: URL, replacingSession: Bool = false) {
        guard profile != directory || replacingSession else { return }
        profile = directory
        profileScope = UUID()
        resetContext(nil)
    }

    func follow(song: Song?, sources: [LyricsSource], custom: [CustomLyricsSource], allowed: Bool, constrained: Bool) {
        #if DEBUG
        if fixtureResults != nil { return }
        #endif
        let resumed = allowed && !self.allowed
        let stopped = !allowed && self.allowed
        self.allowed = allowed
        self.constrained = constrained
        let next = song.map { Context(song: $0, sources: sources, custom: custom) }
        let changed = context != next
        if changed { resetContext(next) }
        if stopped { suspend() }
        if !isInstrumental, lookup == nil, !attempted || resumed { search() }
    }

    func suspend() {
        lookup?.cancel(); lookup = nil
        manualLookup?.cancel(); manualLookup = nil
        assessmentTask?.cancel()
        assessmentTask = nil
        assessmentGeneration = UUID()
        assessedIDs = []
        manualGeneration = UUID()
        searching = false; searchingManually = false
        generation = UUID()
    }

    private func resetContext(_ next: Context?) {
        suspend()
        context = next
        attempted = false
        results = []; manualResults = []
        assessments = [:]
        preference = .init()
        originalLookupSeconds = nil
        originalCacheUse = .unchecked
        error = nil
        apply(nil)
    }

    func search(force: Bool = false, source: String? = nil, userInitiated: Bool = false) {
        guard !isInstrumental else { return }
        if lookup != nil, !force, source == nil { return }
        #if DEBUG
        if let fixtureResults {
            results = source.map { selected in fixtureResults.filter { $0.source == selected } } ?? fixtureResults
            return
        }
        #endif
        guard let context, let profile else { return }
        attempted = true
        lookup?.cancel()
        generation = UUID()
        let token = generation
        let startedAt = Date()
        let lookupStarted = ContinuousClock.now
        searching = true
        error = nil

        lookup = Task { [weak self, client, store] in
            let cacheTicket = await store.ticket()
            let saved = await store.preference(profile: profile, songID: context.song.id)
            let cached = force || source != nil ? nil : await store.catalogue(key: context.cacheKey)
            guard let self, self.accepts(token) else { return }
            self.acceptPreference(saved)
            self.originalCacheUse = cached == nil && saved.selected == nil ? .miss : .hit
            if self.current == nil, let selected = self.preference.selected {
                self.originalLookupSeconds = lookupStarted.duration(to: .now).lyricSeconds
                self.apply(selected)
            }
            if let cached {
                if self.originalLookupSeconds == nil { self.originalLookupSeconds = lookupStarted.duration(to: .now).lyricSeconds }
                self.results = cached.results
                self.autoSelect(finished: false)
                self.assessCandidates(allowFallback: cached.isFresh)
                let returned = Set(cached.results.map(\.source))
                if cached.isFresh && cached.results.contains(where: { !$0.candidates.isEmpty })
                    && self.configuredSources.allSatisfy({ returned.contains($0.id) }) {
                    self.finishLookup(token)
                    return
                }
                if cached.confirmsMissing(sources: Set(self.configuredSources.map(\.id))) {
                    self.finishLookup(token)
                    return
                }
            }

            guard self.allowed else {
                self.assessCandidates(allowFallback: true)
                self.finishLookup(token)
                return
            }
            var received: [LyricsSourceResult] = []
            var sources = context.sources
            var custom = context.custom
            if self.constrained && !userInitiated { sources = Array(sources.prefix(2)); custom = [] }
            for await event in client.candidateResults(for: context.song, sources: sources, customSources: custom, only: source) {
                guard self.accepts(token) else { return }
                Self.merge(event, into: &received)
                Self.merge(event, into: &self.results)
                if let current = self.current, let answer = event.candidates.first(where: { $0.id == current.id }) {
                    let updated = current.retainingTranslations(from: answer)
                    if updated != current { self.current = updated }
                }
                self.autoSelect(finished: false)
                self.assessCandidates(allowFallback: false)
                if self.current != nil, self.originalLookupSeconds == nil {
                    self.originalLookupSeconds = lookupStarted.duration(to: .now).lyricSeconds
                }
            }
            guard self.accepts(token) else { return }
            self.assessCandidates(allowFallback: true)
            if userInitiated, !received.contains(where: { $0.state == .found }), self.current != nil {
                self.error = String(localized: "Refresh found no usable lyrics. The current version is still available.")
            }
            await store.cache(.init(results: received, fetchedAt: startedAt), key: context.cacheKey, ticket: cacheTicket, expectedSources: Set(self.configuredSources.map(\.id)))
            self.finishLookup(token)
        }
    }

    func manualSearch(_ search: LyricsSearch, source: String?, songID: String, scope: UUID) {
        guard !isInstrumental, song?.id == songID, scope == profileScope else { return }
        #if DEBUG
        if let fixtureResults {
            manualResults = source.map { selected in fixtureResults.filter { $0.source == selected } } ?? fixtureResults
            return
        }
        #endif
        guard let context, allowed else { return }
        manualLookup?.cancel()
        manualGeneration = UUID()
        let token = manualGeneration
        searchingManually = true
        manualResults = []
        manualLookup = Task { [weak self, client] in
            for await result in client.candidateResults(for: context.song, search: search,
                sources: context.sources, customSources: context.custom, only: source) {
                guard let self, self.manualGeneration == token, !Task.isCancelled else { return }
                Self.merge(result, into: &self.manualResults)
            }
            guard let self, self.manualGeneration == token, !Task.isCancelled else { return }
            self.searchingManually = false
            self.manualLookup = nil
        }
    }

    func cancelManualSearch() {
        manualLookup?.cancel(); manualLookup = nil
        manualGeneration = UUID()
        searchingManually = false
    }

    func select(_ candidate: LyricsCandidate?, expectedScope: UUID? = nil) async {
        guard expectedScope == nil || expectedScope == profileScope else { return }
        guard let profile, let song, candidate == nil || song.id == candidate?.songID else { return }
        // Cancel cached preference reads that could otherwise apply the old choice
        // while the durable write is being made.
        let wasSearching = searching
        lookup?.cancel(); lookup = nil; searching = false
        generation = UUID()
        let token = generation
        do {
            let saved = try await store.select(candidate, profile: profile, songID: song.id)
            guard generation == token else { return }
            acceptPreference(saved)
            apply(preference.selected ?? recommendation)
            if wasSearching || current == nil { search() }
        } catch { setError(error, token: token) }
    }

    func offset(for songID: String) -> TimeInterval {
        guard let current, current.songID == songID else { return 0 }
        return preference.offset(for: current.id)
    }

    func edits(for candidate: LyricsCandidate) -> [Int: String] {
        candidate.songID == song?.id ? preference.edits(for: candidate.id) : [:]
    }

    func saveOffset(_ offset: Double, for candidate: LyricsCandidate, expectedScope: UUID) async -> Bool {
        guard expectedScope == profileScope else { return false }
        guard let profile, song?.id == candidate.songID else { return false }
        do {
            let saved = try await store.setOffset(offset, for: candidate.id, profile: profile, songID: candidate.songID)
            guard profileScope == expectedScope, song?.id == candidate.songID else { return false }
            acceptPreference(saved)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func saveEdits(_ edits: [Int: String], for candidate: LyricsCandidate, expectedScope: UUID) async -> Bool {
        guard expectedScope == profileScope else { return false }
        guard let profile, song?.id == candidate.songID else { return false }
        do {
            let saved = try await store.saveEdits(edits, for: candidate, profile: profile)
            guard profileScope == expectedScope, song?.id == candidate.songID else { return false }
            acceptPreference(saved)
            editRevision &+= 1
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    var translationSelection: LyricTranslationSelection {
        guard let current else { return .automatic }
        return preference.translationSelections?[current.id.cacheNamespace] ?? .automatic
    }

    func selectTranslation(_ choice: LyricTranslationSelection) async {
        guard let current, let profile else { return }
        let scope = profileScope
        do {
            let saved = try await store.selectTranslation(choice, for: current, profile: profile)
            guard profileScope == scope, self.current?.id == current.id else { return }
            acceptPreference(saved)
            editRevision &+= 1
        } catch {
            guard profileScope == scope, self.current?.id == current.id else { return }
            self.error = error.localizedDescription
        }
    }

    func importedDocument(for candidate: LyricsCandidate) -> LyricTranslationDocument? {
        guard candidate.songID == song?.id else { return nil }
        return preference.imports?[candidate.id.cacheNamespace]
    }

    func saveImport(_ document: LyricTranslationDocument?, candidate: LyricsCandidate, expectedScope: UUID) async throws {
        guard profileScope == expectedScope, let profile, song?.id == candidate.songID,
              candidate.id == current?.id else { throw CancellationError() }
        let saved = try await store.importTranslation(document, for: candidate, profile: profile)
        guard profileScope == expectedScope, song?.id == candidate.songID else { throw CancellationError() }
        acceptPreference(saved)
        editRevision &+= 1
    }

    func resetAllSelections() async {
        guard let profile else { return }
        let scope = profileScope
        do {
            try await store.resetSelections(profile: profile)
            guard profileScope == scope else { return }
            await select(nil)
        } catch { self.error = error.localizedDescription }
    }

    #if DEBUG
    func installUITestVersions(for song: Song, playable: Bool = false) {
        setProfile(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        resetContext(.init(song: song, sources: [.lrclib, .youLyPlus], custom: []))
        let first: LyricsCandidate
        if playable, let tagged = LyricsCandidate.imported(song: song, sourceName: "Fixture Lyrics", text: """
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal">
        <head><metadata><itunes:translations><itunes:translation xml:lang="zh-Hant">
        <itunes:text for="a">我們等著晨光</itunes:text>
        </itunes:translation></itunes:translations></metadata></head>
        <body><div><p begin="0s" end="120s" itunes:key="a"><span begin="0s" end="30s">We wait</span> <span begin="30s" end="115s">for dawn</span></p>
        <p begin="120s" end="175s" itunes:key="b">The paper boat sails</p></div></body>
        </tt>
        """) {
            first = tagged
        } else {
            first = LyricsCandidate(song: song, source: LyricsSource.lrclib.rawValue, sourceName: "LRCLIB",
                metadata: .init(title: song.title, artist: song.artistLine, duration: song.duration),
                lyrics: .synced(Lyrics.parseLRC("[00:12.00]We listen to the ocean\n[00:15.00]The waves return")))
        }
        let second = LyricsCandidate(song: song, source: LyricsSource.youLyPlus.rawValue, sourceName: "YouLyPlus",
            metadata: .init(title: song.title, artist: song.artistLine, duration: song.duration),
            lyrics: .synced(Lyrics.parseLRC("[00:13.00]The song of the ocean\n[00:18.00]We follow the tide")))
        let prepared = [first, second].map { LyricsSourceResult(source: $0.id.source, name: $0.sourceName, state: .found, candidates: [$0]) }
        fixtureResults = prepared
        allowed = true
        results = prepared
        apply(first)
        assessCandidates(allowFallback: true)
    }
    #endif

    func refreshUsage() async { cacheBytes = await store.usage() }

    func clearCatalogueCache() async {
        suspend()
        do { try await store.clearCache(); cacheBytes = 0 } catch { self.error = error.localizedDescription }
    }

    /// Upcoming work reads the same saved selection and candidate cache as Now Playing.
    func preparedVersion(_ context: Context) async -> LyricsCandidate? {
        guard !isInstrumental(context.song.id), let profile else { return nil }
        let cacheTicket = await store.ticket()
        let startedAt = Date()
        let pref = await store.preference(profile: profile, songID: context.song.id)
        if let selected = pref.selected { return selected }
        if let cached = await store.catalogue(key: context.cacheKey),
           let winner = LyricsVersionSelection.recommended(cached.results.flatMap(\.candidates), allowLowConfidence: true,
              assessments: await evaluator.evaluate(cached.results.flatMap(\.candidates))) {
            return winner
        }
        let expectedSources = Set(context.sources.map(\.rawValue) + context.custom.filter(\.isEnabled).map { $0.id.uuidString })
        if let cached = await store.catalogue(key: context.cacheKey), cached.confirmsMissing(sources: expectedSources) { return nil }
        var results: [LyricsSourceResult] = []
        for await result in client.candidateResults(for: context.song, sources: context.sources, customSources: context.custom) {
            guard !Task.isCancelled, !isInstrumental(context.song.id) else { return nil }
            Self.merge(result, into: &results)
            if let winner = LyricsVersionSelection.recommended(results.flatMap(\.candidates), allowLowConfidence: false, assessments: [:]) {
                await store.cache(.init(results: results, fetchedAt: startedAt), key: context.cacheKey, ticket: cacheTicket)
                return winner
            }
        }
        guard !Task.isCancelled, !isInstrumental(context.song.id) else { return nil }
        await store.cache(.init(results: results, fetchedAt: startedAt), key: context.cacheKey, ticket: cacheTicket, expectedSources: expectedSources)
        let candidates = results.flatMap(\.candidates)
        let assessed = await evaluator.evaluate(candidates)
        return Task.isCancelled ? nil : LyricsVersionSelection.recommended(candidates, allowLowConfidence: true, assessments: assessed)
    }

    private func autoSelect(finished: Bool) {
        guard current == nil else { return }
        if let winner = LyricsVersionSelection.recommended(candidates, allowLowConfidence: finished, assessments: assessments) {
            apply(winner)
        }
    }

    private func assessCandidates(allowFallback: Bool) {
        let available = candidates
        let ids = available.map(\.id)
        guard ids != assessedIDs || (allowFallback && current == nil && assessmentTask != nil) else {
            if allowFallback, assessmentTask == nil { autoSelect(finished: true) }
            return
        }
        assessmentTask?.cancel()
        assessedIDs = ids
        assessmentGeneration = UUID()
        let token = assessmentGeneration
        assessmentTask = Task(priority: .utility) { [weak self, evaluator] in
            let assessments = await evaluator.evaluate(available)
            guard let self, !Task.isCancelled, assessmentGeneration == token else { return }
            self.assessmentTask = nil
            self.assessments = assessments
            self.autoSelect(finished: allowFallback)
        }
    }

    private func apply(_ candidate: LyricsCandidate?) {
        guard candidate?.id != current?.id || candidate?.songID != current?.songID else { return }
        current = candidate
        onSelection?(candidate)
    }

    private func finishLookup(_ token: UUID) {
        guard accepts(token) else { return }
        searching = false
        lookup = nil
    }

    private func acceptPreference(_ saved: LyricsVersionStore.Preference) {
        if (saved.revision ?? 0) >= (preference.revision ?? 0) { preference = saved }
    }

    private func accepts(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }
    private func setError(_ error: Error, token: UUID) {
        if generation == token { self.error = error.localizedDescription }
    }

    private static func merge(_ result: LyricsSourceResult, into results: inout [LyricsSourceResult]) {
        if let index = results.firstIndex(where: { $0.source == result.source }) {
            if result.candidates.isEmpty, !results[index].candidates.isEmpty {
                results[index].state = result.state
                results[index].retryAt = result.retryAt
            } else {
                results[index] = .init(source: result.source, name: result.name, state: result.state,
                                       candidates: result.candidates + results[index].candidates, retryAt: result.retryAt)
            }
        } else { results.append(result) }
    }
}
