import Foundation
import Testing
@testable import KodaCore

struct DeviceSoundTests {
    private let headphones = AudioOutputDevice(kind: .bluetooth, name: "My headphones", identifier: "local-port-a")
    private func assigned(_ scope: DeviceSoundBinding.Scope, _ target: DeviceSoundTarget) -> DeviceSoundBinding {
        .init(scope: scope, name: "My assignment", target: target)
    }

    @Test func deviceAndTypeAssignmentsRoundTripWithoutChangingOlderSoundSettings() throws {
        let domain = "koda.device-sound.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var old = SoundSettings(); old.preampDB = -4; old.outputLimit = 0.3
        SoundSettingsStore.save(old, defaults: defaults)
        defaults.set("rock", forKey: "koda.equalizer")
        var settings = DeviceSoundSettings()
        settings.enabled = true
        settings.fallback = .builtIn(.off)
        settings.bind(assigned(.device(kind: .bluetooth, identifier: "local-port-a"), .profile(UUID())))
        settings.bind(assigned(.type(.usb), .builtIn(.vocalBooster)))
        DeviceSoundStore.save(settings, defaults: defaults)
        #expect(DeviceSoundStore.load(defaults: defaults) == settings)
        #expect(SoundSettingsStore.load(defaults: defaults) == old)
        #expect(defaults.string(forKey: "koda.equalizer") == "rock")
    }

    @Test func oldOrInvalidDocumentsStartWithAutomationOff() throws {
        let old = try JSONDecoder().decode(DeviceSoundSettings.self, from: Data("{}".utf8))
        #expect(!old.enabled)
        #expect(old.bindings.isEmpty)
        #expect(old.fallback == nil)
        let domain = "koda.device-sound.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(Data("broken".utf8), forKey: "koda.sound.devices.v1")
        #expect(!DeviceSoundStore.load(defaults: defaults).enabled)
    }

    @Test func exactPortTakesPriorityAndSameNameDoesNotImpersonateIt() {
        var settings = DeviceSoundSettings(); settings.enabled = true
        settings.bind(assigned(.type(.bluetooth), .builtIn(.off)))
        settings.bind(assigned(.device(kind: .bluetooth, identifier: "local-port-a"), .builtIn(.deep)))
        var policy = DeviceSoundPolicy()
        _ = policy.observe(.init(outputs: [headphones]))
        #expect(policy.selection(settings: settings) == .apply(.builtIn(.deep)))
        _ = policy.observe(.init(outputs: [.init(kind: .bluetooth, name: headphones.name, identifier: "local-port-b")]))
        #expect(policy.selection(settings: settings) == .apply(.builtIn(.off)))
    }

    @Test func missingIdentifierNeedsAnExplicitTypeBindingOrChosenDefault() {
        var settings = DeviceSoundSettings(); settings.enabled = true
        settings.bind(assigned(.device(kind: .bluetooth, identifier: "local-port-a"), .builtIn(.deep)))
        var policy = DeviceSoundPolicy()
        _ = policy.observe(.init(outputs: [.init(kind: .bluetooth, name: headphones.name)]))
        #expect(policy.selection(settings: settings) == .unchanged)
        settings.bind(assigned(.type(.bluetooth), .builtIn(.vocalBooster)))
        #expect(policy.selection(settings: settings) == .apply(.builtIn(.vocalBooster)))
    }

    @Test func unknownOrMultipleOutputsCannotApplyTheFallback() {
        var settings = DeviceSoundSettings(); settings.enabled = true; settings.fallback = .builtIn(.rock)
        var policy = DeviceSoundPolicy()
        #expect(policy.selection(settings: settings) == .unavailable)
        _ = policy.observe(.init(outputs: [.init(kind: .unknown, name: "New route", identifier: "new")]))
        #expect(policy.selection(settings: settings) == .unavailable)
        _ = policy.observe(.init(outputs: [headphones, .init(kind: .airPlay, name: "Room")]))
        #expect(policy.selection(settings: settings) == .unavailable)
    }

