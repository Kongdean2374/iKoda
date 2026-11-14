import Foundation
import Testing
@testable import KodaCore

@MainActor
struct AutomaticLyricTranslationPipelineTests {
    private typealias Pipeline = AutomaticLyricTranslationPipeline
    private typealias Input = Pipeline.Input
    private typealias Row = ChineseLyricTranslationPlan.Row

    private func input(_ id: String, count: Int = 3) -> Input {
        Input(songID: id, rows: (0..<count).map { Row(id: $0, text: "A complete sentence number \($0) for \(id)") })
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "koda-translation-pipeline-" + UUID().uuidString)
    }

    private func pipeline(directory: URL, engine: ControlledLyricsEngine, maximumUpcoming: Int = 5) -> Pipeline {
        Pipeline(cache: AutomaticLyricTranslationCache(directory: directory), maximumUpcoming: maximumUpcoming,
                 detectLanguage: { _ in "en" }) { fragments, publish in
            try await engine.run(fragments, publish: publish)
        }
    }

    private enum WaitError: Error { case timedOut }
    private func eventually(_ condition: @MainActor () async -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < limit else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func closingAndReopeningTranslationDoesNotRestartOrDiscardTheSameSong() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("current")
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        let fragments = await engine.fragments(at: 0)
        await engine.publish(0, values: [fragments[0].id: "第一句"])
        service.setRequests(current: song, upcoming: [], enabled: false, isForeground: true)
        #expect(service.snapshot(for: song).lines[0] == "第一句")
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        #expect(await engine.count == 1)
        #expect(service.snapshot(for: song).lines[0] == "第一句")
        await engine.publish(0, values: Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, "完整譯文 \($0.id)") }))
        await engine.finish(0)
        try await eventually { service.snapshot(for: song).phase == .ready }
        let ready = service.snapshot(for: song)
        service.setRequests(current: song, upcoming: [], enabled: false, isForeground: true)
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        #expect(service.snapshot(for: song) == ready)
        #expect(await engine.count == 1)
        await service.flush()
    }

    @Test func aWholeSongIsSubmittedTogetherAndASecondPipelineUsesItsPersistedResult() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("long", count: 73)
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        let fragments = await engine.fragments(at: 0)
        #expect(fragments.count == 73)
        await engine.publish(0, values: Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, "譯文 \($0.id)") }))
        await engine.finish(0)
        try await eventually { service.snapshot(for: song).phase == .ready }
        await service.flush()
        let secondEngine = ControlledLyricsEngine()
        let restored = pipeline(directory: folder, engine: secondEngine)
        defer { restored.suspend(); Task { await secondEngine.finishAll() } }
        restored.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await eventually { restored.snapshot(for: song).phase == .ready }
        #expect(await secondEngine.count == 0)
        #expect(restored.snapshot(for: song).lines == service.snapshot(for: song).lines)
        #expect(restored.snapshot(for: song).completed == 73)
        await restored.flush()
    }

    @Test func backgroundExpirationRetainsProgressAndResumesOnlyMissingFragments() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("resume")
        service.setRequests(current: song, upcoming: [input("later")], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        let original = await engine.fragments(at: 0)
        await engine.publish(0, values: [original[0].id: "已完成"])
        service.setRequests(current: song, upcoming: [input("later")], enabled: true, isForeground: false)
        #expect(service.isWorking) // Existing bounded current work can finish in the background.
        service.suspend()
        await service.flush()
        #expect(service.snapshot(for: song).phase == .paused)
        #expect(service.snapshot(for: song).lines[0] == "已完成")
        await engine.publish(0, values: [original[1].id: "取消後晚到的結果"])
        #expect(service.snapshot(for: song).lines[1] == nil)
        await engine.finish(0)
        try await eventually { !service.isWorking }
        #expect(await engine.count == 1)
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await eventually { await engine.count == 2 }
        let missing = await engine.fragments(at: 1)
        #expect(missing.map(\.id) == Array(original.dropFirst()).map(\.id))
        await engine.publish(1, values: Dictionary(uniqueKeysWithValues: missing.map { ($0.id, "補齊") }))
        await engine.finish(1)
        try await eventually { service.snapshot(for: song).phase == .ready }
        #expect(service.snapshot(for: song).lines[0] == "已完成")
        await service.flush()
    }

    @Test func currentSongPreemptsSpeculationButWaitsForTheOldEngineToExit() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let first = input("first", count: 1), second = input("second", count: 1), chosen = input("chosen", count: 1)
        service.setRequests(current: first, upcoming: [second], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        let firstID = try #require(await engine.fragments(at: 0).first?.id)
        await engine.publish(0, values: [firstID: "第一首"])
        await engine.finish(0)
        try await eventually { await engine.count == 2 }
        #expect(service.activeSongID == "second")
        service.setRequests(current: chosen, upcoming: [second], enabled: true, isForeground: true)
        // A cancellation request cannot create two simultaneous translators.
        #expect(await engine.count == 2)
        await engine.publish(1, values: [firstID: "過期結果"])
        #expect(service.snapshot(for: chosen).lines.isEmpty)
        #expect(service.snapshot(for: second).lines.isEmpty)
        await engine.finish(1)
        try await eventually { await engine.count == 3 }
        #expect(service.activeSongID == "chosen")
        #expect(await engine.fragments(at: 2).first?.text.contains("chosen") == true)
        service.setRequests(current: chosen, upcoming: [], enabled: false, isForeground: true)
        await engine.finish(2, outcome: .unavailable)
        try await eventually { !service.isWorking }
        await service.flush()
    }

    @Test func anAlreadyRunningPrefetchIsAdoptedWhenItBecomesCurrent() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let first = input("first", count: 1), second = input("second", count: 1)
        service.setRequests(current: first, upcoming: [second], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        await engine.publish(0, values: ["0:0": "第一首"])
        await engine.finish(0)
        try await eventually { await engine.count == 2 }
        await engine.publish(1, values: ["0:0": "已預先翻譯"])
        service.setRequests(current: second, upcoming: [], enabled: true, isForeground: true)
        #expect(service.snapshot(for: second).lines[0] == "已預先翻譯")
        #expect(service.activeSongID == "second")
        #expect(await engine.count == 2)
        await engine.finish(1)
        try await eventually { service.snapshot(for: second).phase == .ready }
        #expect(await engine.count == 2)
        await service.flush()
    }

    @Test func prefetchIsBoundedAndDoesNotStartWhenTheAppIsInactive() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine, maximumUpcoming: 2)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("current", count: 1)
        let next = (0..<8).map { input("future-\($0)", count: 1) }
        service.setRequests(current: current, upcoming: next, enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        service.setRequests(current: current, upcoming: next, enabled: true, isForeground: false)
        await engine.publish(0, values: ["0:0": "現在"])
        await engine.finish(0)
        try await eventually { !service.isWorking }
        #expect(await engine.count == 1)
        service.setRequests(current: current, upcoming: next, enabled: true, isForeground: true)
        for index in 1...2 {
            try await eventually { await engine.count == index + 1 }
            await engine.publish(index, values: ["0:0": "預先翻譯 \(index)"])
            await engine.finish(index)
        }
        try await eventually { !service.isWorking }
        #expect(await engine.count == 3)
        #expect(service.snapshot(for: next[2]).phase == .idle)
        await service.flush()
    }

    @Test func changedSourceRowsNeverShowOldResultsAndRetryKeepsCompletedFragments() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let old = input("same-song", count: 2)
        let replacement = Input(songID: old.songID, rows: [Row(id: 0, text: "A different provider sentence")])
        service.setRequests(current: old, upcoming: [], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        await engine.publish(0, values: ["0:0": "第一行已完成"])
        await engine.finish(0, outcome: .needsLanguage(.init(source: "en", target: "zh-Hant")))
        try await eventually { service.snapshot(for: old).phase == .needsLanguage }
        service.retry(songID: old.songID)
        try await eventually { await engine.count == 2 }
        #expect(await engine.fragments(at: 1).map(\.id) == ["1:0"])
        service.setRequests(current: replacement, upcoming: [], enabled: true, isForeground: true)
        #expect(service.snapshot(for: replacement).lines.isEmpty)
        #expect(service.snapshot(for: old).lines.isEmpty)
        await engine.publish(1, values: ["1:0": "過期譯文"])
        await engine.finish(1)
        try await eventually { await engine.count == 3 }
        #expect(await engine.fragments(at: 2).count == 1)
        await engine.publish(2, values: ["0:0": "新來源譯文"])
        await engine.finish(2)
        try await eventually { service.snapshot(for: replacement).phase == .ready }
        #expect(service.snapshot(for: replacement).lines == [0: "新來源譯文"])
        await service.flush()
    }

    @Test func newlyInstalledCurrentLanguageTakesPriorityOverAnActivePrefetch() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("current", count: 2), next = input("next", count: 1)
        service.setRequests(current: current, upcoming: [next], enabled: true, isForeground: true)
        try await eventually { await engine.count == 1 }
        await engine.publish(0, values: ["0:0": "已完成"])
        await engine.finish(0, outcome: .needsLanguage(.init(source: "en", target: "zh-Hant")))
        try await eventually { await engine.count == 2 }
        #expect(service.activeSongID == "next")
        service.retry(songID: current.songID)
        #expect(service.snapshot(for: next).phase == .paused)
        #expect(await engine.count == 2)
        await engine.finish(1)
        try await eventually { await engine.count == 3 }
        #expect(service.activeSongID == "current")
        #expect(await engine.fragments(at: 2).map(\.id) == ["1:0"])
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        await engine.publish(2, values: ["1:0": "剛安裝的語言"])
        await engine.finish(2)
        try await eventually { service.snapshot(for: current).phase == .ready }
        #expect(service.snapshot(for: current).lines == [0: "已完成", 1: "剛安裝的語言"])
        await service.flush()
    }
}

