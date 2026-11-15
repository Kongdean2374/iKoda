import AVFoundation
import Foundation
import Testing
@testable import KodaCore

private actor SuspendedAudioWork<Value: Sendable> {
    private(set) var count = 0
    private var waiting: [Int: CheckedContinuation<Value, Never>] = [:]
    func run() async -> Value {
        count += 1
        let index = count
        return await withCheckedContinuation { waiting[index] = $0 }
    }
    func finish(_ index: Int, with value: Value) { waiting.removeValue(forKey: index)?.resume(returning: value) }
}

private func awaitAudioCondition(_ ready: () async -> Bool) async throws {
    while !(await ready()) { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(1)) }
}

private func cancellationStream(_ id: String, duration: Double = 180) -> ResolvedStream {
    ResolvedStream(videoId: id, url: URL(string: "https://audio-cancellation.test/\(id)")!,
                   userAgent: "test", itag: 140, contentLength: 8, duration: duration, loudnessDb: nil, expiresAt: nil)
}

private func cancellationAnalysis(_ duration: Double) -> TrackAnalysis {
    TrackAnalysis(duration: duration, musicStart: 0, musicEnd: duration, bodyDb: -14,
                  ending: .hard, outroStart: nil, fadeCue: nil, introEnd: 0, bpm: nil, tempoConfidence: 0)
}

@Suite(.timeLimit(.minutes(1)))
struct AutoMixCancellationTests {
    @Test func oneCancelledSubscriberDoesNotCancelAnother() async throws {
        let work = SuspendedAudioWork<TrackAnalysis?>()
        let analyzer = AutoMixAnalyzer(store: nil, directory: nil, measure: { _, _, _ in await work.run() })
        let stream = cancellationStream("shared")
        let first = Task { await analyzer.analysis(for: stream, title: "First") }
        let second = Task { await analyzer.analysis(for: stream, title: "Second") }
        try await awaitAudioCondition {
            let waiting = await analyzer.waitingCount, calls = await work.count
            return waiting == 2 && calls == 1
        }
        first.cancel()
        let cancelled = await first.value
        #expect(cancelled == nil)
        #expect(await analyzer.waitingCount == 1)
        let expected = cancellationAnalysis(180)
        await work.finish(1, with: expected)
        #expect(await second.value == expected)
        #expect(await work.count == 1)
    }

    @Test func deepStopReturnsImmediatelyAndLateWorkCannotReplaceANewJob() async throws {
        let work = SuspendedAudioWork<TrackAnalysis?>()
        let directory = FileManager.default.temporaryDirectory.appending(path: "analysis-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let analyzer = AutoMixAnalyzer(store: nil, directory: directory, measure: { _, _, _ in await work.run() })
        let stream = cancellationStream("same")
        let old = Task { await analyzer.analysis(for: stream, title: "Old") }
        try await awaitAudioCondition { await work.count == 1 }
        await analyzer.cancelAll()
        #expect(await old.value == nil)
        #expect(await analyzer.runningCount == 0)
        let fresh = Task { await analyzer.analysis(for: stream, title: "Fresh") }
        try await awaitAudioCondition { await work.count == 2 }
        await work.finish(1, with: cancellationAnalysis(180))
        try await awaitAudioCondition { await analyzer.completionCount == 1 }
        #expect(await analyzer.waitingCount == 1)
        #expect(await analyzer.runningCount == 1)
        let expected = cancellationAnalysis(240)
        await work.finish(2, with: expected)
        #expect(await fresh.value == expected)
        #expect(await analyzer.analysis(for: stream, title: "Cached") == expected)
        let data = try Data(contentsOf: directory.appending(path: "AutoMix/same.json"))
        #expect(try JSONDecoder().decode(TrackAnalysis.self, from: data) == expected)
    }

    @Test func onePlayerCannotCancelAnotherPlayersMeasurements() async throws {
        let firstWork = SuspendedAudioWork<TrackAnalysis?>(), otherWork = SuspendedAudioWork<TrackAnalysis?>()
        let firstAnalyzer = AutoMixAnalyzer(store: nil, directory: nil, measure: { _, _, _ in await firstWork.run() })
        let otherAnalyzer = AutoMixAnalyzer(store: nil, directory: nil, measure: { _, _, _ in await otherWork.run() })
        let stream = cancellationStream("same")
        let first = Task { await firstAnalyzer.analysis(for: stream, title: "First") }
        let other = Task { await otherAnalyzer.analysis(for: stream, title: "Other") }
        try await awaitAudioCondition {
            let firstCount = await firstWork.count, otherCount = await otherWork.count
            return firstCount == 1 && otherCount == 1
        }
        await firstAnalyzer.cancelAll()
        #expect(await first.value == nil)
        #expect(await otherAnalyzer.waitingCount == 1)
        let expected = cancellationAnalysis(180)
        await otherWork.finish(1, with: expected)
        #expect(await other.value == expected)
        await firstWork.finish(1, with: expected)
    }

    @Test func cancelledCacheSleepPropagatesInsteadOfSpinningOrDownloading() async {
        do {
            _ = try await AutoMixAnalyzer.waitForCache(isReady: { false }, sleep: { throw CancellationError() })
            Issue.record("Cancellation was swallowed")
        } catch is CancellationError { } catch { Issue.record(error) }
    }

    @Test func decodingDoesNotOpenAnAssetForAnAlreadyCancelledTask() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await AutoMixAnalyzer.decode(URL(fileURLWithPath: "/not-an-audio-file"), limit: 180)
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        #expect(await task.value)
    }

