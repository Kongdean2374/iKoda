import Foundation

/// Public route metadata supplied by AVAudioSession. A port UID is only a local matching
/// hint: it is not a hardware serial number and is not promised to survive reconnection.
public struct AudioOutputDevice: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case speaker, bluetooth, usb, wired, airPlay, other, unknown
        public var id: Self { self }
        public var title: String {
            let key: String
            switch self {
            case .speaker: key = "Built-in Speaker"
            case .bluetooth: key = "Bluetooth Audio"
            case .usb: key = "USB Audio"
            case .wired: key = "Wired Headphones"
            case .airPlay: key = "AirPlay"
            case .other: key = "Other Audio Output"
            case .unknown: key = "Unknown Audio Output"
            }
            return NSLocalizedString(key, bundle: KodaLocalization.bundle, comment: "Audio output type")
        }
    }

    public var kind: Kind
    public var name: String
    public var identifier: String?

    public init(kind: Kind, name: String, identifier: String? = nil) {
        self.kind = kind
        self.name = String(name.prefix(200))
        let clean = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.identifier = clean?.isEmpty == false ? clean : nil
    }
}

public struct AudioOutputRoute: Equatable, Sendable {
    public var outputs: [AudioOutputDevice]
    public init(outputs: [AudioOutputDevice] = []) { self.outputs = outputs }
    /// Multiple simultaneous outputs cannot safely be assigned one headphone's profile.
    public var singleOutput: AudioOutputDevice? { outputs.count == 1 ? outputs.first : nil }

    /// Order changes in a route notification are not a physical device change.
    var identity: [String] {
        outputs.map { "\($0.kind.rawValue):\($0.identifier ?? "name:" + $0.name)" }.sorted()
    }
}

public enum DeviceSoundTarget: Codable, Hashable, Sendable {
    case builtIn(EqualizerPreset)
    case profile(UUID)

    public func title(profiles: [SoundProfile]) -> String {
        switch self {
        case .builtIn(let preset): preset.title
        case .profile(let id): profiles.first { $0.id == id }?.name
            ?? NSLocalizedString("Sound Profile Unavailable", bundle: KodaLocalization.bundle, comment: "Deleted profile")
        }
    }

    public func resolve(profiles: [SoundProfile], current: SoundSettings) -> (settings: SoundSettings, preset: EqualizerPreset)? {
        switch self {
        case .builtIn(let preset):
            // Built-in EQ presets contain a curve only. Keep the listener's output ceiling;
            // a stored full sound profile, by contrast, explicitly includes its own ceiling.
            var settings = SoundSettings()
            settings.outputLimit = current.normalized.outputLimit
            return (settings, preset)
        case .profile(let id):
            guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
            return (profile.settings.normalized, profile.preset)
        }
    }
}

public struct DeviceSoundBinding: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: Codable, Hashable, Sendable {
        case device(kind: AudioOutputDevice.Kind, identifier: String)
        case type(AudioOutputDevice.Kind)

        public var kind: AudioOutputDevice.Kind {
            switch self { case .device(let kind, _): kind; case .type(let kind): kind }
        }
    }
    public let id: UUID
    public var scope: Scope
    public var name: String
    public var target: DeviceSoundTarget

    public init(id: UUID = UUID(), scope: Scope, name: String, target: DeviceSoundTarget) {
        self.id = id; self.scope = scope; self.name = String(name.prefix(200)); self.target = target
    }
}

public struct DeviceSoundSettings: Codable, Equatable, Sendable {
    public static let bindingLimit = 64
    public var enabled = false
    /// Nil means retain the user's current sound when a known output has no binding.
    public var fallback: DeviceSoundTarget?
    public var bindings: [DeviceSoundBinding] = []
    public init() {}

    public var normalized: Self {
        var value = self
        var scopes = Set<DeviceSoundBinding.Scope>()
        var ids = Set<UUID>()
        value.bindings = Array(bindings.filter { binding in
            guard binding.scope.kind != .unknown,
                  scopes.insert(binding.scope).inserted, ids.insert(binding.id).inserted else { return false }
            if case .device(_, let identifier) = binding.scope { return !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return true
        }.prefix(Self.bindingLimit))
        return value
    }

    public mutating func bind(_ binding: DeviceSoundBinding) {
        bindings.removeAll { $0.scope == binding.scope }
        bindings.append(binding)
        self = normalized
    }

    private enum CodingKeys: CodingKey { case enabled, fallback, bindings }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        fallback = try values.decodeIfPresent(DeviceSoundTarget.self, forKey: .fallback)
        bindings = try values.decodeIfPresent([DeviceSoundBinding].self, forKey: .bindings) ?? []
        self = normalized
    }
}

public enum DeviceSoundStore {
    private static let key = "koda.sound.devices.v1"
    public static func load(defaults: UserDefaults = .standard) -> DeviceSoundSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(DeviceSoundSettings.self, from: data) else { return .init() }
        return settings.normalized
    }
    public static func save(_ settings: DeviceSoundSettings, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(settings.normalized) { defaults.set(data, forKey: key) }
    }
}

/// No AVFoundation dependencies: deterministic route/override decisions and cancellation
/// tickets can be tested without opening an audio device or affecting other test players.
struct DeviceSoundPolicy: Sendable {
    private(set) var route = AudioOutputRoute()
    private(set) var manuallyOverridden = false
    private var generation: UInt64 = 0

    enum Selection: Equatable {
        case disabled, unavailable, manual, unchanged, apply(DeviceSoundTarget)
    }

    mutating func observe(_ route: AudioOutputRoute) -> UInt64? {
        let changed = self.route.identity != route.identity
        self.route = route
        guard changed else { return nil }
        manuallyOverridden = false
        generation &+= 1
        return generation
    }

    mutating func invalidate(resetOverride: Bool = false) -> UInt64 {
        generation &+= 1
        if resetOverride { manuallyOverridden = false }
        return generation
    }
    mutating func override() { manuallyOverridden = true; generation &+= 1 }
    func accepts(_ ticket: UInt64) -> Bool { generation == ticket }

    func selection(settings: DeviceSoundSettings) -> Selection {
        guard settings.enabled else { return .disabled }
        guard !manuallyOverridden else { return .manual }
        guard let output = route.singleOutput, output.kind != .unknown else { return .unavailable }
        if let identifier = output.identifier,
           let exact = settings.bindings.first(where: { $0.scope == .device(kind: output.kind, identifier: identifier) }) {
            return .apply(exact.target)
        }
        if let typed = settings.bindings.first(where: { $0.scope == .type(output.kind) }) { return .apply(typed.target) }
        if let fallback = settings.fallback { return .apply(fallback) }
        return .unchanged
    }
}

/// Decreases apply immediately for hearing/output safety; an automatic increase eases in.
/// The result remains below the new requested cap, including during an AutoMix overlap.
enum DeviceSoundOutputRamp {
    static func limit(from old: Float, to target: Float, progress: Double) -> Float {
        let target = target.isFinite ? min(1, max(0, target)) : 0
        let old = old.isFinite ? min(target, max(0, old)) : 0
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        let eased = Float(p * p * (3 - 2 * p))
        return min(target, old + (target - old) * eased)
    }
}
