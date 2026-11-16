#if DEBUG
import Foundation
import KodaCore
import Observation

/// A controllable service response for the production account-sync coordinator.
/// No request leaves the process; callers still exercise its scheduling, waiting,
/// reconciliation and error presentation rather than a second sync implementation.
@MainActor @Observable
final class UITestAccountSyncBoundary {
    var readCount = 0
    var isHeld: Bool {
        didSet {
            if !isHeld { readGate?.resume(); readGate = nil }
        }
    }
    var joinedWaiters = 0
    var completedWaiters = 0
    var holdsMutation = false
    var mutationState = "idle"
    var profileCycleState = "idle"
    var catalogReads = 0
    var switchedSnapshotRows = 0
    let profileID: UUID
    let queueIDs: [UUID]
    private var response: AccountLibrary
    private let fails: Bool
    private var readGate: CheckedContinuation<Void, Never>?
    private var ignoresReadCancellation = false
    private var holdsNextRead = false

    init(profileID: UUID, response: AccountLibrary, queueIDs: [UUID], fails: Bool) {
        self.profileID = profileID
        self.response = response
        self.queueIDs = queueIDs
        self.fails = fails
        isHeld = !fails
    }

    func read() async throws -> AccountLibrary {
        readCount += 1
        let snapshot = response
        if holdsNextRead {
            holdsNextRead = false
            isHeld = true
            profileCycleState = "new-refresh"
        }
        if isHeld {
            await withCheckedContinuation { continuation in
                if isHeld { readGate = continuation }
                else { continuation.resume() }
            }
        }
        // The profile-switch regression deliberately models a service callback
        // returning after cancellation. Production must still reject that result.
        if !ignoresReadCancellation { try Task.checkCancellation() }
        if fails { throw MusicError.network }
        return snapshot
    }

    func readCatalog(for requestedProfile: UUID) -> CloudPlaylistCatalogResult {
        catalogReads += 1
        return CloudPlaylistCatalogResult(playlists: requestedProfile == profileID ? response.playlists : [])
    }

    func joinRefresh(in app: AppModel) {
        // Two additional callers arrive while the pull-to-refresh read is held.
        for _ in 0..<2 {
            joinedWaiters += 1
            Task { @MainActor in
                await app.refreshAccount()
                completedWaiters += 1
            }
        }
    }

    func holdCloudRename() async throws {
        mutationState = "running"
        while holdsMutation { try await Task.sleep(for: .milliseconds(25)) }
        try Task.checkCancellation()
        if let index = response.playlists.firstIndex(where: { $0.id == "PLui-alpha" }) {
            response.playlists[index].title = "UI renamed"
        }
    }

    func startCloudRename(in app: AppModel) {
        guard mutationState == "idle" else { return }
        holdsMutation = true
        isHeld = false
        let scope = app.cloudPlaylists.captureScope()
        Task { @MainActor in
            do {
                _ = try await app.cloudPlaylists.rename(id: "PLui-alpha", previousTitle: "Fixture Alpha",
                                                       title: "UI renamed", expectedScope: scope)
                mutationState = "succeeded"
            } catch {
                mutationState = "failed"
            }
        }
    }

    func switchAwayAndBack(in app: AppModel) {
        guard profileCycleState == "idle" else { return }
        ignoresReadCancellation = true
        let oldTask = app.syncTask
        let originalID = app.roster.activeID
        let replacement = Song(id: "ui-after-switch", title: "After switch", artistLine: "Fixture")
        response = AccountLibrary(liked: [replacement])
        holdsNextRead = true
        let other = app.roster.addDeviceProfile(named: "UI other profile")
        app.switchProfile(to: other.id)
        app.switchProfile(to: originalID)
        app.library.open(directory: nil)
        app.library.mergeAccount(liked: [replacement],
                                 albums: [], playlists: [], artists: [])
        profileCycleState = "switched"
        Task { @MainActor in
            await oldTask?.value
            await app.accountWork?.value
            await app.syncTask?.value
            // Session invalidation clears the coordinator's per-session cache.
            // Exercise the replacement service as Siri/entity queries also can.
            await app.cloudPlaylists.refresh(force: true)
            do {
                switchedSnapshotRows = try await app.cloudPlaylists.loadSnapshot(id: "PLui-alpha", force: true).rows.count
            } catch {
                switchedSnapshotRows = -1
            }
            profileCycleState = "settled"
        }
    }
}
#endif
