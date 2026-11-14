import KodaCore
import SwiftUI

/// Playback preparation belongs to Player, so it remains visible after leaving the playlist.
/// The source page filters this status; the queue shows whichever request is active.
struct PlaylistQueueLoadingView: View {
    var sourceID: String? = nil
    @Environment(Player.self) private var player

    var body: some View {
        if let count = player.playlistLoadingCount,
           sourceID == nil || sourceID == player.playlistLoadingSourceID {
            VStack(alignment: .leading, spacing: 8) {
                if let error = player.playlistLoadingError {
                    Label("Couldn't Prepare Playlist", systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.medium))
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading Playlist · \(count) songs")
                            .font(.subheadline)
                            .monospacedDigit()
                    }
                    Text("Loading all playlist pages for the queue. Your current queue stays unchanged until loading finishes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 20) {
                    if player.playlistLoadCanRetry {
                        Button("Retry") { player.retryPlaylistLoading() }
                    }
                    Button("Cancel Loading") { player.cancelPlaylistLoading() }
                }
                .font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
        }
    }
}
