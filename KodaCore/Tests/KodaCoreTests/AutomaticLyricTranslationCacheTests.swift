import Foundation
import Testing
@testable import KodaCore

struct AutomaticLyricTranslationCacheTests {
    typealias Cache = AutomaticLyricTranslationCache

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "koda-automatic-lyrics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func key(_ song: String = "song", text: String = "A source sentence") -> Cache.Key {
        Cache.Key(songID: song, rows: [.init(id: 0, text: text)])
    }

    private func file(_ directory: URL, _ key: Cache.Key) -> URL {
        directory.appending(path: key.fingerprint + ".json")
    }

    @Test func completedSongSurvivesRecreatingTheCacheWithoutChangingTranslationFormatting() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let cache = Cache(directory: directory)
        let entry = Cache.Entry(fragments: ["0:0": "  一句譯文\n第二行  ", "1:0": "另一句"],
                                isComplete: true, savedAt: Date(timeIntervalSince1970: 123))
        await cache.store(entry, for: key)
        let memory = await cache.entry(for: key)
        #expect(memory == entry)
        let reopened = Cache(directory: directory)
        let restored = await reopened.entry(for: key)
        #expect(restored == entry)
    }

    @Test func aMemoryHitDoesNotReadTheFileAgainWhenTheLyricsViewReopens() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let cache = Cache(directory: directory)
        await cache.store(.init(fragments: ["0:0": "立即顯示"], isComplete: true), for: key)
        try Data("corrupt disk contents".utf8).write(to: file(directory, key))
        let memory = await cache.entry(for: key)
        #expect(memory?.fragments == ["0:0": "立即顯示"])
        let reopened = Cache(directory: directory)
        let disk = await reopened.entry(for: key)
        #expect(disk == nil)
    }

    @Test func keyIncludesEverySourceRowItsOrderIdentityTargetAndSong() throws {
        let rows = [ChineseLyricTranslationPlan.Row(id: 1, text: "First\nline"), .init(id: 5, text: "Second")]
        let original = Cache.Key(songID: "a", rows: rows)
        #expect(original == Cache.Key(songID: "a", rows: rows))
        let alternatives = [
            Cache.Key(songID: "b", rows: rows),
            Cache.Key(songID: "a", rows: rows, target: "ja"),
            Cache.Key(songID: "a", rows: Array(rows.reversed())),
            Cache.Key(songID: "a", rows: [.init(id: 2, text: rows[0].text), rows[1]]),
            Cache.Key(songID: "a", rows: [rows[0], .init(id: 5, text: "Second revised")]),
            Cache.Key(songID: "a", rows: [rows[0]])
        ]
        #expect(!alternatives.contains(original))
        #expect(Set(alternatives.map(\.fingerprint)).count == alternatives.count)
        #expect(original.fingerprint.count == 64)
        let decoded = try JSONDecoder().decode(Cache.Key.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test func changedProviderTextCannotReuseTheOldSongTranslation() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Cache(directory: directory)
        await cache.store(.init(fragments: ["0:0": "舊譯文"], isComplete: true), for: key())
        let changedText = await cache.entry(for: key(text: "A different provider sentence"))
        let changedTarget = await cache.entry(for: Cache.Key(songID: "song", rows: [.init(id: 0, text: "A source sentence")], target: "ko"))
        #expect(changedText == nil)
        #expect(changedTarget == nil)
    }

    @Test func partialCheckpointsMergeAndOlderResponsesCannotReplaceNewerFragments() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let cache = Cache(directory: directory)
        await cache.store(.init(fragments: ["0:0": "新譯文"], savedAt: Date(timeIntervalSince1970: 20)), for: key)
        await cache.store(.init(fragments: ["0:0": "舊譯文", "1:0": "另一行"], savedAt: Date(timeIntervalSince1970: 10)), for: key)
        let merged = await cache.entry(for: key)
        #expect(merged?.fragments == ["0:0": "新譯文", "1:0": "另一行"])
        #expect(merged?.isComplete == false)
        let reopened = Cache(directory: directory)
        let checkpoint = await reopened.entry(for: key)
        #expect(checkpoint == merged)
    }

    @Test func aLatePartialCheckpointCannotDowngradeOrReplaceACompletedSong() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let cache = Cache(directory: directory)
        let complete = Cache.Entry(fragments: ["0:0": "第一行", "1:0": "第二行"], isComplete: true,
                                   savedAt: Date(timeIntervalSince1970: 10))
        await cache.store(complete, for: key)
        await cache.store(.init(fragments: ["0:0": "遲到的舊結果"], savedAt: Date(timeIntervalSince1970: 30)), for: key)
        let restored = await cache.entry(for: key)
        #expect(restored == complete)
    }

    @Test func concurrentPartialSavesKeepEveryIndependentFragment() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let cache = Cache(directory: directory)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask { await cache.store(.init(fragments: ["\(index):0": "譯文 \(index)"]), for: key) }
            }
        }
        let result = await cache.entry(for: key)
        #expect(result?.fragments.count == 30)
        #expect(result?.isComplete == false)
        let reopened = Cache(directory: directory)
        let disk = await reopened.entry(for: key)
        #expect(disk == result)
    }

    @Test func entryLimitEvictsTheLeastRecentlyUsedSongFromMemoryAndDisk() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Cache(directory: directory, maximumEntries: 2)
        let first = key("first"), second = key("second"), third = key("third")
        await cache.store(.init(fragments: ["0:0": "一"]), for: first)
        await cache.store(.init(fragments: ["0:0": "二"]), for: second)
        _ = await cache.entry(for: first)
        await cache.store(.init(fragments: ["0:0": "三"]), for: third)
        let evicted = await cache.entry(for: second)
        #expect(evicted == nil)
        #expect(!FileManager.default.fileExists(atPath: file(directory, second).path))
        let reopened = Cache(directory: directory, maximumEntries: 2)
        let keptFirst = await reopened.entry(for: first)
        let keptThird = await reopened.entry(for: third)
        #expect(keptFirst?.fragments == ["0:0": "一"])
        #expect(keptThird?.fragments == ["0:0": "三"])
    }

    @Test func byteBudgetBoundsTheDiskCacheAndOversizedRecordsDoNotEvictGoodTranslations() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Cache(directory: directory, maximumBytes: 1_000)
        let first = key("first"), second = key("second"), huge = key("huge")
        await cache.store(.init(fragments: ["0:0": String(repeating: "a", count: 400)]), for: first)
        await cache.store(.init(fragments: ["0:0": String(repeating: "b", count: 400)]), for: second)
        let evicted = await cache.entry(for: first)
        #expect(evicted == nil)
        await cache.store(.init(fragments: ["0:0": String(repeating: "x", count: 4_000)]), for: huge)
        let preserved = await cache.entry(for: second)
        let oversized = await cache.entry(for: huge)
        #expect(preserved?.fragments["0:0"] == String(repeating: "b", count: 400))
        #expect(oversized == nil)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { total, file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            return total + (values.fileSize ?? 0)
        }
        #expect(total <= 1_000)
        #expect(files.count == 1)
    }

    @Test func corruptIncompatibleAndMismatchedRecordsAreDiscardedSafely() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = key()
        let cache = Cache(directory: directory)
        await cache.store(.init(fragments: ["0:0": "譯文"], isComplete: true), for: key)
        let valid = try Data(contentsOf: file(directory, key))
        var wrongVersion = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        wrongVersion["version"] = 99
        var wrongKey = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var nestedKey = try #require(wrongKey["key"] as? [String: Any])
        nestedKey["target"] = "ja"
        wrongKey["key"] = nestedKey
        var oldEngine = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var engineKey = try #require(oldEngine["key"] as? [String: Any])
        engineKey["engineVersion"] = 999
        oldEngine["key"] = engineKey
        let corruptions = [Data("not JSON".utf8), try JSONSerialization.data(withJSONObject: wrongVersion),
                           try JSONSerialization.data(withJSONObject: wrongKey), try JSONSerialization.data(withJSONObject: oldEngine)]
        for data in corruptions {
            try data.write(to: file(directory, key))
            let reopened = Cache(directory: directory)
            let result = await reopened.entry(for: key)
            #expect(result == nil)
            #expect(!FileManager.default.fileExists(atPath: file(directory, key).path))
        }
    }

    @Test func blankFragmentsDoNotMasqueradeAsCompletedTranslations() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Cache(directory: directory)
        await cache.store(.init(fragments: ["0:0": " \n ", "1:0": " 有效譯文 "], isComplete: true), for: key())
        let result = await cache.entry(for: key())
        #expect(result?.fragments == ["1:0": " 有效譯文 "])
        #expect(result?.isComplete == false)
        await cache.store(.init(fragments: [:], isComplete: true), for: key("already-Chinese"))
        let noForeignText = await cache.entry(for: key("already-Chinese"))
        #expect(noForeignText?.isComplete == true)
    }

    @Test func clearRemovesBothMemoryAndPersistentResults() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Cache(directory: directory)
        await cache.store(.init(fragments: ["0:0": "譯文"]), for: key())
        await cache.clear()
        let memory = await cache.entry(for: key())
        let reopened = Cache(directory: directory)
        let disk = await reopened.entry(for: key())
        #expect(memory == nil)
        #expect(disk == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func disabledCacheDoesNotStoreResults() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = Cache(directory: directory, maximumEntries: 0, maximumBytes: 0)
        await cache.store(.init(fragments: ["0:0": "譯文"]), for: key())
        let result = await cache.entry(for: key())
        #expect(result == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
