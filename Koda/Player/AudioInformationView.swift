import KodaCore
import SwiftUI

/// A snapshot of actual stream declarations and player state. It deliberately does not
/// show account identifiers, media URLs or a quality inferred from the user's preference.
struct AudioInformationView: View {
    @Environment(Player.self) private var player

    var body: some View {
        Form {
            Section {
                row("Codec", player.audioInformation.metadata?.codec)
                row("Source bitrate", player.audioInformation.metadata?.bitrate.map {
                    String(localized: "\((Double($0) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kbps")
                })
                row("Sample rate", player.audioInformation.metadata?.sampleRate.map {
                    String(localized: "\($0.formatted(.number.precision(.fractionLength(0)))) Hz")
                })
                row("Audio Channels", player.audioInformation.metadata?.channels.map { $0.formatted() })
                row("Current audio quality", actualQuality)
                row("Audio source", player.audioInformation.hasStream ? (player.audioInformation.isLocal ? String(localized: "On this device") : String(localized: "Streaming")) : nil)
            } header: {
                Text("Audio Format")
            } footer: {
                Text("Format values come from the selected source or its audio track. Bitrate is source-declared, not inferred from a quality setting. Missing values are unavailable; lossy audio is not labeled lossless.")
            }
            Section("Playback Status") {
                row("Player state", stateTitle(player.audioInformation.state))
                row("Buffering", player.audioInformation.isBuffering ? String(localized: "Waiting for audio") : String(localized: "Not buffering"))
                row("Buffered ahead", player.audioInformation.bufferedSeconds.map { String(localized: "\(Int($0)) seconds") })
                row("Network connection", networkTitle(player.audioInformation.network))
                row("Low Data Mode", player.audioInformation.network.status == .unknown ? nil : (player.audioInformation.network.isConstrained ? String(localized: "On") : String(localized: "Off")))
                row("Recovery attempts", player.audioInformation.retryAttempt.formatted())
                row("Last playback error", player.audioInformation.lastFailure?.message ?? String(localized: "None"))
            }
            Section {
                if player.diagnosticEvents.isEmpty {
                    Text("No diagnostic events").foregroundStyle(.secondary)
                }
                ForEach(player.diagnosticEvents.reversed()) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(eventTitle(event.kind)).font(.subheadline.weight(.medium))
                        if let reason = event.reason { Text(reason.message).font(.caption).foregroundStyle(.secondary) }
                        if let attempt = event.attempt { Text("Attempt \(attempt)").font(.caption).foregroundStyle(.secondary) }
                        if let network = event.network { Text(networkTitle(network)).font(.caption).foregroundStyle(.secondary) }
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button("Clear Diagnostics", role: .destructive) { player.clearDiagnostics() }
                    .disabled(player.diagnosticEvents.isEmpty)
            } header: {
                Text("Recent Diagnostics")
            } footer: {
                Text("Up to 100 events stay on this device. The log excludes account data, cookies, tokens, media URLs and request headers.")
            }
        }
        .navigationTitle("Audio Information")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var actualQuality: String? {
        let format = player.audioInformation.metadata
        let parts = [format?.codec, format?.bitrate.map { String(localized: "\((Double($0) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kbps") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        LabeledContent {
            Text(value ?? String(localized: "Unavailable"))
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        } label: { Text(title) }
    }

    private func stateTitle(_ state: AudioPlaybackState) -> String {
        switch state {
        case .idle: String(localized: "Idle")
        case .loading: String(localized: "Loading")
        case .ready: String(localized: "Ready")
        case .playing: String(localized: "Playing")
        case .paused: String(localized: "Paused")
        case .failed: String(localized: "Playback failed")
        }
    }

    private func networkTitle(_ network: NetworkSnapshot) -> String {
        if network.status == .offline { return String(localized: "Offline") }
        if network.status == .unknown { return String(localized: "Unavailable") }
        switch network.interface {
        case .wifi: return String(localized: "Wi-Fi")
        case .cellular: return String(localized: "Mobile data")
        case .wired: return String(localized: "Wired network")
        case .other: return String(localized: "Other connection")
        case .unknown: return String(localized: "Unavailable")
        }
    }

    private func eventTitle(_ kind: PlaybackDiagnosticEvent.Kind) -> String {
        switch kind {
        case .networkChanged: String(localized: "Network changed")
        case .streamInitializationFailed: String(localized: "Stream initialization failed")
        case .playbackFailed: String(localized: "Playback failed")
        case .retryScheduled: String(localized: "Recovery scheduled")
        case .retryStarted: String(localized: "Reconnecting audio")
        case .waitingForNetwork: String(localized: "Waiting for a connection")
        case .recovered: String(localized: "Playback recovered")
        case .recoveryStopped: String(localized: "Automatic recovery stopped")
        case .interruptionBegan: String(localized: "System audio interruption began")
        case .interruptionEnded: String(localized: "System audio interruption ended")
        case .pausedByUser: String(localized: "Playback paused")
        }
    }
}
