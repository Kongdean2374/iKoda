import SwiftUI

struct ImmersiveSettingsView: View {
    let close: () -> Void
    @Environment(AppModel.self) private var app
    @State private var resetAll = false

    private var profile: ImmersiveProfile {
        let prefs = app.settings.immersive
        return prefs[prefs.last]
    }

    private func setting<Value>(_ key: WritableKeyPath<ImmersiveProfile, Value>) -> Binding<Value> {
        Binding(get: { profile[keyPath: key] }, set: { value in
            let layout = app.settings.immersive.last
            app.settings.immersive[layout][keyPath: key] = value
        })
    }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(spacing: 0) {
            HStack {
                Text("Immersive Settings").font(.headline)
                Spacer()
                Button("Done", action: close).frame(minHeight: 44)
            }
            .padding(.horizontal, 18)
            Form {
                Section("Layout and Placement") {
                    Picker("Immersive Style", selection: $settings.immersive.last) {
                        ForEach(ImmersiveLayout.allCases) { Text($0.title).tag($0) }
                    }
                    #if !targetEnvironment(macCatalyst)
                    Toggle("Enter Automatically in Landscape", isOn: $settings.immersive.automaticLandscape)
                    #endif
                    Toggle("Show Song Information", isOn: setting(\.showsSong))
                    Toggle("Show Cover", isOn: setting(\.artwork))
                    if profile.artwork {
                        Picker("Cover Appearance", selection: setting(\.coverStyle)) {
                            ForEach(ImmersiveCover.allCases) { Text($0.title).tag($0) }
                        }
                        slider("Cover Size", \.artworkSize, 64...360, step: 1)
                        if settings.immersive.last == .theater || settings.immersive.last == .album {
                            Toggle("Place Cover Before Lyrics", isOn: setting(\.artworkBeforeLyrics))
                            slider("Lyrics Area", \.lyricsFraction, 0.35...0.8)
                        }
                    }
                    if settings.immersive.last == .spectrum {
                        Picker("Lyrics Position", selection: setting(\.lyricsPlacement)) {
                            ForEach([ImmersivePlacement.top, .bottom, .left, .right]) { Text($0.title).tag($0) }
                        }
                    }
                }
                Section("Lyrics Display") {
                    slider("Lyrics Text Size", \.originalSize, 20...80, step: 1)
                    slider("Lyrics Line Spacing", \.lineSpacing, 0...32, step: 1)
                    Picker("Lyrics Alignment", selection: setting(\.alignment)) {
                        ForEach(ImmersiveAlignment.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Visible Lines", selection: setting(\.visibleLines)) {
                        Text("Scrollable Lyrics").tag(0)
                        Text("Single Line").tag(1)
                        Text("Two Lines").tag(2)
                        ForEach([3, 5], id: \.self) { Text($0.formatted()).tag($0) }
                    }
                    Toggle("Word-by-Word Highlighting", isOn: setting(\.words))
                    Toggle("Dim Surrounding Lines", isOn: setting(\.fadeNeighbors))
                    Toggle("Show Chinese Translation", isOn: setting(\.translation))
                    if profile.translation {
                        slider("Translation Text Size", \.translationSize, 14...40, step: 1)
                        slider("Space Between Languages", \.translationSpacing, 0...20, step: 1)
                    }
                    if profile.visibleLines == 0 { Toggle("Follow Lyrics Automatically", isOn: setting(\.autoFollow)) }
                    Toggle("Allow Manual Scrolling", isOn: setting(\.manualScroll))
                    Toggle("Tap Lyrics to Seek", isOn: setting(\.seekFromLyrics))
                    ColorPicker("Lyrics Color", selection: setting(\.lyricColor.bindingColor), supportsOpacity: false)
                }
                Section("Audio Visualization") {
                    Toggle("Show Audio Visualization", isOn: setting(\.spectrumEnabled))
                    if profile.spectrumEnabled {
                        Picker("Visualization Type", selection: setting(\.spectrum)) {
                            ForEach(ImmersiveSpectrum.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Visualization Position", selection: setting(\.spectrumPlacement)) {
                            ForEach([ImmersivePlacement.top, .bottom, .left, .right, .background]) { Text($0.title).tag($0) }
                            if profile.artwork && profile.spectrum == .ring {
                                Text(ImmersivePlacement.aroundCover.title).tag(ImmersivePlacement.aroundCover)
                            }
                        }
                        Picker("Visualization Alignment", selection: setting(\.spectrumAlignment)) {
                            ForEach(ImmersiveAlignment.allCases) { Text($0.title).tag($0) }
                        }
                        slider("Sensitivity", \.sensitivity, 0.1...1)
                        slider("Visualization Height", \.amplitude, 0.1...1)
                        slider("Visualization Width", \.visualWidth, 0.3...1)
                        slider("Visualization Opacity", \.spectrumOpacity, 0.1...1)
                        if profile.spectrum == .ring { slider("Ring Radius", \.ringRadius, 0.25...0.8) }
                        if profile.spectrum != .waveform {
                            slider("Smoothing", \.smoothness, 0...0.9)
                            Picker("Frequency Bands", selection: setting(\.bands)) {
                                ForEach([32, 64, 128], id: \.self) { Text($0.formatted()).tag($0) }
                            }
                            Toggle("Reverse Frequency Order", isOn: setting(\.reverseBands))
                        }
                        if profile.spectrum == .bars || profile.spectrum == .mirrored { slider("Bar Spacing", \.gap, 0...10, step: 1) }
                        if profile.spectrum == .bars { Toggle("Mirror Bars Left and Right", isOn: setting(\.bilateralBands)) }
                        Toggle("Use Album Gradient", isOn: setting(\.spectrumGradient))
                        ColorPicker("Visualization Color", selection: setting(\.spectrumColor.bindingColor), supportsOpacity: false)
                        Picker("Frame Rate Limit", selection: setting(\.fps)) {
                            ForEach([30, 60], id: \.self) { fps in Text("\(fps) FPS").tag(fps) }
                        }
                    }
                }
                Section("Background and Appearance") {
                    Picker("Background", selection: setting(\.background)) {
                        ForEach(ImmersiveBackground.allCases) { Text($0.title).tag($0) }
                    }
                    if profile.background == .color {
                        ColorPicker("Background Color", selection: setting(\.backgroundColor.bindingColor), supportsOpacity: false)
                    }
                    if profile.background != .black { slider("Background Brightness", \.backgroundBrightness, 0.1...1) }
                    if profile.background == .artwork { slider("Background Blur", \.backgroundBlur, 4...65, step: 1) }
                }
                Section("Playback Controls") {
                    Picker("Hide Playback Controls", selection: setting(\.autoHide)) {
                        Text("Always Show").tag(0)
                        ForEach([3, 5, 10], id: \.self) { seconds in Text("\(seconds) Seconds").tag(seconds) }
                    }
                    Toggle("Controls at Top", isOn: setting(\.controlsOnTop))
                    Toggle("Show Volume", isOn: setting(\.volume))
                    Toggle("Show AirPlay", isOn: setting(\.airPlay))
                    Toggle("Show Favorite", isOn: setting(\.favorite))
                    Toggle("Show Queue", isOn: setting(\.queue))
                    Toggle("Show Skip Controls", isOn: setting(\.skips))
                    Toggle("Show Sleep Timer", isOn: setting(\.sleep))
                }
                Section("Display and Performance") {
                    Toggle("Keep Screen Awake", isOn: $settings.immersive.keepScreenAwake)
                    #if !targetEnvironment(macCatalyst)
                    Toggle("Use Custom Screen Brightness", isOn: $settings.immersive.customBrightness)
                    if settings.immersive.customBrightness {
                        Slider(value: $settings.immersive.brightness, in: 0.1...1, step: 0.05) { Text("Screen Brightness") }
                    }
                    #endif
                    Picker("Performance", selection: $settings.immersive.performance) {
                        ForEach(ImmersivePerformance.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Button("Reset Current Style", role: .destructive) { app.settings.immersive.resetCurrent() }
                    Button("Reset All Immersive Settings", role: .destructive) { resetAll = true }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog("Reset All Immersive Settings", isPresented: $resetAll, titleVisibility: .visible) {
            Button("Reset All Immersive Settings", role: .destructive) { app.settings.immersive = .init() }
        }
        .accessibilityIdentifier("immersive.settings.panel")
    }

    private func slider(_ title: LocalizedStringKey, _ path: WritableKeyPath<ImmersiveProfile, Double>,
                        _ range: ClosedRange<Double>, step: Double = 0.05) -> some View {
        VStack(alignment: .leading) {
            LabeledContent {
                Text(profile[keyPath: path], format: .number.precision(.fractionLength(0...2))).monospacedDigit()
            } label: { Text(title) }
            Slider(value: setting(path), in: range, step: step) { Text(title) }
        }
    }
}
