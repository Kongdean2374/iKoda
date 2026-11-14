import Foundation
import Observation

/// Optional fields from the selected streaming format, not from a quality preference
/// or an itag lookup. Missing declarations stay unknown, including for old local files.
public struct AudioStreamMetadata: Codable, Sendable, Equatable {
    public var mimeType: String?
    public var bitrate: Int?
    public var sampleRate: Double?
    public var channels: Int?

    public init(mimeType: String? = nil, bitrate: Int? = nil, sampleRate: Double? = nil, channels: Int? = nil) {
        self.mimeType = mimeType
        self.bitrate = bitrate.flatMap { $0 > 0 ? $0 : nil }
        self.sampleRate = sampleRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.channels = channels.flatMap { $0 > 0 ? $0 : nil }
    }

    public var codec: String? {
        guard let mime = mimeType?.lowercased() else { return nil }
        if mime.contains("mp4a.40.29") { return "HE-AAC v2" }
        if mime.contains("mp4a.40.5") { return "HE-AAC" }
        if mime.contains("mp4a.40.2") { return "AAC" }
        if mime.contains("opus") { return "Opus" }
        // audio/mp4 alone is a container, not evidence of a particular codec.
        return nil
    }
}

public enum AudioPlaybackState: String, Codable, Sendable {
    case idle, loading, ready, playing, paused, failed
}

/// Published only when something changes (or at a throttled playback tick).
/// No signed stream URL, request header, account details or media title is included.
public struct AudioPlaybackInformation: Sendable, Equatable {
    public var metadata: AudioStreamMetadata?
    public var hasStream: Bool
    public var isLocal: Bool
    public var bufferedSeconds: TimeInterval?
    public var isBuffering: Bool
    public var network: NetworkSnapshot
    public var state: AudioPlaybackState
    public var lastFailure: PlaybackFailureReason?
    public var retryAttempt: Int

    public init(metadata: AudioStreamMetadata? = nil, hasStream: Bool = false, isLocal: Bool = false,
                bufferedSeconds: TimeInterval? = nil, isBuffering: Bool = false,
                network: NetworkSnapshot = NetworkSnapshot(), state: AudioPlaybackState = .idle,
                lastFailure: PlaybackFailureReason? = nil, retryAttempt: Int = 0) {
        self.metadata = metadata
        self.hasStream = hasStream
        self.isLocal = isLocal
        self.bufferedSeconds = bufferedSeconds.flatMap { $0.isFinite ? max(0, $0) : nil }
        self.isBuffering = isBuffering
        self.network = network
        self.state = state
        self.lastFailure = lastFailure
        self.retryAttempt = max(0, retryAttempt)
    }
}

/// A closed, typed schema makes it impossible to accidentally log a cookie, token,
/// request, arbitrary server error or media URL through this API.
public struct PlaybackDiagnosticEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case networkChanged, streamInitializationFailed, playbackFailed, retryScheduled,
             retryStarted, waitingForNetwork, recovered, recoveryStopped,
             interruptionBegan, interruptionEnded, pausedByUser
    }
    public let id: UUID
    public let date: Date
    public let kind: Kind
    public let reason: PlaybackFailureReason?
    public let attempt: Int?
    public let network: NetworkSnapshot?

    public init(kind: Kind, reason: PlaybackFailureReason? = nil, attempt: Int? = nil,
                network: NetworkSnapshot? = nil, date: Date = Date()) {
        id = UUID()
        self.date = date
        self.kind = kind
        self.reason = reason
        self.attempt = attempt.map { min(5, max(0, $0)) }
        self.network = network
    }
}

/// At most 100 local records. Writes encode on a serial utility queue, preserving order
/// even if Clear is followed immediately by another event. Nothing leaves the device.
@MainActor
@Observable
public final class PlaybackDiagnosticStore {
    public private(set) var events: [PlaybackDiagnosticEvent] = []
    @ObservationIgnored private let storage: URL?
    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let writer = DispatchQueue(label: "Koda.PlaybackDiagnostics", qos: .utility)

    public init(storage: URL? = nil, capacity: Int = 100) {
        self.storage = storage
        self.capacity = min(100, max(1, capacity))
        if let storage, let size = try? storage.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 256_000, let data = try? Data(contentsOf: storage),
           let saved = try? JSONDecoder().decode([PlaybackDiagnosticEvent].self, from: data) {
            events = Array(saved.suffix(self.capacity))
        }
    }

    public func record(_ kind: PlaybackDiagnosticEvent.Kind, reason: PlaybackFailureReason? = nil,
                       attempt: Int? = nil, network: NetworkSnapshot? = nil) {
        // NWPath can repeat equivalent callbacks; do not fill the log with duplicates.
        if kind == .networkChanged, let last = events.last,
           last.kind == kind, last.network == network { return }
        events.append(PlaybackDiagnosticEvent(kind: kind, reason: reason, attempt: attempt, network: network))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        save()
    }

    public func clear() {
        events = []
        save()
    }

    private func save() {
        guard let storage else { return }
        let snapshot = events
        writer.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: storage, options: .atomic)
        }
    }

    /// A deterministic seam for persistence tests; playback never waits for disk writes.
    public func flush() async {
        await withCheckedContinuation { continuation in
            writer.async { continuation.resume() }
        }
    }
}
