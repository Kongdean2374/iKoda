import Foundation
import KodaCore
import Observation

struct CloudPlaylistOperationState: Identifiable {
    enum Phase { case running, succeeded, failed, cancelled, needsConfirmation }
    var id: UUID
    var phase: Phase
    var title: String
    var detail: String?
    var completedCount: Int
    var totalCount: Int
    var resultPlaylistID: String?
    var canRetry: Bool
    var canDismiss: Bool
    var canRecoverCreation: Bool
}

enum CloudAccountAccessError: Error, LocalizedError {
    case signedOut, expired, changed, busy, unresolved, damagedReceipt

    var errorDescription: String? {
        switch self {
        case .signedOut: String(localized: "Sign in to YouTube Music to manage cloud playlists.")
        case .expired: String(localized: "Your YouTube Music sign-in has expired. Sign in again to continue.")
        case .changed: String(localized: "The account changed. Open the playlist again before continuing.")
        case .busy: String(localized: "A cloud operation is already in progress.")
        case .unresolved: String(localized: "Check the unfinished cloud operation before making another change.")
        case .damagedReceipt: String(localized: "The saved cloud operation could not be read. Your cloud playlists have not been changed.")
        }
    }
}

/// A directory and read-back cache of the actual account, never a second playlist
/// database. Views may disappear while a write is running; its state and durable
/// receipt belong here, not to a sheet's transient task.
@MainActor @Observable
final class CloudPlaylistCoordinator {
    private struct AccountContext: Sendable {
        let app: AppModel
        let scope: CloudPlaylistAccountScope
        var profileID: UUID { scope.profileID }
        var generation: UInt64 { scope.generation }
    }

    private(set) var catalog: [PlaylistSummary] = []
    private(set) var snapshots: [String: CloudPlaylistSnapshot] = [:]
    private(set) var isRefreshing = false
    private(set) var refreshError: String?
    private(set) var lastRefreshed: Date?
    private(set) var isFromCache = false
    private(set) var operation: CloudPlaylistOperationState?
    private(set) var readProgress: [String: Int] = [:]
    private(set) var catalogRevision: UInt64 = 0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let journal = CloudPlaylistJournal()
    @ObservationIgnored private var profileID: UUID?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var catalogTask: Task<[PlaylistSummary], Error>?
    @ObservationIgnored private var mutationTask: Task<CloudPlaylistSnapshot, Error>?
    @ObservationIgnored private var likeTask: Task<Song, Error>?
    @ObservationIgnored private var dismissalTask: Task<Void, Never>?
    @ObservationIgnored private var checkpoint: CloudPlaylistCheckpoint?
    @ObservationIgnored private var damagedReceipt = false
    @ObservationIgnored private var snapshotOrder: [String] = []
    @ObservationIgnored private let cacheSession = UUID()
    @ObservationIgnored private var cacheRevision: UInt64 = 0

    #if DEBUG
    @ObservationIgnored private var testingTransport: (any CloudPlaylistTransport)?
    @ObservationIgnored private var testingCatalog: [PlaylistSummary]?
    @ObservationIgnored private var testingLike: (@Sendable (Song) async throws -> Song)?
    @ObservationIgnored private var testingDirectory: URL?
    #endif

    init(app: AppModel) {
        self.app = app
        beginProfileIfNeeded()
    }

    var isBusy: Bool { mutationTask != nil || likeTask != nil || dismissalTask != nil }
    var hasSession: Bool {
        #if DEBUG
        if testingTransport != nil { return true }
        #endif
        guard let profile = app?.roster.active else { return false }
        return profile.isSignedIn && !profile.isExpired
    }
    var availabilityMessage: String? {
        guard !hasSession else { return nil }
        return (app?.roster.active.isExpired == true ? CloudAccountAccessError.expired : .signedOut).localizedDescription
    }
    var pendingCreationTitle: String? {
        guard let checkpoint, checkpoint.playlistID == nil,
              checkpoint.pending?.kind == .create,
              case .create(let title, _) = checkpoint.operation else { return nil }
        return title
    }

