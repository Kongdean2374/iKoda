import SwiftUI

enum ImmersiveLayout: String, CaseIterable, Identifiable, Codable {
    case theater, album, spectrum, minimal
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .theater: "Lyrics Theater"
        case .album: "Album Showcase"
        case .spectrum: "Audio Visualization"
        case .minimal: "Minimal Lyrics"
        }
    }
}

enum ImmersivePlacement: String, CaseIterable, Identifiable, Codable {
    case top, bottom, left, right, background, aroundCover
    var id: Self { self }
    var opposite: Self {
        switch self {
        case .top: .bottom
        case .bottom: .top
        case .left: .right
        case .right: .left
        case .background, .aroundCover: self
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        case .background: "Background"
        case .aroundCover: "Around the Cover"
        }
    }
}
enum ImmersiveAlignment: String, CaseIterable, Identifiable, Codable {
    case leading, center, trailing
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .leading: "Left"
        case .center: "Center"
        case .trailing: "Right"
        }
    }
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

enum ImmersiveBackground: String, CaseIterable, Identifiable, Codable {
    case black, artwork, palette, gradient, color, motion
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .black: "Pure Black"
        case .artwork: "Blurred Artwork"
        case .palette: "Album Colors"
        case .gradient: "Static Gradient"
        case .color: "Custom Color"
        case .motion: "Soft Motion"
        }
    }
}

enum ImmersiveCover: String, CaseIterable, Identifiable, Codable {
    case square, record, glass
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .square: "Square Cover"
        case .record: "Vinyl Record"
        case .glass: "Glass Frame"
        }
    }
}

enum ImmersiveSpectrum: String, CaseIterable, Identifiable, Codable {
    case bars, mirrored, waveform, ring
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .bars: "Vertical Spectrum"
        case .mirrored: "Symmetric Spectrum"
        case .waveform: "PCM Waveform"
        case .ring: "Circular Spectrum"
        }
    }
}

enum ImmersiveSpectrumTint: String, CaseIterable, Identifiable, Codable {
    case fixed, album, gradient
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .fixed: "Custom Color"
        case .album: "Album Colors"
        case .gradient: "Album Gradient"
        }
    }
}

enum ImmersivePerformance: String, CaseIterable, Identifiable, Codable {
    case efficient, balanced, detailed
    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .efficient: "Power Saving"
        case .balanced: "Balanced"
        case .detailed: "High Quality"
        }
    }
}

struct ImmersiveColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var color: Color {
        Color(red: min(1, max(0, red)), green: min(1, max(0, green)), blue: min(1, max(0, blue)))
    }
    var bindingColor: Color {
        get { color }
        set {
            var r: CGFloat = 0; var g: CGFloat = 0; var b: CGFloat = 0; var a: CGFloat = 0
            if UIColor(newValue).getRed(&r, green: &g, blue: &b, alpha: &a) {
                self = .init(red: Double(r), green: Double(g), blue: Double(b))
            }
        }
    }
}

struct ImmersiveProfile: Codable, Equatable {
    var originalSize = 50.0
    var translationSize = 22.0
    var lineSpacing = 14.0
    var translationSpacing = 8.0
    /// Zero is the full scrollable transcript.
    var visibleLines = 3
    var alignment = ImmersiveAlignment.leading
    var words = true
    var fadeNeighbors = true
    var translation = true
    var autoFollow = true
    var manualScroll = true
    var seekFromLyrics = true
    var artwork = true
    var coverStyle = ImmersiveCover.square
    var artworkSize = 185.0
    var artworkBeforeLyrics = false
    var lyricsFraction = 0.70
    var showsSong = true
    var spectrumEnabled = false
    var spectrum = ImmersiveSpectrum.bars
    var spectrumPlacement = ImmersivePlacement.bottom
    var lyricsPlacement = ImmersivePlacement.bottom
    var sensitivity = 0.65
    var amplitude = 0.80
    var smoothness = 0.45
    var bands = 64
    var gap = 3.0
    var visualWidth = 0.90
    var spectrumAlignment = ImmersiveAlignment.center
    var reverseBands = false
    var bilateralBands = false
    var ringRadius = 0.58
    var spectrumOpacity = 0.85
    var spectrumTint = ImmersiveSpectrumTint.gradient
    var spectrumColor = ImmersiveColor(red: 0.55, green: 0.78, blue: 1)
    var fps = 60
    var background = ImmersiveBackground.palette
    var backgroundColor = ImmersiveColor(red: 0.13, green: 0.15, blue: 0.32)
    var lyricColor = ImmersiveColor(red: 1, green: 1, blue: 1)
    var backgroundBrightness = 0.65
    var backgroundBlur = 32.0
    var autoHide = 5
    var controlsOnTop = false
    var volume = false
    var airPlay = true
    var favorite = false
    var queue = false
    var skips = false
    var sleep = false