    @Test func cpuMeasurementCanStopBetweenBoundedChunksWithoutChangingPureResults() throws {
        let samples = [Float](repeating: 0.2, count: 22_050 * 12)
        var checkpoints = 0
        do {
            _ = try TrackAnalyzer.analyze(samples, sampleRate: 22_050, checkCancellation: {
                checkpoints += 1
                if checkpoints == 300 { throw CancellationError() }
            })
            Issue.record("CPU work ignored cancellation")
        } catch is CancellationError { } catch { Issue.record(error) }
        #expect(checkpoints == 300)
        let short = Array(samples.prefix(2205))
        #expect(try TrackAnalyzer.analyzeCancellable(short) == TrackAnalyzer.analyze(short))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct StreamResolverCancellationTests {
    private func resolver(_ work: SuspendedAudioWork<(ResolvedStream, ResolvedStream)>) -> StreamResolver {
        let session = URLSession(configuration: .ephemeral)
        return StreamResolver(session: session, identity: VisitorIdentity(session: session, suite: "resolver-cancel-\(UUID())"),
                              audioFetch: { _ in await work.run() })
    }

    @Test func cancellingPlaybackPreservesADownloadSubscriberAndQualityChoice() async throws {
        let work = SuspendedAudioWork<(ResolvedStream, ResolvedStream)>()
        let resolver = resolver(work)
        let playback = Task { try await resolver.resolve("shared") }
        let download = Task { try await resolver.resolve("shared", quality: .dataSaver) }
        try await awaitAudioCondition {
            let waiting = await resolver.audioSubscriberCount, calls = await work.count
            return waiting == 2 && calls == 1
        }
        playback.cancel()
        do { _ = try await playback.value; Issue.record("Playback was not cancelled") }
        catch is CancellationError { } catch { Issue.record(error) }
        #expect(await resolver.audioSubscriberCount == 1)
        let best = cancellationStream("shared")
        var light = best; light.isDataSaver = true; light.itag = 139
        await work.finish(1, with: (best, light))
        #expect(try await download.value == light)
        #expect(try await resolver.resolve("shared") == best)
        #expect(await work.count == 1)
    }

    @Test func soleCallerCancellationReturnsBeforeWorkAndOldCompletionCannotPoisonCache() async throws {
        let work = SuspendedAudioWork<(ResolvedStream, ResolvedStream)>()
        let resolver = resolver(work)
        let old = Task { try await resolver.resolve("same") }
        try await awaitAudioCondition { await work.count == 1 }
        old.cancel()
        do { _ = try await old.value; Issue.record("Caller waited for old work") }
        catch is CancellationError { } catch { Issue.record(error) }
        #expect(await resolver.audioRequestCount == 0)
        let fresh = Task { try await resolver.resolve("same") }
        try await awaitAudioCondition { await work.count == 2 }
        let stale = cancellationStream("same", duration: 180)
        await work.finish(1, with: (stale, stale))
        try await awaitAudioCondition { await resolver.audioCompletionCount == 1 }
        #expect(await resolver.audioRequestCount == 1)
        #expect(await resolver.audioSubscriberCount == 1)
        let expected = cancellationStream("same", duration: 240)
        await work.finish(2, with: (expected, expected))
        #expect(try await fresh.value == expected)
        #expect(try await resolver.resolve("same") == expected)
    }

    @Test func alreadyCancelledCallerNeverStartsMetadataWork() async {
        let work = SuspendedAudioWork<(ResolvedStream, ResolvedStream)>()
        let resolver = resolver(work)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await resolver.resolve("never"); return false }
            catch is CancellationError { return true } catch { return false }
        }
        #expect(await task.value)
        #expect(await work.count == 0)
    }
}

