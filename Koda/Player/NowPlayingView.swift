import KodaCore
import SwiftUI
import UIKit

/// The full-screen player.
struct NowPlayingView: View {
    enum Panel: Equatable {
        case artwork, lyrics, queue
    }

    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeNowPlaying) private var closeNowPlaying
    @State private var panel: Panel = .artwork
    @Namespace private var artworkSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Room for the cover and the lyrics or queue side by side: a Mac window, an iPad in landscape.
    @State private var isWide = false
    /// The album's tall loop is ready to show.
    @State private var hasTallArt = false
    @State private var size: CGSize = .zero
    @State private var utility: PlayerUtility?
    @State private var lyricControlsExpanded = false

    private var lyricsChrome: LyricsPlayerChrome {
        LyricsPlayerChrome.resolve(isPortraitPhone: !isWide && UIDevice.current.userInterfaceIdiom == .phone && size.width < size.height,
            lyricsVisible: panel == .lyrics, translationVisible: app.settings.showsLyricsTranslation,
            enabled: app.settings.compactBilingualPlayer, controlsExpanded: lyricControlsExpanded)
    }

    private enum PlayerUtility: Hashable, Identifiable {
        case sound, audio, sleep(custom: Bool)
        #if !targetEnvironment(macCatalyst)
        case carPlayLyrics(Song)
        #endif
        var id: Self { self }
        var isSleepTimer: Bool { if case .sleep = self { return true }; return false }
    }

    /// With a tall loop the album's art moves in place of the square cover, as Music shows it:
    /// across the top of the one-column player while its cover page is open, and down the whole
    /// cover column of the wide one, beside lyrics or Up Next too.
    private var showsMotionArt: Bool { hasTallArt && (isWide || panel == .artwork) }

    /// The wide player's controls sit over the art's middle while lyrics or Up Next are beside it.
    private var sideArtWidth: CGFloat { SideMotionArt.width(in: size, beside: panel != .artwork) }

    var body: some View {
        ZStack {
            MeshBackground(palette: app.nowPlayingPalette.palette, isAnimating: player.wantsToPlay && app.settings.animatesPlayerBackground)
            if isWide, player.current != nil {
                SideMotionArt(song: player.current, isPlaying: player.wantsToPlay, beside: panel != .artwork) { hasTallArt = $0 }
                    .opacity(showsMotionArt ? 1 : 0)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: showsMotionArt)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: panel)
            }
            if !isWide, player.current != nil {
                // Kept while lyrics or the queue are open, paused, so coming back doesn't load it again.
                FullScreenMotionArt(song: player.current, isPlaying: player.wantsToPlay && panel == .artwork) { hasTallArt = $0 }
                    .opacity(showsMotionArt ? 1 : 0)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: showsMotionArt)
            }
            if isWide { wideLayout } else { tallLayout }
        }
        // Escape closes the player, in either layout, as it closes a full view anywhere on the Mac.
        .background {
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .background {
            if app.isNowPlayingPresented {
                LyricsTranslationDownloadHost(coordinator: app.lyricsTranslation)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 900 && $0.size.height >= 560 } action: { isWide = $0 }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: lyricsChrome == .full) { _, full in if full { lyricControlsExpanded = false } }
        .onChange(of: player.current == nil) { _, isEmpty in if isEmpty { close() } }
        .onChange(of: app.requestedPanel, initial: true) { _, requested in
            guard let requested else { return }
            app.requestedPanel = nil
            setPanel(requested)
        }
        .playlistPicker(whenOnTop: true)
        .sheet(item: $utility, onDismiss: { app.sleepTimer.clearError() }) { destination in
            NavigationStack {
                Group {
                    switch destination {
                    case .sound: AudioCenterView()
                    case .audio: AudioInformationView()
                    #if !targetEnvironment(macCatalyst)
                    case .carPlayLyrics(let song): CarPlayLyricsDelayView(song: song)
                    #endif
                    case .sleep(let custom): SleepTimerSettingsView(startsWithCustomDuration: custom)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { utility = nil }
                            .accessibilityIdentifier(destination.isSleepTimer ? "sleep.timer.done" : "player.utility.done")
                    }
                }
            }
            .appEnvironment(app)
        }
        .alert("Couldn't Set Sleep Timer", isPresented: Binding(
            get: { utility == nil && app.sleepTimer.errorMessage != nil },
            set: { if !$0 { app.sleepTimer.clearError() } })) {
            Button("OK", role: .cancel) { app.sleepTimer.clearError() }
        } message: {
            Text(app.sleepTimer.errorMessage ?? "")
        }
    }

    /// The phone's player: one column, the cover giving way to lyrics or the queue.
    private var tallLayout: some View {
            VStack(spacing: 0) {
                topBar
                switch panel {
                case .artwork:
                    Spacer(minLength: 12)
                    bigArtwork
                    Spacer(minLength: 12)
                    titleRow
                case .lyrics:
                    compactHeader
                    LyricsPanel()
                        .environment(\.lyricsPlayerChrome, lyricsChrome)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                case .queue:
                    compactHeader
                    QueuePanel()
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if case .failed(let message) = player.phase {
                    FailureBanner(message: message) { player.resume() }
                        .padding(.top, 12)
                }
                Scrubber(compact: lyricsChrome != .full)
                    .padding(.top, lyricsChrome == .full ? 20 : 2)
                TransportControls(compact: lyricsChrome == .compact,
                                  showsAdditionalControls: lyricsChrome == .expanded)
                    .padding(.vertical, lyricsChrome == .full ? 18 : 2)
                if lyricsChrome != .compact {
                    VolumeSlider()
                        .frame(height: lyricsChrome == .expanded ? 44 : 34)
                }
                bottomBar
                    .padding(.top, lyricsChrome == .full ? 14 : 2)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, lyricsChrome == .full ? 8 : 2)
            .animation(reduceMotion ? nil : .smooth(duration: 0.26), value: lyricsChrome)
            .overlay {
                if player.current != nil { floatingArtwork }
            }
    }

    /// The wide player: the cover and controls hold the left, and lyrics or the queue open
    /// beside them instead of over the cover, as Music does on the Mac and iPad.
    private var wideLayout: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 28)
                // Above the art, which reaches up behind it.
                .zIndex(1)
            HStack(spacing: 64) {
                VStack(spacing: 0) {
                    Spacer(minLength: 16)
                    bigArtwork
                    Spacer(minLength: 20)
                    titleRow
                    if case .failed(let message) = player.phase {
                        FailureBanner(message: message) { player.resume() }
                            .padding(.top, 12)
                    }
                    Scrubber()
                        .padding(.top, 16)
                    TransportControls()
                        .padding(.vertical, 12)
                    VolumeSlider()
                        .frame(height: 34)
                    bottomBar
                        .padding(.top, 10)
                    Spacer(minLength: 16)
                }
                .frame(maxWidth: 440)
                .overlay {
                    if player.current != nil { floatingArtwork }
                }
                // Over the art's middle: the art starts at the window's edge, the row 48 points in.
                .frame(width: showsMotionArt && panel != .artwork ? max(440, sideArtWidth - 48) : nil)
                if panel != .artwork {
                    Group {
                        if panel == .lyrics { LyricsPanel() } else { QueuePanel() }
                    }
                    .frame(maxWidth: 620, maxHeight: .infinity)
                    .padding(.vertical, 16)
                    .transition(.opacity.combined(with: .offset(x: 40)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 48)
            .padding(.bottom, 16)
        }
    }

    /// Presented, it dismisses; on the Mac, where it is a layer of the window, the window closes it.
    private func close() {
        if let closeNowPlaying { closeNowPlaying() } else { dismiss() }
    }

    /// The song was asked for and no sound has come yet.
    private var isLoadingSong: Bool { player.isBuffering && player.phase == .loading }

    private var topBar: some View {
        HStack {
            if Platform.isMac {
                // A page on the Mac: the toolbar's back button and Esc close it.
                Color.clear.frame(width: 44, height: 44)
            } else {
                // Bare symbols, as the transport's are: nothing behind them but a soft circle while held.
                Button { close() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TransportButtonStyle(diameter: 44))
                .accessibilityLabel("Close")
            }
            Spacer()
            if app.sleepTimer.isActive {
                SleepTimerPill { utility = .sleep(custom: $0) }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                // The phone's grab handle; on the Mac the player closes with its button or Esc.
                if !Platform.isMac {
                    Capsule().fill(.white.opacity(0.4)).frame(width: 36, height: 5)
                }
            }
            Spacer()
            if let song = player.current {
                Menu {
                    Section {
                        Button("Audio Information", systemImage: "waveform.path") { utility = .audio }
                        #if !targetEnvironment(macCatalyst)
                        Button("CarPlay Lyrics Delay", systemImage: "quote.bubble") { utility = .carPlayLyrics(song) }
                        #endif
                    }
                    SongMenuItems(song: song)
                    Section {
                        SleepTimerMenu { utility = .sleep(custom: $0) }
                        if panel == .lyrics { LyricsTimingMenu(songId: song.id) }
                    }
                    Section {
                        Button("Sound Center", systemImage: "slider.vertical.3") { utility = .sound }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TransportButtonStyle(diameter: 44))
                .menuIndicator(.hidden)
                .accessibilityLabel("More")
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.top, lyricsChrome == .full ? 8 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8), value: app.sleepTimer.isActive)
    }

    /// Where the big cover goes. The cover itself is `floatingArtwork`, drawn once over
    /// the whole screen, so it moves and resizes between here and the compact header
    /// rather than fading out of one and into the other.
    private var bigArtwork: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Color.clear
                .frame(width: side, height: side)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private var floatingArtwork: some View {
        let big = isWide || panel == .artwork
        let radius: CGFloat = big ? 18 : 8
        // The animated cover plays only at full size, as in Music, not in the lyrics and queue header.
        return MixingCovers(artwork: player.current?.artwork, mixing: player.mixing, cornerRadius: radius,
                            animated: big && !showsMotionArt ? player.current : nil, isPlaying: player.wantsToPlay)
            // While the song loads the cover waits a little small, then settles to full size
            // the moment sound starts. Nothing is drawn over the art itself.
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(big ? (isLoadingSong ? 0.2 : 0.35) : 0.25), radius: big ? 30 : 8, y: big ? 18 : 4)
            // The cover breathes back when paused, like a record lifted off.
            .scaleEffect(big && !reduceMotion ? (player.wantsToPlay ? (isLoadingSong ? 0.93 : 1) : 0.84) : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7), value: player.wantsToPlay)
            // No bounce: sound arriving is not a gesture with momentum behind it.
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: isLoadingSong)
            .matchedGeometryEffect(id: "artwork", in: artworkSpace, isSource: false)
            // The full-screen loop takes the square cover's place.
            .opacity(showsMotionArt && (isWide || panel == .artwork) ? 0 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: showsMotionArt)
            .onTapGesture { if !big { setPanel(.artwork) } }
            .accessibilityHidden(true)
    }

    private var titleRow: some View {
        songLines(title: .title3.bold(), byline: .title3)
    }

    /// The byline: one artist opens at a tap, several offer a choice.
    private func artistButton(font: Font) -> some View {
        ArtistLinks(line: player.current?.artistLine ?? "", artists: player.current?.artists ?? [], open: { app.open(.artist($0)) }) {
            MarqueeText(text: player.current?.artistLine ?? "", font: font)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    /// Title, byline and like button. A new song's lines fade in over the last one's, and
    /// lines too long to fit scroll sideways, as in Music.
    private func songLines(title: Font, byline: Font) -> some View {
        ZStack {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: player.current?.title ?? "", font: title)
                    artistButton(font: byline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let song = player.current {
                    LikeButton(song: song)
                }
            }
            .id(player.current?.id)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: player.current?.id)
    }

    /// The cover, title and like button in one row, above lyrics or the queue.
    private var compactHeader: some View {
        let compact = lyricsChrome != .full
        let cover: CGFloat = compact ? 40 : 64
        return HStack(spacing: compact ? 10 : 14) {
            Color.clear
                .frame(width: cover, height: cover)
                .matchedGeometryEffect(id: "artwork", in: artworkSpace)
            songLines(title: compact ? .subheadline.bold() : .headline,
                      byline: compact ? .footnote : .subheadline)
        }
        .padding(.vertical, compact ? 2 : 16)
    }

    /// Lyrics, AirPlay and the queue, as plain symbols like the transport above them, each
    /// centred in the same third of the width as the control above it.
    private var bottomBar: some View {
        HStack(spacing: 0) {
            panelButton(.lyrics, systemImage: "quote.bubble", activeImage: "quote.bubble.fill", label: "Lyrics")
                .frame(maxWidth: .infinity)
            AirPlayButton()
                .frame(width: 52, height: ControlMetrics.touchTarget)
                .frame(maxWidth: .infinity)
            panelButton(.queue, systemImage: "list.bullet", activeImage: "list.bullet", label: "Queue")
                .frame(maxWidth: .infinity)
            if lyricsChrome != .full {
                Button {
                    lyricControlsExpanded.toggle()
                } label: {
                    Image(systemName: lyricControlsExpanded ? "chevron.down" : "slider.horizontal.3")
                        .font(.body.weight(.semibold))
                        .frame(width: 52, height: ControlMetrics.touchTarget)
                }
                .buttonStyle(PlayerToggleStyle(isOn: lyricControlsExpanded))
                .sensoryFeedback(.selection, trigger: lyricControlsExpanded)
                .accessibilityLabel(lyricControlsExpanded ? Text("Collapse Playback Controls") : Text("Expand Playback Controls"))
                .accessibilityIdentifier("lyrics.player.controls")
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// `activeImage` is spelled out because not every symbol has a filled form; `list.bullet.fill` draws nothing.
    private func panelButton(_ target: Panel, systemImage: String, activeImage: String, label: LocalizedStringKey) -> some View {
        let active = panel == target
        return Button {
            setPanel(active ? .artwork : target)
        } label: {
            Image(systemName: active ? activeImage : systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 52, height: ControlMetrics.touchTarget)
        }
        .buttonStyle(PlayerToggleStyle(isOn: active))
        .sensoryFeedback(.selection, trigger: active)
        .accessibilityLabel(label)
        .accessibilityIdentifier(target == .lyrics ? "player.panel.lyrics" : "player.panel.queue")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// With Reduce Motion the panel changes in place, without the cover travelling across the screen.
    private func setPanel(_ next: Panel) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.85)) { panel = next }
    }
}

/// The cover's colours as a slowly moving mesh. It holds still while paused so it costs nothing then.
struct MeshBackground: View {
    let palette: Palette
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !isAnimating || reduceMotion || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            MeshGradient(width: 3, height: 3, points: points(t), colors: palette.mesh)
        }
        .overlay(Color.black.opacity(0.18))
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: palette)
    }

    private func points(_ t: TimeInterval) -> [SIMD2<Float>] {
        // Only the inner points drift; the corners and edges stay put so the mesh always fills the screen.
        let a = Float(sin(t * 0.35)) * 0.12, b = Float(cos(t * 0.27)) * 0.12
        return [
            [0, 0], [0.5 + a * 0.5, 0], [1, 0],
            [0, 0.5 + b * 0.5], [0.5 + a, 0.5 + b], [1, 0.5 - a * 0.5],
            [0, 1], [0.5 - b * 0.5, 1], [1, 1],
        ]
    }
}

