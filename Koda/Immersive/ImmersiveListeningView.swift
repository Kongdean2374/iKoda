import KodaCore
import SwiftUI
import UIKit

struct ImmersiveListeningView: View {
    let automaticallyOpened: Bool
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var screen = ImmersiveScreenController()
    @State private var display: UIScreen?
    @State private var lock = ImmersiveInteractionLock()
    @State private var overlayTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var showSettings = false
    @State private var tool: Tool?
    @State private var pressure = false
    @State private var constrained = false
    @State private var visuals = ImmersiveVisualFrame()
    @State private var landscape = false
    @State private var appeared = false
    @State private var scrubbing = false
    @State private var visualListener = UUID()

    private enum Tool: String, Identifiable {
        case queue, sleep, sources
        var id: String { rawValue }
    }

    private var preferences: ImmersivePreferences { app.settings.immersive }
    private var profile: ImmersiveProfile { preferences[preferences.last] }
    private var awake: Bool { appeared && scene == .active && player.sleepTimerState.completion == nil }
    private var drawing: Bool {
        awake && profile.spectrumEnabled && player.wantsToPlay && !player.isBuffering
            && player.current != nil && !pressure
    }
    private var constrainedGraphics: Bool { constrained || preferences.performance == .efficient }
    private var fps: Int { constrainedGraphics ? 30 : profile.fps }

    private struct Work: Equatable {
        var active: Bool
        var track: String?
        var seek: UInt64
        var route: AudioOutputRoute
        var fps: Int
        var smoothing: Double
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            ZStack {
                background
                presentation(wide: wide, size: geometry.size)
                    .overlay(alignment: .bottom) {
                        if !controlsVisible || lock.isLocked { ImmersivePassiveProgress() }
                    }
                    .padding(.horizontal, wide ? 25 : 14)
                    .padding(.vertical, wide ? 9 : 14)
                    .accessibilityHidden(lock.isLocked)
                    .allowsHitTesting(!lock.isLocked)
                if lock.isLocked {
                    lockOverlay
                } else {
                    if controlsVisible || showSettings { controls(wide: wide) }
                    if showSettings { settingsOverlay(wide: wide) }
                }
            }
            .onChange(of: wide, initial: true) { _, value in
                landscape = value
                exitIfPortrait()
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .background {
            ImmersiveDisplayProbe { display = $0; updateScreen() }
                .accessibilityHidden(true)
        }
        .background {
            if !lock.isLocked && tool == nil && !showSettings {
                LyricsTranslationDownloadHost(coordinator: app.lyricsTranslation)
            }
        }
        .accessibilityIdentifier("immersive.player")
        .interactiveDismissDisabled()
        .persistentSystemOverlays(controlsVisible && !lock.isLocked ? .visible : .hidden)
        .onAppear {
            appeared = true
            updateSystemLimits()
            app.settings.immersiveTranslationsVisible = profile.translation
            updateScreen()
            scheduleHide()
        }
        .onDisappear {
            appeared = false
            app.settings.immersiveTranslationsVisible = false
            overlayTask?.cancel()
            lock = .init()
            player.setAudioVisualization(false, listener: visualListener)
            updateScreen()
        }
        .onChange(of: profile.translation) { _, value in app.settings.immersiveTranslationsVisible = value }
        .onChange(of: awake) { _, value in
            updateScreen()
            if value {
                lock.hideIfExpired(at: .now)
                scheduleHide()
            }
        }
        .onChange(of: preferences.keepScreenAwake) { _, _ in updateScreen() }
        .onChange(of: preferences.customBrightness) { _, _ in updateScreen() }
        .onChange(of: preferences.brightness) { _, _ in updateScreen() }
        .onChange(of: profile.autoHide) { _, _ in scheduleHide() }
        .onChange(of: voiceOver) { _, _ in scheduleHide() }
        .onChange(of: player.sleepTimerState.completion) { _, completion in
            if completion != nil { overlayTask?.cancel(); close() }
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in updateSystemLimits() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in updateSystemLimits() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            pressure = true
            visuals.frame = nil
        }
        .onChange(of: player.current?.id) { _, _ in updateSystemLimits() }
        .task(id: Work(active: drawing, track: player.current?.id, seek: player.audioVisualizationSeek,
                       route: player.audioOutputRoute, fps: fps, smoothing: profile.smoothness)) {
            let current = player.current?.id
            let seek = player.audioVisualizationSeek
            let route = player.audioOutputRoute
            visuals.frame = nil
            player.setAudioVisualization(drawing, listener: visualListener)
            guard drawing else { return }
            let sampler = ImmersiveAudioSampler()
            let interval = Duration.microseconds(1_000_000 / fps)
            let smoothing = profile.smoothness
            let listener = visualListener
            var lastUsable = ContinuousClock.now
            while !Task.isCancelled {
                let result: AudioVisualizationFrame?
                if let input = player.audioVisualizationInput {
                    result = await sampler.read(input, near: player.position(), smooth: smoothing)
                } else { result = nil }
                guard !Task.isCancelled, player.current?.id == current, player.audioVisualizationSeek == seek,
                      player.audioOutputRoute == route, drawing else { return }
                if result != nil {
                    lastUsable = .now
                    visuals.frame = result
                } else {
                    if visuals.frame != nil { visuals.frame = nil }
                    if lastUsable.duration(to: .now) > .seconds(4) {
                        player.setAudioVisualization(false, listener: listener)
                        return
                    }
                }
                do { try await Task.sleep(for: result == nil ? .milliseconds(100) : interval) } catch { return }
            }
        }
        .sheet(item: $tool, onDismiss: scheduleHide) { tool in
            NavigationStack {
                Group {
                    switch tool {
                    case .queue: QueuePanel().padding()
                    case .sleep: SleepTimerSettingsView(startsWithCustomDuration: false)
                    case .sources: LyricsVersionsView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { self.tool = nil } }
                }
            }
            .appEnvironment(app)
        }
    }