    @Test func manualOverrideSurvivesDuplicateAndRenamedRouteNotifications() {
        var settings = DeviceSoundSettings(); settings.enabled = true; settings.fallback = .builtIn(.rock)
        var policy = DeviceSoundPolicy()
        _ = policy.observe(.init(outputs: [headphones]))
        policy.override()
        let duplicate = policy.observe(.init(outputs: [headphones]))
        let rename = policy.observe(.init(outputs: [.init(kind: .bluetooth, name: "Renamed", identifier: "local-port-a")]))
        #expect(duplicate == nil)
        #expect(rename == nil)
        #expect(policy.selection(settings: settings) == .manual)
        _ = policy.observe(.init(outputs: [.init(kind: .usb, name: "USB", identifier: "usb")]))
        #expect(policy.selection(settings: settings) == .apply(.builtIn(.rock)))
    }

    @Test func rapidChangesAndManualEditsInvalidateEveryOlderDebounceTicket() throws {
        var policy = DeviceSoundPolicy()
        let firstObserved = policy.observe(.init(outputs: [headphones]))
        let first = try #require(firstObserved)
        let secondObserved = policy.observe(.init(outputs: [.init(kind: .usb, name: "USB")]))
        let second = try #require(secondObserved)
        #expect(!policy.accepts(first))
        #expect(policy.accepts(second))
        policy.override()
        #expect(!policy.accepts(second))
        let third = policy.invalidate(resetOverride: true)
        #expect(policy.accepts(third))
        #expect(!policy.manuallyOverridden)
    }

    @Test func disablingSwitchingNeverAppliesAProfile() {
        var settings = DeviceSoundSettings(); settings.fallback = .builtIn(.rock)
        var policy = DeviceSoundPolicy(); _ = policy.observe(.init(outputs: [headphones]))
        #expect(policy.selection(settings: settings) == .disabled)
        settings.enabled = true
        #expect(policy.selection(settings: settings) == .apply(.builtIn(.rock)))
        settings.enabled = false
        #expect(policy.selection(settings: settings) == .disabled)
    }

    @Test(arguments: AudioOutputDevice.Kind.allCases.filter { $0 != .unknown })
    func everyRecognizedOutputKindSupportsExplicitTypeAssignments(_ kind: AudioOutputDevice.Kind) {
        var settings = DeviceSoundSettings(); settings.enabled = true
        settings.bind(assigned(.type(kind), .builtIn(.spokenWord)))
        var policy = DeviceSoundPolicy()
        _ = policy.observe(.init(outputs: [.init(kind: kind, name: "Output")]))
        #expect(policy.selection(settings: settings) == .apply(.builtIn(.spokenWord)))
    }

    @Test func missingProfileDoesNotResolveToAnotherSoundAndBuiltInKeepsOutputLimit() throws {
        var current = SoundSettings(); current.outputLimit = 0.2; current.customEnabled = true; current.bassBoostDB = 9
        let missing = DeviceSoundTarget.profile(UUID())
        if case .some = missing.resolve(profiles: [], current: current) { Issue.record("Missing profile was replaced") }
        let builtin = try #require(DeviceSoundTarget.builtIn(.rock).resolve(profiles: [], current: current))
        #expect(builtin.settings.outputLimit == 0.2)
        #expect(!builtin.settings.customEnabled)
        #expect(builtin.settings.bassBoostDB == 0)
        #expect(builtin.preset == .rock)
    }

    @Test func rebindingReplacesTheScopeAndUntrustedAssignmentsStayBounded() {
        var settings = DeviceSoundSettings()
        settings.bind(assigned(.type(.usb), .builtIn(.rock)))
        settings.bind(assigned(.type(.usb), .builtIn(.jazz)))
        #expect(settings.bindings.count == 1)
        #expect(settings.bindings[0].target == .builtIn(.jazz))
        settings.bindings.append(assigned(.type(.unknown), .builtIn(.rock)))
        settings.bindings.append(assigned(.device(kind: .wired, identifier: ""), .builtIn(.rock)))
        for index in 0..<100 { settings.bindings.append(assigned(.device(kind: .bluetooth, identifier: "\(index)"), .builtIn(.off))) }
        #expect(settings.normalized.bindings.count == DeviceSoundSettings.bindingLimit)
        #expect(!settings.normalized.bindings.contains { $0.scope.kind == .unknown })
    }

