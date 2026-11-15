import KodaCore
import SwiftUI

/// A preview of a local, bounded queue from one fresh cloud source. No write API is
/// available here; only an explicit Start can replace playback, with an intent check.
struct KodaFlowView: View {
    let playlist: PlaylistSummary
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var preset = 40
    @State private var customMinutes = "60"
    @State private var snapshot: CloudPlaylistSnapshot?
    @State private var plan: KodaFlowPlanner.Plan?
    @State private var operation: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var profileID: UUID?
    @State private var expectedIntent: UInt64?
    @State private var expectedScope: CloudPlaylistAccountScope?
    @State private var snapshotScope: CloudPlaylistAccountScope?
    @State private var preparing = false
    @State private var errorMessage: String?
    @State private var isStarting = false
    @FocusState private var isEditingMinutes: Bool

    private var minutes: Int? { preset == 0 ? Int(customMinutes) : preset }
    private var validMinutes: Bool { minutes.map { (1...720).contains($0) } == true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(snapshot?.title ?? playlist.title).font(.headline)
                        .accessibilityIdentifier("flow.source.title")
                    Text("Koda Flow uses only this cloud playlist. It does not change the playlist on YouTube Music.")
                        .font(.footnote).foregroundStyle(.secondary)
                    CloudPlaylistSessionNotice()
                }
                Section("Listening Time") {
                    Picker("Duration", selection: $preset) {
                        ForEach([40, 60, 120], id: \.self) { value in
                            Text("\(value) minutes").tag(value)
                                .accessibilityIdentifier("flow.duration.\(value)")
                        }
                        Text("Custom Duration").tag(0)
                            .accessibilityIdentifier("flow.duration.custom")
                    }
                    .accessibilityIdentifier("flow.duration")
                    .disabled(preparing)
                    if preset == 0 {
                        TextField("Minutes (1–720)", text: $customMinutes)
                            .keyboardType(.numberPad)
                            .focused($isEditingMinutes)
                            .accessibilityIdentifier("flow.custom.minutes")
                            .disabled(preparing)
                    }
                    if preparing {
                        ProgressView("Preparing Koda Flow…")
                            .accessibilityIdentifier("flow.preparing")
                        if let count = app.cloudPlaylists.readProgress[playlist.id] {
                            Text("Loading Playlist · \(count) songs").font(.footnote).monospacedDigit()
                        }
                        Button("Cancel Preparation") { cancel(showMessage: true) }
                            .accessibilityIdentifier("flow.cancel")
                    } else {
                        Button(plan == nil ? String(localized: "Arrange Flow") : String(localized: "Rearrange Flow")) {
                            prepare(reload: false)
                        }
                        .disabled(!validMinutes || !app.cloudPlaylists.hasSession)
                        .accessibilityIdentifier("flow.arrange")
                        Button("Refresh Source Playlist") { prepare(reload: true) }
                            .disabled(!validMinutes || !app.cloudPlaylists.hasSession)
                            .accessibilityIdentifier("flow.refresh")
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.secondary) }
                        .accessibilityIdentifier("flow.error")
                }
                if let plan {
                    Section {
                        LabeledContent("Songs", value: plan.songs.count.formatted())
                            .accessibilityIdentifier("flow.preview.count")
                        LabeledContent("Estimated Duration", value: duration(plan.estimatedDuration))
                            .accessibilityIdentifier("flow.preview.duration")
                        if abs(plan.difference) < 0.5 {
                            Text("Matches the Requested Time")
                        } else {
                            LabeledContent(plan.difference > 0 ? String(localized: "Over Target") : String(localized: "Under Target"),
                                           value: duration(abs(plan.difference)))
                        }
                        if plan.isSourceTooShort {
                            Text("This playlist is shorter than the requested time. All eligible songs are included; no songs are added from elsewhere.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .accessibilityIdentifier("flow.shortage")
                        }
                        if plan.duplicateCount > 0 {
                            Text("\(plan.duplicateCount) repeated song entries are excluded from this Flow only.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if plan.unknownDurationCount > 0 {
                            Text("\(plan.unknownDurationCount) songs without a usable duration are excluded.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let unavailable = snapshot?.unavailableCount, unavailable > 0 {
                            Text("\(unavailable) unavailable songs are excluded.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Start Flow", systemImage: "play.fill", action: start)
                            .disabled(plan.songs.isEmpty || preparing || !app.cloudPlaylists.hasSession)
                            .accessibilityIdentifier("flow.start")
                    } header: {
                        Text("Flow Preview")
                    } footer: {
                        Text("Durations come from the song information. AutoMix and crossfade can shorten playback. Flow ends without starting a recommendation radio; use the Sleep Timer if you need a fixed stopping time.")
                    }
                    Section("Upcoming Songs") {
                        ForEach(Array(plan.songs.enumerated()), id: \.element.id) { index, song in
                            HStack(alignment: .top, spacing: 10) {
                                Text((index + 1).formatted()).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(minWidth: 24, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title).font(.body)
                                    Text(song.artistLine).font(.caption).foregroundStyle(.secondary)
                                    if let seconds = song.duration {
                                        Text(duration(seconds)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("flow.song.\(song.id)")
                        }
                    }
                }
            }
            .navigationTitle("Koda Flow")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { cancel(showMessage: false); dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isEditingMinutes = false }
                }
            }
            .onAppear { profileID = app.roster.activeID }
            .onDisappear { cancel(showMessage: false) }
            .onChange(of: preset) { _, _ in invalidatePreview() }
            .onChange(of: customMinutes) { _, _ in invalidatePreview() }
            .onChange(of: app.roster.activeID) { _, _ in cancel(showMessage: false); dismiss() }
            .onChange(of: player.playbackIntentRevision) { _, _ in
                guard !isStarting, expectedIntent != nil else { return }
                cancel(showMessage: false)
                errorMessage = String(localized: "Playback changed. Arrange Flow again before starting it.")
            }
        }
    }

    private func prepare(reload: Bool) {
        guard let minutes, (1...720).contains(minutes),
              let scope = app.cloudPlaylists.captureScope() else { return }
        cancel(showMessage: false)
        let id = UUID(), profile = app.roster.activeID, intent = player.playbackIntentRevision
        requestID = id; profileID = profile; expectedIntent = intent; expectedScope = scope
        preparing = true; errorMessage = nil; plan = nil
        let cached = reload || snapshotScope != scope ? nil : snapshot
        operation = Task {
            do {
                let source: CloudPlaylistSnapshot
                if let cached { source = cached }
                else { source = try await app.cloudPlaylists.loadSnapshot(id: playlist.id, force: true, expectedScope: scope) }
                try Task.checkCancellation()
                guard app.cloudPlaylists.captureScope() == scope else { throw CloudAccountAccessError.changed }
                guard requestID == id, profile == app.roster.activeID, intent == player.playbackIntentRevision else { return }
                guard source.id.trimmingPrefix("VL") == playlist.id.trimmingPrefix("VL") else {
                    preparing = false; operation = nil
                    errorMessage = String(localized: "The source playlist changed. Open Koda Flow again.")
                    return
                }
                snapshot = source; snapshotScope = scope
                let result = try await KodaFlowPlanner.makePlan(sourceID: source.id, songs: source.songs,
                    minutes: minutes, seed: UInt64.random(in: .min ... .max))
                try Task.checkCancellation()
                guard app.cloudPlaylists.captureScope() == scope else { throw CloudAccountAccessError.changed }
                guard requestID == id, profile == app.roster.activeID, intent == player.playbackIntentRevision else { return }
                plan = result; preparing = false; operation = nil
            } catch is CancellationError {
                if requestID == id { preparing = false; operation = nil }
            } catch {
                guard requestID == id, profile == app.roster.activeID else { return }
                preparing = false; operation = nil
                switch error as? KodaFlowPlanner.PlanningError {
                case .noKnownDurations:
                    errorMessage = String(localized: "This playlist has no playable songs with a known duration. Try refreshing the source playlist.")
                case .invalidTarget:
                    errorMessage = String(localized: "Enter a listening time from 1 to 720 minutes.")
                case .missingSource:
                    errorMessage = String(localized: "Choose a cloud playlist before arranging Koda Flow.")
                case nil:
                    errorMessage = playlistToolboxErrorMessage(error)
                }
            }
        }
    }

    private func start() {
        guard let plan, let expectedIntent, let expectedScope,
              profileID == app.roster.activeID,
              app.cloudPlaylists.captureScope() == expectedScope else {
            invalidatePreview()
            errorMessage = String(localized: "Playback changed. Arrange Flow again before starting it.")
            return
        }
        isStarting = true
        if player.playFlow(plan.songs, sourceID: plan.sourceID, expectedIntentRevision: expectedIntent) {
            dismiss()
        } else {
            isStarting = false
            invalidatePreview()
            errorMessage = String(localized: "Playback changed. Arrange Flow again before starting it.")
        }
    }

    private func cancel(showMessage: Bool) {
        requestID = UUID(); operation?.cancel(); operation = nil
        preparing = false; expectedIntent = nil; expectedScope = nil; plan = nil
        if showMessage { errorMessage = String(localized: "Flow preparation was cancelled. Your current queue is unchanged.") }
    }

    private func invalidatePreview() {
        cancel(showMessage: false)
        errorMessage = nil
    }

    private func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds.rounded()).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