private final class HoldingCacheProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started: [String: Int] = [:]
    nonisolated(unsafe) private static var stopped = Set<String>()
    static func hasStarted(_ id: String) -> Bool { lock.withLock { started[id, default: 0] > 0 } }
    static func requestCount(_ id: String) -> Int { lock.withLock { started[id, default: 0] } }
    static func hasStopped(_ id: String) -> Bool { lock.withLock { stopped.contains(id) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "audio-cancellation.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.withLock { Self.started[request.url!.lastPathComponent, default: 0] += 1 } }
    override func stopLoading() { Self.lock.withLock { _ = Self.stopped.insert(request.url!.lastPathComponent) } }
}

@Suite(.timeLimit(.minutes(1)))
struct CachingLoaderCancellationTests {
    @Test func stoppingDoesNotWaitForAnAlreadyClaimedDiskOperation() async {
        let lifetime = CacheFillLifetime()
        let entered = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Bool>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        DispatchQueue(label: "cache-stop-blocked-write").async {
            var timedOut = false
            lifetime.whileActive {
                entered.continuation.yield(())
                entered.continuation.finish()
                timedOut = release.wait(timeout: .now() + 5) == .timedOut
            }
            completed.continuation.yield(timedOut)
            completed.continuation.finish()
        }
        var began = entered.stream.makeAsyncIterator()
        _ = await began.next()
        lifetime.stop()
        release.signal()
        var finished = completed.stream.makeAsyncIterator()
        let timedOut = await finished.next()
        #expect(timedOut == false)
        let accepted = lifetime.whileActive { Issue.record("A post-stop write started") }
        #expect(!accepted)
    }

    @Test func terminalLifetimeRejectsLateWritesAndReleasesUseOnlyOnce() throws {
        let lifetime = CacheFillLifetime()
        var bytes = Data()
        lifetime.whileActive { bytes.append(1) }
        lifetime.stop()
        let accepted = lifetime.whileActive { bytes.append(2) }
        #expect(!accepted)
        #expect(bytes == Data([1]))
        #expect(lifetime.releaseStoreUse())
        #expect(!lifetime.releaseStoreUse())
        #expect(!lifetime.stop())
    }

    @Test func stoppingOneAssetCancelsOnlyItsSessionAndCannotRestartCacheFilling() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "loader-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AudioStore(directory: directory)
        let firstID = UUID().uuidString, otherID = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HoldingCacheProtocol.self]
        let first = try #require(CachingLoader(stream: cancellationStream(firstID), song: nil, store: store, sessionConfiguration: configuration))
        let other = try #require(CachingLoader(stream: cancellationStream(otherID), song: nil, store: store, sessionConfiguration: configuration))
        defer { first.stop(); other.stop() }
        let asset = first.makeAsset()
        await first.beginCacheFillForTesting()
        await other.beginCacheFillForTesting()
        try await awaitAudioCondition { HoldingCacheProtocol.hasStarted(firstID) && HoldingCacheProtocol.hasStarted(otherID) }
        CachingLoader.stop(asset: asset)
        await first.waitForPendingOperations()
        try await awaitAudioCondition { HoldingCacheProtocol.hasStopped(firstID) }
        #expect(!HoldingCacheProtocol.hasStopped(otherID))
        await first.beginCacheFillForTesting()
        #expect(HoldingCacheProtocol.requestCount(firstID) == 1)
        #expect(store.entry(firstID)?.isComplete != true)
        other.stop()
        await other.waitForPendingOperations()
        try await awaitAudioCondition { HoldingCacheProtocol.hasStopped(otherID) }
    }

    @Test func stoppingACacheLoaderPreservesExplicitDownloadOwnershipAndBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "download-kept-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AudioStore(directory: directory)
        let song = Song(id: "saved", title: "Saved", artistLine: "Artist")
        let stream = cancellationStream(song.id)
        store.markDownloaded([song])
        store.prepare(stream, song: song)
        let bytes = Data(0..<8)
        try store.write(bytes, at: 0, for: song.id)
        let loader = try #require(CachingLoader(stream: stream, song: song, store: store))
        loader.stop()
        await loader.waitForPendingOperations()
        #expect(store.entry(song.id)?.isDownload == true)
        #expect(store.entry(song.id)?.isComplete == true)
        #expect(store.read(song.id, at: 0, count: 8) == bytes)
    }
}
