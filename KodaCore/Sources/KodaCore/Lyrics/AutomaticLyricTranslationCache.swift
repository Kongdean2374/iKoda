import CryptoKit
import Foundation

/// Device-local checkpoints for automatic translations. One actor owns the directory so
/// an older partial checkpoint cannot overwrite a completed song. Files are expendable;
/// an unreadable, corrupt or incompatible record behaves as a cache miss.
public actor AutomaticLyricTranslationCache {
    public struct Key: Codable, Hashable, Sendable {
        public let songID: String
        public let target: String
        public let fingerprint: String
        private let engineVersion: Int
        private static let currentEngineVersion = 1

        /// Source text and its ordered row IDs are part of the identity. The same song from
        /// another provider cannot accidentally reuse a translation with different rows.
        public init(songID: String, rows: [ChineseLyricTranslationPlan.Row], target: String = "zh-Hant", namespace: String? = nil) {
            self.songID = songID
            self.target = target
            engineVersion = Self.currentEngineVersion
            var digest = SHA256()
            func append(_ value: String) {
                let bytes = Data(value.utf8)
                // Length framing is unambiguous even when lyrics contain separators/newlines.
                digest.update(data: Data("\(bytes.count):".utf8))
                digest.update(data: bytes)
            }
            append("Koda automatic lyrics \(Self.currentEngineVersion)")
            append(songID)
            append(target)
            if let namespace { append(namespace) }
            append(String(rows.count))
            for row in rows { append(String(row.id)); append(row.text) }
            fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }

        fileprivate var isSupported: Bool {
            engineVersion == Self.currentEngineVersion && Self.isFingerprint(fingerprint)
        }

        fileprivate static func isFingerprint(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var fragments: [String: String]
        public var isComplete: Bool
        public var savedAt: Date
        public var usedCompatibility: Bool?
        public var appleDiagnostics: AppleLyricDiagnostics?

        public init(fragments: [String: String], isComplete: Bool = false, savedAt: Date = Date(),
                    usedCompatibility: Bool? = nil, appleDiagnostics: AppleLyricDiagnostics? = nil) {
            self.fragments = fragments
            self.isComplete = isComplete
            self.savedAt = savedAt
            self.usedCompatibility = usedCompatibility
            self.appleDiagnostics = appleDiagnostics
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let key: Key
        let entry: Entry
    }

    private struct Record {
        var size: Int
        var access: UInt64
        var value: Envelope?
    }

    private let directory: URL
    private let maximumEntries: Int
    private var maximumBytes: Int
    private let maximumRecordBytes: Int
    private var records: [String: Record] = [:]
    private var didLoadIndex = false
    private var accessCounter: UInt64 = 0
    private static let formatVersion = 1

    public init(directory: URL, maximumEntries: Int = 200, maximumBytes: Int = 20_000_000) {
        self.directory = directory
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
        maximumRecordBytes = min(max(0, maximumBytes), 2_000_000)
    }

    /// Memory hits perform no disk reads. First use indexes only file metadata; records
    /// are decoded lazily on this actor's executor, never on the UI's main actor.
    public func entry(for key: Key) -> Entry? {
        guard isEnabled, key.isSupported else { return nil }
        loadIndexIfNeeded()
        let id = key.fingerprint
        guard var record = records[id] else { return nil }
        if let value = record.value {
            guard value.key == key else { remove(id); return nil }
            record.access = nextAccess()
            records[id] = record
            return value.entry
        }
        let url = fileURL(id)
        guard let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              attributes.isRegularFile == true, attributes.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else { remove(id); return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumRecordBytes + 1),
              data.count <= maximumRecordBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.formatVersion, envelope.key == key, envelope.key.isSupported,
              let clean = sanitized(envelope.entry) else { remove(id); return nil }
        record.size = data.count
        record.access = nextAccess()
        record.value = Envelope(version: Self.formatVersion, key: key, entry: clean)
        records[id] = record
        trim()
        return records[id] == nil ? nil : clean
    }

    /// Callers can checkpoint partial work and resume only missing fragments. A complete
    /// record wins over a later partial checkpoint; newer fragments win partial conflicts.
    /// Persistence failures leave a bounded in-memory result available for this session.
    public func store(_ incoming: Entry, for key: Key) {
        guard isEnabled, key.isSupported, let clean = sanitized(incoming) else { return }
        loadIndexIfNeeded()
        let merged: Entry
        if let previous = entry(for: key) {
            if previous.isComplete, !clean.isComplete { return }
            let newer = clean.savedAt >= previous.savedAt
            let fragments = previous.fragments.merging(clean.fragments) { old, new in newer ? new : old }
            merged = Entry(fragments: fragments, isComplete: previous.isComplete || clean.isComplete,
                           savedAt: max(previous.savedAt, clean.savedAt),
                           usedCompatibility: newer ? clean.usedCompatibility : previous.usedCompatibility,
                           appleDiagnostics: (newer ? clean.appleDiagnostics : previous.appleDiagnostics) ?? previous.appleDiagnostics)
        } else {
            merged = clean
        }
        guard merged.fragments.count <= 20_000 else { return }
        let envelope = Envelope(version: Self.formatVersion, key: key, entry: merged)
        guard let data = try? JSONEncoder().encode(envelope), data.count <= maximumRecordBytes else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(key.fingerprint), options: .atomic)
        records[key.fingerprint] = Record(size: data.count, access: nextAccess(), value: envelope)
        trim()
    }

    public func discard(_ key: Key) {
        loadIndexIfNeeded()
        remove(key.fingerprint)
    }

    public func setCapacity(_ bytes: Int) {
        maximumBytes = max(0, bytes)
        loadIndexIfNeeded()
        trim()
    }

    public func byteCount() -> Int {
        loadIndexIfNeeded()
        return records.values.reduce(0) { $0 + $1.size }
    }

    public func clear() {
        loadIndexIfNeeded()
        for id in Array(records.keys) { remove(id) }
    }

    private var isEnabled: Bool { maximumEntries > 0 && maximumBytes > 0 }

    private func sanitized(_ entry: Entry) -> Entry? {
        guard entry.fragments.count <= 20_000, entry.savedAt.timeIntervalSince1970.isFinite else { return nil }
        let fragments = entry.fragments.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return Entry(fragments: fragments,
                     isComplete: entry.isComplete && fragments.count == entry.fragments.count,
                     savedAt: entry.savedAt, usedCompatibility: entry.usedCompatibility, appleDiagnostics: entry.appleDiagnostics)
    }

    private func nextAccess() -> UInt64 {
        accessCounter += 1
        return accessCounter
    }

    private func fileURL(_ id: String) -> URL { directory.appending(path: id + ".json") }

    private func loadIndexIfNeeded() {
        guard !didLoadIndex else { return }
        didLoadIndex = true
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) else { return }
        var indexed: [(id: String, size: Int, date: Date)] = []
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard Key.isFingerprint(id), let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let size = values.fileSize ?? 0
            guard size > 0, size <= maximumRecordBytes else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            indexed.append((id, size, values.contentModificationDate ?? .distantPast))
        }
        // File modification dates approximate recency after relaunch; an in-memory access
        // counter supplies precise LRU ordering for subsequent reads without touching disk.
        indexed.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        for item in indexed { records[item.id] = Record(size: item.size, access: nextAccess(), value: nil) }
        trim()
    }

    private func trim() {
        var total = records.values.reduce(0) { $0 + $1.size }
        for (id, record) in records.sorted(by: { $0.value.access < $1.value.access }) {
            guard records.count > maximumEntries || total > maximumBytes else { break }
            total -= record.size
            remove(id)
        }
    }

    private func remove(_ id: String) {
        records.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: fileURL(id))
    }
}