    @Test func routeOutputLimitEasesUpButFallsImmediatelyAndSharedMixStaysCapped() {
        var previous: Float = 0.2
        for index in 0...100 {
            let limit = DeviceSoundOutputRamp.limit(from: 0.2, to: 0.8, progress: Double(index) / 100)
            #expect(limit >= previous && limit <= 0.8)
            let gains = OutputGainBudget.allocate(requested: [limit, limit], limit: limit)
            #expect(gains.reduce(0, +) <= limit)
            previous = limit
        }
        #expect(DeviceSoundOutputRamp.limit(from: 0.9, to: 0.1, progress: 0) == 0.1)
        #expect(DeviceSoundOutputRamp.limit(from: .infinity, to: .nan, progress: .infinity) == 0)
    }

    @Test func changingProfilesUsesTheExistingSmoothPCMProcessing() {
        var processor = SoundProcessor()
        var before = SoundSettings(); before.preampDB = -12
        var after = SoundSettings(); after.preampDB = -3; after.bassBoostDB = 12
        processor.configure(before, preset: .off, sampleRate: 48_000, smooth: false)
        let previous = processor.run(0.25)
        processor.configure(after, preset: .deep, sampleRate: 48_000)
        #expect(processor.isTransitioning)
        #expect(abs(processor.run(0.25) - previous) < 0.001)
        for index in 0..<2000 {
            let sample = SoundSafety.limit(processor.run(Float(sin(Double(index) * 0.07))), ceiling: 1)
            #expect(sample.isFinite && abs(sample) <= 1)
        }
        #expect(!processor.isTransitioning)
    }
}

@MainActor
@Suite(.serialized)
struct DeviceSoundPlayerTests {
    @Test func assignmentAppliesWithoutReplacingEngineOrChangingPausedQueue() throws {
        let domain = "koda.device-sound-player.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let player = Player(music: YouTubeMusic(defaultsSuite: domain), defaults: defaults)
        let engine = player.engineIdentifier
        var sound = SoundSettings(); sound.customEnabled = true; sound.gains[4] = -7; sound.outputLimit = 0.2
        let profile = SoundProfile(name: "Headphones", settings: sound, preset: .jazz)
        player.saveSoundProfiles([profile])
        var settings = DeviceSoundSettings(); settings.enabled = true
        settings.bind(.init(scope: .type(.bluetooth), name: "Bluetooth", target: .profile(profile.id)))
        player.deviceSoundSettings = settings
        player.receiveAudioOutputRoute(.init(outputs: [.init(kind: .bluetooth, name: "Headphones", identifier: "a")]))
        player.applyCurrentDeviceSound()
        #expect(player.equalizer == .jazz)
        #expect(player.soundSettings == sound)
        #expect(player.appliedDeviceSound == .profile(profile.id))
        #expect(player.outputVolume <= 0.2)
        #expect(player.engineIdentifier == engine)
        #expect(!player.wantsToPlay)
        #expect(player.loadedItemCount == 0)
        #expect(SoundSettingsStore.load(defaults: defaults) == sound)
        #expect(DeviceSoundStore.load(defaults: defaults) == settings)
    }

    @Test func manualEditWinsUntilAnActualDeviceChangeOrExplicitReapply() throws {
        let domain = "koda.device-sound-player.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let player = Player(music: YouTubeMusic(defaultsSuite: domain), defaults: defaults)
        var settings = DeviceSoundSettings(); settings.enabled = true; settings.fallback = .builtIn(.rock)
        player.deviceSoundSettings = settings
        let route = AudioOutputRoute(outputs: [.init(kind: .usb, name: "USB", identifier: "a")])
        player.receiveAudioOutputRoute(route)
        player.applyCurrentDeviceSound()
        player.equalizer = .jazz
        player.receiveAudioOutputRoute(route)
        player.applyCurrentDeviceSound()
        #expect(player.equalizer == .jazz)
        #expect(player.deviceSoundManuallyOverridden)
        // Editing another output or the fallback must not take away this output's override.
        player.deviceSoundSettings.bind(.init(scope: .type(.bluetooth), name: "Other", target: .builtIn(.deep)))
        player.deviceSoundSettings.fallback = .builtIn(.vocalBooster)
        player.applyCurrentDeviceSound()
        #expect(player.equalizer == .jazz)
        #expect(player.deviceSoundManuallyOverridden)
        player.useDeviceSoundBinding()
        player.applyCurrentDeviceSound()
        #expect(player.equalizer == .vocalBooster)
        #expect(!player.deviceSoundManuallyOverridden)
    }

