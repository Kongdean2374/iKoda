import KodaCore
import SwiftUI

/// UI facade only. The player owns the persisted deadline, task and completion action,
/// so dismissing this screen or restoring the app cannot create a second timer.
@MainActor
@Observable
final class SleepTimer {
    private let player: Player
    private(set) var errorMessage: String?

    static let presets = [5, 10, 15, 30, 45, 60, 90, 120, 180]

    init(player: Player) { self.player = player }

    var isActive: Bool { player.sleepTimerState.isActive }
    var deadline: Date? { player.sleepTimerState.deadline }
    var lastDurationMinutes: Int { player.sleepTimerState.lastDurationMinutes }
    var canStopAtEndOfSong: Bool { player.current != nil }
    var action: SleepTimerAction {
        get { player.sleepTimerState.preferredAction }
        set { player.setSleepTimerAction(newValue); clearError() }
    }

    func start(minutes: Int) { perform { try player.scheduleSleepTimer(minutes: minutes) } }
    func stopAtEndOfSong() { perform { try player.scheduleSleepTimerAtEndOfSong() } }
    func extend(minutes: Int = 15) { perform { try player.extendSleepTimer(minutes: minutes) } }
    func reset() { perform { try player.resetSleepTimer() } }
    func cancel() { player.cancelSleepTimer(); clearError() }
    func clearError() { errorMessage = nil }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); clearError() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Clock text is computed from the persisted deadline; it is never decremented in a view.
    func label(at date: Date) -> String {
        guard isActive else { return "" }
        guard let deadline else { return String(localized: "End of song") }
        let left = max(0, deadline.timeIntervalSince(date))
        return Duration.seconds(left.rounded(.up))
            .formatted(.time(pattern: left >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    static func durationLabel(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

/// The existing submenu stays compact; the stable Now Playing parent presents its settings.
struct SleepTimerMenu: View {
    let openSettings: (Bool) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            SleepTimerActions(openSettings: openSettings)
        } label: {
            Label("Sleep Timer", systemImage: app.sleepTimer.isActive ? "moon.fill" : "moon")
        }
        .accessibilityIdentifier("sleep.timer.menu")
    }
}

/// Shared by the ellipsis submenu and the countdown pill without an extra submenu.
struct SleepTimerActions: View {
    let openSettings: (Bool) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        let timer = app.sleepTimer
        if timer.isActive {
            Section {
                Button(timer.deadline == nil ? String(localized: "Switch to a 15-Minute Timer") : String(localized: "Extend by 15 Minutes"), systemImage: "plus.circle") { timer.extend() }
                    .accessibilityIdentifier("sleep.timer.extend")
                if timer.deadline != nil {
                    Button("Reset Timer", systemImage: "arrow.counterclockwise") { timer.reset() }
                        .accessibilityIdentifier("sleep.timer.reset")
                }
                Button("Turn Off Timer", systemImage: "moon.zzz", role: .destructive) { timer.cancel() }
                    .accessibilityIdentifier("sleep.timer.cancel")
            }
        }
        Menu("Set Timer Duration", systemImage: "timer") {
            ForEach(SleepTimer.presets, id: \.self) { minutes in
                Button(SleepTimer.durationLabel(minutes: minutes)) { timer.start(minutes: minutes) }
                    .accessibilityIdentifier("sleep.timer.duration.\(minutes)")
            }
            Button("Custom Duration…", systemImage: "pencil") { openSettings(true) }
                .accessibilityIdentifier("sleep.timer.custom")
        }
        Button("End of Song", systemImage: "music.note") { timer.stopAtEndOfSong() }
            .disabled(!timer.canStopAtEndOfSong)
            .accessibilityIdentifier("sleep.timer.endOfSong")
        Button("Timer Settings…", systemImage: "slider.horizontal.3") { openSettings(false) }
            .accessibilityIdentifier("sleep.timer.settings")
    }
}

/// Scheduling and completion are independent: a countdown fires at its deadline;
/// End of Song fires at that occurrence's end. Both use the selected completion action.
struct SleepTimerSettingsView: View {
    var startsWithCustomDuration = false
    @Environment(AppModel.self) private var app
    @State private var selectedMinutes = 30
    @State private var customMinutes = "30"
    @State private var loadedPreferences = false
    @FocusState private var editingMinutes: Bool

    private var timer: SleepTimer { app.sleepTimer }
    private var validMinutes: Int? {
        let value = selectedMinutes == 0 ? Int(customMinutes.trimmingCharacters(in: .whitespacesAndNewlines)) : selectedMinutes
        guard let value, SleepTimerPolicy.minuteRange.contains(value) else { return nil }
        return value
    }

    var body: some View {
        Form {
            Section("Timer Status") {
                if timer.isActive {
                    SleepTimerStatus(timer: timer)
                    Button(timer.deadline == nil ? String(localized: "Switch to a 15-Minute Timer") : String(localized: "Extend by 15 Minutes"), systemImage: "plus.circle") { timer.extend() }
                        .accessibilityIdentifier("sleep.timer.extend")
                    if timer.deadline != nil {
                        Button("Reset Timer", systemImage: "arrow.counterclockwise") { timer.reset() }
                            .accessibilityIdentifier("sleep.timer.reset")
                    }
                    Button("Turn Off Timer", systemImage: "moon.zzz", role: .destructive) { timer.cancel() }
                        .accessibilityIdentifier("sleep.timer.cancel")
                } else {
                    Text("No sleep timer is running.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("sleep.timer.off")
                }
            }
            if let error = timer.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Timer Duration", selection: $selectedMinutes) {
                    ForEach(SleepTimer.presets, id: \.self) { minutes in
                        Text(SleepTimer.durationLabel(minutes: minutes))
                            .tag(minutes)
                            .accessibilityIdentifier("sleep.timer.duration.\(minutes)")
                    }
                    Text("Custom Duration…").tag(0).accessibilityIdentifier("sleep.timer.custom")
                }
                .accessibilityIdentifier("sleep.timer.duration")
                if selectedMinutes == 0 {
                    TextField("Minutes", text: $customMinutes)
                        .keyboardType(.numberPad)
                        .focused($editingMinutes)
                        .accessibilityIdentifier("sleep.timer.custom.minutes")
                    Text("Enter a whole number from 1 to 720 minutes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Start Timer", systemImage: "timer") {
                    guard let minutes = validMinutes else { return }
                    editingMinutes = false
                    timer.start(minutes: minutes)
                }
                .disabled(validMinutes == nil)
                .accessibilityIdentifier("sleep.timer.start")
                Button("End of Song", systemImage: "music.note") {
                    editingMinutes = false
                    timer.stopAtEndOfSong()
                }
                .disabled(!timer.canStopAtEndOfSong)
                .accessibilityIdentifier("sleep.timer.endOfSong")
            } header: {
                Text("Stop Playing After")
            } footer: {
                Text("Starting a new timer replaces the current schedule. End of Song requires a selected song.")
            }
            Section {
                Picker("When Timer Ends", selection: Binding(get: { timer.action }, set: { timer.action = $0 })) {
                    Text(SleepTimerAction.finishPlaybackSession.title)
                        .tag(SleepTimerAction.finishPlaybackSession)
                        .accessibilityIdentifier("sleep.expiry.finish")
                    Text(SleepTimerAction.pause.title)
                        .tag(SleepTimerAction.pause)
                        .accessibilityIdentifier("sleep.expiry.pause")
                }
                .accessibilityIdentifier("sleep.timer.expiryAction")
                .accessibilityValue(timer.action.title)
            } footer: {
                Text("Finish Playback Session stops Koda's playback work and keeps your queue. Pause keeps the usual paused session. A countdown performs the selected action immediately when time is up; it does not wait for the song to finish.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Sleep Timer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editingMinutes = false }
                    .accessibilityIdentifier("sleep.timer.keyboard.done")
            }
        }
        .onAppear {
            guard !loadedPreferences else { return }
            let previous = timer.lastDurationMinutes
            selectedMinutes = startsWithCustomDuration || !SleepTimer.presets.contains(previous) ? 0 : previous
            customMinutes = String(previous)
            loadedPreferences = true
        }
    }
}

/// The once-a-second clock is isolated from the form, its pickers and text entry.
private struct SleepTimerStatus: View {
    let timer: SleepTimer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: scenePhase != .active)) { context in
            LabeledContent("Time Remaining") {
                Text(timer.label(at: context.date)).monospacedDigit()
                    .accessibilityIdentifier("sleep.timer.remaining")
            }
        }
        if let deadline = timer.deadline {
            LabeledContent("Ends At") {
                Text(deadline, format: .dateTime.hour().minute())
                    .accessibilityIdentifier("sleep.timer.deadline")
            }
        }
    }
}