    /// UI actions capture this before creating a Task, so an old button tap cannot
    /// become a new account's operation when that Task is eventually scheduled.
    func captureScope() -> CloudPlaylistAccountScope? {
        prepareForAccountSync()
        guard let profileID, hasSession else { return nil }
        return .init(profileID: profileID, generation: generation)
    }

    /// Signing in again may keep the same profile ID after invalidating an expired
    /// session. Restore that profile's receipt before its next library sync arrives.
    func prepareForAccountSync() {
        #if DEBUG
        if testingTransport != nil { return }
        #endif
        beginProfileIfNeeded()
    }

    /// Called before a profile/session changes. Pending writes may still return a
    /// receipt, which is saved to their original profile without touching this UI.
    func invalidateSession() {
        generation &+= 1
        catalogRevision &+= 1
        restoration?.cancel(); restoration = nil
        catalogTask?.cancel(); catalogTask = nil
        mutationTask?.cancel(); mutationTask = nil
        likeTask?.cancel(); likeTask = nil
        dismissalTask?.cancel(); dismissalTask = nil
        profileID = nil
        catalog = []; snapshots = [:]; snapshotOrder = []; readProgress = [:]
        checkpoint = nil; operation = nil; damagedReceipt = false
        isRefreshing = false; refreshError = nil; lastRefreshed = nil; isFromCache = false
        #if DEBUG
        testingTransport = nil; testingCatalog = nil; testingLike = nil; testingDirectory = nil
        #endif
    }

