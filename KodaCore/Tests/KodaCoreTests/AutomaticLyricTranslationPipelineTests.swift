import Foundation
import Observation
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

    /// Observe the state transition itself rather than timing scheduler progress. The
    /// suite shares MainActor with hundreds of playback tests, so a wall-clock 3-second
    /// polling deadline can expire before this test receives any executor time.
    private func eventually(_ condition: @escaping @MainActor () -> Bool,
                            sourceLocation: SourceLocation = #_sourceLocation) async throws {
        while !condition() {
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            withObservationTracking { _ = condition() } onChange: {
                continuation.yield(())
                continuation.finish()
            }
            for await _ in stream { break }
            if Task.isCancelled {
                Issue.record("Cancelled while waiting for the observed translation state.", sourceLocation: sourceLocation)
                throw CancellationError()
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func closingAndReopeningTranslationDoesNotRestartOrDiscardTheSameSong() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("current")
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
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

    @Test(.timeLimit(.minutes(1))) func aWholeSongIsSubmittedTogetherAndASecondPipelineUsesItsPersistedResult() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("long", count: 73)
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
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

    @Test(.timeLimit(.minutes(1))) func completedTranslationActuallyRunsAgainAndKeepsReadableText() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("regenerate", count: 1)
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        let initial = await engine.fragments(at: 0)
        let fragment = try #require(initial.first?.id)
        await engine.publish(0, values: [fragment: "舊譯文"])
        await engine.finish(0)
        try await eventually { service.snapshot(for: song).phase == .ready }
        await service.regenerate(song, discardDisk: false)
        try await engine.waitForCalls(2)
        #expect(await engine.fragments(at: 1).map(\.id) == [fragment])
        #expect(service.snapshot(for: song).lines[0] == "舊譯文")
        await engine.publish(0, values: [fragment: "舊工作回傳"])
        #expect(service.snapshot(for: song).lines[0] == "舊譯文")
        await engine.publish(1, values: [fragment: "新譯文"])
        await engine.finish(1)
        try await eventually { service.snapshot(for: song).phase == .ready }
        #expect(service.snapshot(for: song).lines[0] == "新譯文")
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func rapidVersionChangesRejectLateWorkDespiteIdenticalText() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let rows = input("same-track", count: 1).rows
        let a = Input(songID: "same-track", rows: rows, namespace: "provider-a", mode: .quick)
        let b = Input(songID: "same-track", rows: rows, namespace: "provider-b", mode: .quality)
        let c = Input(songID: "same-track", rows: rows, namespace: "provider-c", mode: .immersive)
        service.setRequests(current: a, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        let started = await engine.fragments(at: 0)
        let fragment = try #require(started.first?.id)
        service.setRequests(current: b, upcoming: [], enabled: true, isForeground: true)
        service.setRequests(current: c, upcoming: [], enabled: true, isForeground: true)
        await engine.publish(0, values: [fragment: "過期來源"])
        #expect(service.snapshot(for: c).lines.isEmpty)
        await engine.finish(0)
        try await engine.waitForCalls(2)
        await engine.publish(1, values: [fragment: "最新來源"])
        await engine.finish(1)
        try await eventually { service.snapshot(for: c).phase == .ready }
        #expect(service.snapshot(for: c).lines[0] == "最新來源")
        #expect(service.snapshot(for: a).lines.isEmpty)
        #expect(service.snapshot(for: b).lines.isEmpty)
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func diagnosticsReportActualRouteAndMarkSubsequentCacheReads() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = AutomaticLyricTranslationCache(directory: folder)
        let song = Input(songID: "observed", rows: [.init(id: 0, text: "The door opens")], namespace: "test")
        let service = Pipeline(cache: cache, detectLanguage: { _ in "en" }, observedEngine: { _, fragments, publish, report in
            var details = AppleLyricDiagnostics()
            details.strategies = [.lowLatency]
            details.languages = [.init(source: "en", target: "zh-Hant", support: .available)]
            details.usedCompatibility = true
            await report(details)
            await publish(Dictionary(uniqueKeysWithValues: fragments.map { ($0.id, "門打開了") }))
            return .compatible
        })
        service.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await eventually { service.snapshot(for: song).phase == .ready }
        let initial = service.snapshot(for: song)
        #expect(initial.cacheUse == .miss)
        #expect(initial.apple.strategies == [.lowLatency])
        #expect(initial.apple.usedCompatibility == true)
        #expect(initial.sourceRows == 1 && initial.completedRows == 1)
        #expect(initial.translationSeconds != nil)
        await service.flush()

        let restored = Pipeline(cache: cache, detectLanguage: { _ in "en" }, observedEngine: { _, _, _, _ in
            Issue.record("The complete cache should prevent a translation request")
            return .unavailable
        })
        restored.setRequests(current: song, upcoming: [], enabled: true, isForeground: true)
        try await eventually { restored.snapshot(for: song).phase == .ready }
        let cached = restored.snapshot(for: song)
        #expect(cached.cacheUse == .hit)
        #expect(cached.translationSeconds == nil)
        #expect(cached.apple.strategies == initial.apple.strategies)
        await restored.flush()
    }

    @Test(.timeLimit(.minutes(1))) func backgroundExpirationRetainsProgressAndResumesOnlyMissingFragments() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let song = input("resume")
        service.setRequests(current: song, upcoming: [input("later")], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
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
        try await engine.waitForCalls(2)
        let missing = await engine.fragments(at: 1)
        #expect(missing.map(\.id) == Array(original.dropFirst()).map(\.id))
        await engine.publish(1, values: Dictionary(uniqueKeysWithValues: missing.map { ($0.id, "補齊") }))
        await engine.finish(1)
        try await eventually { service.snapshot(for: song).phase == .ready }
        #expect(service.snapshot(for: song).lines[0] == "已完成")
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func currentSongPreemptsSpeculationButWaitsForTheOldEngineToExit() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let first = input("first", count: 1), second = input("second", count: 1), chosen = input("chosen", count: 1)
        service.setRequests(current: first, upcoming: [second], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        let firstID = try #require(await engine.fragments(at: 0).first?.id)
        await engine.publish(0, values: [firstID: "第一首"])
        await engine.finish(0)
        try await engine.waitForCalls(2)
        #expect(service.activeSongID == "second")
        service.setRequests(current: chosen, upcoming: [second], enabled: true, isForeground: true)
        // A cancellation request cannot create two simultaneous translators.
        #expect(await engine.count == 2)
        await engine.publish(1, values: [firstID: "過期結果"])
        #expect(service.snapshot(for: chosen).lines.isEmpty)
        #expect(service.snapshot(for: second).lines.isEmpty)
        await engine.finish(1)
        try await engine.waitForCalls(3)
        #expect(service.activeSongID == "chosen")
        #expect(await engine.fragments(at: 2).first?.text.contains("chosen") == true)
        service.setRequests(current: chosen, upcoming: [], enabled: false, isForeground: true)
        await engine.finish(2, outcome: .unavailable)
        try await eventually { !service.isWorking }
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func anAlreadyRunningPrefetchIsAdoptedWhenItBecomesCurrent() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let first = input("first", count: 1), second = input("second", count: 1)
        service.setRequests(current: first, upcoming: [second], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        await engine.publish(0, values: ["0:0": "第一首"])
        await engine.finish(0)
        try await engine.waitForCalls(2)
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

    @Test(.timeLimit(.minutes(1))) func prefetchIsBoundedAndDoesNotStartWhenTheAppIsInactive() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine, maximumUpcoming: 2)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("current", count: 1)
        let next = (0..<8).map { input("future-\($0)", count: 1) }
        service.setRequests(current: current, upcoming: next, enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        service.setRequests(current: current, upcoming: next, enabled: true, isForeground: false)
        await engine.publish(0, values: ["0:0": "現在"])
        await engine.finish(0)
        try await eventually { !service.isWorking }
        #expect(await engine.count == 1)
        service.setRequests(current: current, upcoming: next, enabled: true, isForeground: true)
        for index in 1...2 {
            try await engine.waitForCalls(index + 1)
            await engine.publish(index, values: ["0:0": "預先翻譯 \(index)"])
            await engine.finish(index)
        }
        try await eventually { !service.isWorking }
        #expect(await engine.count == 3)
        #expect(service.snapshot(for: next[2]).phase == .idle)
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func changedSourceRowsNeverShowOldResultsAndRetryKeepsCompletedFragments() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let old = input("same-song", count: 2)
        let replacement = Input(songID: old.songID, rows: [Row(id: 0, text: "A different provider sentence")])
        service.setRequests(current: old, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        await engine.publish(0, values: ["0:0": "第一行已完成"])
        await engine.finish(0, outcome: .needsLanguage(.init(source: "en", target: "zh-Hant")))
        try await eventually { service.snapshot(for: old).phase == .needsLanguage }
        service.retry(songID: old.songID)
        try await engine.waitForCalls(2)
        #expect(await engine.fragments(at: 1).map(\.id) == ["1:0"])
        service.setRequests(current: replacement, upcoming: [], enabled: true, isForeground: true)
        #expect(service.snapshot(for: replacement).lines.isEmpty)
        #expect(service.snapshot(for: old).lines.isEmpty)
        await engine.publish(1, values: ["1:0": "過期譯文"])
        await engine.finish(1)
        try await engine.waitForCalls(3)
        #expect(await engine.fragments(at: 2).count == 1)
        await engine.publish(2, values: ["0:0": "新來源譯文"])
        await engine.finish(2)
        try await eventually { service.snapshot(for: replacement).phase == .ready }
        #expect(service.snapshot(for: replacement).lines == [0: "新來源譯文"])
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func newlyInstalledCurrentLanguageTakesPriorityOverAnActivePrefetch() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("current", count: 2), next = input("next", count: 1)
        service.setRequests(current: current, upcoming: [next], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        await engine.publish(0, values: ["0:0": "已完成"])
        await engine.finish(0, outcome: .needsLanguage(.init(source: "en", target: "zh-Hant")))
        try await engine.waitForCalls(2)
        #expect(service.activeSongID == "next")
        service.retry(songID: current.songID)
        #expect(service.snapshot(for: next).phase == .paused)
        #expect(await engine.count == 2)
        await engine.finish(1)
        try await engine.waitForCalls(3)
        #expect(service.activeSongID == "current")
        #expect(await engine.fragments(at: 2).map(\.id) == ["1:0"])
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        await engine.publish(2, values: ["1:0": "剛安裝的語言"])
        await engine.finish(2)
        try await eventually { service.snapshot(for: current).phase == .ready }
        #expect(service.snapshot(for: current).lines == [0: "已完成", 1: "剛安裝的語言"])
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func delayedCurrentLyricsUseAnExplicitBackgroundAllowanceWithoutStartingFutureSongs() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("delayed-current", count: 1), next = input("next", count: 1)
        // A foreground lyrics lookup is still pending when the scene becomes inactive.
        service.setRequests(current: nil, upcoming: [], enabled: true, isForeground: true)
        service.setRequests(current: nil, upcoming: [], enabled: true, isForeground: false,
                            allowsBackgroundCurrent: true)
        #expect(!service.isWorking)
        // Its existing platform allowance admits only the completed current-song lookup.
        service.setRequests(current: current, upcoming: [next], enabled: true, isForeground: false,
                            allowsBackgroundCurrent: true)
        try await engine.waitForCalls(1)
        #expect(service.activeSongID == current.songID)
        await engine.publish(0, values: ["0:0": "背景完成的目前歌曲"])
        await engine.finish(0)
        try await eventually { service.snapshot(for: current).phase == .ready }
        try await eventually { !service.isWorking }
        #expect(await engine.count == 1)
        #expect(service.snapshot(for: next).phase == .idle)
        // A subsequent background song cannot inherit the previous song's permission.
        service.setRequests(current: next, upcoming: [], enabled: true, isForeground: false)
        #expect(!service.isWorking)
        #expect(await engine.count == 1)
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func backgroundAdmissionRequiresEnabledWorkAndCannotUndoExpiration() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("current", count: 1)
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: false)
        #expect(!service.isWorking)
        service.setRequests(current: current, upcoming: [], enabled: false, isForeground: false,
                            allowsBackgroundCurrent: true)
        #expect(!service.isWorking)
        #expect(await engine.count == 0)
        service.suspend()
        // Even a late callback carrying the old permit cannot override expiration.
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: false,
                            allowsBackgroundCurrent: true)
        #expect(!service.isWorking)
        #expect(await engine.count == 0)
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        await engine.publish(0, values: ["0:0": "前景恢復"])
        await engine.finish(0)
        try await eventually { service.snapshot(for: current).phase == .ready }
        await service.flush()
    }

    @Test(.timeLimit(.minutes(1))) func normalBackgroundCompletionKeepsItsBudgetUntilTheFinalCheckpointIsDurable() async throws {
        let folder = directory(), engine = ControlledLyricsEngine(), gate = CheckpointGate()
        let cache = AutomaticLyricTranslationCache(directory: folder)
        let service = Pipeline(cache: cache, detectLanguage: { _ in "en" }) { fragments, publish in
            try await engine.run(fragments, publish: publish)
        }
        service.checkpointWriter = { key, entry in
            await gate.waitBeforeWrite()
            await cache.store(entry, for: key)
        }
        defer {
            service.suspend()
            Task { await gate.release(); await engine.finishAll() }
            try? FileManager.default.removeItem(at: folder)
        }
        let current = input("durable-current", count: 1), next = input("future", count: 1)
        service.setRequests(current: current, upcoming: [next], enabled: true, isForeground: false,
                            allowsBackgroundCurrent: true)
        try await engine.waitForCalls(1)
        await engine.publish(0, values: ["0:0": "已翻譯，正在儲存"])
        await engine.finish(0)
        await gate.waitUntilEntered()
        try await eventually { service.snapshot(for: current).phase == .ready }
        #expect(service.isWorking)
        #expect(service.activeSongID == current.songID)
        #expect(await engine.count == 1)
        let key = AutomaticLyricTranslationCache.Key(songID: current.songID, rows: current.rows)
        let before = AutomaticLyricTranslationCache(directory: folder)
        #expect(await before.entry(for: key) == nil)
        await gate.release()
        try await eventually { !service.isWorking }
        #expect(service.activeSongID == nil)
        #expect(await engine.count == 1) // No background speculative work follows completion.
        let reopened = AutomaticLyricTranslationCache(directory: folder)
        let saved = try #require(await reopened.entry(for: key))
        #expect(saved.isComplete)
        #expect(saved.fragments == ["0:0": "已翻譯，正在儲存"])
    }

    @Test(.timeLimit(.minutes(1))) func aLanguageRetryArrivingDuringFinalPersistenceIsNotLost() async throws {
        let folder = directory(), engine = ControlledLyricsEngine(), gate = CheckpointGate()
        let cache = AutomaticLyricTranslationCache(directory: folder)
        let service = Pipeline(cache: cache, detectLanguage: { _ in "en" }) { fragments, publish in
            try await engine.run(fragments, publish: publish)
        }
        service.checkpointWriter = { key, entry in
            await gate.waitBeforeWrite()
            await cache.store(entry, for: key)
        }
        defer {
            service.suspend()
            Task { await gate.release(); await engine.finishAll() }
            try? FileManager.default.removeItem(at: folder)
        }
        let current = input("retry-while-writing", count: 2)
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        await engine.publish(0, values: ["0:0": "已完成"])
        await engine.finish(0, outcome: .needsLanguage(.init(source: "en", target: "zh-Hant")))
        await gate.waitUntilEntered()
        try await eventually { service.snapshot(for: current).phase == .needsLanguage }
        #expect(service.isWorking)
        service.retry(songID: current.songID)
        #expect(await engine.count == 1)
        await gate.release()
        try await engine.waitForCalls(2)
        #expect(await engine.fragments(at: 1).map(\.id) == ["1:0"])
        await engine.publish(1, values: ["1:0": "繼續完成"])
        await engine.finish(1)
        try await eventually { !service.isWorking }
        #expect(service.snapshot(for: current).phase == .ready)
        #expect(service.snapshot(for: current).lines == [0: "已完成", 1: "繼續完成"])
    }
}

/// An asynchronous disk gate: holding a writer never blocks MainActor or a worker thread.
private actor CheckpointGate {
    private let enteredStream: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let releasedStream: AsyncStream<Void>
    private let releasedContinuation: AsyncStream<Void>.Continuation
    private var entered = false
    private var released = false

    init() {
        let (entryEvents, entryEmitter) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (releaseEvents, releaseEmitter) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        enteredStream = entryEvents
        enteredContinuation = entryEmitter
        releasedStream = releaseEvents
        releasedContinuation = releaseEmitter
    }
    func waitBeforeWrite() async {
        entered = true
        enteredContinuation.yield(())
        enteredContinuation.finish()
        guard !released else { return }
        for await _ in releasedStream { break }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        for await _ in enteredStream { break }
    }
    func release() {
        released = true
        releasedContinuation.yield(())
        releasedContinuation.finish()
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
    private var callWaiters: [UUID: (count: Int, continuation: AsyncStream<Void>.Continuation)] = [:]
    var count: Int { calls.count }

    func waitForCalls(_ expected: Int, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        guard calls.count < expected else { return }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        callWaiters[id] = (expected, continuation)
        defer { callWaiters.removeValue(forKey: id) }
        for await _ in stream { break }
        if Task.isCancelled {
            Issue.record("Cancelled waiting for translation engine call \(expected); received \(calls.count).", sourceLocation: sourceLocation)
            throw CancellationError()
        }
    }

    func run(_ fragments: [ChineseLyricTranslationPlan.Fragment], publish: @escaping Pipeline.Publish) async throws -> Pipeline.Outcome {
        let index = calls.count
        calls.append(Call(fragments: fragments, publish: publish))
        for waiter in callWaiters.values where calls.count >= waiter.count {
            waiter.continuation.yield(())
            waiter.continuation.finish()
        }
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

extension AutomaticLyricTranslationPipelineTests {
    @Test(.timeLimit(.minutes(1)))
    func finishedListeningSessionRejectsForegroundRetriesAndKeepsCompletedText() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("deep-stop", count: 3)
        service.setRequests(current: current, upcoming: [input("future")], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        let fragments = await engine.fragments(at: 0)
        await engine.publish(0, values: [fragments[0].id: "已保存"])
        service.setPlaybackSessionFinished(true)
        await service.flush()
        service.setRequests(current: current, upcoming: [input("future")], enabled: true, isForeground: true)
        service.retry(songID: current.songID)
        await engine.publish(0, values: [fragments[1].id: "不應出現"])
        #expect(service.snapshot(for: current).lines == [0: "已保存"])
        await engine.finish(0)
        try await eventually { !service.isWorking }
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: false, allowsBackgroundCurrent: true)
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        service.retry(songID: current.songID)
        #expect(await engine.count == 1)
        #expect(service.snapshot(for: current).phase == .paused)

        service.setPlaybackSessionFinished(false)
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(2)
        let missing = await engine.fragments(at: 1)
        #expect(missing.map(\.id) == Array(fragments.dropFirst()).map(\.id))
        await engine.publish(1, values: Dictionary(uniqueKeysWithValues: missing.map { ($0.id, "繼續") }))
        await engine.finish(1)
        try await eventually { !service.isWorking }
        #expect(service.snapshot(for: current).phase == .ready)
        #expect(service.snapshot(for: current).lines[0] == "已保存")
    }

    @Test(.timeLimit(.minutes(1)))
    func restoredFinishedSessionCannotStartTranslationUntilManualPlaybackResumes() async throws {
        let folder = directory(), engine = ControlledLyricsEngine()
        let service = pipeline(directory: folder, engine: engine)
        defer { service.suspend(); Task { await engine.finishAll() }; try? FileManager.default.removeItem(at: folder) }
        let current = input("restored-stop", count: 1)
        service.setPlaybackSessionFinished(true)
        service.setRequests(current: current, upcoming: [input("future")], enabled: true, isForeground: true)
        service.retry(songID: current.songID)
        #expect(!service.isWorking)
        #expect(await engine.count == 0)
        service.setPlaybackSessionFinished(false)
        #expect(!service.isWorking) // The owner must reconcile the selected song first.
        service.setRequests(current: current, upcoming: [], enabled: true, isForeground: true)
        try await engine.waitForCalls(1)
        await engine.finish(0, outcome: .unavailable)
        try await eventually { !service.isWorking }
    }
}
