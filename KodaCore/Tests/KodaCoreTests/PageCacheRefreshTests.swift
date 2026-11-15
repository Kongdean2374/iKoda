import Foundation
import Testing
@testable import KodaCore

struct PageCacheRefreshTests {
    private actor HeldPage {
        private var continuation: CheckedContinuation<String, Never>?
        private var didStart = false
        private var completed = false
        func load() async -> String {
            if completed { return "old" }
            return await withCheckedContinuation { continuation = $0; didStart = true }
        }
        func started() -> Bool { didStart }
        func finish() { completed = true; continuation?.resume(returning: "old"); continuation = nil }
    }

    private func waitForStart(_ held: HeldPage) async throws {
        for _ in 0..<500 {
            if await held.started() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        await held.finish()
        #expect(await held.started(), "The controlled metadata request should start")
        throw CancellationError()
    }

    @Test func anOldRequestCannotRepopulateTheCacheAfterForcedRefresh() async throws {
        let cache = PageCache()
        let held = HeldPage()
        let old = Task { try await cache.value("playlist") { await held.load() } }
        try await waitForStart(held)
        await cache.removeAll()
        let fresh: String = try await cache.value("playlist") { "current" }
        #expect(fresh == "current")
        await held.finish()
        #expect(try await old.value == "old")
        let next: String = try await cache.value("playlist") { "unexpected new request" }
        #expect(next == "current")
    }

    @Test func cancelledMetadataCannotBecomeAPageCacheHit() async throws {
        let cache = PageCache()
        let held = HeldPage()
        let task = Task { try await cache.value("playlist") { await held.load() } }
        try await waitForStart(held)
        task.cancel()
        await held.finish()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError {}
        let fresh: String = try await cache.value("playlist") { "current" }
        #expect(fresh == "current")
    }
}