struct LikeButton: View {
    let song: Song
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let liked = library.isLiked(song)
        Button {
            library.toggleLike(song)
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.title3.weight(.semibold))
                .foregroundStyle(liked ? Color.pink : .white)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: liked)
                .symbolEffectsRemoved(reduceMotion)
                // Drawn at the trailing edge of its tap area, so the heart lines up with the
                // end of the progress bar rather than sitting inside it.
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: liked)
        .accessibilityLabel(liked ? String(localized: "Unlike") : String(localized: "Like"))
    }
}

/// Previous, play/pause and next, each centred in a third of the width, the same thirds
/// the bottom bar uses, so the two rows line up. With skip buttons on (Settings), they sit
/// at either end, smaller, and the row is shared five ways.
struct TransportControls: View {
    var compact = false
    var showsAdditionalControls = false
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var backs = 0
    @State private var forwards = 0
    @State private var rewinds = 0
    @State private var advances = 0

    var body: some View {
        let settings = app.settings
        let interval = settings.skipInterval
        let showsSkips = !compact && (settings.showsSkipButtons || showsAdditionalControls)
        HStack(spacing: 0) {
            if showsSkips {
                skipButton(interval.backSymbol, label: "Back \(interval.rawValue) Seconds", size: 24, taps: rewinds) {
                    rewinds += 1
                    player.skip(by: -interval.seconds)
                }
                .frame(maxWidth: .infinity)
                .disabled(player.phase != .ready)
            }
            skipButton("backward.fill", label: "Previous", size: compact ? 21 : 32, taps: backs) {
                backs += 1
                player.previous()
            }
            .frame(maxWidth: .infinity)
            PlayPauseButton(size: compact ? 26 : 44)
                .frame(maxWidth: .infinity)
            skipButton("forward.fill", label: "Next", size: compact ? 21 : 32, taps: forwards) {
                forwards += 1
                player.next()
            }
            .frame(maxWidth: .infinity)
            if showsSkips {
                skipButton(interval.forwardSymbol, label: "Ahead \(interval.rawValue) Seconds", size: 24, taps: advances) {
                    advances += 1
                    player.skip(by: interval.seconds)
                }
                .frame(maxWidth: .infinity)
                .disabled(player.phase != .ready)
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: backs + forwards + rewinds + advances)
        .disabled(player.current == nil)
    }

    /// Only the pressed button answers: its own symbol bounces.
    private func skipButton(_ symbol: String, label: LocalizedStringKey, size: CGFloat = 32, taps: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .symbolEffect(.bounce.down, value: taps)
                .symbolEffectsRemoved(reduceMotion)
                // Up to 72 wide: five to a row still fits the narrowest iPhone.
                .frame(minWidth: ControlMetrics.touchTarget, maxWidth: 72,
                       minHeight: compact ? ControlMetrics.touchTarget : 60)
                .contentShape(.rect)
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }
}

/// A soft circle behind the symbol while it is held, as Music's transport buttons show.
private struct TransportButtonStyle: ButtonStyle {
    var diameter: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
                    .frame(width: diameter, height: diameter)
            }
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Every toggle in Now Playing: white with a dark symbol while on, plain or faintly filled
/// while off. Drawn by Koda rather than with an interactive glass layer, which can take the
/// touch for itself so the button's action never runs.
struct PlayerToggleStyle: ButtonStyle {
    var isOn: Bool
    /// The fill behind the symbol while off: none for a lone symbol, faint for a row of toggles.
    var offFill: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            // The page's ink when on, so it reads on Now Playing's dark colours and in a light panel.
            .foregroundStyle(isOn ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background {
                // Color.primary, not the hierarchical style: that follows the label's own ink,
                // which is the page colour while on.
                Capsule().fill(Color.primary.opacity(isOn ? (pressed ? 0.85 : 1) : offFill + (pressed ? 0.12 : 0)))
            }
            .contentShape(.capsule)
            .scaleEffect(pressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: pressed)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isOn)
    }
}