/// Cancellation deliberately does not resume the continuation. Tests can deliver late
/// callbacks and acknowledge shutdown independently, exercising the generation boundary.
private actor ControlledLyricsEngine {
    typealias Pipeline = AutomaticLyricTranslationPipeline
    struct Call: Sendable {
        let fragments: [ChineseLyricTranslationPlan.Fragment]
        let publish: Pipeline.Publish
    }
    private var calls: [Call] = []
    private var completions: [Int: CheckedContinuation<Pipeline.Outcome, Error>] = [:]
    var count: Int { calls.count }

    func run(_ fragments: [ChineseLyricTranslationPlan.Fragment], publish: @escaping Pipeline.Publish) async throws -> Pipeline.Outcome {
        let index = calls.count
        calls.append(Call(fragments: fragments, publish: publish))
        return try await withCheckedThrowingContinuation { completions[index] = $0 }
    }
    func fragments(at index: Int) -> [ChineseLyricTranslationPlan.Fragment] { calls[index].fragments }
    func publish(_ index: Int, values: [String: String]) async { await calls[index].publish(values) }
    func finish(_ index: Int, outcome: Pipeline.Outcome = .complete) { completions.removeValue(forKey: index)?.resume(returning: outcome) }
    func finishAll() {
        let waiting = completions.values
        completions.removeAll()
        for continuation in waiting { continuation.resume(throwing: CancellationError()) }
    }
}
