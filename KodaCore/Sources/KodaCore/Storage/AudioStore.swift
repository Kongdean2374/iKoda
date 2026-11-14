import Foundation

/// Songs' audio kept on this phone: saved while they stream, so a song played before starts
/// from the file, and downloaded, kept until the listener removes it.
///
/// One file per song, filled as bytes arrive in any order, and an index of which bytes each
/// holds. Songs saved from listening are a cache: past `cacheLimit` the least recently played
/// go first, never a download or a song being played. Every method may be called from any
/// thread; the index is written off the calling thread, a moment after a change.
public final class AudioStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var videoId: String
        /// The song itself, so downloads can be listed with no connection.
        public var song: Song?
        public var contentLength: Int64?
        public var itag: Int?
        public var duration: TimeInterval?
        public var loudnessDb: Double?
        public var ranges = ByteRanges()
        /// Kept until removed, never evicted.
        public var isDownload = false
        public var added: Date
        public var lastUsed: Date

        public var isComplete: Bool { contentLength.map { $0 > 0 && ranges.contains(0..<$0) } ?? false }
        public var bytes: Int64 { ranges.count }

        init(videoId: String, song: Song?, at date: Date) {
            self.videoId = videoId
            self.song = song
            added = date
            lastUsed = date
        }

        // Saved data must survive upgrades: anything missing takes its default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            videoId = try c.decode(String.self, forKey: .videoId)
            song = try c.decodeIfPresent(Song.self, forKey: .song)
            contentLength = try c.decodeIfPresent(Int64.self, forKey: .contentLength)
            itag = try c.decodeIfPresent(Int.self, forKey: .itag)
            duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
            loudnessDb = try c.decodeIfPresent(Double.self, forKey: .loudnessDb)
            ranges = try c.decodeIfPresent(ByteRanges.self, forKey: .ranges) ?? ByteRanges()
            isDownload = try c.decodeIfPresent(Bool.self, forKey: .isDownload) ?? false
            added = try c.decodeIfPresent(Date.self, forKey: .added) ?? Date()
            lastUsed = try c.decodeIfPresent(Date.self, forKey: .lastUsed) ?? added
        }
    }

    private let directory: URL
    private let indexFile: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var handles: [String: FileHandle] = [:]
    /// A late decoder failure must not discard a newer file written at the same path.
    private var fileVersions: [String: UUID] = [:]
    /// Songs being played or fetched, by how many users; never evicted.
    private var inUse: [String: Int] = [:]
    private var cacheLimitBytes: Int64
    private var saveVersion = 0
    private let saveQueue = DispatchQueue(label: "koda.audiostore.save", qos: .utility)

    public init(directory: URL, cacheLimit: Int64 = 1_000_000_000) {
        self.directory = directory
        indexFile = directory.appending(path: "index.json")
        cacheLimitBytes = cacheLimit
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexFile),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in saved { entries[entry.videoId] = entry }
            // Missing, truncated or replaced bytes cannot be made complete by an old index.
            var changed = false
            for id in Array(entries.keys) { changed = validateStoredFile(id) || changed }
            if changed { scheduleSave() }
        }
    }

    // MARK: Reading

    public func entry(_ videoId: String) -> Entry? {
        var changed = false
        let entry = lock.withLock {
            changed = validateStoredFile(videoId)
            return entries[videoId]
        }
        if changed { scheduleSave() }
        return entry
    }

    /// Downloads, most recently added first.
    public var downloads: [Entry] {
        var changed = false
        let result = lock.withLock {
            for id in entries.values.filter(\.isDownload).map(\.videoId) { changed = validateStoredFile(id) || changed }
            return entries.values.filter(\.isDownload).sorted { $0.added > $1.added }
        }
        if changed { scheduleSave() }
        return result
    }

    /// Songs held whole, downloaded or kept from listening, most recently played first: what
    /// plays with no connection.
    public var completeSongs: [Song] {
        lock.withLock { entries.values.filter(\.isComplete).sorted { $0.lastUsed > $1.lastUsed }.compactMap(\.song) }
    }

    public var cacheBytes: Int64 { lock.withLock { entries.values.filter { !$0.isDownload }.reduce(0) { $0 + $1.bytes } } }
    public var downloadBytes: Int64 { lock.withLock { entries.values.filter(\.isDownload).reduce(0) { $0 + $1.bytes } } }

    public var cacheLimit: Int64 {
        get { lock.withLock { cacheLimitBytes } }
        set {
            lock.withLock { cacheLimitBytes = newValue }
            evict()
        }
    }

    func fileURL(_ videoId: String) -> URL { directory.appending(path: "\(videoId).m4a") }

    /// The song as a stream from its file, when every byte of it is here.
    func completeStream(_ videoId: String) -> ResolvedStream? {
        var changed = false
        let result: ResolvedStream? = lock.withLock {
            changed = validateStoredFile(videoId)
            guard var entry = entries[videoId], entry.isComplete else { return nil }
            entry.lastUsed = Date()
            entries[videoId] = entry
            let version = fileVersions[videoId] ?? UUID()
            fileVersions[videoId] = version
            return ResolvedStream(videoId: videoId, url: fileURL(videoId), userAgent: "", itag: entry.itag ?? 0,
                                  contentLength: entry.contentLength, duration: entry.duration,
                                  loudnessDb: entry.loudnessDb, expiresAt: nil, localFileVersion: version)
        }
        if changed { scheduleSave() }
        return result
    }

    func contiguousLength(_ videoId: String, from offset: Int64) -> Int64 {
        lock.withLock { entries[videoId]?.ranges.contiguousLength(from: offset) ?? 0 }
    }

    /// The first byte the song's file is missing, and where that gap ends.
    func firstGap(_ videoId: String, from offset: Int64 = 0) -> Range<Int64>? {
        lock.withLock {
            guard let entry = entries[videoId], let length = entry.contentLength,
                  let start = entry.ranges.firstMissing(from: offset, before: length) else { return nil }
            return start..<entry.ranges.gapEnd(from: start, before: length)
        }
    }

    /// Bytes from the file, only when all of them are there.
    func read(_ videoId: String, at offset: Int64, count: Int64) -> Data? {
        lock.withLock {
            guard count > 0, let entry = entries[videoId], entry.ranges.contains(offset..<(offset + count)),
                  let handle = openHandle(videoId) else { return nil }
            do {
                try handle.seek(toOffset: UInt64(offset))
                return try handle.read(upToCount: Int(count))
            } catch {
                return nil
            }
        }
    }

    // MARK: Writing

    /// Get ready to hold `stream`'s bytes. A different format of the song than the one held
    /// (another length) starts the file again.
    func prepare(_ stream: ResolvedStream, song: Song?) {
        lock.withLock {
            _ = validateStoredFile(stream.videoId)
            var entry = entries[stream.videoId] ?? Entry(videoId: stream.videoId, song: song, at: Date())
            if let length = stream.contentLength, entry.contentLength != nil, entry.contentLength != length {
                discardBytes(&entry)
            }
            if let song { entry.song = song }
            entry.contentLength = stream.contentLength ?? entry.contentLength
            entry.itag = stream.itag
            entry.duration = stream.duration ?? entry.duration
            entry.loudnessDb = stream.loudnessDb ?? entry.loudnessDb
            entry.lastUsed = Date()
            entries[stream.videoId] = entry
        }
        scheduleSave()
    }

    /// Write `data` where it belongs in the song's file.
    func write(_ data: Data, at offset: Int64, for videoId: String) throws {
        guard !data.isEmpty else { return }
        let completed: Bool = try lock.withLock {
            guard var entry = entries[videoId], let handle = openHandle(videoId) else { return false }
            let wasComplete = entry.isComplete
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
            fileVersions[videoId] = UUID()
            entry.ranges.insert(offset..<(offset + Int64(data.count)))
            entries[videoId] = entry
            guard entry.isComplete, !wasComplete else { return false }
            try? handle.close()
            handles[videoId] = nil
            return true
        }
        scheduleSave()
        if completed { evict() }
    }

    /// Keep the song through eviction while it plays or downloads; balance with `endUse`.
    func beginUse(_ videoId: String) {
        lock.withLock { inUse[videoId, default: 0] += 1 }
    }

    func endUse(_ videoId: String) {
        lock.withLock {
            let count = (inUse[videoId] ?? 1) - 1
            inUse[videoId] = count > 0 ? count : nil
        }
        evict()
    }

    /// A file that failed to play: drop its bytes so it is fetched again, keeping whether it is a download.
    public func discard(_ videoId: String) {
        lock.withLock {
            guard var entry = entries[videoId] else { return }
            discardBytes(&entry)
            entries[videoId] = entry
        }
        scheduleSave()
    }

    /// Remove only an exact local file positively rejected by the decoder. Remote failures,
    /// audio-session interruptions and an old item's failure never erase a valid download.
    /// Its existing download designation remains, so Downloads can fetch it again normally.
    @discardableResult
    public func discardInvalidLocalStream(_ stream: ResolvedStream, error: Error?) -> Bool {
        guard stream.url.isFileURL, LocalAudioFailure.isConfirmed(error) else { return false }
        let discarded = lock.withLock {
            guard stream.url.standardizedFileURL == fileURL(stream.videoId).standardizedFileURL,
                  let version = stream.localFileVersion, version == fileVersions[stream.videoId],
                  var entry = entries[stream.videoId] else { return false }
            discardBytes(&entry)
            entries[stream.videoId] = entry
            return true
        }
        if discarded { scheduleSave() }
        return discarded
    }

    // MARK: Downloads

    /// Mark songs as downloads, kept until removed. Their bytes are fetched by `Downloads`.
    func markDownloaded(_ songs: [Song], at date: Date = Date()) {
        lock.withLock {
            for song in songs {
                var entry = entries[song.id] ?? Entry(videoId: song.id, song: song, at: date)
                if !entry.isDownload { entry.added = date }
                entry.isDownload = true
                entry.song = song
                entries[song.id] = entry
            }
        }
        scheduleSave()
    }

    /// Remove downloads and their files, unless one is playing: that one stays as cache.
    func removeDownloads(_ videoIds: [String]) {
        lock.withLock {
            for id in videoIds {
                guard var entry = entries[id], entry.isDownload else { continue }
                if inUse[id] != nil {
                    entry.isDownload = false
                    entries[id] = entry
                } else {
                    removeFile(id)
                }
            }
        }
        scheduleSave()
    }

    public func removeAllDownloads() {
        removeDownloads(downloads.map(\.videoId))
    }

    /// Empty the listening cache, except songs in use.
    public func clearCache() {
        lock.withLock {
            for (id, entry) in entries where !entry.isDownload && inUse[id] == nil { removeFile(id) }
        }
        scheduleSave()
    }

    // MARK: Housekeeping

    /// Called with the lock held (or during initialization). Validate size, not file contents:
    /// AVFoundation remains responsible for decoding, avoiding audio scans on the main thread.
    @discardableResult
    private func validateStoredFile(_ videoId: String) -> Bool {
        guard var entry = entries[videoId], let highestByte = entry.ranges.ranges.last?.upperBound else { return false }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL(videoId).path)
        } catch {
            let failure = error as NSError
            // File protection or temporarily unavailable storage is not proof of corruption.
            guard failure.domain == NSCocoaErrorDomain,
                  [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) else { return false }
            discardBytes(&entry)
            entries[videoId] = entry
            return true
        }
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              let type = attributes[.type] as? FileAttributeType else { return false }
        let regularFile = type == .typeRegular
        let matches = regularFile && size >= highestByte && (!entry.isComplete || size == entry.contentLength)
        guard !matches else { return false }
        discardBytes(&entry)
        entries[videoId] = entry
        return true
    }

    /// Bring the cache under its limit, least recently played first.
    func evict() {
        lock.withLock {
            var total = entries.values.filter { !$0.isDownload }.reduce(0) { $0 + $1.bytes }
            guard total > cacheLimitBytes else { return }
            let candidates = entries.values.filter { !$0.isDownload && inUse[$0.videoId] == nil }.sorted { $0.lastUsed < $1.lastUsed }
            for entry in candidates {
                guard total > cacheLimitBytes else { break }
                total -= entry.bytes
                removeFile(entry.videoId)
            }
        }
        scheduleSave()
    }

    /// Called with the lock held.
    private func openHandle(_ videoId: String) -> FileHandle? {
        if let handle = handles[videoId] { return handle }
        let url = fileURL(videoId)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forUpdating: url) else { return nil }
        handles[videoId] = handle
        return handle
    }

    /// Called with the lock held.
    private func discardBytes(_ entry: inout Entry) {
        try? handles[entry.videoId]?.close()
        handles[entry.videoId] = nil
        try? FileManager.default.removeItem(at: fileURL(entry.videoId))
        entry.ranges = ByteRanges()
        fileVersions[entry.videoId] = UUID()
    }

    /// Called with the lock held.
    private func removeFile(_ videoId: String) {
        try? handles[videoId]?.close()
        handles[videoId] = nil
        try? FileManager.default.removeItem(at: fileURL(videoId))
        entries[videoId] = nil
        fileVersions[videoId] = nil
    }

    /// Write the index a moment later, once, for the newest state.
    private func scheduleSave() {
        let version = lock.withLock {
            saveVersion += 1
            return saveVersion
        }
        saveQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let snapshot: [Entry]? = self.lock.withLock {
                version == self.saveVersion ? Array(self.entries.values) : nil
            }
            guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.indexFile, options: .atomic)
        }
    }

    /// Write the index now, on this thread: the app is leaving the screen.
    public func flush() {
        let snapshot = lock.withLock {
            saveVersion += 1
            return Array(entries.values)
        }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: indexFile, options: .atomic) }
    }
}
