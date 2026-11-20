#if !targetEnvironment(macCatalyst)
import KodaCore
import SwiftUI

struct CarPlayLyricsDelayView: View {
    let song: Song
    @Environment(Library.self) private var library
    @Environment(AppModel.self) private var app

    private var delay: TimeInterval { library.carPlayLyricsOffset(for: song.id) }

    var body: some View {
        Form {
            Section {
                Text(song.title).font(.headline)
                LabeledContent("Current Delay") {
                    HStack(spacing: 4) {
                        Text(delay, format: .number.sign(strategy: .always(includingZero: true)).precision(.fractionLength(1)))
                            .monospacedDigit()
                        Text("seconds").foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("carplay.lyrics.delay.value")
                Stepper("Adjust Delay", value: Binding(get: { delay }, set: set),
                        in: CarPlayLyricsTiming.range, step: 0.1)
                HStack {
                    adjustment(-0.5)
                    adjustment(-0.1)
                    adjustment(0.1)
                    adjustment(0.5)
                }
                Button("Reset Delay") { set(0) }
                    .disabled(delay == 0)
            } footer: {
                Text("Positive values show lyrics later. This setting only affects this song in the Koda Lyrics activity.")
            }
            Section {
                if app.carPlay.isActive {
                    Button("End Koda Lyrics", systemImage: "xmark.circle") { app.carPlay.stop() }
                } else {
                    Button("Start Koda Lyrics", systemImage: "quote.bubble") { app.carPlay.start() }
                        .disabled(app.carPlay.isEnding)
                }
            } footer: {
                Text("After starting, tap Show Lyrics on your iPhone Lock Screen. CarPlay displays lyrics when Live Activities are enabled for your car.")
            }
        }
        .navigationTitle("CarPlay Lyrics Delay")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Koda Lyrics", isPresented: Binding(get: { app.carPlay.errorMessage != nil },
                                                   set: { if !$0 { app.carPlay.errorMessage = nil } })) {
            Button("OK", role: .cancel) { app.carPlay.errorMessage = nil }
        } message: {
            Text(app.carPlay.errorMessage ?? "")
        }
    }

    private func set(_ value: TimeInterval) { library.setCarPlayLyricsOffset(value, for: song.id) }

    private func adjustment(_ seconds: TimeInterval) -> some View {
        Button { set(delay + seconds) } label: {
            Text(seconds, format: .number.sign(strategy: .always(includingZero: true)).precision(.fractionLength(1)))
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.borderless)
        .disabled(CarPlayLyricsTiming.normalizedOffset(delay + seconds) == delay)
        .accessibilityIdentifier("carplay.lyrics.delay.\(seconds)")
    }
}
#endif
