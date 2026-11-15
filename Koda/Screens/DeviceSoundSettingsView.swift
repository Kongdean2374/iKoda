import KodaCore
import SwiftUI

/// Extends Sound Center using its existing presets and DSP; no global system EQ is implied.
struct DeviceSoundSettingsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        Form {
            Section {
                Toggle("Automatically Switch Sound", isOn: $player.deviceSoundSettings.enabled)
                    .accessibilityIdentifier("sound.automaticRouting")
            } footer: {
                Text("Applies sound profiles to Koda music when the audio output changes. Other apps and music video audio are unaffected.")
            }
            Section {
                if player.audioOutputRoute.outputs.isEmpty {
                    Text("Audio output information is unavailable.").foregroundStyle(.secondary)
                }
                ForEach(Array(player.audioOutputRoute.outputs.enumerated()), id: \.offset) { _, output in
                    LabeledContent(output.name.isEmpty ? output.kind.title : output.name, value: output.kind.title)
                }
                if !player.deviceSoundSettings.enabled {
                    Text("Automatic switching is off.").foregroundStyle(.secondary)
                } else if player.deviceSoundManuallyOverridden {
                    Label("Manual Override", systemImage: "hand.raised")
                    Button("Use Assigned Sound") { player.useDeviceSoundBinding() }
                } else if player.deviceSoundProfileMissing {
                    Label("Sound Profile Unavailable", systemImage: "exclamationmark.triangle")
                    Text("The assigned profile was deleted. Choose another profile; your current sound is kept.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let target = player.appliedDeviceSound {
                    LabeledContent("Applied Device Sound", value: target.title(profiles: player.soundProfiles))
                    Button("Keep Current Sound for This Output") { player.keepCurrentDeviceSound() }
                } else {
                    Text("Keeping your current sound.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Current Audio Output")
            } footer: {
                Text("Manual changes in Sound Center take priority until the output changes or you choose Use Assigned Sound.")
            }
            if let output = player.audioOutputRoute.singleOutput, output.kind != .unknown {
                Section {
                    if let identifier = output.identifier {
                        NavigationLink {
                            DeviceSoundBindingEditor(scope: .device(kind: output.kind, identifier: identifier), name: output.name)
                        } label: {
                            Label("This Device", systemImage: "headphones")
                        }
                    }
                    NavigationLink {
                        DeviceSoundBindingEditor(scope: .type(output.kind), name: output.kind.title)
                    } label: {
                        LabeledContent("This Output Type", value: output.kind.title)
                    }
                } header: {
                    Text("Assign Sound")
                } footer: {
                    Text("Device matching uses the identifier iOS currently provides, which may change. Names do not prove a device's model or identity. If matching is unreliable, assign an output type or use manual sound settings.")
                }
            } else {
                Section {
                    Text("Unknown or multiple simultaneous outputs keep the current sound. Connect one output to assign a profile.")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Unassigned Output", selection: $player.deviceSoundSettings.fallback) {
                    Text("Keep Current Sound").tag(DeviceSoundTarget?.none)
                    DeviceSoundTargetOptions(profiles: player.soundProfiles, selection: player.deviceSoundSettings.fallback, optional: true)
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("Default Sound")
            } footer: {
                Text("A default applies only to a recognized single output without a binding. Unknown outputs and missing saved profiles never replace your sound.")
            }
            Section("Saved Device Assignments") {
                if player.deviceSoundSettings.bindings.isEmpty {
                    Text("No Device Assignments").foregroundStyle(.secondary)
                }
                ForEach(player.deviceSoundSettings.bindings) { binding in
                    NavigationLink {
                        DeviceSoundBindingEditor(scope: binding.scope, name: binding.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bindingLabel(binding))
                            Text(binding.target.title(profiles: player.soundProfiles))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in
                    var settings = player.deviceSoundSettings
                    for index in offsets.sorted(by: >) where settings.bindings.indices.contains(index) {
                        settings.bindings.remove(at: index)
                    }
                    player.deviceSoundSettings = settings
                }
            }
        }
        .navigationTitle("Device Sound Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.refreshAudioOutputRoute() }
    }

    private func bindingLabel(_ binding: DeviceSoundBinding) -> String {
        if case .type(let kind) = binding.scope { return String(localized: "All \(kind.title) Outputs") }
        return binding.name.isEmpty ? binding.scope.kind.title : binding.name
    }
}

private struct DeviceSoundBindingEditor: View {
    let scope: DeviceSoundBinding.Scope
    let name: String
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var target = DeviceSoundTarget.builtIn(.off)
    @State private var confirmsRemoval = false
    @State private var initialized = false

    private var existing: DeviceSoundBinding? { player.deviceSoundSettings.bindings.first { $0.scope == scope } }
    private var isFull: Bool { existing == nil && player.deviceSoundSettings.bindings.count >= DeviceSoundSettings.bindingLimit }
    private var targetAvailable: Bool {
        if case .some = target.resolve(profiles: player.soundProfiles, current: player.soundSettings) { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Audio Output", value: name.isEmpty ? scope.kind.title : name)
                Picker("Sound Profile", selection: $target) {
                    DeviceSoundTargetOptions(profiles: player.soundProfiles, selection: target, optional: false)
                }
                .pickerStyle(.navigationLink)
            } footer: {
                if case .type = scope {
                    Text("This assignment applies to every output of this type. A device-specific assignment takes priority.")
                } else {
                    Text("This assignment uses the current iOS device identifier. If it changes, reconnect and assign the device again.")
                }
            }
            Section {
                Button("Save Assignment") {
                    var settings = player.deviceSoundSettings
                    settings.bind(.init(id: existing?.id ?? UUID(), scope: scope, name: name, target: target))
                    player.deviceSoundSettings = settings
                    dismiss()
                }
                .disabled(isFull || !targetAvailable)
                if existing != nil {
                    Button("Remove Assignment", role: .destructive) { confirmsRemoval = true }
                }
            } footer: {
                if isFull { Text("You can save up to 64 device assignments. Remove one to add another.") }
                if !player.deviceSoundSettings.enabled { Text("Turn on automatic switching to apply saved assignments when outputs change.") }
            }
        }
        .navigationTitle("Assign Sound")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if let existing { target = existing.target }
        }
        .confirmationDialog("Remove Device Assignment?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove Assignment", role: .destructive) {
                var settings = player.deviceSoundSettings
                settings.bindings.removeAll { $0.scope == scope }
                player.deviceSoundSettings = settings
                dismiss()
            }
        } message: {
            Text("The saved sound profile is kept.")
        }
    }
}

/// Optional tags are explicit: SwiftUI pickers must use the exact selection type.
private struct DeviceSoundTargetOptions: View {
    let profiles: [SoundProfile]
    let selection: DeviceSoundTarget?
    let optional: Bool
    var body: some View {
        Section("Built-in Equalizer") {
            ForEach(EqualizerPreset.allCases) { preset in
                option(preset.title, target: .builtIn(preset))
            }
        }
        Section("Headphone Profiles") {
            ForEach(profiles) { profile in option(profile.name, target: .profile(profile.id)) }
            if case .profile(let id)? = selection, !profiles.contains(where: { $0.id == id }) {
                option(String(localized: "Sound Profile Unavailable"), target: .profile(id)).disabled(true)
            }
        }
    }

    @ViewBuilder private func option(_ title: String, target: DeviceSoundTarget) -> some View {
        if optional { Text(title).tag(Optional(target)) }
        else { Text(title).tag(target) }
    }
}