    func refresh(force: Bool = true, expectedScope: CloudPlaylistAccountScope? = nil) async {
        let context: AccountContext
        do { context = try await prepareProfile(expectedScope: expectedScope) }
        catch {
            // An old request must not place its error on the next account's UI.
            if !hasSession { refreshError = availabilityMessage }
            return
        }
        let app = context.app, profileID = context.profileID
        if !force, let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < 15 * 60 { return }
        if !force, let catalogTask { _ = try? await catalogTask.value; return }
        // A background AccountLibrary result includes playlist metadata too. Stop
        // that older round before accepting a newer authoritative cloud read.
        app.cloudRefreshBegan()
        catalogTask?.cancel()
        catalogRevision &+= 1
        let revision = catalogRevision, generation = context.generation
        isRefreshing = true
        refreshError = nil
        let task = Task { @MainActor [weak self] () throws -> [PlaylistSummary] in
            guard let self else { throw CancellationError() }
            return try await app.withCloudAccountWork {
                try await self.validate(profileID: profileID, generation: generation)
                #if DEBUG
                if let catalog = self.testingCatalog { return catalog }
                #endif
                let result = try await app.music.libraryPlaylists()
                try await self.validate(profileID: profileID, generation: generation)
                return result
            }
        }
        catalogTask = task
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard isCurrent(profileID, generation), catalogRevision == revision else { return }
            applyCatalog(result, for: profileID)
            await reloadReceiptAfterRefresh(profileID: profileID, generation: generation)
        } catch {
            guard isCurrent(profileID, generation), catalogRevision == revision else { return }
            if !(error is CancellationError) { refreshError = Self.message(error) }
        }
        if isCurrent(profileID, generation), catalogRevision == revision {
            isRefreshing = false
            catalogTask = nil
        }
    }

    /// Reopening a detail/Flow preparation asks fresh complete pages by default.
    func loadSnapshot(id: String, force: Bool = true, expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        let context = try await prepareProfile(expectedScope: expectedScope)
        let id = Self.canonical(id)
        if !force, let cached = snapshots[id] { return cached }
        readProgress[id] = 0
        defer {
            if isCurrent(context.profileID, context.generation) { readProgress[id] = nil }
        }
        let transport = transport(profileID: context.profileID, generation: context.generation, reading: id)
        let snapshot = try await context.app.withCloudAccountWork { [self] in
            try await validate(profileID: context.profileID, generation: context.generation)
            let snapshot = try await transport.readPlaylist(id: id)
            try await validate(profileID: context.profileID, generation: context.generation)
            return snapshot
        }
        guard isCurrent(context.profileID, context.generation) else { throw CloudAccountAccessError.changed }
        remember(snapshot)
        return snapshot
    }

    func editablePlaylists(for songs: [Song], expectedScope: CloudPlaylistAccountScope? = nil) async throws -> [EditablePlaylist] {
        let context = try await prepareProfile(expectedScope: expectedScope)
        let transport = transport(profileID: context.profileID, generation: context.generation)
        return try await context.app.withCloudAccountWork { [self] in
            try await validate(profileID: context.profileID, generation: context.generation)
            let values = try await transport.editablePlaylists(videoIDs: songs.map(\.id))
            try await validate(profileID: context.profileID, generation: context.generation)
            return values
        }
    }

    func create(title: String, songs: [Song] = [], expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        try await start(.create(title: title.trimmingCharacters(in: .whitespacesAndNewlines), songs: songs), expectedScope: expectedScope)
    }

    func add(songs: [Song], to playlistID: String, expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        try await start(.add(playlistID: Self.canonical(playlistID), songs: songs), expectedScope: expectedScope)
    }

    func remove(rows: [CloudPlaylistRow], from playlistID: String, expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        try await start(.remove(playlistID: Self.canonical(playlistID), rows: rows), expectedScope: expectedScope)
    }

    func rename(id: String, previousTitle: String, title: String, expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        try await start(.rename(playlistID: Self.canonical(id), previousTitle: previousTitle,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines)), expectedScope: expectedScope)
    }

    func retry(expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        let context = try await prepareProfile(expectedScope: expectedScope)
        await context.app.accountWork?.value
        try requireCurrent(context)
        await reloadReceiptAfterRefresh(profileID: context.profileID, generation: context.generation)
        try requireCurrent(context)
        guard let checkpoint, operation?.canRetry == true else { throw CloudAccountAccessError.unresolved }
        return try await run(checkpoint, context: context)
    }

    /// Only an explicit user-selected, freshly read editable playlist can resolve a
    /// Create whose response was lost. Names alone never silently select a target.
    func recoverCreation(using playlistID: String, expectedScope: CloudPlaylistAccountScope? = nil) async throws -> CloudPlaylistSnapshot {
        let context = try await prepareProfile(expectedScope: expectedScope)
        guard !isBusy, var saved = checkpoint, let title = pendingCreationTitle else { throw CloudAccountAccessError.unresolved }
        let snapshot = try await loadSnapshot(id: playlistID, expectedScope: context.scope)
        try requireCurrent(context)
        guard snapshot.title == title, snapshot.capabilities.canAdd else { throw CloudPlaylistError.readOnly }
        saved.playlistID = snapshot.id
        saved.pending = nil
        return try await run(saved, context: context, recoveringCreation: true)
    }

    func cancel() {
        mutationTask?.cancel()
        likeTask?.cancel()
        if operation != nil {
            operation?.phase = .cancelled
            operation?.detail = String(localized: "Cancelled. Changes already sent to YouTube Music may still be present.")
        }
    }

    func clearStatus() {
        guard !isBusy, operation?.canDismiss == true else { return }
        guard let receipt = checkpoint, let profileID, let directory = storageDirectory(for: profileID) else {
            operation = nil
            return
        }
        let generation = generation
        operation?.canDismiss = false
        dismissalTask = Task { @MainActor [weak self, journal] in
            do {
                try await journal.archive(id: receipt.id, in: directory)
                guard let self, self.isCurrent(profileID, generation), self.checkpoint?.id == receipt.id else { return }
                self.checkpoint = nil
                self.operation = nil
                self.dismissalTask = nil
            } catch {
                guard let self, self.isCurrent(profileID, generation) else { return }
                self.dismissalTask = nil
                self.operation?.detail = Self.message(error)
                self.operation?.canDismiss = true
            }
        }
    }

    /// Idempotent Like is confirmed from a fresh account read before local UI changes.
    func like(song: Song, expectedScope: CloudPlaylistAccountScope? = nil) async throws {
        let context = try await prepareProfile(expectedScope: expectedScope)
        try requireAvailableMutation()
        let id = UUID(), intent = context.app.libraryIntentRevision
        context.app.cloudMutationBegan()
        invalidateCatalogRead()
        operation = .init(id: id, phase: .running, title: String(localized: "Like Song"), detail: nil,
                          completedCount: 0, totalCount: 1, resultPlaylistID: nil,
                          canRetry: false, canDismiss: false, canRecoverCreation: false)
        let task = Task { @MainActor [self] in
            try await context.app.withCloudAccountWork {
                try await validate(profileID: context.profileID, generation: context.generation)
                #if DEBUG
                if testingTransport != nil {
                    guard let testingLike else { throw CloudPlaylistError.unsupported }
                    return try await testingLike(song)
                }
                #endif
                try await context.app.music.setLiked(videoId: song.id, liked: true)
                try await validate(profileID: context.profileID, generation: context.generation)
                let liked = try await context.app.music.likedSongs()
                try await validate(profileID: context.profileID, generation: context.generation)
                guard let confirmed = liked.first(where: { $0.id == song.id }) else { throw CloudPlaylistError.unconfirmedWrite }
                return confirmed
            }
        }
        likeTask = task
        do {
            let confirmed = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard isCurrent(context.profileID, context.generation), operation?.id == id else { throw CloudAccountAccessError.changed }
            context.app.confirmedCloudLike(confirmed, profileID: context.profileID, intentRevision: intent)
            operation?.phase = .succeeded
            operation?.completedCount = 1
            operation?.detail = String(localized: "Confirmed in YouTube Music.")
            operation?.canDismiss = true
            likeTask = nil
        } catch {
            if isCurrent(context.profileID, context.generation), operation?.id == id {
                likeTask = nil
                operation?.phase = error is CancellationError ? .cancelled : .failed
                operation?.detail = Self.message(error)
                operation?.canDismiss = true
            }
            throw error
        }
    }

    /// A complete account-library sync can supply the directory without another
    /// request, but may not overwrite a newer manual refresh or mutation.
    func receiveCatalog(_ values: [PlaylistSummary], for profileID: UUID, expectedRevision: UInt64) {
        guard let app, app.roster.activeID == profileID, catalogRevision == expectedRevision, !isBusy else { return }
        guard self.profileID == profileID else { return }
        applyCatalog(values, for: profileID)
    }

    func receiveRefreshError(_ error: Error, for profileID: UUID, expectedRevision: UInt64) {
        guard app?.roster.activeID == profileID, catalogRevision == expectedRevision, !isBusy else { return }
        refreshError = Self.message(error)
    }

    // MARK: Durable operation lifecycle

    private func start(_ intent: CloudPlaylistOperation, expectedScope: CloudPlaylistAccountScope?) async throws -> CloudPlaylistSnapshot {
        let context = try await prepareProfile(expectedScope: expectedScope)
        try requireAvailableMutation()
        return try await run(.init(operation: intent), context: context)
    }

    private func run(_ receipt: CloudPlaylistCheckpoint, context: AccountContext, recoveringCreation: Bool = false) async throws -> CloudPlaylistSnapshot {
        try requireCurrent(context)
        guard !isBusy else { throw CloudAccountAccessError.busy }
        guard !damagedReceipt else { throw CloudAccountAccessError.damagedReceipt }
        context.app.cloudMutationBegan()
        invalidateCatalogRead()
        checkpoint = receipt
        operation = Self.state(receipt, phase: .running)
        guard let directory = storageDirectory(for: context.profileID) else { throw CloudAccountAccessError.changed }
        let transport = transport(profileID: context.profileID, generation: context.generation)
        let validate = validator(profileID: context.profileID, generation: context.generation)
        let task = Task { @MainActor [self] in
            try await context.app.withCloudAccountWork {
                try await validate()
                // A profile may have switched away and back while an old Create
                // was returning its ID. Read the durable receipt only after that
                // older task has released the shared account barrier.
                let persisted = try await journal.load(in: directory)
                try await validate()
                var effective = receipt
                if let persisted {
                    if persisted.id == receipt.id {
                        guard persisted.operation == receipt.operation else { throw CloudPlaylistError.invalidOperation }
                        if recoveringCreation {
                            guard persisted.playlistID == nil, persisted.pending?.kind == .create else {
                                checkpoint = persisted
                                operation = Self.state(persisted, phase: .needsConfirmation)
                                throw CloudAccountAccessError.unresolved
                            }
                        } else {
                            effective = persisted
                        }
                    } else if !persisted.isComplete {
                        checkpoint = persisted
                        operation = Self.state(persisted, phase: .needsConfirmation)
                        throw CloudAccountAccessError.unresolved
                    }
                }
                checkpoint = effective
                try await journal.save(effective, in: directory)
                return try await CloudPlaylistRunner.run(effective, transport: transport, validate: validate) { [weak self, journal] next in
                    // A successful Create ID is valuable even after cancellation or
                    // switching accounts. Always save its original profile first.
                    try await journal.save(next, in: directory)
                    await self?.receivedCheckpoint(next, profileID: context.profileID, generation: context.generation)
                }
            }
        }
        mutationTask = task
        defer {
            if isCurrent(context.profileID, context.generation) { mutationTask = nil }
        }
        do {
            let snapshot = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard isCurrent(context.profileID, context.generation), checkpoint?.id == receipt.id else { throw CloudAccountAccessError.changed }
            mutationTask = nil
            remember(snapshot)
            var entries = catalog
            if let index = entries.firstIndex(where: { $0.id == snapshot.id }) { entries[index] = snapshot.playlist }
            else { entries.insert(snapshot.playlist, at: 0) }
            #if DEBUG
            if testingCatalog != nil { testingCatalog = entries }
            #endif
            applyCatalog(entries, for: context.profileID)
            operation = Self.state(checkpoint ?? receipt, phase: .succeeded)
            operation?.detail = String(localized: "Confirmed in YouTube Music.")
            return snapshot
        } catch {
            if isCurrent(context.profileID, context.generation), checkpoint?.id == receipt.id {
                mutationTask = nil
                let saved = checkpoint ?? receipt
                operation = Self.state(saved, phase: saved.pending != nil ? .needsConfirmation : (error is CancellationError ? .cancelled : .failed))
                operation?.detail = Self.message(error)
            }
            throw error
        }
    }

    private func requireAvailableMutation() throws {
        guard !isBusy else { throw CloudAccountAccessError.busy }
        guard !damagedReceipt else { throw CloudAccountAccessError.damagedReceipt }
        guard checkpoint == nil || checkpoint?.isComplete == true else { throw CloudAccountAccessError.unresolved }
    }

    private func invalidateCatalogRead() {
        catalogRevision &+= 1
        catalogTask?.cancel()
        catalogTask = nil
        isRefreshing = false
    }

    private func receivedCheckpoint(_ value: CloudPlaylistCheckpoint, profileID: UUID, generation: UInt64) {
        guard isCurrent(profileID, generation), checkpoint?.id == value.id else { return }
        checkpoint = value
        let phase = operation?.phase == .cancelled ? CloudPlaylistOperationState.Phase.cancelled : .running
        operation = Self.state(value, phase: phase)
    }

    private func prepareProfile(expectedScope: CloudPlaylistAccountScope?) async throws -> AccountContext {
        try Task.checkCancellation()
        #if DEBUG
        if testingTransport == nil { beginProfileIfNeeded() }
        #else
        beginProfileIfNeeded()
        #endif
        let captured = try context()
        if let expectedScope, expectedScope != captured.scope { throw CloudAccountAccessError.changed }
        await restoration?.value
        try requireCurrent(captured)
        return captured
    }

    private func beginProfileIfNeeded() {
        guard let app else { return }
        if profileID != app.roster.activeID {
            invalidateSession()
            let id = app.roster.activeID, generation = generation
            profileID = id
            let directory = app.roster.folder(for: id)
            restoration = Task { @MainActor [weak self, journal] in
                let cache = await journal.loadCatalog(in: directory)
                let saved: Result<CloudPlaylistCheckpoint?, Error>
                do { saved = .success(try await journal.load(in: directory)) }
                catch { saved = .failure(error) }
                guard let self, self.isCurrent(id, generation), !Task.isCancelled else { return }
                if let cache, self.lastRefreshed == nil {
                    self.catalog = cache.playlists
                    self.lastRefreshed = cache.fetchedAt
                    self.isFromCache = true
                }
                switch saved {
                case .success(let checkpoint):
                    self.checkpoint = checkpoint
                    if let checkpoint {
                        self.operation = Self.state(checkpoint, phase: checkpoint.isComplete ? .succeeded : .needsConfirmation)
                        if !checkpoint.isComplete {
                            self.operation?.detail = String(localized: "An unfinished cloud change was restored. Check its status before continuing.")
                        }
                    }
                case .failure:
                    self.damagedReceipt = true
                    self.refreshError = CloudAccountAccessError.damagedReceipt.localizedDescription
                }
            }
        }
    }

    /// A cancelled operation may have returned a Create ID after the listener
    /// switched away. The serialized refresh waits for that old request, then reads
    /// its newest durable receipt before presenting retry/recovery choices.
    private func reloadReceiptAfterRefresh(profileID: UUID, generation: UInt64) async {
        guard !isBusy, isCurrent(profileID, generation) else { return }
        #if DEBUG
        if testingTransport != nil { return }
        #endif
        do {
            guard let directory = storageDirectory(for: profileID) else { return }
            let saved = try await journal.load(in: directory)
            guard isCurrent(profileID, generation), !isBusy else { return }
            if let saved, saved != checkpoint {
                checkpoint = saved
                operation = Self.state(saved, phase: saved.isComplete ? .succeeded : .needsConfirmation)
                if !saved.isComplete {
                    operation?.detail = String(localized: "An unfinished cloud change was restored. Check its status before continuing.")
                }
            }
        } catch {
            guard isCurrent(profileID, generation) else { return }
            damagedReceipt = true
            refreshError = CloudAccountAccessError.damagedReceipt.localizedDescription
        }
    }

    private func context() throws -> AccountContext {
        guard let app, let profileID, app.roster.activeID == profileID else { throw CloudAccountAccessError.changed }
        guard hasSession else { throw app.roster.active.isExpired ? CloudAccountAccessError.expired : .signedOut }
        return AccountContext(app: app, scope: .init(profileID: profileID, generation: generation))
    }

    private func requireCurrent(_ context: AccountContext) throws {
        try Task.checkCancellation()
        guard context.scope.matches(activeProfileID: app?.roster.activeID,
                                    coordinatorProfileID: profileID, generation: generation) else {
            throw CloudAccountAccessError.changed
        }
        guard hasSession else { throw context.app.roster.active.isExpired ? CloudAccountAccessError.expired : .signedOut }
    }

    private func isCurrent(_ profileID: UUID, _ generation: UInt64) -> Bool {
        self.profileID == profileID && self.generation == generation && app?.roster.activeID == profileID
    }

    private func validate(profileID: UUID, generation: UInt64) async throws {
        try Task.checkCancellation()
        guard isCurrent(profileID, generation), let app else { throw CloudAccountAccessError.changed }
        #if DEBUG
        if testingTransport != nil { return }
        #endif
        guard app.roster.active.isSignedIn else { throw CloudAccountAccessError.signedOut }
        guard !app.roster.active.isExpired else { throw CloudAccountAccessError.expired }
        guard await app.music.accounts.active?.profileID == profileID else { throw CloudAccountAccessError.changed }
        try Task.checkCancellation()
        guard isCurrent(profileID, generation) else { throw CloudAccountAccessError.changed }
    }

    private func validator(profileID: UUID, generation: UInt64) -> @Sendable () async throws -> Void {
        { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.validate(profileID: profileID, generation: generation)
        }
    }

    private func transport(profileID: UUID, generation: UInt64, reading id: String? = nil) -> any CloudPlaylistTransport {
        #if DEBUG
        if let testingTransport { return testingTransport }
        #endif
        return YouTubeCloudPlaylistTransport(music: app!.music,
            validate: validator(profileID: profileID, generation: generation),
            progress: { [weak self] count in
                await self?.receivedProgress(count, for: id, profileID: profileID, generation: generation)
            })
    }

    private func receivedProgress(_ count: Int, for id: String?, profileID: UUID, generation: UInt64) {
        guard isCurrent(profileID, generation), let id else { return }
        readProgress[id] = count
    }

    private func remember(_ snapshot: CloudPlaylistSnapshot) {
        snapshots[snapshot.id] = snapshot
        snapshotOrder.removeAll { $0 == snapshot.id }
        snapshotOrder.append(snapshot.id)
        while snapshotOrder.count > 12 { snapshots[snapshotOrder.removeFirst()] = nil }
    }

    private func applyCatalog(_ values: [PlaylistSummary], for profileID: UUID) {
        guard let app, app.roster.activeID == profileID else { return }
        let previous = Set(catalog.map(\.id))
        var seen = Set<String>()
        catalog = values.filter { $0.id != "LM" && $0.id != "SE" && seen.insert($0.id).inserted }
        let date = Date()
        lastRefreshed = date
        isFromCache = false
        refreshError = nil
        app.applyCloudPlaylistCatalogToLibrary(catalog, previousCloudIDs: previous, profileID: profileID)
        guard let directory = storageDirectory(for: profileID) else { return }
        let value = CloudPlaylistJournal.Catalog(playlists: catalog, fetchedAt: date)
        cacheRevision &+= 1
        let revision = cacheRevision, session = cacheSession
        Task { [journal] in try? await journal.saveCatalog(value, session: session, revision: revision, in: directory) }
    }

    private static func state(_ checkpoint: CloudPlaylistCheckpoint, phase: CloudPlaylistOperationState.Phase) -> CloudPlaylistOperationState {
        let title: String
        let total: Int
        switch checkpoint.operation {
        case .create(_, let songs): title = String(localized: "Create Cloud Playlist"); total = max(1, songs.count)
        case .add(_, let songs): title = String(localized: "Add to Cloud Playlist"); total = songs.count
        case .remove(_, let rows): title = String(localized: "Remove from Cloud Playlist"); total = rows.count
        case .rename: title = String(localized: "Rename Cloud Playlist"); total = 1
        }
        let unknownCreation = checkpoint.pending?.kind == .create && checkpoint.playlistID == nil
        return .init(id: checkpoint.id, phase: phase, title: title, detail: nil,
                     completedCount: checkpoint.isComplete ? total : checkpoint.completedCount, totalCount: total,
                     resultPlaylistID: checkpoint.playlistID,
                     canRetry: phase != .running && phase != .succeeded && !unknownCreation,
                     canDismiss: phase != .running && checkpoint.pending == nil,
                     canRecoverCreation: phase != .running && unknownCreation)
    }

    static func message(_ error: Error) -> String {
        if error is CloudPlaylistError || error is CloudAccountAccessError { return error.localizedDescription }
        if error is CloudPlaylistJournal.Failure {
            return String(localized: "Koda could not save the cloud operation safely. Free some storage and try again.")
        }
        if error is CancellationError {
            return String(localized: "Cancelled. Changes already sent to YouTube Music may still be present.")
        }
        return error.friendlyMessage
    }

    private static func canonical(_ id: String) -> String { String(id.trimmingPrefix("VL")) }

    private func storageDirectory(for profileID: UUID) -> URL? {
        #if DEBUG
        if let testingDirectory { return testingDirectory }
        #endif
        return app?.roster.folder(for: profileID)
    }

    #if DEBUG
    /// Offline production-component tests only. Absent from the Release binary.
    func installUITestData(catalog: [PlaylistSummary], snapshots: [CloudPlaylistSnapshot],
                           transport: any CloudPlaylistTransport,
                           like: (@Sendable (Song) async throws -> Song)? = nil,
                           testingDirectory: URL? = nil) {
        invalidateSession()
        profileID = app?.roster.activeID
        testingTransport = transport
        testingCatalog = catalog
        testingLike = like
        self.testingDirectory = testingDirectory ?? FileManager.default.temporaryDirectory.appending(path: "KodaCloudUI-\(UUID())")
        self.catalog = catalog
        self.snapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        snapshotOrder = snapshots.map(\.id)
        lastRefreshed = Date()
    }
    #endif
}
