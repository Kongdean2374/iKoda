import KodaCore
import SwiftUI

/// A small extension of the existing queue controls, with ordinary shuffle still available.
struct SmartShuffleSettingsView: View {
    @Environment(Player.self) private var player

    var body: some View {
        Form {
            Section {
                Toggle("Smart Shuffle", isOn: Binding(
                    get: { player.smartShuffleSettings.enabled },
                    set: { player.setSmartShuffle($0) }
                ))
            } footer: {
                Text("Smart Shuffle balances recent plays, repeated songs, artists, likes and skips using only local information. Ordinary Shuffle remains available from the queue.")
            }
            Section {
                Toggle("Resume Playback on Launch", isOn: Binding(
                    get: { player.resumePlaybackOnLaunch },
                    set: { player.resumePlaybackOnLaunch = $0 }
                ))
            } footer: {
                Text("When enabled, Koda resumes a previously playing queue after reopening if audio is available.")
            }
            Section("Repeat Avoidance") {
                Stepper(value: setting(\.recentWindow), in: 10...50, step: 5) {
                    Text("Avoid the last \(player.smartShuffleSettings.recentWindow) songs")
                }
                Picker("Consecutive Songs by One Artist", selection: setting(\.artistLimit)) {
                    ForEach(1...3, id: \.self) { value in
                        Text("\(value) songs").tag(value)
                    }
                }
                Picker("Smart Shuffle Strength", selection: setting(\.strength)) {
                    Text("Low").tag(SmartShuffleSettings.Strength.low)
                    Text("Standard").tag(SmartShuffleSettings.Strength.standard)
                    Text("High").tag(SmartShuffleSettings.Strength.high)
                }
            }
            Section("Liked Songs") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Liked Song Weight")
                        Spacer()
                        Text(player.smartShuffleSettings.likedWeight, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                    }
                    Slider(value: setting(\.likedWeight), in: 1...3, step: 0.1) {
                        Text("Liked Song Weight")
                    }
                }
            } footer: {
                Text("A higher weight makes liked songs more likely to play earlier. Small queues relax repeat avoidance when necessary.")
            }
            Section {
                Button("Reset Smart Shuffle Settings") {
                    let enabled = player.smartShuffleSettings.enabled
                    player.smartShuffleSettings = SmartShuffleSettings(enabled: enabled)
                }
            } footer: {
                Text("Preference changes apply to the next smart shuffle. Manually added or rearranged upcoming songs keep their positions. Your saved playlists are never changed.")
            }
        }
        .navigationTitle("Smart Shuffle")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func setting<Value>(_ keyPath: WritableKeyPath<SmartShuffleSettings, Value>) -> Binding<Value> {
        Binding(get: { player.smartShuffleSettings[keyPath: keyPath] }, set: { value in
            var settings = player.smartShuffleSettings
            settings[keyPath: keyPath] = value
            player.smartShuffleSettings = settings.validated
        })
    }
}
