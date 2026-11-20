#if !targetEnvironment(macCatalyst)
import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

private struct CarPlayPlayerEntry: TimelineEntry {
    let date: Date
    let player: CarPlayPlayerSnapshot?
    let sharedContainerAvailable: Bool
}

private struct CarPlayPlayerProvider: TimelineProvider {
    func placeholder(in context: Context) -> CarPlayPlayerEntry {
        CarPlayPlayerEntry(date: .now, player: nil, sharedContainerAvailable: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (CarPlayPlayerEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CarPlayPlayerEntry>) -> Void) {
        // App-side changes request reloads. A sparse fallback also handles a
        // temporary render failure without keeping either process running.
        completion(Timeline(entries: [entry()], policy: .after(.now.addingTimeInterval(15 * 60))))
    }

    private func entry() -> CarPlayPlayerEntry {
        let file = CarPlayPlayerSnapshot.file
        return CarPlayPlayerEntry(date: .now, player: file.flatMap(CarPlayPlayerSnapshot.read),
                                 sharedContainerAvailable: file != nil)
    }
}

struct CarPlayPlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: CarPlayPlayerSnapshot.widgetKind, provider: CarPlayPlayerProvider()) { entry in
            CarPlayPlayerWidgetView(entry: entry)
        }
        .configurationDisplayName("Koda Player")
        .description("A vinyl player with controls for Koda and CarPlay.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

private struct CarPlayPlayerWidgetView: View {
    let entry: CarPlayPlayerEntry
    @Environment(\.colorScheme) private var colorScheme
    private var playing: Bool { entry.player?.wantsToPlay == true }
    private var trackControlsEnabled: Bool { entry.player?.hasQueueItem != false }

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            VStack(spacing: 2) {
                vinyl.frame(width: size * 0.50, height: size * 0.50)
                if let title = entry.player?.nowPlayingTitle {
                    Text(title).privacySensitive()
                        .font(.caption2.weight(.semibold)).lineLimit(1)
                } else {
                    Text(entry.sharedContainerAvailable ? LocalizedStringKey("Koda Player") : LocalizedStringKey("Playback Controls"))
                        .font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
                }
                HStack(spacing: 0) {
                    control(.previous, symbol: "backward.end.fill", label: "Previous Track", enabled: trackControlsEnabled)
                    control(.toggle, symbol: entry.player == nil ? "playpause.fill" : playing ? "pause.fill" : "play.fill",
                            label: "Play or Pause",
                            enabled: entry.player.map { $0.hasQueueItem || $0.hasLikedSongs } ?? true)
                    control(.next, symbol: "forward.end.fill", label: "Next Track", enabled: trackControlsEnabled)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 4)
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: colorScheme == .dark
                ? [Color(white: 0.16), Color(white: 0.045)]
                : [Color(white: 0.96), Color(white: 0.83)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var vinyl: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.black, Color(white: 0.22), .black, Color(white: 0.18), .black],
                                          center: .center, startAngle: .degrees(30), endAngle: .degrees(390)))
            ForEach(0..<6) { groove in
                Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
                    .padding(CGFloat(groove) * 2 + 2)
            }
            GeometryReader { geometry in
                let label = geometry.size.width * 0.48
                Group {
                    if let data = entry.player?.artwork, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .privacySensitive()
                    } else {
                        ZStack {
                            Color(red: 0.24, green: 0.35, blue: 1)
                            Image(systemName: "music.note").font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: label, height: label)
                .clipShape(Circle())
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func control(_ action: CarPlayTransportAction, symbol: String, label: LocalizedStringKey,
                         enabled: Bool) -> some View {
        Button(intent: CarPlayTransportIntent(action)) {
            Image(systemName: symbol)
                .font(.system(size: action == .toggle ? 19 : 14, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

struct CarPlayLyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KodaLyricsActivityAttributes.self) { context in
            CarPlayLyricsActivityView(context: context)
                .activityBackgroundTint(Color(white: 0.075))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    CarPlayLyricsActivityView(context: context)
                }
            } compactLeading: {
                Image(systemName: "quote.bubble.fill").accessibilityLabel("Koda Lyrics")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .accessibilityHidden(true)
            } minimal: {
                Image(systemName: "quote.bubble.fill").accessibilityLabel("Koda Lyrics")
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct CarPlayLyricsActivityView: View {
    let context: ActivityViewContext<KodaLyricsActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        let small = family == .small
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .accessibilityHidden(true)
                Text(context.state.title).privacySensitive().lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.75))

            if context.state.status == .hidden {
                if small {
                    Text("Enable lyrics on your iPhone.")
                } else {
                    Button(intent: ShowCarPlayLyricsIntent(activityID: context.activityID)) {
                        Label("Show Lyrics", systemImage: "quote.bubble")
                    }
                    .buttonStyle(.bordered)
                }
            } else if context.isStale {
                Text("Waiting for playback update…")
            } else {
                switch context.state.status {
                case .hidden: EmptyView()
                case .loading: Text("Loading lyrics…")
                case .unavailable: Text("No synced lyrics")
                case .betweenLines: Text("Waiting for the next lyric…")
                case .line:
                    if let original = context.state.original {
                        Text(original).font(.headline).lineLimit(2).privacySensitive()
                    }
                    if let translation = context.state.translation {
                        Text(translation).font(.subheadline).lineLimit(2)
                            .foregroundStyle(.white.opacity(0.8)).privacySensitive()
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(small ? 7 : 12)
    }
}
#endif
