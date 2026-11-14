import Foundation
import Testing
@testable import KodaCore

private func onSnapshotWorker<T: Sendable>(
    _ operation: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(with: Result { try operation() })
        }
    }
}

private final class SnapshotWriteEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) { lock.withLock { events.append(event) } }
    func snapshot() -> [String] { lock.withLock { events } }
}

private struct UnencodableQueueSnapshot: Encodable {
    struct EncodingFailure: Error {}
    func encode(to encoder: Encoder) throws { throw EncodingFailure() }
}

struct QueueSnapshotWriterTests {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "queue-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func delayedOldSnapshotCannotOverwriteSynchronousBackgroundFlush() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let writer = QueueSnapshotWriter()
        let oldVersion = writer.reserve()
        #expect(writer.isCurrent(oldVersion)) // The original race began after this check.
        let oldMayCommit = DispatchSemaphore(value: 0)
        defer { oldMayCommit.signal() }
        let old = Task {
            try await onSnapshotWorker {
                oldMayCommit.wait()
                return try writer.write(Data("old".utf8), version: oldVersion, to: file)
            }
        }
        let newestVersion = writer.reserve()
        let flushed = try writer.write(Data("foreground-to-background".utf8), version: newestVersion, to: file)
        #expect(flushed)
        oldMayCommit.signal()
        let oldCommitted = try await old.value
        #expect(!oldCommitted)
        #expect(try Data(contentsOf: file) == Data("foreground-to-background".utf8))
    }

    @Test func heldOldFileWriteFinishesBeforeNewReservationAndCommit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let oldData = Data("old".utf8)
        let newestData = Data("newest".utf8)
        let enteredOldWrite = DispatchSemaphore(value: 0)
        let releaseOldWrite = DispatchSemaphore(value: 0)
        defer { releaseOldWrite.signal() }
        let newRequestStarted = DispatchSemaphore(value: 0)
        let events = SnapshotWriteEvents()
        let writer = QueueSnapshotWriter { data, destination in
            let old = data == oldData
            events.append(old ? "old-write-start" : "new-write-start")
            if old {
                enteredOldWrite.signal()
                releaseOldWrite.wait()
            }
            try data.write(to: destination, options: .atomic)
            events.append(old ? "old-write-finish" : "new-write-finish")
        }
        let oldVersion = writer.reserve()
        let old = Task {
            try await onSnapshotWorker { try writer.write(oldData, version: oldVersion, to: file) }
        }
        try await onSnapshotWorker { enteredOldWrite.wait() }
        let newest = Task {
            try await onSnapshotWorker {
                newRequestStarted.signal()
                let version = writer.reserve()
                return try writer.write(newestData, version: version, to: file)
            }
        }
        try await onSnapshotWorker { newRequestStarted.wait() }
        releaseOldWrite.signal()
        let oldCommitted = try await old.value
        let newestCommitted = try await newest.value
        #expect(oldCommitted)
        #expect(newestCommitted)
        #expect(events.snapshot() == ["old-write-start", "old-write-finish", "new-write-start", "new-write-finish"])
        #expect(try Data(contentsOf: file) == newestData)
    }

    @Test func reservingNewestInvalidatesOlderEncodingBeforeEitherWrites() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let writer = QueueSnapshotWriter()
        let old = writer.reserve()
        let newest = writer.reserve()
        let staleWrite = try writer.write(Data("old".utf8), version: old, to: file)
        #expect(!staleWrite)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let newWrite = try writer.write(Data("new".utf8), version: newest, to: file)
        #expect(newWrite)
        #expect(try Data(contentsOf: file) == Data("new".utf8))
    }

    @Test func encodingFailureKeepsLastDurableSnapshotAndDoesNotPermitStaleCommit() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let writer = QueueSnapshotWriter()
        let durable = writer.reserve()
        try writer.write(Data("durable".utf8), version: durable, to: file)
        let delayed = writer.reserve()
        _ = writer.reserve() // The failed snapshot reserves before encoding, as Player does.
        #expect(throws: UnencodableQueueSnapshot.EncodingFailure.self) {
            try JSONEncoder().encode(UnencodableQueueSnapshot())
        }
        let staleWrite = try writer.write(Data("stale".utf8), version: delayed, to: file)
        #expect(!staleWrite)
        #expect(try Data(contentsOf: file) == Data("durable".utf8))
        let next = writer.reserve()
        let nextWrite = try writer.write(Data("recovered".utf8), version: next, to: file)
        #expect(nextWrite)
    }

    @Test func invalidDirectoryReleasesLockWithoutRevivingAnOlderVersion() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let writer = QueueSnapshotWriter()
        let durable = writer.reserve()
        try writer.write(Data("durable".utf8), version: durable, to: file)
        let delayed = writer.reserve()
        let failing = writer.reserve()
        let invalidFile = directory.appending(path: "missing-parent/queue.json")
        #expect(throws: (any Error).self) {
            try writer.write(Data("cannot-write".utf8), version: failing, to: invalidFile)
        }
        let staleWrite = try writer.write(Data("stale".utf8), version: delayed, to: file)
        #expect(!staleWrite)
        #expect(try Data(contentsOf: file) == Data("durable".utf8))
        // A retry of the same newest reservation remains valid after an I/O failure.
        let retried = try writer.write(Data("retry".utf8), version: failing, to: file)
        #expect(retried)
        #expect(try Data(contentsOf: file) == Data("retry".utf8))
    }

    @Test func atomicRoundTripPreservesExistingJSONBytesAndSchema() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let writer = QueueSnapshotWriter()
        let payload = Data(#"{"queue":{"items":[]},"position":42.25,"smartHistory":{},"wasPlaying":false,"schemaVersion":2}"#.utf8)
        let version = writer.reserve()
        let written = try writer.write(payload, version: version, to: file)
        #expect(written)
        let restored = try Data(contentsOf: file)
        #expect(restored == payload)
        let json = try #require(JSONSerialization.jsonObject(with: restored) as? [String: Any])
        #expect(json["position"] as? Double == 42.25)
        #expect(json["schemaVersion"] as? Int == 2)
        #expect(Set(json.keys) == ["queue", "position", "smartHistory", "wasPlaying", "schemaVersion"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["queue.json"])
    }

    @Test func committedOrForeignVersionCannotReplaceCurrentFile() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "queue.json")
        let writer = QueueSnapshotWriter()
        let version = writer.reserve()
        try writer.write(Data("current".utf8), version: version, to: file)
        let duplicate = try writer.write(Data("duplicate".utf8), version: version, to: file)
        #expect(!duplicate)
        #expect(!writer.isCurrent(version))
        let foreign = QueueSnapshotWriter().reserve()
        let foreignWrite = try writer.write(Data("foreign".utf8), version: foreign, to: file)
        #expect(!foreignWrite)
        #expect(try Data(contentsOf: file) == Data("current".utf8))
    }
}