private struct FailureBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry", action: retry).font(.footnote.weight(.semibold)).buttonStyle(.glass)
        }
        .padding(12)
        .kodaGlassSurface(in: .rect(cornerRadius: 16))
    }
}

/// Time left on the sleep timer, at the top of Now Playing; a tap changes or ends it.
private struct SleepTimerPill: View {
    let openSettings: (Bool) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Menu {
            SleepTimerActions(openSettings: openSettings)
        } label: {
            TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { _ in
                let remaining = app.sleepTimer.label(at: .now)
                Label(remaining, systemImage: "moon.fill")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(remaining)
            }
            .kodaGlassSurface(in: .capsule, interactive: true)
            .frame(minHeight: ControlMetrics.touchTarget)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityIdentifier("sleep.timer.pill")
    }
}

/// Shift synced lyrics for the playing song, when they run ahead of or behind the singing.
private struct LyricsTimingMenu: View {
    let songId: String
    @Environment(Library.self) private var library

    var body: some View {
        let offset = library.lyricsOffset(for: songId)
        Menu {
            Button("Show Lyrics Earlier", systemImage: "backward") { library.setLyricsOffset(offset - 0.2, for: songId) }
            Button("Show Lyrics Later", systemImage: "forward") { library.setLyricsOffset(offset + 0.2, for: songId) }
            if offset != 0 {
                Button("Reset Timing", systemImage: "arrow.counterclockwise") { library.setLyricsOffset(0, for: songId) }
            }
        } label: {
            Label(offset == 0 ? String(localized: "Lyrics Timing") : String(format: String(localized: "Lyrics Timing (%+.1fs)"), locale: Locale.current, offset), systemImage: "timer")
        }
        // The menu stays open between steps, so the listener can nudge and watch the lyrics move.
        .menuActionDismissBehavior(.disabled)
    }
}

extension EnvironmentValues {
    /// Closes Now Playing when it is shown as part of a window rather than presented.
    @Entry var closeNowPlaying: (() -> Void)? = nil
}

extension EnvironmentValues {
    @Entry var lyricsPlayerChrome: LyricsPlayerChrome = .full
}
