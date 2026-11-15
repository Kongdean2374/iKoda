import AVFoundation
import KodaCore
import SwiftUI

/// The video carrying on after its page was left: the iPhone's tab bar accessory. The picture
/// keeps moving in a small frame beside the title; a tap goes back to the page, the buttons play,
/// pause and close. It takes over picture in picture while the page is away, so leaving the app
/// from here floats the video as it would from the page.
struct VideoMiniPlayer: View {
    let playback: VideoPlayback
    let open: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isInline: Bool { placement == .inline }

    var body: some View {
        if let video = playback.current {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    picture(video)
                        .frame(width: isInline ? 46 : 64, height: isInline ? 26 : 36)
                        .clipShape(.rect(cornerRadius: isInline ? 5 : 7, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(video.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !isInline {
                            Text(subtitle(video))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
                .onTapGesture(perform: open)

                if playback.isLoading {
                    ProgressView().frame(width: ControlMetrics.touchTarget, height: ControlMetrics.touchTarget)
                } else {
                    Button {
                        if playback.autoplayCountdown != nil { playback.playNext() } else { playback.togglePlay() }
                    } label: {
                        Image(systemName: playback.hasEnded && playback.autoplayCountdown == nil ? "arrow.counterclockwise"
                              : playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp))
                            .frame(width: ControlMetrics.touchTarget, height: ControlMetrics.touchTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
                }
                if !isInline {
                    Button {
                        withAnimation(reduceMotion ? nil : .smooth) { playback.stop() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: ControlMetrics.touchTarget, height: ControlMetrics.touchTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Close Video"))
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: String(localized: "Open Video"), open)
        }
    }

    @ViewBuilder
    private func picture(_ video: Video) -> some View {
        if playback.player.currentItem != nil {
            VideoSurface(player: playback.player, role: .mini, register: playback.register)
        } else {
            VideoThumbnail(video: video, cornerRadius: 0, width: 120, showsProgress: false)
        }
    }

    private func subtitle(_ video: Video) -> String {
        if let seconds = playback.autoplayCountdown, let next = playback.upNext {
            return String(localized: "Up next in \(seconds): \(next.title)")
        }
        return video.channel?.name ?? ""
    }
}

/// The Mac's bar for a video playing while its page is away, where the songs' player bar sits:
/// the picture, what it is, skip, play/pause and how far it's got, and close. A click on the
/// picture or title goes back to the page.
struct MacVideoBar: View {
    let playback: VideoPlayback
    let open: () -> Void
    @State private var width: CGFloat = 900
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let video = playback.current {
            HStack(spacing: 14) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        Group {
                            if playback.player.currentItem != nil {
                                VideoSurface(player: playback.player, role: .mini, register: playback.register)
                            } else {
                                VideoThumbnail(video: video, cornerRadius: 0, width: 160, showsProgress: false)
                            }
                        }
                        .frame(width: 80, height: 45)
                        .clipShape(.rect(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(video.title).font(.headline).lineLimit(1)
                            Text(playback.autoplayCountdown.map { String(localized: "Up next in \($0)") } ?? video.channel?.name ?? "")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 0, maxWidth: 360, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(BarButtonStyle(padding: 4))
                .help(String(localized: "Back to the Video"))

                Spacer(minLength: 8)

                HStack(spacing: 10) {
                    if !playback.isLive {
                        iconButton("gobackward.10", help: String(localized: "Back 10 Seconds")) { playback.skip(by: -10) }
                    }
                    iconButton(playback.isPlaying ? "pause.fill" : "play.fill", help: playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"), size: 22) {
                        if playback.autoplayCountdown != nil { playback.playNext() } else { playback.togglePlay() }
                    }
                    if !playback.isLive {
                        iconButton("goforward.10", help: String(localized: "Forward 10 Seconds")) { playback.skip(by: 10) }
                    }
                }

                // A narrow window gives the title the progress line's room.
                if !playback.isLive, playback.duration > 0, width >= 560 {
                    VideoBarProgress(playback: playback)
                        .frame(width: 140)
                }

                iconButton("xmark", help: String(localized: "Close Video"), size: 14, weight: .semibold, style: .secondary) {
                    withAnimation(reduceMotion ? nil : .smooth) { playback.stop() }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal, 12)
            .frame(height: 68)
            // The whole bar takes the click: glass alone doesn't, and a click between its
            // buttons went through to the page scrolled under it.
            .contentShape(.rect(cornerRadius: 22, style: .continuous))
            .kodaGlassSurface(in: .rect(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    /// As the songs' bar draws them: a 28 pt target, not just the symbol's own pixels.
    private func iconButton(_ symbol: String, help: String, size: CGFloat = 17, weight: Font.Weight = .medium,
                            style: HierarchicalShapeStyle = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(style)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(BarButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Keep the frequently changing clock out of the whole bar, its title and video surface.
private struct VideoBarProgress: View {
    let playback: VideoPlayback

    var body: some View {
        ProgressView(value: min(playback.time, playback.duration), total: playback.duration)
            .progressViewStyle(.linear)
            .tint(.primary)
            .accessibilityLabel(String(localized: "Playback position"))
    }
}
