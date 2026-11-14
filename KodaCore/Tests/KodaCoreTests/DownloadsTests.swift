import Foundation
import Testing
@testable import KodaCore

/// Controlled suspensions exercise the real download scheduler without network requests or
/// elapsed retry timers. Metadata deliberately ignores cancellation to expose stale commits.
@MainActor
@Suite(.serialized)
struct DownloadsTests {
    @MainActor
    private final class ControlledIO {
        struct Transfer {
            let id: String
            let allowsCellular: Bool
            let session: ObjectIdentifier
        }
        private(set) var metadataRequests: [String] = []
        private(set) var transfers: [Transfer] = []
        private(set) var delays: [Duration] = []
        private var metadata: [Int: CheckedContinuation<ResolvedStream, any Error>] = [:]
        private var filling: [Int: CheckedContinuation<Void, any Error>] = [:]
        private var sleeping: [Int: CheckedContinuation<Void, any Error>] = [:]

        func load(_ id: String) async throws -> ResolvedStream {
            let index = metadataRequests.count
            metadataRequests.append(id)
            return try await withCheckedThrowingContinuation { metadata[index] = $0 }
        }

        func fill(_ id: String, stream: ResolvedStream, session: URLSession, store: AudioStore) async throws {
            let index = transfers.count
            transfers.append(Transfer(id: id, allowsCellular: session.configuration.allowsCellularAccess,
                                      session: ObjectIdentifier(session)))
            try await withCheckedThrowingContinuation { filling[index] = $0 }
            try Task.checkCancellation()
            guard let length = stream.contentLength else { throw MusicError.network }
            try store.write(Data(repeating: 42, count: Int(length)), at: 0, for: id)
        }

        func sleep(_ delay: Duration) async throws {
            let index = delays.count
            delays.append(delay)
            try await withCheckedThrowingContinuation { sleeping[index] = $0 }
        }

        func resolve(_ index: Int, length: Int64 = 4) {
            let id = metadataRequests[index]
            let stream = ResolvedStream(videoId: id, url: URL(string: "https://example.invalid/\(id)")!,
                                        userAgent: "test", itag: 140, contentLength: length,
                                        duration: 180, loudnessDb: nil, expiresAt: nil)
            metadata.removeValue(forKey: index)?.resume(returning: stream)
        }

        func fail(_ index: Int, error: any Error = MusicError.network) {
            metadata.removeValue(forKey: index)?.resume(throwing: error)
        }
        func finish(_ index: Int) { filling.removeValue(forKey: index)?.resume() }
        func wake(_ index: Int) { sleeping.removeValue(forKey: index)?.resume() }

        func cancelAll() {
            for continuation in metadata.values { continuation.resume(throwing: CancellationError()) }
            for continuation in filling.values { continuation.resume(throwing: CancellationError()) }
            for continuation in sleeping.values { continuation.resume(throwing: CancellationError()) }
            metadata.removeAll(); filling.removeAll(); sleeping.removeAll()
        }
    }

    @MainActor
    private struct Harness {
        let downloads: Downloads
        let store: AudioStore
        let io: ControlledIO
        let suite: String
        let defaults: UserDefaults
        let directory: URL

        init(allowsCellular: Bool = true) {
            suite = "koda.download-tests." + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(allowsCellular, forKey: "koda.downloads.cellular")
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            store = AudioStore(directory: directory)
            io = ControlledIO()
            let fixture = io
            downloads = Downloads(store: store, music: YouTubeMusic(defaultsSuite: suite), defaults: defaults)
            downloads.streamLoader = { try await fixture.load($0) }
            downloads.fillLoader = { try await fixture.fill($0, stream: $1, session: $2, store: $3) }
            downloads.retrySleep = { try await fixture.sleep($0) }
            downloads.networkSnapshotOverride = .init(status: .online, interface: .wifi)
        }

        func cleanUp() {
            downloads.removeAll()
            io.cancelAll()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func songs(_ ids: [String]) -> [Song] {
        ids.map { Song(id: $0, title: "Song \($0)", artistLine: "Artist") }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "Expected the controlled download operation to reach its checkpoint")
        throw CancellationError()
    }

    private func drainReadyTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }

