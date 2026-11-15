import AVFoundation
import Foundation
import ObjectiveC

/// Feeds AVFoundation a song from YouTube while keeping every byte that arrives, so next
/// time the song plays from the phone.
///
/// The asset gets a `koda-cache:` URL, which AVFoundation can't load by itself, so it asks
/// this loader for each byte range it wants. Bytes already on disk are answered from the
/// file. For the rest one ranged request runs at a time, from the first byte any waiting
/// request needs to the next byte already held; what arrives is written to the file and
/// answered from there. When nobody is waiting it fills the song's remaining gaps, so a
/// song that was skipped through still ends up whole. Everything runs on one serial queue.
final class CachingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let stream: ResolvedStream
    private let length: Int64
    private let store: AudioStore
    private let queue = DispatchQueue(label: "koda.cachingloader", qos: .userInitiated)
    private var session: URLSession!
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var task: URLSessionDataTask?
    /// Where the running request's next byte belongs, and where it stops.
    private var taskOffset: Int64 = 0
    private var taskEnd: Int64 = 0
    private var taskAccepted = false
    private var failure: Error?
    private let lifetime = CacheFillLifetime()

    /// A waiting request this close ahead of the running one is left to it rather than
    /// starting a request of its own.
    private static let reachAhead: Int64 = 512 * 1024
    /// The most handed to AVFoundation in one go.
    private static let slice: Int64 = 512 * 1024

    /// Nil when the stream's length isn't known: without it the file can't be laid out.
    init?(stream: ResolvedStream, song: Song?, store: AudioStore,
          sessionConfiguration: URLSessionConfiguration = .default) {
        guard let length = stream.contentLength, length > 0 else { return nil }
        self.stream = stream
        self.length = length
        self.store = store
        super.init()
        store.prepare(stream, song: song)
        store.beginUse(stream.videoId)
        let operations = OperationQueue()
        operations.underlyingQueue = queue
        operations.maxConcurrentOperationCount = 1
        let configuration = sessionConfiguration
        // The file is the cache; URLCache keeping a second copy would only take space.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: SessionEvents(loader: self), delegateQueue: operations)
    }

    deinit {
        session.invalidateAndCancel()
        if lifetime.releaseStoreUse() { store.endUse(stream.videoId) }
    }

    /// An asset reading through this loader; the asset keeps the loader alive, since its
    /// resource loader holds its delegate weakly.
    func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "koda-cache://audio/\(stream.videoId).m4a")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        objc_setAssociatedObject(asset, &loaderKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }

    /// Deep stop is terminal for this asset's loader. Ordinary AVFoundation request
    /// cancellation deliberately retains the old fill-the-cache behavior below.
    static func stop(asset: AVAsset) {
        (objc_getAssociatedObject(asset, &loaderKey) as? CachingLoader)?.stop()
    }

    func stop() {
        guard lifetime.stop() else { return }
        // URLSession cancellation is thread-safe and does not wait for the delegate queue's
        // current disk write/eviction. That one already-claimed write may finish while the
        // queue drains; no callback can claim another write after the terminal flag is set.
        session.invalidateAndCancel()
        queue.async { [self] in
            task?.cancel()
            task = nil
            session.invalidateAndCancel()
            let pending = requests
            requests.removeAll()
            for request in pending { request.finishLoading(with: URLError(.cancelled)) }
            if lifetime.releaseStoreUse() { store.endUse(stream.videoId) }
        }
    }

    /// Deterministic test seam exercises the real session/cache path without requiring an
    /// AVFoundation decoder to ask for bytes. Production starts filling through serve().
    func beginCacheFillForTesting() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in fetchIfNeeded(); continuation.resume() }
        }
    }

    func waitForPendingOperations() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !lifetime.isStopped else {
            loadingRequest.finishLoading(with: URLError(.cancelled))
            return true
        }
        requests.append(loadingRequest)
        serve()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // The running request keeps going: what it fetches is kept either way.
        requests.removeAll { $0 === loadingRequest }
    }

    // MARK: Answering

    private func serve() {
        guard !lifetime.isStopped else { return }
        requests.removeAll { answer($0) }
        fetchIfNeeded()
    }

    /// Answer as much of `request` as the file holds; true once it is finished.
    private func answer(_ request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = AVFileType.m4a.rawValue
            info.contentLength = length
            info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else {
            request.finishLoading()
            return true
        }
        let end = data.requestsAllDataToEndOfResource ? length : min(length, data.requestedOffset + Int64(data.requestedLength))
        while data.currentOffset < end {
            guard !lifetime.isStopped else { return false }
            let count = min(store.contiguousLength(stream.videoId, from: data.currentOffset), end - data.currentOffset, Self.slice)
            guard count > 0, let bytes = store.read(stream.videoId, at: data.currentOffset, count: count) else { break }
            data.respond(with: bytes)
        }
        if data.currentOffset >= end {
            request.finishLoading()
            return true
        }
        if let failure {
            request.finishLoading(with: failure)
            return true
        }
        return false
    }

    // MARK: Fetching

    private func fetchIfNeeded() {
        guard !lifetime.isStopped, failure == nil else { return }
        guard let needed = requests.compactMap({ $0.dataRequest?.currentOffset }).min() else {
            // Nobody waiting: fill the song's gaps while there is no request running.
            if task == nil, let gap = store.firstGap(stream.videoId) { start(gap) }
            return
        }
        if task != nil, needed >= taskOffset, needed < min(taskEnd, taskOffset + Self.reachAhead) { return }
        guard let gap = store.firstGap(stream.videoId, from: needed) else { return }
        task?.cancel()
        start(gap)
    }

    private func start(_ range: Range<Int64>) {
        guard !lifetime.isStopped else { return }
        var request = URLRequest(url: stream.url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue(stream.userAgent, forHTTPHeaderField: "User-Agent")
        taskOffset = range.lowerBound
        taskEnd = range.upperBound
        taskAccepted = false
        let task = session.dataTask(with: request)
        self.task = task
        // A deep stop racing this callback must win before any new request is resumed.
        lifetime.whileActive { task.resume() }
    }

    /// Whether the response is audio for the range asked; checked once, on its first bytes.
    private func accept(_ response: URLResponse?, hasBody: Bool = true) throws {
        let accepted = try CachingResponse.acceptedRange(response, requested: taskOffset..<taskEnd, length: length, hasBody: hasBody)
        taskOffset = accepted.lowerBound
        taskEnd = accepted.upperBound
    }

    fileprivate func received(_ data: Data, from task: URLSessionTask) {
        guard !lifetime.isStopped, task === self.task, !data.isEmpty else { return }
        if !taskAccepted {
            do {
                try accept(task.response)
            } catch {
                // Preserve the actual status through AVFoundation's underlying NSError.
                fail(error)
                return
            }
            taskAccepted = true
        }
        guard Int64(data.count) <= taskEnd - taskOffset else {
            fail(AudioStreamResponseError.invalidRange)
            return
        }
        do {
            // Claim one write before the terminal boundary. A write already in progress
            // may finish during async shutdown; callbacks arriving after stop cannot write.
            guard try lifetime.whileActive({ try store.write(data, at: taskOffset, for: stream.videoId) }) else { return }
        } catch {
            fail(error)
            return
        }
        taskOffset += Int64(data.count)
        serve()
    }

    fileprivate func completed(_ task: URLSessionTask, error: Error?) {
        guard !lifetime.isStopped, task === self.task else { return }
        self.task = nil
        if let error, (error as? URLError)?.code != .cancelled {
            // A definite access verdict must not become a retryable transport failure.
            if let response = task.response as? HTTPURLResponse, response.statusCode != 200, response.statusCode != 206 {
                fail(AudioStreamResponseError.httpStatus(response.statusCode))
            } else {
                fail(error)
            }
            return
        }
        // A refusal can come with no body, and so without any bytes to check it on; retrying
        // it would loop.
        if error == nil, !taskAccepted {
            do {
                try accept(task.response, hasBody: false)
            } catch {
                fail(error)
                return
            }
        }
        serve()
    }

    private func fail(_ error: Error) {
        guard !lifetime.isStopped else { return }
        failure = error
        task?.cancel()
        task = nil
        serve()
    }
}

/// The serial delegate queue owns loading state. Claiming an operation is serialized with
/// stop, but disk work runs outside this lock: deep stop never waits for disk eviction.
/// An operation claimed before stop may finish; stop prevents every later claim.
final class CacheFillLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var ownsStoreUse = true
    var isStopped: Bool { lock.withLock { stopped } }

    @discardableResult func stop() -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
    }

    @discardableResult func whileActive(_ operation: () throws -> Void) rethrows -> Bool {
        guard lock.withLock({ !stopped }) else { return false }
        try operation()
        return true
    }

    func releaseStoreUse() -> Bool {
        lock.withLock {
            guard ownsStoreUse else { return false }
            ownsStoreUse = false
            return true
        }
    }
}

nonisolated(unsafe) private var loaderKey: UInt8 = 0

/// The session's delegate. A session keeps its delegate until invalidated, so this holds the
/// loader weakly, letting it go with its asset.
private final class SessionEvents: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var loader: CachingLoader?

    init(loader: CachingLoader) {
        self.loader = loader
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        loader?.received(data, from: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        loader?.completed(task, error: error)
    }
}
