import AVFoundation
import KodaCore
import Observation
import ShazamKit
import UIKit

/// A short-lived, explicit microphone session. Neither audio samples nor recognition
/// history are saved to disk. Apple ShazamKit produces the catalog metadata.
@MainActor
@Observable
final class MusicCatcher {
    private final class WeakInstance {
        weak var value: MusicCatcher?
        init(_ value: MusicCatcher) { self.value = value }
    }
    private static var instances: [WeakInstance] = []
    private static var audioOwners = Set<UUID>()
    static var ownsAudioSession: Bool { !audioOwners.isEmpty }
    static var canDeactivateAfterRecording: (() -> Bool)?

    /// A newer play/video/profile/sleep intention wins over any permission or match
    /// callback still in flight. Ready metadata stays visible when preview is tapped.
    static func cancelActiveRecognition() {
        instances.removeAll { $0.value == nil }
        for instance in instances {
            guard let catcher = instance.value, !catcher.restoringPlayback, catcher.flow.isWorking else { continue }
            catcher.cancel(allowPlaybackRestore: false)
        }
    }

    fileprivate static func acquiredAudio(_ id: UUID) { audioOwners.insert(id) }
    fileprivate static func releasedAudio(_ id: UUID) { audioOwners.remove(id) }

    let flow = MusicRecognitionFlow()
    @ObservationIgnored private let activity = MusicRecognitionActivityGate()
    var sceneIsActive: Bool { activity.state == .active }
    @ObservationIgnored private let provider: any MusicRecognitionProviding
    @ObservationIgnored private let searchOverride: (@MainActor (String) async throws -> [Song])?
    @ObservationIgnored private var expectedIntent: UInt64 = 0
    @ObservationIgnored private var playbackLease: MusicCatcherPlaybackLease?
    @ObservationIgnored private var restoringPlayback = false

    init(provider: (any MusicRecognitionProviding)? = nil,
         search: (@MainActor (String) async throws -> [Song])? = nil) {
        self.provider = provider ?? ShazamMicrophoneRecognizer()
        self.searchOverride = search
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakInstance(self))
    }

    func start(app: AppModel) {
        Self.cancelActiveRecognition()
        expectedIntent = app.player.playbackIntentRevision
        let profile = app.roster.activeID
        playbackLease = nil
        flow.start(provider: provider, isCurrent: { [weak self, weak app] in
            guard let self, let app else { return false }
            return app.roster.activeID == profile
                && app.player.playbackIntentRevision == self.expectedIntent
        }, waitUntilActive: { [weak self] in
            guard let self else { return false }
            // UIKit's state closes the small gap before SwiftUI delivers scenePhase.
            if UIApplication.shared.applicationState != .active {
                self.activity.update(UIApplication.shared.applicationState == .background ? .background : .inactive)
            }
            return await self.activity.waitUntilActive()
        }, beforeRecording: { [weak self, weak app] in
            guard let self, let app, self.sceneIsActive, UIApplication.shared.applicationState == .active,
                  app.roster.activeID == profile, app.player.playbackIntentRevision == self.expectedIntent,
                  !app.videos.ownsAudioSession, !VoiceSearch.ownsAudioSession else { return false }
            let wasPlaying = app.player.wantsToPlay
            if wasPlaying { app.player.pause(from: "Music Catcher microphone") }
            self.expectedIntent = app.player.playbackIntentRevision
            self.playbackLease = MusicCatcherPlaybackLease(profileID: profile, occurrenceID: app.player.queue.current?.id,
                intentRevision: self.expectedIntent, wasPlaying: wasPlaying)
            return true
        }, stoppedRecording: { [weak self, weak app] allowRestore in
            guard let self, let app else { return }
            defer { self.playbackLease = nil }
            guard allowRestore, self.playbackLease?.canRestore(profileID: app.roster.activeID,
                occurrenceID: app.player.queue.current?.id, intentRevision: app.player.playbackIntentRevision,
                sceneIsActive: self.sceneIsActive && UIApplication.shared.applicationState == .active,
                sessionFinished: app.player.isPlaybackSessionFinished,
                otherAudioOwner: app.videos.ownsAudioSession || VoiceSearch.ownsAudioSession) == true else { return }
            self.restoringPlayback = true
            app.player.resume()
            self.expectedIntent = app.player.playbackIntentRevision
            self.restoringPlayback = false
        }, search: { [weak self, weak app] query in
            if let search = self?.searchOverride { return try await search(query) }
            guard let app else { throw CancellationError() }
            return try await app.music.search(query, filter: .songs).songs
        })
    }

    func cancel(allowPlaybackRestore: Bool) {
        activity.cancelWaiters()
        flow.cancel(allowPlaybackRestore: allowPlaybackRestore)
        playbackLease = nil
    }

    func validateCurrentIntent(_ revision: UInt64) {
        guard flow.isWorking, revision != expectedIntent else { return }
        cancel(allowPlaybackRestore: false)
    }

    func updateActivity(_ state: MusicRecognitionActivityGate.State) {
        activity.update(state)
        if flow.isWorking && (state == .background || (state == .inactive && flow.phase != .authorizing)) {
            cancel(allowPlaybackRestore: false)
        }
    }

    func close() {
        cancel(allowPlaybackRestore: true)
        flow.clear()
    }
}

