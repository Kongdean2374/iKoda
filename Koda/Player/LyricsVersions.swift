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
    var recommendation: LyricsCandidate? { LyricsVersionSelection.recommended(candidates, allowLowConfidence: true) }

    func setProfile(_ directory: URL) {
        guard profile != directory else { return }
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
        if lookup == nil, !attempted || resumed { search() }
    }

    func suspend() {
        lookup?.cancel(); lookup = nil
        manualLookup?.cancel(); manualLookup = nil
        manualGeneration = UUID()
        searching = false; searchingManually = false
        generation = UUID()
    }

    private func resetContext(_ next: Context?) {
        suspend()
        context = next
        attempted = false
        results = []; manualResults = []
        preference = .init()
        error = nil
        apply(nil)
    }

    func search(force: Bool = false, source: String? = nil, userInitiated: Bool = false) {
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
        searching = true
        error = nil

        lookup = Task { [weak self, client, store] in
            let cacheTicket = await store.ticket()
            let saved = await store.preference(profile: profile, songID: context.song.id)
            let cached = force || source != nil ? nil : await store.catalogue(key: context.cacheKey)
            guard let self, self.accepts(token) else { return }
            self.preference = saved
            if self.current == nil, let selected = saved.selected { self.apply(selected) }
            if let cached {
                self.results = cached.results
                self.autoSelect(finished: cached.isFresh)
                let returned = Set(cached.results.map(\.source))
                if cached.isFresh && self.configuredSources.allSatisfy({ returned.contains($0.id) }) {
                    self.finishLookup(token)
                    return
                }
            }

            guard self.allowed else { self.finishLookup(token); return }
            var received: [LyricsSourceResult] = []
            var sources = context.sources
            var custom = context.custom
            if self.constrained && !userInitiated { sources = Array(sources.prefix(2)); custom = [] }
            for await event in client.candidateResults(for: context.song, sources: sources, customSources: custom, only: source) {
                guard self.accepts(token) else { return }
                Self.merge(event, into: &received)
                Self.merge(event, into: &self.results)
                self.autoSelect(finished: false)
            }
            guard self.accepts(token) else { return }
            self.autoSelect(finished: true)
            await store.cache(.init(results: received, fetchedAt: startedAt), key: context.cacheKey, ticket: cacheTicket)
            self.finishLookup(token)
        }
    }

    func manualSearch(_ search: LyricsSearch, source: String?) {
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
            preference = saved
            apply(candidate ?? recommendation)
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
            guard self.profile == profile, song?.id == candidate.songID else { return false }
            preference = saved
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func saveEdits(_ edits: [Int: String], for candidate: LyricsCandidate, expectedScope: UUID) async -> Bool {
        guard expectedScope == profileScope else { return false }
        guard let profile, song?.id == candidate.songID else { return false }
        do {
            let saved = try await store.saveEdits(edits, for: candidate, profile: profile)
            guard self.profile == profile, song?.id == candidate.songID else { return false }
            preference = saved
            editRevision &+= 1
            return true
        } catch { self.error = error.localizedDescription; return false }
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
        preference = saved
        editRevision &+= 1
    }

    func resetAllSelections() async {
        guard let profile else { return }
        do {
            try await store.resetSelections(profile: profile)
            guard self.profile == profile else { return }
            await select(nil)
        } catch { self.error = error.localizedDescription }
    }

    #if DEBUG
    func installUITestVersions(for song: Song) {
        setProfile(FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        resetContext(.init(song: song, sources: [.lrclib, .youLyPlus], custom: []))
        let first = LyricsCandidate(song: song, source: LyricsSource.lrclib.rawValue, sourceName: "LRCLIB",
            metadata: .init(title: song.title, artist: song.artistLine, duration: song.duration),
            lyrics: .synced(Lyrics.parseLRC("[00:12.00]We listen to the ocean\n[00:15.00]The waves return")))
        let second = LyricsCandidate(song: song, source: LyricsSource.youLyPlus.rawValue, sourceName: "YouLyPlus",
            metadata: .init(title: song.title, artist: song.artistLine, duration: song.duration),
            lyrics: .synced(Lyrics.parseLRC("[00:13.00]The song of the ocean\n[00:18.00]We follow the tide")))
        let prepared = [first, second].map { LyricsSourceResult(source: $0.id.source, name: $0.sourceName, state: .found, candidates: [$0]) }
        fixtureResults = prepared
        allowed = true
        results = prepared
        apply(first)
    }
    #endif

    func refreshUsage() async { cacheBytes = await store.usage() }

    func clearCatalogueCache() async {
        suspend()
        do { try await store.clearCache(); cacheBytes = 0 } catch { self.error = error.localizedDescription }
    }

    /// Upcoming work reads the same saved selection and candidate cache as Now Playing.
    func preparedVersion(_ context: Context) async -> LyricsCandidate? {
        guard let profile else { return nil }
        let cacheTicket = await store.ticket()
        let startedAt = Date()
        let pref = await store.preference(profile: profile, songID: context.song.id)
        if let selected = pref.selected { return selected }
        if let cached = await store.catalogue(key: context.cacheKey),
           let winner = LyricsVersionSelection.recommended(cached.results.flatMap(\.candidates), allowLowConfidence: true) {
            return winner
        }
        var results: [LyricsSourceResult] = []
        for await result in client.candidateResults(for: context.song, sources: context.sources, customSources: context.custom) {
            guard !Task.isCancelled else { return nil }
            Self.merge(result, into: &results)
            if let winner = LyricsVersionSelection.recommended(results.flatMap(\.candidates), allowLowConfidence: false) {
                await store.cache(.init(results: results, fetchedAt: startedAt), key: context.cacheKey, ticket: cacheTicket)
                return winner
            }
        }
        guard !Task.isCancelled else { return nil }
        await store.cache(.init(results: results, fetchedAt: startedAt), key: context.cacheKey, ticket: cacheTicket)
        return LyricsVersionSelection.recommended(results.flatMap(\.candidates), allowLowConfidence: true)
    }

    private func autoSelect(finished: Bool) {
        guard current == nil else { return }
        if let winner = LyricsVersionSelection.recommended(candidates, allowLowConfidence: finished) { apply(winner) }
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

    private func accepts(_ token: UUID) -> Bool { generation == token && !Task.isCancelled }
    private func setError(_ error: Error, token: UUID) {
        if generation == token { self.error = error.localizedDescription }
    }

    private static func merge(_ result: LyricsSourceResult, into results: inout [LyricsSourceResult]) {
        if let index = results.firstIndex(where: { $0.source == result.source }) {
            if result.candidates.isEmpty, !results[index].candidates.isEmpty {
                results[index].state = result.state
            } else {
                results[index] = .init(source: result.source, name: result.name, state: result.state,
                                       candidates: result.candidates + results[index].candidates)
            }
        } else { results.append(result) }
    }
}
