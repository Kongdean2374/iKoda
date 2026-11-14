import KodaCore
import SwiftUI

/// The existing audio tap remains the only EQ engine. This screen edits its persisted values;
/// moving a slider never replaces the playing item or restarts the song.
struct AudioCenterView: View {
    @Environment(Player.self) private var player
    @State private var profiles = SoundSettingsStore.profiles()
    @State private var namingProfile = false
    @State private var editingProfile: UUID?
    @State private var draftName = ""
    @State private var deletingProfile: SoundProfile?
    @State private var confirmsReset = false

    private var baseCurve: [Float] {
        player.soundSettings.customEnabled ? player.soundSettings.normalized.gains : player.equalizer.gains
    }

    var body: some View {
        @Bindable var player = player
        Form {
            Section {
                Toggle("Sound Effects", isOn: $player.soundSettings.enabled)
                NavigationLink {
                    EqualizerSettingsView()
                } label: {
                    LabeledContent("Built-in Equalizer", value: player.equalizer.title)
                }
                Toggle("Use Custom EQ", isOn: customBinding)
                if player.soundProcessingAvailable == false && player.soundSettings.requiresProcessing(preset: player.equalizer) {
                    Label("Sound effects are unavailable for the current audio. Your Koda output limit still applies.", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Turning sound effects off bypasses EQ, bass boost and preamp. Your Koda output limit still applies.")
            }
            equalizerSection
                .disabled(!player.soundSettings.enabled)
            gainSection
            profilesSection
            Section {
                Button("Reset Sound Settings", role: .destructive) { confirmsReset = true }
            }
        }
        .navigationTitle("Sound Center")
        .navigationBarTitleDisplayMode(.inline)
        .alert(editingProfile == nil ? String(localized: "Save Sound Profile") : String(localized: "Rename Sound Profile"), isPresented: $namingProfile) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveProfile() }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("Delete Sound Profile?", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deletingProfile?.id { profiles.removeAll { $0.id == id }; persistProfiles() }
                deletingProfile = nil
            }
        } message: {
            Text("The current sound settings stay unchanged.")
        }
        .confirmationDialog("Reset Sound Settings?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                player.equalizer = .off
                player.soundSettings = SoundSettings()
            }
        } message: {
            Text("EQ, bass boost, preamp and the Koda output limit return to their defaults. Saved profiles are kept.")
        }
    }

    private var customBinding: Binding<Bool> {
        Binding(get: { player.soundSettings.customEnabled }, set: { enabled in
            var settings = player.soundSettings
            settings.customEnabled = enabled
            player.soundSettings = settings
        })
    }

    private var equalizerSection: some View {
        Section {
            EQCurve(values: player.soundSettings.effectiveGains(preset: player.equalizer))
                .frame(height: 130)
                .padding(.vertical, 6)
            ForEach(0..<10, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: Self.frequencyNames[index])
                        Spacer()
                        Text(baseCurve[index], format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                        Text(verbatim: "dB").foregroundStyle(.secondary)
                    }
                    Slider(value: bandBinding(index), in: -12...12, step: 0.5)
                        .accessibilityLabel(String(localized: "\(Self.frequencyNames[index]) band"))
                        .accessibilityValue(String(localized: "\(baseCurve[index].formatted(.number.precision(.fractionLength(1)))) dB"))
                }
            }
            Button("Reset to Flat") {
                var settings = player.soundSettings
                settings.customEnabled = true
                settings.gains = Array(repeating: 0, count: 10)
                settings.bassBoostDB = 0
                player.soundSettings = settings
            }
        } header: {
            Text("10-Band Equalizer")
        } footer: {
            Text("Adjusting a band creates a custom curve. The graph includes bass boost; the sliders show the underlying EQ values.")
        }
    }

    private func bandBinding(_ index: Int) -> Binding<Float> {
        Binding(get: { baseCurve[index] }, set: { gain in
            var settings = player.soundSettings
            if !settings.customEnabled { settings.gains = player.equalizer.gains }
            settings.customEnabled = true
            settings.gains[index] = gain
            player.soundSettings = settings
        })
    }

    private var gainSection: some View {
        @Bindable var player = player
        return Section {
            gainSlider("Bass Boost", value: $player.soundSettings.bassBoostDB, range: 0...12)
                .disabled(!player.soundSettings.enabled)
            gainSlider("Preamp", value: $player.soundSettings.preampDB, range: -24...12)
                .disabled(!player.soundSettings.enabled)
            LabeledContent("Protected Preamp") {
                Text(String(localized: "\(player.soundSettings.effectivePreampDB(preset: player.equalizer).formatted(.number.precision(.fractionLength(1)))) dB"))
                    .monospacedDigit()
            }
            VStack(alignment: .leading) {
                HStack {
                    Text("Koda Output Limit")
                    Spacer()
                    Text(player.soundSettings.outputLimit, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                Slider(value: $player.soundSettings.outputLimit, in: 0...1, step: 0.01)
                    .accessibilityLabel("Koda Output Limit")
            }
        } header: {
            Text("Gain & Protection")
        } footer: {
            Text("Headroom protection automatically reduces preamp gain when the curve boosts frequencies. Transient protection prevents digital overload. The output limit controls Koda music only, not other apps or the device volume.")
        }
    }

    private func gainSlider(_ title: LocalizedStringKey, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Text(title)
                Spacer()
                Text(String(localized: "\(value.wrappedValue.formatted(.number.precision(.fractionLength(1)))) dB")).monospacedDigit()
            }
            Slider(value: value, in: range, step: 0.5).accessibilityLabel(title)
        }
    }

    private var profilesSection: some View {
        Section {
            ForEach(profiles) { profile in
                Button { apply(profile) } label: {
                    HStack {
                        Text(profile.name).foregroundStyle(.primary)
                        Spacer()
                        if profile.settings == player.soundSettings && profile.preset == player.equalizer {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        editingProfile = profile.id
                        draftName = profile.name
                        namingProfile = true
                    }
                    Button("Replace with Current Settings", systemImage: "square.and.arrow.down") {
                        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                            profiles[index].settings = player.soundSettings.normalized
                            profiles[index].preset = player.equalizer
                            persistProfiles()
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { deletingProfile = profile }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { deletingProfile = profile }
                    Button("Rename") {
                        editingProfile = profile.id
                        draftName = profile.name
                        namingProfile = true
                    }.tint(.blue)
                }
            }
            Button("Save Current Sound", systemImage: "plus") {
                editingProfile = nil
                draftName = ""
                namingProfile = true
            }
            .disabled(profiles.count >= SoundSettingsStore.profileLimit)
        } header: {
            Text("Headphone Profiles")
        } footer: {
            Text("Save up to 32 profiles for your headphones. Load a profile to adjust its values, then use Replace with Current Settings to save the changes.")
        }
    }

    private func apply(_ profile: SoundProfile) {
        player.equalizer = profile.preset
        player.soundSettings = profile.settings.normalized
    }

    private func saveProfile() {
        if let id = editingProfile, let index = profiles.firstIndex(where: { $0.id == id }) {
            profiles[index].name = String(draftName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        } else if profiles.count < SoundSettingsStore.profileLimit {
            profiles.append(SoundProfile(name: draftName, settings: player.soundSettings, preset: player.equalizer))
        }
        persistProfiles()
    }

    private func persistProfiles() { SoundSettingsStore.saveProfiles(profiles) }
    private static let frequencyNames = ["32 Hz", "64 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz"]
}

private struct EQCurve: View {
    let values: [Float]
    var body: some View {
        Canvas { context, size in
            let mid = size.height / 2
            var grid = Path()
            for index in 0..<10 {
                let x = size.width * CGFloat(index) / 9
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            grid.move(to: CGPoint(x: 0, y: mid)); grid.addLine(to: CGPoint(x: size.width, y: mid))
            context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
            var curve = Path()
            for (index, gain) in values.prefix(10).enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / 9, y: mid - CGFloat(gain / 12) * (mid - 4))
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityLabel("Equalizer curve")
        .accessibilityHidden(true) // Every band has its own adjustable VoiceOver slider below.
    }
}
