import Foundation
import Testing
@testable import KodaCore

@Suite struct AccountRefreshWaitTests {
    @Test func completedRefreshReturnsWithoutWaitingForItsDeadline() async {
        let task = Task<Void, Never> {}
        #expect(await AccountRefreshWait.wait(for: task) == .completed)
    }

    @Test func aDeadlineDoesNotWaitForOrCancelTheEarlierCloudMutation() async {
        let gate = RefreshTestGate()
        let mutation = Task { await gate.operation() }
        await gate.waitUntilStarted()
        #expect(await AccountRefreshWait.wait(for: mutation, timeout: .zero) == .timedOut)
        #expect(await gate.finished == false)
        await gate.release()
        await mutation.value
        #expect(await gate.finished == true)
        #expect(await gate.wasCancelled == false)
    }

    @Test func navigatingAwayCancelsOnlyThatWaiter() async {
        let gate = RefreshTestGate()
        let shared = Task { await gate.operation() }
        await gate.waitUntilStarted()
        let waiter = Task { await AccountRefreshWait.wait(for: shared) }
        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        #expect(await gate.finished == false)
        await gate.release()
        await shared.value
        #expect(await gate.wasCancelled == false)
    }

    @Test func repeatedPullWaitersObserveTheSameCompletion() async {
        let gate = RefreshTestGate()
        let shared = Task { await gate.operation() }
        await gate.waitUntilStarted()
        let first = Task { await AccountRefreshWait.wait(for: shared) }
        let second = Task { await AccountRefreshWait.wait(for: shared) }
        await gate.release()
        #expect(await first.value == .completed)
        #expect(await second.value == .completed)
        #expect(await gate.executions == 1)
    }

    @Test func aTimedOutWaiterDoesNotPoisonASecondWaiter() async {
        let gate = RefreshTestGate()
        let shared = Task { await gate.operation() }
        await gate.waitUntilStarted()
        #expect(await AccountRefreshWait.wait(for: shared, timeout: .zero) == .timedOut)
        let second = Task { await AccountRefreshWait.wait(for: shared) }
        await gate.release()
        #expect(await second.value == .completed)
        #expect(await gate.wasCancelled == false)
    }
}

private actor RefreshTestGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var executions = 0
    private(set) var finished = false
    private(set) var wasCancelled = false

    func operation() async {
        executions += 1
        await withCheckedContinuation { continuation in
            blocked = continuation
            started?.resume()
            started = nil
        }
        wasCancelled = Task.isCancelled
        finished = true
    }

    func waitUntilStarted() async {
        guard blocked == nil else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() { blocked?.resume(); blocked = nil }
}
