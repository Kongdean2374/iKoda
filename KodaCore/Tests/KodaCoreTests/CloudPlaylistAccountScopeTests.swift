import Foundation
import Testing
@testable import KodaCore

@Suite struct CloudPlaylistAccountScopeTests {
    @Test func aReceiptRestoreCannotRetargetAnOldActionToTheNewAccount() async {
        let first = UUID(), second = UUID()
        let gate = SuspendedCloudPreparation(profileID: first)
        let task = Task { await gate.prepareAndWrite() }
        await gate.waitUntilRestoring()
        await gate.switchAccount(to: second)
        await gate.finishRestoring()
        #expect(await task.value == false)
        #expect(await gate.writtenProfiles.isEmpty)
    }

    @Test func switchingAwayAndBackStillInvalidatesTheOldButtonTap() async {
        let first = UUID()
        let gate = SuspendedCloudPreparation(profileID: first)
        let task = Task { await gate.prepareAndWrite() }
        await gate.waitUntilRestoring()
        await gate.switchAccount(to: UUID())
        await gate.switchAccount(to: first)
        await gate.finishRestoring()
        #expect(await task.value == false)
        #expect(await gate.writtenProfiles.isEmpty)
    }

    @Test func anUnchangedAccountMayContinueAfterReceiptRestoration() async {
        let profile = UUID()
        let gate = SuspendedCloudPreparation(profileID: profile)
        let task = Task { await gate.prepareAndWrite() }
        await gate.waitUntilRestoring()
        await gate.finishRestoring()
        #expect(await task.value == true)
        #expect(await gate.writtenProfiles == [profile])
    }

    @Test func invalidatedCoordinatorCannotAcceptAStillActiveRosterID() {
        let profile = UUID()
        let scope = CloudPlaylistAccountScope(profileID: profile, generation: 1)
        #expect(!scope.matches(activeProfileID: profile, coordinatorProfileID: nil, generation: 2))
    }
}

/// Models the same suspension boundary as restoring a profile receipt. No timing
/// sleeps: the test switches accounts only once the operation is definitely waiting.
private actor SuspendedCloudPreparation {
    var profileID: UUID
    var generation: UInt64 = 1
    var writtenProfiles: [UUID] = []
    private var restoreContinuation: CheckedContinuation<Void, Never>?
    private var observingContinuation: CheckedContinuation<Void, Never>?

    init(profileID: UUID) { self.profileID = profileID }

    func prepareAndWrite() async -> Bool {
        let scope = CloudPlaylistAccountScope(profileID: profileID, generation: generation)
        await withCheckedContinuation { continuation in
            restoreContinuation = continuation
            observingContinuation?.resume()
            observingContinuation = nil
        }
        guard scope.matches(activeProfileID: profileID, coordinatorProfileID: profileID, generation: generation) else { return false }
        writtenProfiles.append(scope.profileID)
        return true
    }

    func waitUntilRestoring() async {
        guard restoreContinuation == nil else { return }
        await withCheckedContinuation { observingContinuation = $0 }
    }

    func switchAccount(to id: UUID) { profileID = id; generation &+= 1 }
    func finishRestoring() { restoreContinuation?.resume(); restoreContinuation = nil }
}
