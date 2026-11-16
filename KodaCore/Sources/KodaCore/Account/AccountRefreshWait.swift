import Foundation

/// A view can stop waiting for a shared refresh without cancelling whatever cloud
/// mutation currently owns the account. Unlike a task-group timeout, this does not
/// wait for an uncooperative child before returning the deadline result.
public enum AccountRefreshWait {
    public enum Outcome: Equatable, Sendable { case completed, timedOut, cancelled }

    public static func wait(for task: Task<Void, Never>, timeout: Duration = .seconds(60)) async -> Outcome {
        let completion = Completion()
        let observer = Task { await task.value; await completion.resolve(.completed) }
        let timer = Task {
            do { try await Task.sleep(for: timeout) }
            catch { return }
            await completion.resolve(.timedOut)
        }
        defer { observer.cancel(); timer.cancel() }
        return await withTaskCancellationHandler {
            await completion.value()
        } onCancel: {
            Task { await completion.resolve(.cancelled) }
        }
    }

    private actor Completion {
        private var outcome: Outcome?
        private var continuation: CheckedContinuation<Outcome, Never>?

        func value() async -> Outcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation = $0 }
        }

        func resolve(_ value: Outcome) {
            guard outcome == nil else { return }
            outcome = value
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