    private func updateSystemLimits() {
        let system = ProcessInfo.processInfo
        constrained = system.isLowPowerModeEnabled || system.thermalState != .nominal
        pressure = system.thermalState == .serious || system.thermalState == .critical
    }

    private func updateScreen() {
        screen.update(screen: display, active: awake, keepAwake: preferences.keepScreenAwake,
                      brightness: preferences.customBrightness ? preferences.brightness : nil)
    }

    private func exitIfPortrait() {
        if automaticallyOpened, !landscape, !lock.isLocked, !showSettings, tool == nil { close() }
    }

    private func scheduleHide() {
        overlayTask?.cancel()
        if lock.isLocked, let expiry = lock.revealUntil {
            overlayTask = Task {
                do { try await Task.sleep(for: max(.zero, ContinuousClock.now.duration(to: expiry))) } catch { return }
                transition { lock.hideIfExpired(at: .now) }
            }
        } else if !lock.isLocked, profile.autoHide > 0, !showSettings, tool == nil, !voiceOver, !scrubbing {
            overlayTask = Task {
                do { try await Task.sleep(for: .seconds(profile.autoHide)) } catch { return }
                transition { controlsVisible = false }
            }
        }
    }

    private func transition(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18), change)
    }

    private var lockOverlay: some View {
        ZStack(alignment: .trailing) {
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { revealLock() }
                .accessibilityLabel("Show Unlock Button")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { revealLock() }
                .accessibilityHidden(lock.revealUntil != nil)
                .accessibilityIdentifier("immersive.lock.shield")
            if lock.revealUntil != nil {
                Button {
                    if lock.unlock(at: .now) {
                        controlsVisible = true
                        scheduleHide()
                        exitIfPortrait()
                    } else { revealLock() }
                } label: {
                    Image(systemName: "lock.fill").font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(width: 48, height: 48)
                        .background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 12)
                .accessibilityLabel("Unlock Touch Controls")
                .accessibilityIdentifier("immersive.lock.unlock")
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func revealLock() {
        lock.hideIfExpired(at: .now)
        guard lock.revealUntil == nil else { return }
        transition { lock.showIfHidden(at: .now) }
        scheduleHide()
    }

    private var background: some View {
        ZStack {
            Color.black
            switch profile.background {
            case .black: Color.clear
            case .artwork:
                if !reduceTransparency {
                    GeometryReader { geometry in
                        ArtworkView(artwork: player.current?.artwork, size: max(geometry.size.width, geometry.size.height), fillsFrame: true)
                            .blur(radius: profile.backgroundBlur)
                            .scaleEffect(1.12)
                    }
                }
            case .palette:
                LinearGradient(colors: app.nowPlayingPalette.palette.mesh, startPoint: .topLeading, endPoint: .bottomTrailing)
            case .gradient: LinearGradient(colors: [Color.indigo, Color.black], startPoint: .top, endPoint: .bottom)
            case .color: profile.backgroundColor.color
            case .motion:
                MeshBackground(palette: app.nowPlayingPalette.palette,
                               isAnimating: awake && player.wantsToPlay && !constrainedGraphics && !reduceMotion)
            }
            Color.black.opacity(max(0.44, 1 - profile.backgroundBrightness))
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { transition { controlsVisible = true }; scheduleHide() }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func presentation(wide: Bool, size: CGSize) -> some View {
        let widthLimit = max(100, size.width - (wide ? 50 : 28))
        let coverLimit = CGFloat(max(64, min(profile.artworkSize, wide ? size.height * 0.59 : size.width * 0.58)))
        let lyric = ImmersiveLyricDisplay(profile: profile, wide: wide)
        let art = cover(size: coverLimit)
        VStack(spacing: 8) {
            if profile.showsSong, preferences.last != .album { songDescription }
            switch preferences.last {
            case .theater:
                if profile.artwork {
                    let layout = wide ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 4))
                    layout {
                        if profile.artworkBeforeLyrics { art }
                        lyric.frame(width: wide ? widthLimit * profile.lyricsFraction : nil)
                        if !profile.artworkBeforeLyrics { art }
                    }
                } else { lyric }
            case .album:
                let layout = wide ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 10))
                layout {
                    if profile.artworkBeforeLyrics { album(art) }
                    lyric.frame(width: wide && profile.artwork ? widthLimit * profile.lyricsFraction : nil)
                    if !profile.artworkBeforeLyrics { album(art) }
                }
            case .spectrum, .minimal:
                if profile.artwork { art.frame(maxHeight: wide ? 120 : 145) }
                if preferences.last == .spectrum && profile.spectrumEnabled && profile.spectrumPlacement != .aroundCover {
                    if profile.spectrumPlacement == .background {
                        lyric.background { spectrum.opacity(0.54) }
                    } else {
                        let beside = wide && [.left, .right].contains(profile.spectrumPlacement)
                        let layout = beside ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(spacing: 8))
                        layout {
                            let lyricsFirst = [.bottom, .right].contains(profile.spectrumPlacement)
                            if lyricsFirst { lyric }
                            spectrum.frame(maxWidth: .infinity, maxHeight: .infinity)
                                .layoutPriority(2)
                            if !lyricsFirst { lyric }
                        }
                    }
                } else { lyric }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaPadding(.vertical, wide ? 36 : 58)
        .background {
            if profile.spectrumEnabled, profile.spectrumPlacement == .background, preferences.last != .spectrum {
                spectrum.opacity(0.52)
            }
        }
        .overlay(alignment: edgeAlignment) {
            if profile.spectrumEnabled, preferences.last != .spectrum,
               profile.spectrumPlacement != .aroundCover, profile.spectrumPlacement != .background {
                spectrum.frame(width: [.left, .right].contains(profile.spectrumPlacement) ? 80 : nil,
                               height: [.top, .bottom].contains(profile.spectrumPlacement) ? 44 : nil)
            }
        }
    }

    private var edgeAlignment: Alignment {
        switch profile.spectrumPlacement {
        case .top: .top
        case .left: .leading
        case .right: .trailing
        default: .bottom
        }
    }

    private var spectrum: some View {
        ImmersiveVizLayer(model: visuals, profile: profile, limit: constrainedGraphics ? 32 : preferences.performance == .detailed ? 128 : 64,
                         active: drawing, albumColor: app.nowPlayingPalette.palette.accent)
    }

    private func album<Content: View>(_ art: Content) -> some View {
        VStack(spacing: 8) {
            if profile.artwork { art }
            if profile.showsSong { songDescription }
        }
    }

    private func cover(size: CGFloat) -> some View {
        ZStack {
            if profile.spectrumEnabled && profile.spectrum == .ring && profile.spectrumPlacement == .aroundCover {
                spectrum.frame(width: size, height: size)
            }
            let coverSize = profile.spectrumEnabled && profile.spectrum == .ring && profile.spectrumPlacement == .aroundCover
                ? size * profile.ringRadius * 0.86 : size
            switch profile.coverStyle {
            case .square: ArtworkView(artwork: player.current?.artwork, size: coverSize, cornerRadius: 13)
            case .glass:
                ArtworkView(artwork: player.current?.artwork, size: coverSize * 0.86, cornerRadius: 15)
                    .padding(7).glassEffect(in: .rect(cornerRadius: 18))
            case .record:
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                               paused: !awake || !player.wantsToPlay || reduceMotion || constrainedGraphics)) { _ in
                    ZStack {
                        Circle().fill(.black.opacity(0.84))
                        ForEach(1..<6) { index in
                            Circle().strokeBorder(.white.opacity(0.13), lineWidth: 1).padding(Double(index) * coverSize / 16)
                        }
                        ArtworkView(artwork: player.current?.artwork, size: coverSize * 0.57, circle: true)
                            .rotationEffect(.degrees(reduceMotion || constrainedGraphics ? 0 : player.position() * 24))
                        Circle().fill(.black).frame(width: 6, height: 6)
                    }
                    .frame(width: coverSize, height: coverSize)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var songDescription: some View {
        VStack(spacing: 2) {
            if let song = player.current {
                Text(song.title).font(.headline.weight(.semibold)).lineLimit(2)
                Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func settingsOverlay(wide: Bool) -> some View {
        ZStack(alignment: .trailing) {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismissSettings() }
            ImmersiveSettingsView(close: dismissSettings)
                .frame(maxWidth: wide ? 340 : 360)
                .frame(maxHeight: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .padding(10)
        }
        .transition(.opacity)
    }

    private func dismissSettings() {
        transition { showSettings = false }
        scheduleHide()
        exitIfPortrait()
    }

    private func controls(wide: Bool) -> some View {
        VStack(spacing: 2) {
            HStack {
                icon("Close", "xmark") { close() }
                Spacer()
                Menu {
                    Picker("Immersive Style", selection: Binding(get: { preferences.last }, set: { app.settings.immersive.last = $0; scheduleHide() })) {
                        ForEach(ImmersiveLayout.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Immersive Settings", systemImage: "slider.horizontal.3") {
                        transition { showSettings = true }
                        overlayTask?.cancel()
                    }
                    Button("Lyrics Sources", systemImage: "square.stack") { tool = .sources }
                    Button("Exit Immersive Listening", systemImage: "xmark") { close() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Immersive Settings")
                .accessibilityIdentifier("immersive.settings")
            }
            if !profile.controlsOnTop { Spacer(minLength: 0) }
            VStack(spacing: 0) {
                Scrubber(compact: true, onScrubbing: { active in
                    scrubbing = active
                    scheduleHide()
                })
                ViewThatFits(in: .horizontal) {
                    transportButtons
                    ScrollView(.horizontal) { transportButtons }.scrollIndicators(.hidden)
                }
                if profile.volume { VolumeSlider().frame(height: 34) }
            }
            .padding(.horizontal, wide ? 56 : 8)
            if profile.controlsOnTop { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 9)
        .overlay(alignment: .trailing) {
            icon("Lock Touch Controls", "lock.open") {
                guard tool == nil, !showSettings, !scrubbing else { return }
                lock.lock(at: .now)
                controlsVisible = false
                scheduleHide()
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("immersive.lock.lock")
        }
        .transition(.opacity)
    }

    private var transportButtons: some View {
        HStack(spacing: 3) {
            if profile.skips { icon("Jump Back", app.settings.skipInterval.backSymbol) { player.seek(to: player.position() - app.settings.skipInterval.seconds) } }
            icon("Previous", "backward.fill") { player.previous() }
            icon(player.wantsToPlay ? "Pause" : "Play", player.wantsToPlay ? "pause.fill" : "play.fill") {
                player.togglePlayPause(from: "Immersive Listening")
            }.accessibilityIdentifier("immersive.transport")
            icon("Next", "forward.fill") { player.next() }
            if profile.skips { icon("Jump Forward", app.settings.skipInterval.forwardSymbol) { player.seek(to: player.position() + app.settings.skipInterval.seconds) } }
            if profile.airPlay { AirPlayButton().frame(width: 44, height: 44) }
            if profile.favorite, let song = player.current {
                icon("Like", library.isLiked(song) ? "heart.fill" : "heart") { library.toggleLike(song) }
            }
            if profile.queue { icon("Queue", "list.bullet") { tool = .queue } }
            if profile.sleep { icon("Sleep Timer", "moon") { tool = .sleep } }
        }
        .glassEffect(in: Capsule())
    }

    private func icon(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            scheduleHide()
            action()
        } label: {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

@MainActor @Observable private final class ImmersiveVisualFrame {
    var frame: AudioVisualizationFrame?
}

private struct ImmersiveVizLayer: View {
    let model: ImmersiveVisualFrame
    let profile: ImmersiveProfile
    let limit: Int
    let active: Bool
    let albumColor: Color

    var body: some View {
        ImmersiveSpectrumView(frame: model.frame, profile: profile, bandLimit: limit, active: active, albumColor: albumColor)
    }
}

private struct ImmersivePassiveProgress: View {
    @Environment(Player.self) private var player
    @Environment(\.scenePhase) private var scene

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: scene != .active || !player.wantsToPlay)) { clock in
            GeometryReader { geometry in
                let fraction = min(1, max(0, player.position(at: clock.date) / max(1, player.duration)))
                Capsule().fill(.white.opacity(0.22))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.62)).frame(width: fraction * geometry.size.width)
                    }
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 15)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
