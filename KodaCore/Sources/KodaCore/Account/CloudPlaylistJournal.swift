import Foundation

/// Device-side receipts are not playlists. They prevent an interrupted cloud write
/// from being replayed blindly after a relaunch. Each account profile has its own file.
public actor CloudPlaylistJournal {
    private var catalogVersions: [URL: (session: UUID, revision: UInt64)] = [:]
    private var snapshotVersions: [URL: (session: UUID, revision: UInt64)] = [:]
    public enum Failure: Error, Equatable, Sendable {
        case unreadableReceipt, unsupportedVersion, storageUnavailable
    }

    private struct Envelope: Codable {
        let version: Int
        let checkpoint: CloudPlaylistCheckpoint
    }

    public struct Catalog: Codable, Sendable {
        public let playlists: [PlaylistSummary]
        public let fetchedAt: Date

        public init(playlists: [PlaylistSummary], fetchedAt: Date) {
            self.playlists = playlists
            self.fetchedAt = fetchedAt
        }
    }

    public init() {}

    public func load(in directory: URL) throws -> CloudPlaylistCheckpoint? {
        let file = receiptFile(in: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
            guard envelope.version == 1 else { throw Failure.unsupportedVersion }
            return envelope.checkpoint
        } catch let failure as Failure {
            throw failure
        } catch {
            // Do not silently discard an unknown write and permit a second Create.
            throw Failure.unreadableReceipt
        }
    }

    public func save(_ checkpoint: CloudPlaylistCheckpoint, in directory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(version: 1, checkpoint: checkpoint))
            try data.write(to: receiptFile(in: directory), options: .atomic)
        } catch {
            throw Failure.storageUnavailable
        }
    }

    /// A delayed dismissal cannot remove a receipt for a newer operation.
    public func archive(id: UUID, in directory: URL) throws {
        guard let current = try load(in: directory), current.id == id else { return }
        let file = receiptFile(in: directory)
        let backup = directory.appending(path: "cloud-playlist-operation-backup.json")
        do {
            let data = try Data(contentsOf: file)
            try data.write(to: backup, options: .atomic)
            try FileManager.default.removeItem(at: file)
        } catch {
            throw Failure.storageUnavailable
        }
    }

    public func loadCatalog(in directory: URL) -> Catalog? {
        guard let data = try? Data(contentsOf: catalogFile(in: directory)) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// The app supplies a monotonic revision when accepting a result, before it
    /// schedules persistence. Actor arrival order alone cannot establish freshness.
    public func saveCatalog(_ value: Catalog, session: UUID, revision: UInt64, in directory: URL) throws {
        if let accepted = catalogVersions[directory], accepted.session == session,
           accepted.revision >= revision { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: catalogFile(in: directory), options: .atomic)
            catalogVersions[directory] = (session, revision)
        } catch {
            throw Failure.storageUnavailable
        }
    }

    /// Complete display snapshots only. These are never accepted as proof that a
    /// cloud mutation succeeded or that its current permissions still allow it.
    public func loadSnapshots(in directory: URL) -> [CloudPlaylistSnapshot] {
        guard let data = try? Data(contentsOf: snapshotFile(in: directory)),
              let values = try? JSONDecoder().decode([CloudPlaylistSnapshot].self, from: data) else { return [] }
        return CloudPlaylistCachePolicy.retainedSnapshots(values)
    }

    public func saveSnapshots(_ values: [CloudPlaylistSnapshot], session: UUID, revision: UInt64, in directory: URL) throws {
        if let accepted = snapshotVersions[directory], accepted.session == session,
           accepted.revision >= revision { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let retained = CloudPlaylistCachePolicy.retainedSnapshots(values)
            try JSONEncoder().encode(retained).write(to: snapshotFile(in: directory), options: .atomic)
            snapshotVersions[directory] = (session, revision)
        } catch {
            throw Failure.storageUnavailable
        }
    }

    private func receiptFile(in directory: URL) -> URL {
        directory.appending(path: "cloud-playlist-operation.json")
    }

    private func catalogFile(in directory: URL) -> URL {
        directory.appending(path: "cloud-playlists-cache.json")
    }

    private func snapshotFile(in directory: URL) -> URL {
        directory.appending(path: "cloud-playlist-snapshots.json")
    }
}
