import AVFoundation
import Foundation

/// Measures songs for AutoMix, once each: results are kept in memory and on disk by video id.
///
/// The audio comes from the song's file in `AudioStore`. A song playing or waiting on the
/// standby player is being saved whole by `CachingLoader` anyway, so the analyzer waits a
/// little for it to finish; when it doesn't (caching off, a slow connection), it fetches the
/// file once itself into a temporary file.
actor AutoMixAnalyzer {
    private let store: AudioStore?
    private let directory: URL?
    private var memory: [String: TrackAnalysis] = [:]
    typealias Measure = @Sendable (ResolvedStream, String, AudioStore?) async throws -> TrackAnalysis?
    private struct Job {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<TrackAnalysis?, Never>]
    }
    private var running: [String: Job] = [:]
    private let measureOverride: Measure?
    var runningCount: Int { running.count }
    var waitingCount: Int { running.values.reduce(0) { $0 + $1.waiters.count } }
    /// Test synchronization observes completion processing, including stale workers.
    private(set) var completionCount = 0

    /// How long to wait for the caching loader to finish a song before fetching it here.
    static let cacheWait: Duration = .seconds(20)

    init(store: AudioStore?, directory: URL?, measure: Measure? = nil) {
        self.store = store
        self.measureOverride = measure
        self.directory = directory?.appending(path: "AutoMix")
        if let folder = self.directory { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    /// The song's measurements, or nil when its audio can't be had. Callers share the
    /// expensive work, but own individual subscriptions: cancelling one cannot cancel a
    /// second caller. The final subscriber's cancellation stops the actual detached work.
    func analysis(for stream: ResolvedStream, title: String) async -> TrackAnalysis? {
        guard !Task.isCancelled else { return nil }
        let id = stream.videoId
        if let known = memory[id] { return known }
        if let saved = load(id) {
            memory[id] = saved
            AutoMixLog.note("analysis \(title) [\(id)] from disk: \(saved.summary)")
            return saved
        }
        let subscriber = UUID()
        let result: TrackAnalysis? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if var job = running[id] {
                    job.waiters[subscriber] = continuation
                    running[id] = job
                    return
                }
                let jobID = UUID(), store = store, measureOverride = measureOverride
                let task = Task.detached(priority: .utility) { [weak self] in
                    let result: TrackAnalysis?
                    do {
                        try Task.checkCancellation()
                        if let measureOverride { result = try await measureOverride(stream, title, store) }
                        else { result = try await Self.measure(stream, title: title, store: store) }
                        try Task.checkCancellation()
                    } catch { await self?.finish(id, jobID: jobID, result: nil); return }
                    await self?.finish(id, jobID: jobID, result: result)
                }
                running[id] = Job(id: jobID, task: task, waiters: [subscriber: continuation])
            }
        } onCancel: {
            Task { await self.cancelSubscriber(subscriber, streamID: id) }
        }
        return Task.isCancelled ? nil : result
    }

    /// Each Player owns its analyzer. Deep stop cancels only this owner's jobs, never
    /// another player or the explicit download manager. Completed measurements remain cached.
    func cancelAll() {
        let jobs = Array(running.values)
        running.removeAll()
        for job in jobs {
            job.task.cancel()
            for continuation in job.waiters.values { continuation.resume(returning: nil) }
        }
    }

    private func cancelSubscriber(_ subscriber: UUID, streamID: String) {
        guard var job = running[streamID], let continuation = job.waiters.removeValue(forKey: subscriber) else { return }
        if job.waiters.isEmpty { running[streamID] = nil; job.task.cancel() }
        else { running[streamID] = job }
        continuation.resume(returning: nil)
    }

    private func finish(_ id: String, jobID: UUID, result: TrackAnalysis?) {
        completionCount &+= 1
        guard let job = running[id], job.id == jobID else { return }
        running[id] = nil
        if let result {
            memory[id] = result
            save(result, id: id)
        }
        for continuation in job.waiters.values { continuation.resume(returning: result) }
    }

    private static func measure(_ stream: ResolvedStream, title: String, store: AudioStore?) async throws -> TrackAnalysis? {
        try Task.checkCancellation()
        let id = stream.videoId
        let began = Date()
        var ownsStoreUse = false
        defer { if ownsStoreUse { store?.endUse(id) } }
        var source = "file"
        var temporary: URL?
        var url: URL?
        if stream.url.isFileURL {
            url = stream.url
        } else if let store {
            store.beginUse(id)
            ownsStoreUse = true
            if try await waitForCache(isReady: { store.entry(id)?.isComplete == true }) {
                url = store.fileURL(id)
                source = "cache (waited \(Date().timeIntervalSince(began).s1) s)"
            }
        }
        try Task.checkCancellation()
        if url == nil {
            do {
                temporary = try await download(stream)
                url = temporary
                source = "download"
            } catch {
                if Task.isCancelled { throw CancellationError() }
                AutoMixLog.note("analysis \(title) [\(id)] FAILED to fetch audio: \(error.localizedDescription)")
                return nil
            }
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        try Task.checkCancellation()
        guard let url else { return nil }
        let decodeStart = Date()
        let samples: [Float]
        do {
            samples = try await decode(url, limit: stream.duration)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            AutoMixLog.note("analysis \(title) [\(id)] FAILED to decode: \(error.localizedDescription)")
            return nil
        }
        let decoded = Date().timeIntervalSince(decodeStart)
        guard samples.count > Int(TrackAnalyzer.sampleRate * 5) else {
            AutoMixLog.note("analysis \(title) [\(id)] FAILED: only \(samples.count) samples")
            return nil
        }
        let measureStart = Date()
        try Task.checkCancellation()
        let result = try TrackAnalyzer.analyzeCancellable(samples)
        try Task.checkCancellation()
        AutoMixLog.note("analysis \(title) [\(id)] via \(source), decode \(decoded.s2) s, measure \(Date().timeIntervalSince(measureStart).s2) s: \(result.summary)")
        return result
    }

    static func waitForCache(isReady: @Sendable () -> Bool,
                             sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(500)) }) async throws -> Bool {
        let deadline = ContinuousClock.now + cacheWait
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if isReady() { return true }
            try await sleep()
        }
        try Task.checkCancellation()
        return isReady()
    }

    /// The song's audio as mono floats at the analysis rate. `limit` stops at YouTube's length,
    /// since AVFoundation reads its fragmented M4A as longer than it is.
    static func decode(_ url: URL, limit: TimeInterval?) async throws -> [Float] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let cancellation = AnalysisAssetCancellation(asset)
        return try await withTaskCancellationHandler {
            try await decode(asset, limit: limit)
        } onCancel: { cancellation.cancel() }
    }

    private static func decode(_ asset: AVURLAsset, limit: TimeInterval?) async throws -> [Float] {
        try Task.checkCancellation()
        defer { asset.cancelLoading() }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try Task.checkCancellation()
        let reader = try AVAssetReader(asset: asset)
        defer { reader.cancelReading() }
        if let limit, limit.isFinite, limit > 0 {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 1000))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: TrackAnalyzer.sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var mono: [Float] = []
        if let limit, limit.isFinite, limit > 0 {
            mono.reserveCapacity(Int(min(limit, 7200) * TrackAnalyzer.sampleRate) + 1024)
        }
        while true {
            try Task.checkCancellation()
            guard let buffer = output.copyNextSampleBuffer() else { break }
            guard let block = CMSampleBufferGetDataBuffer(buffer),
                  let format = CMSampleBufferGetFormatDescription(buffer),
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
            let channels = max(1, Int(description.mChannelsPerFrame))
            let length = CMBlockBufferGetDataLength(block)
            var interleaved = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            interleaved.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            if channels == 1 {
                mono.append(contentsOf: interleaved)
            } else {
                let frames = interleaved.count / channels
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channels { sum += interleaved[f * channels + c] }
                    mono.append(sum / Float(channels))
                }
            }
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        return mono
    }

    /// The whole file into a temporary file, the way `CachingLoader` asks for it.
    private static func download(_ stream: ResolvedStream) async throws -> URL {
        try Task.checkCancellation()
        var request = URLRequest(url: stream.url)
        request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
        if let length = stream.contentLength, length > 0 {
            request.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
        }
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 || status == 206 else {
            throw URLError(.badServerResponse)
        }
        let destination = FileManager.default.temporaryDirectory.appending(path: "automix-\(stream.videoId)-\(UUID().uuidString).m4a")
        try FileManager.default.moveItem(at: file, to: destination)
        do { try Task.checkCancellation() }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }

    // MARK: Disk

    private func file(_ id: String) -> URL? { directory?.appending(path: "\(id).json") }

    private func load(_ id: String) -> TrackAnalysis? {
        guard let url = file(id), let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              saved.version == TrackAnalysis.currentVersion else { return nil }
        return saved
    }

    private func save(_ analysis: TrackAnalysis, id: String) {
        guard let url = file(id), let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// AVAsset's supported cancellation entry point can be called from a task-cancellation
/// handler while its asynchronous property load is suspended. No mutable decode state is
/// shared with that handler; AVAssetReader remains confined to the measuring task.
private final class AnalysisAssetCancellation: @unchecked Sendable {
    let asset: AVURLAsset
    init(_ asset: AVURLAsset) { self.asset = asset }
    func cancel() { asset.cancelLoading() }
}