    static func initial(for layout: ImmersiveLayout) -> Self {
        var profile = Self()
        switch layout {
        case .theater: break
        case .album:
            profile.artworkBeforeLyrics = true
            profile.artworkSize = 260
            profile.lyricsFraction = 0.50
            profile.originalSize = 37
        case .spectrum:
            profile.spectrumEnabled = true
            profile.spectrumPlacement = .top
            profile.artwork = false
            profile.visibleLines = 1
            profile.originalSize = 30
            profile.alignment = .center
        case .minimal:
            profile.artwork = false
            profile.originalSize = 66
            profile.alignment = .center
            profile.background = .black
        }
        return profile
    }

    mutating func normalize() {
        func safe(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        originalSize = safe(originalSize, 20...80, 50)
        translationSize = safe(translationSize, 14...40, 22)
        lineSpacing = safe(lineSpacing, 0...32, 14)
        translationSpacing = safe(translationSpacing, 0...20, 8)
        artworkSize = safe(artworkSize, 64...360, 185)
        lyricsFraction = safe(lyricsFraction, 0.35...0.8, 0.70)
        sensitivity = safe(sensitivity, 0.1...1, 0.65)
        amplitude = safe(amplitude, 0.1...1, 0.8)
        smoothness = safe(smoothness, 0...0.9, 0.45)
        gap = safe(gap, 0...10, 3)
        visualWidth = safe(visualWidth, 0.3...1, 0.9)
        ringRadius = safe(ringRadius, 0.25...0.8, 0.58)
        spectrumOpacity = safe(spectrumOpacity, 0.1...1, 0.85)
        backgroundBrightness = safe(backgroundBrightness, 0.1...1, 0.65)
        backgroundBlur = safe(backgroundBlur, 4...65, 32)
        if ![0, 1, 2, 3, 5].contains(visibleLines) { visibleLines = 3 }
        if ![32, 64, 128].contains(bands) { bands = 64 }
        if ![30, 60].contains(fps) { fps = 60 }
        if ![0, 3, 5, 10].contains(autoHide) { autoHide = 5 }
        if spectrumPlacement == .aroundCover && (!artwork || spectrum != .ring) { spectrumPlacement = .bottom }
    }
}

struct ImmersivePreferences: Codable, Equatable {
    var last = ImmersiveLayout.theater
    var automaticLandscape = false
    var keepScreenAwake = true
    var customBrightness = false
    var brightness = 0.5
    var performance = ImmersivePerformance.balanced
    private var profiles: [String: ImmersiveProfile] = [:]

    private enum CodingKeys: String, CodingKey {
        case last, automaticLandscape, keepScreenAwake, customBrightness, brightness, performance, profiles
    }

    private enum ProfileKey: String, CodingKey { case theater, album, spectrum, minimal }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        last = (try? container.decode(ImmersiveLayout.self, forKey: .last)) ?? .theater
        automaticLandscape = (try? container.decode(Bool.self, forKey: .automaticLandscape)) ?? false
        keepScreenAwake = (try? container.decode(Bool.self, forKey: .keepScreenAwake)) ?? true
        customBrightness = (try? container.decode(Bool.self, forKey: .customBrightness)) ?? false
        brightness = (try? container.decode(Double.self, forKey: .brightness)) ?? 0.5
        performance = (try? container.decode(ImmersivePerformance.self, forKey: .performance)) ?? .balanced
        if let saved = try? container.nestedContainer(keyedBy: ProfileKey.self, forKey: .profiles) {
            for layout in ImmersiveLayout.allCases {
                if let key = ProfileKey(rawValue: layout.rawValue),
                   let profile = try? saved.decode(ImmersiveProfile.self, forKey: key) {
                    self[layout] = profile
                }
            }
        }
    }

    subscript(_ layout: ImmersiveLayout) -> ImmersiveProfile {
        get { profiles[layout.rawValue] ?? .initial(for: layout) }
        set {
            var normalized = newValue
            normalized.normalize()
            profiles[layout.rawValue] = normalized
        }
    }

    mutating func resetCurrent() { profiles[last.rawValue] = nil }

    static func restore(_ data: Data?) -> Self {
        guard let data, var preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if !preferences.brightness.isFinite { preferences.brightness = 0.5 }
        preferences.brightness = min(1, max(0.1, preferences.brightness))
        return preferences
    }
}
