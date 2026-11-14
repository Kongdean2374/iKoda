import Foundation

/// User-adjustable values, separate from the built-in preset identifier so older settings
/// retain their meaning. Values are normalized at decoding and before reaching the DSP.
public struct SoundSettings: Codable, Equatable, Sendable {
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public var enabled = true
    public var customEnabled = false
    public var gains = [Float](repeating: 0, count: 10)
    public var bassBoostDB: Float = 0
    public var preampDB: Float = 0
    /// A linear output gain ceiling belonging to Koda, not the device's system volume.
    public var outputLimit: Float = 1

    public init() {}

    public var normalized: Self {
        var value = self
        value.gains = (0..<10).map { Self.clamp(gains.indices.contains($0) ? gains[$0] : 0, -12...12, fallback: 0) }
        value.bassBoostDB = Self.clamp(bassBoostDB, 0...12, fallback: 0)
        value.preampDB = Self.clamp(preampDB, -24...12, fallback: 0)
        value.outputLimit = Self.clamp(outputLimit, 0...1, fallback: 1)
        return value
    }

    public func effectiveGains(preset: EqualizerPreset) -> [Float] {
        let value = normalized
        guard value.enabled else { return Array(repeating: 0, count: 10) }
        var curve = value.customEnabled ? value.gains : preset.gains
        // Bass boost shares the equalizer's existing sections; no second shelf is stacked.
        for (index, weight) in [Float(1), 0.8, 0.5, 0.2].enumerated() {
            curve[index] = min(12, max(-12, curve[index] + value.bassBoostDB * weight))
        }
        return curve
    }

    public func requiresProcessing(preset: EqualizerPreset) -> Bool {
        let value = normalized
        return value.enabled && (value.customEnabled || preset != .off || value.bassBoostDB > 0 || value.preampDB != 0)
    }

    /// Used at AVPlayer output, so the limit also applies on routes without an audio tap.
    public func outputGain(for volume: Float) -> Float {
        min(normalized.outputLimit, Self.clamp(volume, 0...1, fallback: 0))
    }

    /// Gain after headroom protection, excluding the user's output limit. A positive preamp
    /// can recover a cut curve's headroom, but cannot lift a full-scale signal above 0 dBFS.
    public func effectivePreampDB(preset: EqualizerPreset, sampleRate: Double = 48_000) -> Float {
        let design = Equalizer.soundDesign(normalized, preset: preset, sampleRate: sampleRate)
        return 20 * log10(max(design.preamp, Float.leastNormalMagnitude))
    }

    private static func clamp(_ value: Float, _ range: ClosedRange<Float>, fallback: Float) -> Float {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey { case enabled, customEnabled, gains, bassBoostDB, preampDB, outputLimit }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        customEnabled = try c.decodeIfPresent(Bool.self, forKey: .customEnabled) ?? false
        gains = try c.decodeIfPresent([Float].self, forKey: .gains) ?? Array(repeating: 0, count: 10)
        bassBoostDB = try c.decodeIfPresent(Float.self, forKey: .bassBoostDB) ?? 0
        preampDB = try c.decodeIfPresent(Float.self, forKey: .preampDB) ?? 0
        outputLimit = try c.decodeIfPresent(Float.self, forKey: .outputLimit) ?? 1
        self = normalized
    }
}

public struct SoundProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var settings: SoundSettings
    public var preset: EqualizerPreset

    public init(id: UUID = UUID(), name: String, settings: SoundSettings, preset: EqualizerPreset) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.settings = settings.normalized
        self.preset = preset
    }
}

/// A versioned, small UserDefaults document; it never rewrites the old koda.equalizer key.
public enum SoundSettingsStore {
    private static let key = "koda.sound.settings.v1"
    private static let profilesKey = "koda.sound.profiles.v1"
    public static let profileLimit = 32

    public static func load(defaults: UserDefaults = .standard) -> SoundSettings {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(SoundSettings.self, from: data) else { return SoundSettings() }
        return value.normalized
    }

    public static func save(_ settings: SoundSettings, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings.normalized) { defaults.set(data, forKey: key) }
    }

    public static func profiles(defaults: UserDefaults = .standard) -> [SoundProfile] {
        guard let data = defaults.data(forKey: profilesKey), let values = try? JSONDecoder().decode([SoundProfile].self, from: data) else { return [] }
        var seen = Set<UUID>()
        return Array(values.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }.prefix(profileLimit))
    }

    public static func saveProfiles(_ profiles: [SoundProfile], defaults: UserDefaults = .standard) {
        let values = Array(profiles.prefix(profileLimit)).map { SoundProfile(id: $0.id, name: $0.name, settings: $0.settings, preset: $0.preset) }.filter { !$0.name.isEmpty }
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: profilesKey) }
    }
}

/// The same PCM processing used by the audio tap and unit tests. New filter designs crossfade
/// over 30 ms instead of discarding filter history or restarting an AVPlayerItem.
struct SoundProcessor {
    private var stages = [Biquad]()
    private var previousStages = [Biquad]()
    private var gain: Float = 1
    private var previousGain: Float = 1
    private var remaining = 0
    private var rampFrames = 1
    var isTransitioning: Bool { remaining > 0 }

    mutating func configure(_ settings: SoundSettings, preset: EqualizerPreset, sampleRate: Double, smooth: Bool = true) {
        configure(design: Equalizer.soundDesign(settings.normalized, preset: preset, sampleRate: sampleRate), sampleRate: sampleRate, smooth: smooth)
    }

    mutating func configure(design: Equalizer.Design, sampleRate: Double, smooth: Bool = true) {
        previousStages = stages
        previousGain = gain
        if stages.count != design.sections.count { stages = Array(repeating: Biquad(), count: design.sections.count) }
        for i in stages.indices { stages[i].coefficients = design.sections[i] }
        gain = design.preamp
        let rate = sampleRate.isFinite && (8_000...384_000).contains(sampleRate) ? sampleRate : 48_000
        rampFrames = max(1, Int(rate * 0.03))
        remaining = smooth ? rampFrames : 0
    }

    mutating func run(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        var current = sample
        for i in stages.indices { current = stages[i].run(current) }
        current *= gain
        guard remaining > 0 else { return current.isFinite ? current : 0 }
        var previous = sample
        for i in previousStages.indices { previous = previousStages[i].run(previous) }
        previous *= previousGain
        let fraction = 1 - Float(remaining) / Float(rampFrames)
        remaining -= 1
        let result = previous + (current - previous) * fraction
        return result.isFinite ? result : 0
    }
}

/// Smooth protection for filter transients. Below 95% of the requested ceiling it is exactly
/// transparent; above the knee it approaches the ceiling without a hard-clipped corner.
enum SoundSafety {
    static func limit(_ sample: Float, ceiling: Float) -> Float {
        guard sample.isFinite, ceiling.isFinite, ceiling > 0 else { return 0 }
        let ceiling = min(1, ceiling)
        let magnitude = abs(sample), knee = ceiling * 0.95
        guard magnitude > knee else { return sample }
        let room = ceiling - knee
        let limited = knee + room * (1 - exp(-(magnitude - knee) / room))
        return sample < 0 ? -min(ceiling, limited) : min(ceiling, limited)
    }
}
