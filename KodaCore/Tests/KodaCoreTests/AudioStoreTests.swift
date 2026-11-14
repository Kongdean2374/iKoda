import Foundation
import Testing
@testable import KodaCore

private func onAudioStoreWorker<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue(label: "koda.tests.audiostore-race", qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

private enum AudioStoreRaceFailure: Error {
    case oldWriterDidNotStart, flushDidNotStart, flushDidNotFinish
}

struct ByteRangesTests {
    @Test func mergesOverlappingAndTouchingRanges() {
        var ranges = ByteRanges()
        ranges.insert(10..<20)
        ranges.insert(30..<40)
        ranges.insert(20..<25)
        #expect(ranges.ranges == [10..<25, 30..<40])
        ranges.insert(24..<31)
        #expect(ranges.ranges == [10..<40])
        #expect(ranges.count == 30)
    }

    @Test func findsGapsAndContiguousRuns() {
        var ranges = ByteRanges()
        ranges.insert(0..<100)
        ranges.insert(200..<300)
        #expect(ranges.contiguousLength(from: 50) == 50)
        #expect(ranges.contiguousLength(from: 150) == 0)
        #expect(ranges.contains(0..<100))
        #expect(!ranges.contains(50..<150))
        #expect(ranges.firstMissing(before: 400) == 100)
        #expect(ranges.gapEnd(from: 100, before: 400) == 200)
        #expect(ranges.firstMissing(from: 200, before: 400) == 300)
        #expect(ranges.gapEnd(from: 300, before: 400) == 400)
        #expect(ranges.firstMissing(from: 0, before: 100) == nil)
    }
}

struct AudioStoreTests {
    func makeStore(limit: Int64 = 1_000_000) throws -> (AudioStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "audiostore-\(UUID().uuidString)")
        return (AudioStore(directory: directory, cacheLimit: limit), directory)
    }

    func stream(_ id: String, length: Int64) -> ResolvedStream {
        ResolvedStream(videoId: id, url: URL(string: "https://example.com/\(id)")!, userAgent: "test", itag: 140,
                       contentLength: length, duration: 200, loudnessDb: 1.5, expiresAt: nil)
    }

    @Test func fillsAFileOutOfOrderAndPlaysItWhole() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("a", length: 10), song: nil)
        try store.write(Data([5, 6, 7, 8, 9]), at: 5, for: "a")
        #expect(store.completeStream("a") == nil)
        #expect(store.firstGap("a") == 0..<5)
        #expect(store.read("a", at: 5, count: 5) == Data([5, 6, 7, 8, 9]))
        #expect(store.read("a", at: 3, count: 5) == nil, "bytes the file doesn't hold were read")

        try store.write(Data([0, 1, 2, 3, 4]), at: 0, for: "a")
        let file = try #require(store.completeStream("a"))
        #expect(file.url.isFileURL)
        #expect(file.duration == 200)
        #expect(file.loudnessDb == 1.5)
        #expect(try Data(contentsOf: file.url) == Data(0..<10))
    }

    @Test func remembersWhatItHoldsAcrossLaunches() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("a", length: 4), song: nil)
        try store.write(Data([1, 2, 3, 4]), at: 0, for: "a")
        store.flush()
        let reopened = AudioStore(directory: directory)
        #expect(reopened.completeStream("a") != nil)
    }

    @Test func aLateScheduledIndexCannotRestoreADownloadRemovedBeforeBackgroundFlush() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldWriteEntered = DispatchSemaphore(value: 0)
        let releaseOldWrite = DispatchSemaphore(value: 0)
        let holdFirstWriteOnly = DispatchSemaphore(value: 1)
        let oldWriteTimedOut = DispatchSemaphore(value: 0)
        let flushStarted = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        defer { releaseOldWrite.signal() }
        store.beforeScheduledIndexWrite = {
            guard holdFirstWriteOnly.wait(timeout: .now()) == .success else { return }
            oldWriteEntered.signal()
            if releaseOldWrite.wait(timeout: .now() + 15) == .timedOut {
                oldWriteTimedOut.signal()
            }
        }
        let track = Song(id: "playing-download", title: "Playing", artistLine: "Artist")
        let resolved = stream(track.id, length: 4)
        // Keep the complete race on GCD workers. Hopping back to a cooperative executor
        // while holding a writer makes this test depend on unrelated parallel test work.
        let evidence = try await onAudioStoreWorker {
            store.markDownloaded([track])
            store.prepare(resolved, song: track)
            try store.write(Data([1, 2, 3, 4]), at: 0, for: track.id)
            guard oldWriteEntered.wait(timeout: .now() + 5) == .success else {
                throw AudioStoreRaceFailure.oldWriterDidNotStart
            }

            // Removing a playing download preserves its bytes as cache. An old index
            // must not turn that same valid file back into a user download.
            store.beginUse(track.id)
            defer { store.endUse(track.id) }
            store.removeDownloads([track.id])
            var completed = false
            defer {
                releaseOldWrite.signal()
                if !completed { _ = flushFinished.wait(timeout: .now() + 5) }
            }
            DispatchQueue(label: "koda.tests.audiostore-flush", qos: .userInitiated).async {
                flushStarted.signal()
                store.flush()
                flushFinished.signal()
            }
            guard flushStarted.wait(timeout: .now() + 5) == .success else {
                throw AudioStoreRaceFailure.flushDidNotStart
            }
            let finishedBeforeOldWriter = flushFinished.wait(timeout: .now() + .milliseconds(200)) == .success
            releaseOldWrite.signal()
            completed = finishedBeforeOldWriter || flushFinished.wait(timeout: .now() + 5) == .success
            guard completed else { throw AudioStoreRaceFailure.flushDidNotFinish }
            return (finishedBeforeOldWriter: finishedBeforeOldWriter,
                    oldWriterTimedOut: oldWriteTimedOut.wait(timeout: .now()) == .success)
        }
        #expect(!evidence.finishedBeforeOldWriter, "flush must serialize after a snapshot already writing")
        #expect(!evidence.oldWriterTimedOut, "the stale writer must remain held until the test explicitly releases it")

        let reopened = AudioStore(directory: directory)
        #expect(reopened.entry(track.id)?.isDownload == false)
        #expect(reopened.readyOfflineSongs.isEmpty)
        #expect(reopened.completeStream(track.id) != nil)
        #expect(try Data(contentsOf: store.fileURL(track.id)) == Data([1, 2, 3, 4]))
    }

    @Test func offlineLibraryContainsOnlyExplicitCompleteDownloadsWithoutDeletingPlaybackCache() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = Song(id: "cached", title: "Cached", artistLine: "Artist")
        let downloaded = Song(id: "downloaded", title: "Downloaded", artistLine: "Artist")
        let partial = Song(id: "partial", title: "Partial", artistLine: "Artist")
        let waiting = Song(id: "waiting", title: "Waiting", artistLine: "Artist")
        store.markDownloaded([downloaded, partial, waiting])
        for song in [cached, downloaded, partial] {
            store.prepare(stream(song.id, length: 4), song: song)
            try store.write(Data(count: song.id == partial.id ? 2 : 4), at: 0, for: song.id)
        }
        #expect(store.readyOfflineSongs == [downloaded])
        #expect(Set(store.completeSongs.map(\.id)) == [cached.id, downloaded.id])
        #expect(store.completeStream(cached.id) != nil)
        #expect(store.entry(cached.id)?.isDownload == false)
        #expect(Set(store.downloads.map(\.videoId)) == [downloaded.id, partial.id, waiting.id])
    }

    @Test func removingADownloadInUseDoesNotLeaveItInTheOfflineLibrary() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = Song(id: "playing", title: "Playing", artistLine: "Artist")
        store.prepare(stream(song.id, length: 4), song: song)
        try store.write(Data(count: 4), at: 0, for: song.id)
        #expect(store.readyOfflineSongs.isEmpty)
        store.markDownloaded([song])
        #expect(store.readyOfflineSongs == [song])
        store.beginUse(song.id)
        store.removeDownloads([song.id])
        #expect(store.readyOfflineSongs.isEmpty)
        #expect(store.completeStream(song.id) != nil, "removing the download must not interrupt its current playback")
        #expect(store.completeSongs == [song])
        #expect(store.entry(song.id)?.isDownload == false)
        store.endUse(song.id)
    }

    @Test(arguments: [0, 2, 6])
    func offlineLibraryRevalidatesMissingOrReplacedFiles(replacementSize: Int) throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = Song(id: "local", title: "Local", artistLine: "Artist")
        store.markDownloaded([song])
        store.prepare(stream(song.id, length: 4), song: song)
        try store.write(Data(count: 4), at: 0, for: song.id)
        #expect(store.readyOfflineSongs == [song])
        if replacementSize == 0 { try FileManager.default.removeItem(at: store.fileURL(song.id)) }
        else { try Data(count: replacementSize).write(to: store.fileURL(song.id)) }
        #expect(store.readyOfflineSongs.isEmpty)
        #expect(store.entry(song.id)?.isDownload == true)
        #expect(store.entry(song.id)?.isComplete == false)
    }

    @Test func reopeningLegacyCacheNeverPromotesItToAnOfflineDownload() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = Song(id: "legacy-cache", title: "Cached", artistLine: "Artist")
        let downloaded = Song(id: "downloaded", title: "Downloaded", artistLine: "Artist")
        store.markDownloaded([downloaded])
        for song in [cached, downloaded] {
            store.prepare(stream(song.id, length: 4), song: song)
            try store.write(Data(count: 4), at: 0, for: song.id)
        }
        store.flush()
        let index = directory.appending(path: "index.json")
        var entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        let old = try #require(entries.firstIndex { $0["videoId"] as? String == cached.id })
        entries[old].removeValue(forKey: "isDownload")
        try JSONSerialization.data(withJSONObject: entries).write(to: index)
        let reopened = AudioStore(directory: directory)
        #expect(reopened.readyOfflineSongs == [downloaded])
        #expect(Set(reopened.completeSongs.map(\.id)) == [cached.id, downloaded.id])
        #expect(reopened.entry(cached.id)?.isDownload == false)
    }

    @Test func evictsTheLeastRecentlyPlayedButNeverADownload() throws {
        let (store, directory) = try makeStore(limit: 10)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Song(id: "kept", title: "Kept", artistLine: "Artist")
        store.markDownloaded([kept])
        store.prepare(stream("kept", length: 8), song: kept)
        try store.write(Data(count: 8), at: 0, for: "kept")
        for id in ["old", "new"] {
            store.prepare(stream(id, length: 6), song: nil)
            try store.write(Data(count: 6), at: 0, for: id)
        }
        // 12 bytes of cache over a limit of 10: the older song goes; the download doesn't count.
        #expect(store.entry("old") == nil)
        #expect(store.entry("new")?.isComplete == true)
        #expect(store.entry("kept")?.isComplete == true)
        #expect(store.downloads.map(\.videoId) == ["kept"])
    }

    @Test func aSongInUseIsNotEvicted() throws {
        let (store, directory) = try makeStore(limit: 5)
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("playing", length: 6), song: nil)
        store.beginUse("playing")
        try store.write(Data(count: 6), at: 0, for: "playing")
        #expect(store.entry("playing")?.isComplete == true)
        store.endUse("playing")
        #expect(store.entry("playing") == nil)
    }

    @Test func aDifferentFormatStartsTheFileAgain() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("a", length: 4), song: nil)
        try store.write(Data(count: 4), at: 0, for: "a")
        store.prepare(stream("a", length: 6), song: nil)
        #expect(store.entry("a")?.bytes == 0)
        #expect(store.completeStream("a") == nil)
    }

    @Test func missingAndTruncatedFilesCannotRemainCompleteDownloads() throws {
        for replacementSize in [0, 2, 6] {
            let (store, directory) = try makeStore()
            defer { try? FileManager.default.removeItem(at: directory) }
            let song = Song(id: "local", title: "Local", artistLine: "Artist")
            store.markDownloaded([song])
            store.prepare(stream(song.id, length: 4), song: song)
            try store.write(Data([1, 2, 3, 4]), at: 0, for: song.id)
            #expect(store.completeStream(song.id) != nil)
            if replacementSize == 0 { try FileManager.default.removeItem(at: store.fileURL(song.id)) }
            else { try Data(count: replacementSize).write(to: store.fileURL(song.id)) }
            #expect(store.completeStream(song.id) == nil)
            #expect(store.entry(song.id)?.isComplete == false)
            #expect(store.entry(song.id)?.bytes == 0)
            #expect(store.downloads.first?.isDownload == true)
            store.flush()
            let reopened = AudioStore(directory: directory)
            #expect(reopened.completeStream(song.id) == nil)
            #expect(reopened.downloads.first?.isDownload == true)
        }
    }

    @Test func confirmedLocalCorruptionDropsOnlyThoseBytesAndPreservesDownloadIntent() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let song = Song(id: "broken", title: "Broken", artistLine: "Artist")
        store.markDownloaded([song])
        store.prepare(stream(song.id, length: 4), song: song)
        try store.write(Data([1, 2, 3, 4]), at: 0, for: song.id)
        let broken = try #require(store.completeStream(song.id))
        let invalidMedia = NSError(domain: "AVFoundationErrorDomain", code: -11829)
        #expect(store.discardInvalidLocalStream(broken, error: invalidMedia))
        #expect(store.completeStream(song.id) == nil)
        #expect(store.entry(song.id)?.isDownload == true)
        #expect(store.entry(song.id)?.song == song)
        #expect(store.firstGap(song.id) == 0..<4)

        store.prepare(stream(song.id, length: 4), song: song)
        try store.write(Data([5, 6, 7, 8]), at: 0, for: song.id)
        let repaired = try #require(store.completeStream(song.id))
        #expect(repaired.localFileVersion != broken.localFileVersion)
        #expect(!store.discardInvalidLocalStream(broken, error: invalidMedia), "an old item's late failure cannot erase new bytes")
        #expect(try Data(contentsOf: repaired.url) == Data([5, 6, 7, 8]))
        #expect(store.entry(song.id)?.isComplete == true)
    }

    @Test func remoteAuthenticationAndAudioSessionFailuresNeverDiscardValidLocalAudio() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("valid", length: 4), song: nil)
        try store.write(Data([1, 2, 3, 4]), at: 0, for: "valid")
        let local = try #require(store.completeStream("valid"))
        let errors: [Error] = [
            URLError(.timedOut), URLError(.networkConnectionLost), MusicError.signedOut,
            MusicError.badResponse(403), AudioStreamResponseError.httpStatus(404),
            NSError(domain: "AVFoundationErrorDomain", code: -11819),
            NSError(domain: "AVFoundationErrorDomain", code: -11839),
            NSError(domain: "AVFoundationErrorDomain", code: -11835),
            NSError(domain: "AVFoundationErrorDomain", code: -11831),
            NSError(domain: "AVFoundationErrorDomain", code: -11831,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: "AVFoundationErrorDomain", code: -11821)]),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: "AVFoundationErrorDomain", code: -11821,
                    userInfo: [NSUnderlyingErrorKey: AudioStreamResponseError.httpStatus(403) as NSError]),
            NSError(domain: "AVFoundationErrorDomain", code: -11821,
                    userInfo: [NSUnderlyingErrorKey: URLError(.timedOut) as NSError])
        ]
        for error in errors { #expect(!store.discardInvalidLocalStream(local, error: error)) }
        #expect(!store.discardInvalidLocalStream(local, error: nil))
        var remote = local
        remote.url = URL(string: "https://example.invalid/audio")!
        #expect(!store.discardInvalidLocalStream(remote, error: NSError(domain: "AVFoundationErrorDomain", code: -11829)))
        #expect(try Data(contentsOf: local.url) == Data([1, 2, 3, 4]))
        #expect(store.completeStream("valid") != nil)
    }

    @Test func launchValidationDoesNotTrustAnOldCompleteIndexForATruncatedFile() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        store.prepare(stream("old", length: 8), song: nil)
        try store.write(Data(count: 8), at: 0, for: "old")
        store.flush()
        try Data(count: 3).write(to: store.fileURL("old"))
        let reopened = AudioStore(directory: directory)
        #expect(reopened.completeStream("old") == nil)
        #expect(reopened.entry("old")?.bytes == 0)
    }
}