/// SHSession is available on iOS/Mac Catalyst 15+. The signing App ID must have
/// Apple's ShazamKit service enabled. A sideload signing identity may lack it;
/// a service rejection is shown as unavailable, never as a fabricated match.
@MainActor
private final class ShazamMicrophoneRecognizer: MusicRecognitionProviding {
    var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private let ownerID = UUID()
    private var operationID: UUID?
    private var continuation: CheckedContinuation<RecognizedMusic, any Error>?
    private var engine: AVAudioEngine?
    private var formatMixer: AVAudioMixerNode?
    private var tapInstalled = false
    private var ownsSession = false
    private var session: SHSession?
    private var delegate: ShazamMatchDelegate?
    private var timeout: Task<Void, Never>?
    private var audioObservers: [any NSObjectProtocol] = []

    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func recognize() async throws -> RecognizedMusic {
        cancel()
        try Task.checkCancellation()
        let id = UUID()
        operationID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do { try startAudio(id: id) }
                catch { complete(.failure(.unavailable), id: id) }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.complete(.failure(.cancelled), id: id) }
        }
    }

    func cancel() {
        guard let id = operationID else { return }
        complete(.failure(.cancelled), id: id)
    }

    private func startAudio(id: UUID) throws {
        guard operationID == id, !Task.isCancelled else { throw CancellationError() }
        let audio = AVAudioSession.sharedInstance()
        // Mixing keeps unrelated audio apps under iOS's normal audio policy. Koda's
        // own music is paused by the controller; microphone input is never played out.
        try audio.setCategory(.playAndRecord, mode: .measurement, options: .mixWithOthers)
        ownsSession = true
        MusicCatcher.acquiredAudio(ownerID)
        try audio.setActive(true)
        let session = SHSession()
        let delegate = ShazamMatchDelegate { [weak self] result in
            Task { @MainActor [weak self] in self?.complete(result, id: id) }
        }
        session.delegate = delegate
        self.session = session
        self.delegate = delegate
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0,
              let recognitionFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
            throw MusicRecognitionFailure.unavailable
        }
        // Follow Apple's microphone example rather than assuming a USB/Bluetooth
        // input's native rate/channel count is accepted by the signature generator:
        // https://developer.apple.com/documentation/shazamkit/matching-audio-using-the-built-in-microphone
        // append(_:at:) documents PCM 48/44.1/32/16 kHz. The mixer converts the
        // hardware input to 48 kHz mono before ShazamKit sees any samples.
        let mixer = AVAudioMixerNode()
        formatMixer = mixer
        engine.attach(mixer)
        engine.connect(input, to: mixer, format: nativeFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: recognitionFormat)
        // Mute only the downstream output. Muting the tapped format mixer would
        // feed silence to recognition; leaving output audible would cause feedback.
        engine.mainMixerNode.outputVolume = 0
        mixer.installTap(onBus: 0, bufferSize: 2048, format: recognitionFormat, block: Self.tap(session: session))
        tapInstalled = true
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audio, queue: nil
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in self?.complete(.failure(.interrupted), id: id) }
        })
        audioObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: audio, queue: nil
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
                  reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
            // Rebuilding the engine after an input device changes requires another
            // deliberate attempt. Ignore our own category-change notification.
            Task { @MainActor [weak self] in self?.complete(.failure(.interrupted), id: id) }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            audioObservers.append(NotificationCenter.default.addObserver(forName: name, object: audio, queue: nil) { [weak self] _ in
                Task { @MainActor [weak self] in self?.complete(.failure(.interrupted), id: id) }
            })
        }
        engine.prepare()
        try engine.start()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.complete(.failure(.noMatch), id: id)
        }
    }

    private func complete(_ result: Result<RecognizedMusic, MusicRecognitionFailure>, id: UUID) {
        guard operationID == id else { return }
        operationID = nil
        let waiting = continuation
        continuation = nil
        timeout?.cancel()
        timeout = nil
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
        audioObservers.removeAll()
        if let engine {
            if engine.isRunning { engine.stop() }
            if let mixer = formatMixer {
                if tapInstalled { mixer.removeTap(onBus: 0) }
                engine.disconnectNodeInput(mixer)
                engine.disconnectNodeOutput(mixer)
                engine.detach(mixer)
            }
            engine.reset()
        }
        tapInstalled = false
        formatMixer = nil
        engine = nil
        session?.delegate = nil
        session = nil
        delegate = nil
        if ownsSession {
            ownsSession = false
            MusicCatcher.releasedAudio(ownerID)
            if MusicCatcher.canDeactivateAfterRecording?() == true {
                let audio = AVAudioSession.sharedInstance()
                try? audio.setActive(false, options: .notifyOthersOnDeactivation)
                try? audio.setCategory(.playback, mode: .default, policy: .longFormAudio)
            }
        }
        switch result {
        case .success(let match): waiting?.resume(returning: match)
        case .failure(let error): waiting?.resume(throwing: error)
        }
    }

    nonisolated private static func tap(session: SHSession) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let session = session
        return { buffer, time in session.matchStreamingBuffer(buffer, at: time) }
    }
}

/// Shazam invokes these callbacks from its own queue. Pass only immutable metadata
/// to MainActor, never a live SHMatch, a microphone buffer, credentials or raw errors.
nonisolated private final class ShazamMatchDelegate: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let deliver: @Sendable (Result<RecognizedMusic, MusicRecognitionFailure>) -> Void
    init(deliver: @escaping @Sendable (Result<RecognizedMusic, MusicRecognitionFailure>) -> Void) {
        self.deliver = deliver
        super.init()
    }
    func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first, let title = item.title, !title.isEmpty else {
            deliver(.failure(.noMatch)); return
        }
        deliver(.success(RecognizedMusic(title: title, artist: item.artist ?? "", artworkURL: item.artworkURL)))
    }
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: (any Error)?) {
        // An unmatched streaming window can be followed by a better one. Keep
        // listening within the one bounded 20-second attempt, without a retry loop.
        if error != nil { deliver(.failure(.unavailable)) }
    }
}