    @Test func backoffReleasesBothTransferSlotsForLaterSongs() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let tracks = songs(["a", "b", "c", "d"])
        h.downloads.download(tracks)
        try await waitUntil { h.io.metadataRequests.count == 2 }
        #expect(Set(h.io.metadataRequests) == ["a", "b"])
        h.io.fail(0)
        h.io.fail(1)
        try await waitUntil { h.io.metadataRequests.count == 4 && h.io.delays.count == 2 }
        #expect(Set(h.io.metadataRequests.suffix(2)) == ["c", "d"])
        #expect(h.downloads.state(of: tracks[0]) == .waiting)
        #expect(h.downloads.state(of: tracks[1]) == .waiting)
        // Neither failed song's retry timer has been released.
        h.io.resolve(2)
        h.io.resolve(3)
        try await waitUntil { h.io.transfers.count == 2 }
        h.io.finish(0)
        h.io.finish(1)
        try await waitUntil { h.downloads.state(of: tracks[2]) == .downloaded && h.downloads.state(of: tracks[3]) == .downloaded }
        #expect(h.downloads.bytes == 8)
        #expect(h.io.metadataRequests.count == 4)
    }

    @Test func removedMetadataCannotPrepareAFileOrReviveTheDownload() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let track = songs(["removed"])[0]
        h.downloads.download([track])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.downloads.remove([track])
        h.io.resolve(0, length: 99)
        await drainReadyTasks()
        #expect(h.downloads.state(of: track) == .none)
        #expect(h.downloads.songs.isEmpty)
        #expect(h.store.entry(track.id)?.contentLength == nil)
        #expect(h.store.downloads.isEmpty)
        #expect(h.io.transfers.isEmpty)
    }

    @Test func lateRemovedAttemptCannotClearTheReplacementOrConsumeExtraSlots() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let tracks = songs(["same", "b", "c"])
        h.downloads.download([tracks[0]])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.downloads.remove([tracks[0]])
        h.downloads.download([tracks[0]])
        try await waitUntil { h.io.metadataRequests.count == 2 }
        h.io.resolve(0, length: 99)
        await drainReadyTasks()
        #expect(h.store.entry(tracks[0].id)?.contentLength == nil)
        #expect(h.io.transfers.isEmpty)
        h.downloads.download(Array(tracks.suffix(2)))
        try await waitUntil { h.io.metadataRequests.count >= 3 }
        await drainReadyTasks()
        // The replacement still owns one of the two slots, so c must remain queued.
        #expect(h.io.metadataRequests == ["same", "same", "b"])
        h.io.resolve(1)
        try await waitUntil { h.io.transfers.count == 1 }
        h.io.finish(0)
        try await waitUntil { h.downloads.state(of: tracks[0]) == .downloaded && h.io.metadataRequests.count == 4 }
        #expect(h.store.entry(tracks[0].id)?.contentLength == 4)
        #expect(h.io.metadataRequests.last == "c")
    }

    @Test func cellularPolicyRestartsActiveWorkWithANewSession() async throws {
        let h = Harness(allowsCellular: false)
        defer { h.cleanUp() }
        let track = songs(["session"])[0]
        h.downloads.download([track])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.io.resolve(0)
        try await waitUntil { h.io.transfers.count == 1 }
        #expect(!h.io.transfers[0].allowsCellular)
        h.downloads.allowsCellular = true
        try await waitUntil { h.io.metadataRequests.count == 2 }
        h.io.resolve(1)
        try await waitUntil { h.io.transfers.count == 2 }
        #expect(h.io.transfers[1].allowsCellular)
        #expect(h.io.transfers[0].session != h.io.transfers[1].session)
        h.io.finish(0)
        await drainReadyTasks()
        #expect(h.store.entry(track.id)?.bytes == 0)
        #expect(h.downloads.state(of: track) != .downloaded)
        h.io.finish(1)
        try await waitUntil { h.downloads.state(of: track) == .downloaded }
        #expect(h.downloads.bytes == 4)
        #expect(h.defaults.bool(forKey: "koda.downloads.cellular"))
    }

    @Test func cellularOnlyPathWaitsUntilCellularDownloadsAreEnabled() async throws {
        let h = Harness(allowsCellular: false)
        defer { h.cleanUp() }
        let track = songs(["waiting"])[0]
        h.downloads.networkSnapshotOverride = .init(status: .online, interface: .cellular, isExpensive: true)
        h.downloads.download([track])
        await drainReadyTasks()
        #expect(h.io.metadataRequests.isEmpty)
        #expect(h.downloads.state(of: track) == .waiting)
        h.downloads.allowsCellular = true
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.io.resolve(0)
        try await waitUntil { h.io.transfers.count == 1 }
        #expect(h.io.transfers[0].allowsCellular)
    }

    @Test func retriesStopAtTheBudgetAndAnExplicitRetryStartsANewBudget() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let track = songs(["retry"])[0]
        h.downloads.download([track])
        for attempt in 0..<Downloads.maximumAttempts {
            try await waitUntil { h.io.metadataRequests.count == attempt + 1 }
            h.io.fail(attempt)
            if attempt + 1 < Downloads.maximumAttempts {
                try await waitUntil { h.io.delays.count == attempt + 1 }
                h.io.wake(attempt)
            }
        }
        try await waitUntil { h.downloads.state(of: track) == .failed }
        #expect(h.io.metadataRequests.count == Downloads.maximumAttempts)
        #expect(h.io.delays == [.seconds(10), .seconds(20), .seconds(40), .seconds(80), .seconds(160)])
        h.downloads.retry([track])
        try await waitUntil { h.io.metadataRequests.count == Downloads.maximumAttempts + 1 }
        h.io.resolve(Downloads.maximumAttempts)
        try await waitUntil { h.io.transfers.count == 1 }
        h.io.finish(0)
        try await waitUntil { h.downloads.state(of: track) == .downloaded }
    }

    @Test func aRemovedBackoffCannotRestartOrDisplaceANewDownload() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let track = songs(["backoff"])[0]
        h.downloads.download([track])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.io.fail(0)
        try await waitUntil { h.io.delays.count == 1 }
        h.downloads.remove([track])
        h.downloads.download([track])
        try await waitUntil { h.io.metadataRequests.count == 2 }
        // The canceled sleep also ignores cancellation until the test releases it.
        h.io.wake(0)
        await drainReadyTasks()
        #expect(h.io.metadataRequests.count == 2)
        #expect(h.downloads.songs.map(\.id) == [track.id])
        h.io.resolve(1)
        try await waitUntil { h.io.transfers.count == 1 }
        h.io.finish(0)
        try await waitUntil { h.downloads.state(of: track) == .downloaded }
    }

    @Test(arguments: ["remove", "removeAll", "cancel"])
    func canceledCollectionRejectsItsLatePlaylistResult(action: String) async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let tracks = songs(["prefix", "later-page"])
        let request = h.downloads.beginCollection([tracks[0]])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        switch action {
        case "remove": h.downloads.remove([tracks[0]])
        case "removeAll": h.downloads.removeAll()
        default: h.downloads.cancelCollection(request)
        }
        #expect(!h.downloads.completeCollection(tracks, request: request))
        #expect(h.downloads.state(of: tracks[1]) == .none)
        #expect(!h.store.downloads.contains { $0.videoId == tracks[1].id })
        if action != "cancel" {
            h.io.resolve(0)
            await drainReadyTasks()
            #expect(h.downloads.songs.isEmpty)
            #expect(h.io.transfers.isEmpty)
        }
    }

    @Test func aCollectionCommitsOnlyOnceWithoutDuplicatingItsInitialPage() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let tracks = songs(["prefix", "tail", "unexpected"])
        let request = h.downloads.beginCollection([tracks[0]])
        #expect(h.downloads.completeCollection(Array(tracks.prefix(2)), request: request))
        #expect(!h.downloads.completeCollection(tracks, request: request))
        try await waitUntil { h.io.metadataRequests.count == 2 }
        #expect(Set(h.downloads.songs.map(\.id)) == ["prefix", "tail"])
        #expect(h.downloads.songs.count == 2)
        #expect(h.downloads.state(of: tracks[2]) == .none)
    }

    @Test func completeCachedAudioBecomesADownloadEvenWhileOffline() async throws {
        let h = Harness(allowsCellular: false)
        defer { h.cleanUp() }
        let track = songs(["cached"])[0]
        let stream = ResolvedStream(videoId: track.id, url: URL(string: "https://example.invalid/cached")!,
                                    userAgent: "test", itag: 140, contentLength: 4,
                                    duration: 180, loudnessDb: nil, expiresAt: nil)
        h.store.prepare(stream, song: track)
        try h.store.write(Data([1, 2, 3, 4]), at: 0, for: track.id)
        h.downloads.networkSnapshotOverride = .init(status: .offline)
        h.downloads.download([track])
        try await waitUntil { h.downloads.state(of: track) == .downloaded }
        #expect(h.io.metadataRequests.isEmpty)
        #expect(h.downloads.bytes == 4)
        #expect(h.store.downloads.count == 1)
    }

    @Test func invalidatedDownloadedAudioWaitsForTheNetworkAndRefills() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let track = songs(["invalidated"])[0]
        h.downloads.download([track])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.io.resolve(0)
        try await waitUntil { h.io.transfers.count == 1 }
        h.io.finish(0)
        try await waitUntil { h.downloads.state(of: track) == .downloaded }
        h.downloads.refreshInvalidatedDownload(track.id)
        #expect(h.io.metadataRequests.count == 1)
        h.downloads.networkSnapshotOverride = .init(status: .offline)
        h.store.discard(track.id)
        h.downloads.refreshInvalidatedDownload(track.id)
        h.downloads.refreshInvalidatedDownload(track.id)
        #expect(h.downloads.state(of: track) == .waiting)
        #expect(h.downloads.bytes == 0)
        await drainReadyTasks()
        #expect(h.io.metadataRequests.count == 1)
        h.downloads.networkSnapshotOverride = .init(status: .online, interface: .wifi)
        try await waitUntil { h.io.metadataRequests.count == 2 }
        h.io.resolve(1)
        try await waitUntil { h.io.transfers.count == 2 }
        h.io.finish(1)
        try await waitUntil { h.downloads.state(of: track) == .downloaded }
        #expect(h.downloads.songs.map(\.id) == [track.id])
        #expect(h.downloads.bytes == 4)
    }

    @Test func authorizationFailureStopsWithoutAutomaticRetry() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        let track = songs(["requires-login"])[0]
        h.downloads.download([track])
        try await waitUntil { h.io.metadataRequests.count == 1 }
        h.io.fail(0, error: MusicError.signedOut)
        try await waitUntil { h.downloads.state(of: track) == .failed }
        #expect(h.io.delays.isEmpty)
        #expect(h.io.metadataRequests.count == 1)
        #expect(h.io.transfers.isEmpty)
    }
}
