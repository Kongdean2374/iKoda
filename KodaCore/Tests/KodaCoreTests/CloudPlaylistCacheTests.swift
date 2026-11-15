import Foundation
import Testing
@testable import KodaCore

@Suite struct CloudPlaylistCacheTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func returningToHomeOrLibraryUsesARecentCompleteCatalog() {
        let policy = CloudPlaylistCachePolicy.catalog
        #expect(policy.decision(fetchedAt: now.addingTimeInterval(-899), failedAt: nil,
                                force: false, isInFlight: false, now: now) == .useCache)
        #expect(policy.decision(fetchedAt: now.addingTimeInterval(-900), failedAt: nil,
                                force: false, isInFlight: false, now: now) == .fetch)
    }

    @Test func anEmptyButVerifiedCatalogStillHasAFreshnessWindow() {
        #expect(CloudPlaylistCachePolicy.catalog.decision(fetchedAt: now, failedAt: nil,
                force: false, isInFlight: false, now: now) == .useCache)
        #expect(CloudPlaylistCachePolicy.catalog.decision(fetchedAt: nil, failedAt: nil,
                force: false, isInFlight: false, now: now) == .fetch)
    }

    @Test func simultaneousForcedRefreshesJoinRatherThanCancelAndRestart() {
        for force in [false, true] {
            #expect(CloudPlaylistCachePolicy.catalog.decision(fetchedAt: nil, failedAt: nil,
                    force: force, isInFlight: true, now: now) == .join)
        }
    }

    @Test func aFailedRefreshDoesNotRetryOnEveryNavigationButExplicitRetryWorks() {
        let policy = CloudPlaylistCachePolicy.catalog
        let old = now.addingTimeInterval(-3_600)
        #expect(policy.decision(fetchedAt: old, failedAt: now.addingTimeInterval(-29),
                                force: false, isInFlight: false, now: now) == .useCache)
        #expect(policy.decision(fetchedAt: old, failedAt: now.addingTimeInterval(-29),
                                force: true, isInFlight: false, now: now) == .fetch)
        #expect(policy.decision(fetchedAt: old, failedAt: now.addingTimeInterval(-30),
                                force: false, isInFlight: false, now: now) == .fetch)
    }

    @Test func playlistDisplayUsesTheOriginalSyncWindowButManagementBypassesFreshCache() {
        let policy = CloudPlaylistCachePolicy.snapshot
        #expect(policy.decision(fetchedAt: now.addingTimeInterval(-899), failedAt: nil,
                                force: false, isInFlight: false, now: now) == .useCache)
        #expect(policy.decision(fetchedAt: now.addingTimeInterval(-900), failedAt: nil,
                                force: false, isInFlight: false, now: now) == .fetch)
        #expect(policy.decision(fetchedAt: now, failedAt: nil,
                                force: true, isInFlight: false, now: now) == .fetch)
    }

    @Test func aClockCorrectionCannotMakeAFutureDatedCacheFreshForever() {
        #expect(CloudPlaylistCachePolicy.catalog.decision(fetchedAt: now.addingTimeInterval(3_600), failedAt: nil,
                force: false, isInFlight: false, now: now) == .fetch)
    }

    @Test func boundedSnapshotStorageNeverTruncatesALargePlaylist() {
        let newest = snapshot("large", rows: 600)
        let older = snapshot("older", rows: 400)
        let small = snapshot("small", rows: 2)
        let retained = CloudPlaylistCachePolicy.retainedSnapshots([newest, older, small], limit: 12, rowBudget: 650)
        #expect(retained.map(\.id) == ["large", "small"])
        #expect(retained[0].rows.count == 600)
        #expect(CloudPlaylistCachePolicy.retainedSnapshots([newest], rowBudget: 10).first?.rows.count == 600)
    }

    @Test func snapshotStorageUsesNewestMetadataAndLimitsTheNumberOfLists() {
        let latest = snapshot("same", rows: 3)
        let old = snapshot("same", rows: 1)
        let retained = CloudPlaylistCachePolicy.retainedSnapshots([latest, old, snapshot("other", rows: 1)], limit: 1)
        #expect(retained == [latest])
    }

    @Test func completeSnapshotsSurviveRelaunchWithoutCrossingAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cloud-snapshot-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appending(path: "account-a"), second = root.appending(path: "account-b")
        let cached = snapshot("PLone", rows: 520)
        try await CloudPlaylistJournal().saveSnapshots([cached], session: UUID(), revision: 1, in: first)
        #expect(await CloudPlaylistJournal().loadSnapshots(in: first) == [cached])
        #expect(await CloudPlaylistJournal().loadSnapshots(in: second).isEmpty)
    }

    @Test func lateOldSnapshotPersistenceCannotUndoAnInvalidation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-snapshot-order-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CloudPlaylistJournal(), session = UUID()
        let fresh = snapshot("PLone", rows: 2)
        var invalidated = fresh
        invalidated.fetchedAt = .distantPast
        try await journal.saveSnapshots([invalidated], session: session, revision: 2, in: directory)
        try await journal.saveSnapshots([fresh], session: session, revision: 1, in: directory)
        #expect(await journal.loadSnapshots(in: directory).first?.fetchedAt == .distantPast)
    }

    @Test func malformedDisplayCacheIsIgnoredWithoutTouchingMutationReceipts() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-snapshot-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CloudPlaylistJournal()
        let receipt = CloudPlaylistCheckpoint(operation: .create(title: "Keep receipt", songs: []))
        try await journal.save(receipt, in: directory)
        try Data("broken cache".utf8).write(to: directory.appending(path: "cloud-playlist-snapshots.json"))
        #expect(await journal.loadSnapshots(in: directory).isEmpty)
        #expect(try await journal.load(in: directory) == receipt)
    }

    private func snapshot(_ id: String, rows: Int) -> CloudPlaylistSnapshot {
        .init(playlist: .init(id: id, title: id), rows: (0..<rows).map {
            .init(id: "row-\($0)", song: .init(id: "song-\($0)", title: "Song", artistLine: "Artist"), setVideoID: "set-\($0)")
        }, fetchedAt: now)
    }
}
