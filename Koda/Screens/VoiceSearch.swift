import AVFoundation
import KodaCore
import Speech
import SwiftUI

/// Listens for a search, on the device where the phone can, and stops by itself
/// once the listener has finished speaking.
@MainActor
@Observable
final class VoiceSearch {
    enum Phase: Equatable {
        case starting
        case listening
        case blocked(String)
        case failed(String)
    }

    private(set) var phase: Phase = .starting
    private(set) var transcript = ""
    /// How loud the microphone is, 0…1, for the listening animation.
    private(set) var level: Double = 0

    private var lifecycle = VoiceSearchLifecycle()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private var onFinish: ((String) -> Void)?

    /// How long a pause ends the search, once something has been said.
    private static let endOfSpeech: Duration = .milliseconds(1400)

    func start(onFinish: @escaping (String) -> Void) async {
        guard !Task.isCancelled else { return }
        cancel()
        let generation = lifecycle.begin()
        phase = .starting
        transcript = ""
        self.onFinish = onFinish

        await withTaskCancellationHandler {
            await self.startListening(for: generation)
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.stopAudio(for: generation) }
        }
    }

    private func startListening(for generation: VoiceSearchLifecycle.Generation) async {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard mayContinueStarting(generation) else { return }
        guard speech == .authorized else {
            phase = .blocked(String(localized: "Koda needs Speech Recognition to search by voice. You can allow it in Settings."))
            stopAudio(for: generation)
            return
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        guard mayContinueStarting(generation) else { return }
        guard microphone else {
            phase = .blocked(String(localized: "Koda needs the microphone to search by voice. You can allow it in Settings."))
            stopAudio(for: generation)
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            phase = .failed(String(localized: "Voice search isn't available right now."))
            stopAudio(for: generation)
            return
        }
        do {
            guard mayContinueStarting(generation) else { return }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            lifecycle.acquiredAudioSession(for: generation)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .search
            // Kept on the phone whenever the phone can do it.
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            guard mayContinueStarting(generation) else { return }
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                phase = .failed(String(localized: "Koda couldn't start listening."))
                stopAudio(for: generation)
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(feeding: request) { [weak self] level in
                Task { @MainActor in
                    guard let self, self.lifecycle.accepts(generation) else { return }
                    self.level = level
                }
            })
            tapInstalled = true
            engine.prepare()
            guard mayContinueStarting(generation) else { return }
            try engine.start()

            task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, isFinal, failed in
                Task { @MainActor in self?.receive(text, isFinal: isFinal, failed: failed, generation: generation) }
            })
            phase = .listening
        } catch {
            guard lifecycle.accepts(generation) else { return }
            phase = .failed(String(localized: "Koda couldn't start listening."))
            stopAudio(for: generation)
        }
    }

    /// Permission APIs need not honor task cancellation. Check both cancellation
    /// and generation immediately after every await, before touching audio resources.
    private func mayContinueStarting(_ generation: VoiceSearchLifecycle.Generation) -> Bool {
        guard lifecycle.accepts(generation, taskIsCancelled: Task.isCancelled) else {
            stopAudio(for: generation)
            return false
        }
        return true
    }

    /// Stop listening without searching.
    func cancel() {
        guard let generation = lifecycle.current else { return }
        stopAudio(for: generation)
    }

    /// Search for what has been heard so far.
    func finish() {
        guard let generation = lifecycle.current else { return }
        finish(for: generation)
    }

    private func finish(for generation: VoiceSearchLifecycle.Generation) {
        guard lifecycle.accepts(generation) else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let onFinish = onFinish
        stopAudio(for: generation)
        if !text.isEmpty { onFinish?(text) }
    }

    private func receive(_ text: String?, isFinal: Bool, failed: Bool, generation: VoiceSearchLifecycle.Generation) {
        guard lifecycle.accepts(generation) else { return }
        if let text, !text.isEmpty { transcript = text }
        if isFinal || (failed && !transcript.isEmpty) {
            finish(for: generation)
            return
        }
        if failed {
            phase = .failed(String(localized: "Koda didn't catch that. Try again."))
            stopAudio(for: generation)
            return
        }
        // Each new word restarts the wait; a pause after speaking ends the search.
        silence?.cancel()
        silence = Task { [weak self] in
            try? await Task.sleep(for: Self.endOfSpeech)
            guard !Task.isCancelled else { return }
            self?.finish(for: generation)
        }
    }

    private func stopAudio(for generation: VoiceSearchLifecycle.Generation) {
        guard let cleanup = lifecycle.end(generation) else { return }
        silence?.cancel()
        silence = nil
        if let engine {
            if engine.isRunning { engine.stop() }
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.reset()
        }
        tapInstalled = false
        engine = nil
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        onFinish = nil
        level = 0
        // Dismissing a pending permission prompt never owned the audio session.
        guard cleanup.restoreAudioSession else { return }
        // Hand audio back to playback, as Koda had it.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // These run on audio and speech threads. Built outside the main actor, so
    // nothing in them is checked against it.

    nonisolated private static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            // Speech sits around -40…-10 dB; map that onto 0…1.
            let db = 20 * log10(max(rms, 0.000_01))
            level(Double(min(max((db + 50) / 40, 0), 1)))
        }
    }

    nonisolated private static func results(_ deliver: @escaping @Sendable (String?, Bool, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            deliver(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }
}

/// The listening sheet: what is heard so far, over a microphone that moves with the voice.
struct VoiceSearchSheet: View {
    let onSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var voice = VoiceSearch()

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                // Rings that grow with the voice.
                ForEach(0..<2) { ring in
                    Circle()
                        .fill(Color.accentColor.opacity(0.18 - Double(ring) * 0.07))
                        .frame(width: 92, height: 92)
                        .scaleEffect(reduceMotion ? 1 : 1 + voice.level * (0.45 + Double(ring) * 0.35))
                        .animation(.spring(response: 0.18, dampingFraction: 0.6), value: voice.level)
                }
                Image(systemName: isListening ? "mic.fill" : "mic.slash.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(isListening ? Color.accentColor : .secondary)
                    .frame(width: 92, height: 92)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
                    .onTapGesture { if isListening { voice.finish() } }
                    .accessibilityLabel(isListening ? String(localized: "Finish speaking") : String(localized: "Microphone"))
            }
            .frame(height: 170)

            Group {
                switch voice.phase {
                case .starting:
                    Text(String(localized: "Starting…")).foregroundStyle(.secondary)
                case .listening:
                    Text(voice.transcript.isEmpty ? String(localized: "Say a song, artist or album") : voice.transcript)
                        .foregroundStyle(voice.transcript.isEmpty ? .secondary : .primary)
                        .contentTransition(.interpolate)
                        .animation(.smooth(duration: 0.2), value: voice.transcript)
                case .blocked(let message), .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .frame(minHeight: 60)

            if case .blocked = voice.phase {
                Button(String(localized: "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            Button(String(localized: "Cancel"), systemImage: "xmark") {
                voice.cancel()
                dismiss()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(16)
        }
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.start, trigger: isListening)
        .task {
            await voice.start { text in
                onSearch(text)
                dismiss()
            }
        }
        .onDisappear { voice.cancel() }
    }

    private var isListening: Bool { voice.phase == .listening }
}
