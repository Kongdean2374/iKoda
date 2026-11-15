import KodaCore
import SwiftUI
import UIKit

struct MusicCatcherView: View {
    let onSearch: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var catcher = MusicCatcher()
    @State private var selectedID: String?
    @State private var playlistSong: Song?
    @State private var saving = false
    @State private var saved = false
    @State private var playlistAdded = false
    @State private var saveError: String?
    @State private var saveTask: Task<Void, Never>?

    init(provider: (any MusicRecognitionProviding)? = nil,
         search: (@MainActor (String) async throws -> [Song])? = nil,
         onSearch: @escaping (String) -> Void) {
        self.onSearch = onSearch
        _catcher = State(initialValue: MusicCatcher(provider: provider, search: search))
    }

    private var selected: Song? { catcher.flow.candidates.first { $0.id == selectedID }?.song }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Recognize nearby music with Apple's Shazam service, then choose the matching YouTube Music song. Koda does not save microphone recordings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    status
                    if catcher.flow.isWorking {
                        Button("Cancel Recognition", role: .cancel) { catcher.cancel(allowPlaybackRestore: true) }
                            .accessibilityIdentifier("catcher.cancel")
                    } else {
                        Button("Recognize Song", systemImage: "shazam.logo") {
                            selectedID = nil
                            saved = false
                            playlistAdded = false
                            saveError = nil
                            catcher.start(app: app)
                        }
                        .disabled(saving)
                        .accessibilityIdentifier("catcher.start")
                    }
                } header: { Text("Music Catcher") } footer: {
                    Text("Koda may pause its music while listening for up to 20 seconds. An unavailable recognition service does not prevent manual search.")
                }

                if let recognized = catcher.flow.recognized {
                    Section("Recognized Music") {
                        HStack(spacing: 12) {
                            ArtworkView(artwork: recognized.artworkURL.map { Artwork(url: $0) }, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(recognized.title).font(.headline).accessibilityIdentifier("catcher.recognized.title")
                                Text(recognized.artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Button("Search in YouTube Music", systemImage: "magnifyingglass") {
                            onSearch(recognized.searchQuery)
                            dismiss()
                        }
                    }
                }

                if catcher.flow.phase == .ready {
                    Section {
                        if catcher.flow.candidates.isEmpty {
                            Text("No matching YouTube Music songs were found. Try searching by title or artist.")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("catcher.noCandidates")
                        }
                        ForEach(catcher.flow.candidates) { candidate in
                            Button {
                                selectedID = candidate.id
                                saved = false
                                playlistAdded = false
                                saveError = nil
                            } label: { candidateRow(candidate) }
                            .buttonStyle(.plain)
                            .disabled(saving)
                            .accessibilityAddTraits(selectedID == candidate.id ? .isSelected : [])
                            .accessibilityIdentifier("catcher.candidate.\(candidate.id)")
                        }
                    } header: { Text("Choose the YouTube Music Version") } footer: {
                        Text("Check the artist and version before saving. Live, Remix and Cover recordings may be different songs.")
                    }
                }

                if let selected {
                    Section("Selected Song") {
                        Text(selected.title).font(.headline)
                        Button("Play Selected Song", systemImage: "play.fill") { player.play([selected]) }
                            .disabled(saving)
                        Button("Like on YouTube Music", systemImage: saved ? "heart.fill" : "heart") { like(selected) }
                            .disabled(saving || saved)
                            .accessibilityIdentifier("catcher.like")
                        Button("Add to Playlist", systemImage: "text.badge.plus") { playlistSong = selected }
                            .disabled(saving)
                            .accessibilityIdentifier("catcher.add")
                        if saving { ProgressView("Confirming with YouTube Music…") }
                        if saved || playlistAdded { Label("Saved to YouTube Music", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                        if let saveError { Text(saveError).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Music Catcher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(item: $playlistSong) { song in
            CloudAddToPlaylistView(songs: [song], onAdded: { _ in
                playlistAdded = true
                playlistSong = nil
            }).appEnvironment(app)
        }
        .onAppear { updateActivity(scenePhase) }
        .onChange(of: scenePhase) { _, phase in
            updateActivity(phase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            catcher.updateActivity(.active)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            catcher.updateActivity(.background)
        }
        .onChange(of: player.playbackIntentRevision) { _, revision in
            catcher.validateCurrentIntent(revision)
        }
        .onChange(of: app.roster.activeID) { _, _ in
            catcher.cancel(allowPlaybackRestore: false)
            saveTask?.cancel()
            dismiss()
        }
        .onDisappear {
            catcher.close()
            saveTask?.cancel()
        }
    }

    private func updateActivity(_ phase: ScenePhase) {
        switch phase {
        case .active: catcher.updateActivity(.active)
        case .inactive: catcher.updateActivity(.inactive)
        case .background: catcher.updateActivity(.background)
        @unknown default: catcher.updateActivity(.background)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch catcher.flow.phase {
        case .idle: EmptyView()
        case .authorizing: ProgressView("Waiting for Microphone Permission…").accessibilityIdentifier("catcher.permission")
        case .listening: ProgressView("Listening for Music…").accessibilityIdentifier("catcher.listening")
        case .searching: ProgressView("Finding YouTube Music Matches…").accessibilityIdentifier("catcher.searching")
        case .ready: EmptyView()
        case .failed(let reason):
            Text(message(for: reason)).foregroundStyle(.secondary).accessibilityIdentifier("catcher.failure")
            if reason == .permissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        }
    }

    private func candidateRow(_ candidate: MusicRecognitionCandidate) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ArtworkView(artwork: candidate.song.artwork, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.song.title).font(.body).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Text(candidate.song.artistLine).font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    if let seconds = candidate.song.duration, seconds.isFinite, seconds > 0, seconds <= 86_400 {
                        Text(Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
                    } else { Text("Duration Unavailable") }
                    if candidate.confidence == .differentVersion { Text("Different Version") }
                    else if candidate.confidence == .needsReview { Text("Check This Match") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if selectedID == candidate.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
    }

    private func like(_ song: Song) {
        guard !saving else { return }
        guard let scope = app.cloudPlaylists.captureScope() else {
            saveError = app.cloudPlaylists.availabilityMessage ?? CloudAccountAccessError.signedOut.localizedDescription
            return
        }
        saving = true
        saveError = nil
        let profile = app.roster.activeID
        saveTask = Task {
            defer { saving = false }
            do {
                try Task.checkCancellation()
                guard app.roster.activeID == profile else { return }
                try await app.cloudPlaylists.like(song: song, expectedScope: scope)
                guard !Task.isCancelled, app.roster.activeID == profile else { return }
                saved = true
            } catch {
                guard !Task.isCancelled, app.roster.activeID == profile else { return }
                saveError = error.friendlyMessage
            }
        }
    }

    private func message(for failure: MusicRecognitionFailure) -> String {
        switch failure {
        case .permissionDenied: String(localized: "Allow microphone access in Settings to recognize nearby music.")
        case .audioBusy: String(localized: "Stop video or voice recording before recognizing music.")
        case .interrupted: String(localized: "Recognition was interrupted. Start again when audio is available.")
        case .noMatch: String(localized: "No song was recognized. Move closer to the music or try again.")
        case .searchFailed: String(localized: "The music was recognized, but YouTube Music search failed. Try searching with the recognized title.")
        case .unavailable: String(localized: "Apple's music recognition service is unavailable for this app or device. Check your connection or use manual search. Some signing profiles do not support this service.")
        case .cancelled: String(localized: "Recognition Cancelled")
        }
    }
}