    @Test func deletedProfileAndRemovedBindingClearStatusWithoutChangingSound() throws {
        let domain = "koda.device-sound-player.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let player = Player(music: YouTubeMusic(defaultsSuite: domain), defaults: defaults)
        let profile = SoundProfile(name: "A", settings: SoundSettings(), preset: .deep)
        player.saveSoundProfiles([profile])
        var settings = DeviceSoundSettings(); settings.enabled = true
        settings.bind(.init(scope: .type(.wired), name: "Wired", target: .profile(profile.id)))
        player.deviceSoundSettings = settings
        player.receiveAudioOutputRoute(.init(outputs: [.init(kind: .wired, name: "Wired")]))
        player.applyCurrentDeviceSound()
        #expect(player.appliedDeviceSound == .profile(profile.id))
        player.saveSoundProfiles([])
        player.applyCurrentDeviceSound()
        #expect(player.appliedDeviceSound == nil)
        #expect(player.deviceSoundProfileMissing)
        #expect(player.equalizer == .deep)
        player.deviceSoundSettings.bindings = []
        player.applyCurrentDeviceSound()
        #expect(!player.deviceSoundProfileMissing)
        #expect(player.appliedDeviceSound == nil)
        #expect(player.equalizer == .deep)
    }

    @Test func disablingAutomationKeepsInstalledSoundAndRejectsTheNextRoute() throws {
        let domain = "koda.device-sound-player.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let player = Player(music: YouTubeMusic(defaultsSuite: domain), defaults: defaults)
        var settings = DeviceSoundSettings(); settings.enabled = true
        settings.fallback = .builtIn(.rock)
        settings.bind(.init(scope: .type(.usb), name: "USB", target: .builtIn(.jazz)))
        player.deviceSoundSettings = settings
        player.receiveAudioOutputRoute(.init(outputs: [.init(kind: .usb, name: "USB")]))
        player.applyCurrentDeviceSound()
        #expect(player.equalizer == .jazz)
        player.deviceSoundSettings.enabled = false
        player.receiveAudioOutputRoute(.init(outputs: [.init(kind: .speaker, name: "Speaker")]))
        player.applyCurrentDeviceSound()
        #expect(player.equalizer == .jazz)
        #expect(player.appliedDeviceSound == nil)
        #expect(!player.deviceSoundProfileMissing)
        #expect(!player.wantsToPlay)
    }

    @Test func namedProfileChangesRefreshBindingsAndSurvivePlayerRestoration() throws {
        let domain = "koda.device-sound-player.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let player = Player(music: YouTubeMusic(defaultsSuite: domain), defaults: defaults)
        var profile = SoundProfile(name: "Before", settings: SoundSettings(), preset: .jazz)
        player.saveSoundProfiles([profile])
        var settings = DeviceSoundSettings(); settings.enabled = true; settings.fallback = .profile(profile.id)
        player.deviceSoundSettings = settings
        let route = AudioOutputRoute(outputs: [.init(kind: .usb, name: "USB")])
        player.receiveAudioOutputRoute(route)
        player.applyCurrentDeviceSound()
        profile.name = "After"
        profile.settings.preampDB = -8
        player.saveSoundProfiles([profile])
        player.applyCurrentDeviceSound()
        #expect(player.appliedDeviceSound?.title(profiles: player.soundProfiles) == "After")
        #expect(player.soundSettings.preampDB == -8)
        let restored = Player(music: YouTubeMusic(defaultsSuite: domain), defaults: defaults)
        restored.receiveAudioOutputRoute(route)
        restored.applyCurrentDeviceSound()
        #expect(restored.soundProfiles == [profile])
        #expect(restored.deviceSoundSettings == settings)
        #expect(restored.soundSettings == profile.settings)
        #expect(!restored.wantsToPlay)
    }
}
