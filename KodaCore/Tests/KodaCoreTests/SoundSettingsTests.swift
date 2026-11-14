import Foundation
import Testing
@testable import KodaCore

struct SoundSettingsTests {
    @Test func settingsAndNamedProfilesRoundTripWithoutTouchingLegacyPreset() throws {
        let domain = "Koda.SoundSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("rock", forKey: "koda.equalizer")
        var settings = SoundSettings()
        settings.customEnabled = true
        settings.gains = [12, -12, 4, 2, -1, 0, 3, 1, -2, 5]
        settings.preampDB = -8
        settings.outputLimit = 0.6
        SoundSettingsStore.save(settings, defaults: defaults)
        #expect(SoundSettingsStore.load(defaults: defaults) == settings)
        let profile = SoundProfile(name: "My headphones", settings: settings, preset: .jazz)
        SoundSettingsStore.saveProfiles([profile], defaults: defaults)
        var restored = SoundSettingsStore.profiles(defaults: defaults)
        #expect(restored == [profile])
        restored[0].name = "Renamed headphones"
        SoundSettingsStore.saveProfiles(restored, defaults: defaults)
        #expect(SoundSettingsStore.profiles(defaults: defaults).first?.name == "Renamed headphones")
        SoundSettingsStore.saveProfiles([], defaults: defaults)
        #expect(SoundSettingsStore.profiles(defaults: defaults).isEmpty)
        #expect(defaults.string(forKey: "koda.equalizer") == "rock")
    }

    @Test func migrationAndInvalidValuesHaveSafeDefaults() throws {
        let partial = Data("{\"gains\":[40,-60],\"outputLimit\":2}".utf8)
        let decoded = try JSONDecoder().decode(SoundSettings.self, from: partial)
        #expect(decoded.gains == [12, -12, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(decoded.outputLimit == 1)
        #expect(decoded.enabled)
        #expect(!decoded.customEnabled)
        var invalid = decoded
        invalid.preampDB = .infinity
        invalid.bassBoostDB = .nan
        #expect(invalid.normalized.preampDB == 0)
        #expect(invalid.normalized.bassBoostDB == 0)
    }

    @Test func bassUsesTheSameTenBandsAndHeadroomNeverExceedsFullScale() {
        var settings = SoundSettings()
        settings.customEnabled = true
        settings.gains = Array(repeating: 12, count: 10)
        settings.bassBoostDB = 12
        settings.preampDB = 12
        let design = Equalizer.soundDesign(settings, preset: .off, sampleRate: 48_000)
        #expect(design.sections.count == 10)
        #expect(settings.effectiveGains(preset: .off).allSatisfy { $0 <= 12 })
        let peak = Equalizer.peakResponse(design.sections, sampleRate: 48_000)
        #expect(peak + 20 * log10(design.preamp) < 0.001)
        #expect(settings.effectivePreampDB(preset: .off) < 0)
        settings.gains = Array(repeating: -12, count: 10)
        settings.bassBoostDB = 0
        settings.preampDB = 6
        let recovering = Equalizer.soundDesign(settings, preset: .off, sampleRate: 48_000)
        #expect(recovering.preamp > 1)
        #expect(Equalizer.peakResponse(recovering.sections, sampleRate: 48_000) + 20 * log10(recovering.preamp) < 0.001)
    }

    @Test func actualPCMPreampAttenuatesAndOutputCapAppliesEvenWhenDisabled() {
        var settings = SoundSettings()
        settings.preampDB = -6
        var processor = SoundProcessor()
        processor.configure(settings, preset: .off, sampleRate: 48_000, smooth: false)
        #expect(abs(processor.run(0.5) - 0.5 * Float(pow(10.0, -6.0 / 20.0))) < 0.0001)
        settings.enabled = false
        settings.outputLimit = 0.4
        processor.configure(settings, preset: .rock, sampleRate: 48_000, smooth: false)
        #expect(processor.run(0.75) == 0.75)
        #expect(settings.outputGain(for: 1) == 0.4)
        #expect(settings.outputGain(for: 0.2) == 0.2)
        #expect(settings.outputGain(for: .nan) == 0)
        #expect(!settings.requiresProcessing(preset: .rock))
    }

    @Test func actualPCMCustomCurveChangesFrequencyResponse() {
        var settings = SoundSettings()
        settings.customEnabled = true
        settings.gains[5] = -12
        var processor = SoundProcessor()
        processor.configure(settings, preset: .off, sampleRate: 48_000, smooth: false)
        var inputPower: Double = 0, outputPower: Double = 0
        for frame in 0..<48_000 {
            let sample = Float(0.5 * sin(2 * Double.pi * 1000 * Double(frame) / 48_000))
            let output = processor.run(sample)
            if frame > 4800 {
                inputPower += Double(sample * sample)
                outputPower += Double(output * output)
            }
        }
        #expect(10 * log10(outputPower / inputPower) < -11.5)
    }

    @Test func allPresetsSwitchWithoutNonFiniteSamplesAndSafetyBoundsTransients() {
        var processor = SoundProcessor()
        var settings = SoundSettings()
        for preset in EqualizerPreset.allCases {
            processor.configure(settings, preset: preset, sampleRate: 44_100)
            var safe = true
            for frame in 0..<2000 {
                let input = Float(sin(Double(frame) * 0.13))
                let output = SoundSafety.limit(processor.run(input), ceiling: 1)
                safe = safe && output.isFinite && abs(output) <= 1
            }
            #expect(safe)

        }
        settings.enabled = false
        processor.configure(settings, preset: .bassBooster, sampleRate: 44_100)
        for _ in 0..<2000 { _ = processor.run(0.25) }
        #expect(!processor.isTransitioning)
        #expect(abs(processor.run(0.25) - 0.25) < 0.0001)
        #expect(SoundSafety.limit(.infinity, ceiling: 1) == 0)
        #expect(abs(SoundSafety.limit(100, ceiling: 0.6)) <= 0.6)
        #expect(SoundSafety.limit(0.1, ceiling: 0.6) == 0.1)
    }
}
