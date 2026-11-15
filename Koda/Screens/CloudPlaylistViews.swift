import KodaCore
import SwiftUI

/// Shared account/operation surfaces keep remote writes visible after their originating
/// sheet disappears. No action here substitutes a local playlist for a cloud result.
struct CloudPlaylistSessionNotice: View {
    @Environment(AppModel.self) private var app
    @State private var showsProfile = false

    var body: some View {
        if let message = app.cloudPlaylists.availabilityMessage {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Sign In to YouTube Music") { showsProfile = true }
                    .buttonStyle(.glass)
            }
            .sheet(isPresented: $showsProfile) { ProfileView().appEnvironment(app) }
        }
    }
}

struct CloudPlaylistOperationView: View {
    @Environment(AppModel.self) private var app
    @State private var recovering = false
    @State private var actionError: String?

    var body: some View {
        if let state = app.cloudPlaylists.operation {
            VStack(alignment: .leading, spacing: 8) {
                Label(state.title, systemImage: icon(state.phase))
                    .font(.subheadline.weight(.semibold))
                if let detail = state.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("cloud.operation.detail")
                }
                if state.phase == .running {
                    ProgressView(value: Double(state.completedCount), total: Double(max(1, state.totalCount)))
                    Text("\(state.completedCount) of \(state.totalCount)")
                        .font(.caption).monospacedDigit()
                    Button("Cancel") { app.cloudPlaylists.cancel() }
                }
                if state.canRetry {
                    Button("Check Cloud Status Again") {
                        guard let scope = app.cloudPlaylists.captureScope() else { return }
                        Task {
                            do { _ = try await app.cloudPlaylists.retry(expectedScope: scope); actionError = nil }
                            catch { actionError = playlistToolboxErrorMessage(error) }
                        }
                    }
                    .disabled(app.cloudPlaylists.isBusy)
                    .accessibilityIdentifier("cloud.operation.retry")
                }
                if state.canRecoverCreation {
                    Button("Find the Created Playlist") { recovering = true }
                        .accessibilityIdentifier("cloud.operation.recover")
                }
                if state.canDismiss {
                    Button("Dismiss Status") { app.cloudPlaylists.clearStatus(); actionError = nil }
                }
                if let actionError { Text(actionError).font(.footnote).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $recovering) { CloudPlaylistRecoveryView().appEnvironment(app) }
        }
    }

    private func icon(_ phase: CloudPlaylistOperationState.Phase) -> String {
        switch phase {
        case .running: "icloud.and.arrow.up"
        case .succeeded: "checkmark.icloud"
        case .failed, .needsConfirmation: "exclamationmark.icloud"
        case .cancelled: "xmark.icloud"
        }
    }
}

struct CloudPlaylistCreateView: View {
    var songs: [Song] = []
    var suggestedTitle = ""
    var onCreated: ((CloudPlaylistSnapshot) -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var errorMessage: String?
    @State private var result: CloudPlaylistSnapshot?
    @State private var profileID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section { CloudPlaylistSessionNotice(); CloudPlaylistOperationView() }
                if let result {
                    Section {
                        Label("Confirmed on YouTube Music", systemImage: "checkmark.icloud")
                            .accessibilityIdentifier("cloud.create.confirmed")
                        Text(result.title).font(.headline)
                        Text("\(result.songs.count) songs")
                        Button("Open Playlist") { dismiss(); app.open(.playlist(result.playlist)) }
                    }
                } else {
                    Section {
                        TextField("Playlist Name", text: $title)
                            .accessibilityIdentifier("cloud.create.name")
                        Text("\(songs.count) songs").foregroundStyle(.secondary)
                        Button("Create Cloud Playlist", action: create)
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || !app.cloudPlaylists.hasSession || app.cloudPlaylists.isBusy)
                            .accessibilityIdentifier("cloud.create.submit")
                    } footer: {
                        Text("A private playlist will be created in your YouTube Music account. It is complete only after the cloud result is confirmed.")
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
            }
            .navigationTitle("New Cloud Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear { title = suggestedTitle; profileID = app.roster.activeID }
            .onChange(of: app.roster.activeID) { _, _ in dismiss() }
        }
    }

    private func create() {
        guard profileID == app.roster.activeID, result == nil, !app.cloudPlaylists.isBusy else { return }
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        let expected = profileID, name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        Task {
            do {
                guard expected == app.roster.activeID else { return }
                let confirmed = try await app.cloudPlaylists.create(title: name, songs: songs, expectedScope: scope)
                guard expected == app.roster.activeID else { return }
                result = confirmed
                onCreated?(confirmed)
            } catch {
                guard expected == app.roster.activeID else { return }
                errorMessage = playlistToolboxErrorMessage(error)
            }
        }
    }
}

struct CloudAddToPlaylistView: View {
    let songs: [Song]
    var excludingID: String?
    var onAdded: ((CloudPlaylistSnapshot) -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var choices: [EditablePlaylist] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selected: EditablePlaylist?
    @State private var showsConfirmation = false
    @State private var creating = false
    @State private var result: CloudPlaylistSnapshot?
    @State private var profileID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section { CloudPlaylistSessionNotice(); CloudPlaylistOperationView() }
                if let result {
                    Section {
                        Label("Confirmed on YouTube Music", systemImage: "checkmark.icloud")
                        Text(result.title)
                            .accessibilityIdentifier("cloud.add.confirmed")
                    }
                }
                Section {
                    Button("New Cloud Playlist", systemImage: "plus") { creating = true }
                        .disabled(!app.cloudPlaylists.hasSession || app.cloudPlaylists.isBusy)
                    if loading { ProgressView("Loading Playlists…") }
                    ForEach(choices.filter { $0.id != excludingID }) { playlist in
                        Button {
                            selected = playlist
                            showsConfirmation = true
                        } label: {
                            Label(playlist.title, systemImage: "music.note.list")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .disabled(app.cloudPlaylists.isBusy)
                        .accessibilityIdentifier("cloud.destination.\(playlist.id)")
                    }
                    if !loading, choices.isEmpty, app.cloudPlaylists.hasSession, errorMessage == nil {
                        Text("No editable cloud playlists were returned. Create one or refresh your account.")
                            .foregroundStyle(.secondary)
                    }
                } header: { Text("Editable YouTube Music Playlists") }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary); Button("Retry") { Task { await load() } } } }
                Section {
                    Text("YouTube Music determines which playlists you can edit. Existing entries are preserved; new entries are verified before completion.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add to Cloud Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { profileID = app.roster.activeID; await load() }
            .refreshable { await load() }
            .onChange(of: app.roster.activeID) { _, _ in dismiss() }
            .confirmationDialog("Add Songs to This Cloud Playlist?", isPresented: $showsConfirmation, titleVisibility: .visible) {
                Button("Add Songs") { if let selected { add(to: selected.id) } }
            } message: {
                if let selected { Text("Add \(songs.count) songs to “\(selected.title)” on YouTube Music.") }
            }
            .sheet(isPresented: $creating) {
                CloudPlaylistCreateView(songs: songs, onCreated: { confirmed in
                    result = confirmed; creating = false; onAdded?(confirmed)
                }).appEnvironment(app)
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        let expected = app.roster.activeID
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        loading = true; errorMessage = nil
        defer { if expected == app.roster.activeID { loading = false } }
        do {
            let values = try await app.cloudPlaylists.editablePlaylists(for: songs, expectedScope: scope)
            guard !Task.isCancelled, expected == app.roster.activeID else { return }
            choices = values
        } catch {
            guard !Task.isCancelled, expected == app.roster.activeID else { return }
            errorMessage = playlistToolboxErrorMessage(error)
        }
    }

    private func add(to id: String) {
        guard profileID == app.roster.activeID, !app.cloudPlaylists.isBusy else { return }
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        let expected = profileID
        errorMessage = nil
        Task {
            do {
                guard expected == app.roster.activeID else { return }
                let confirmed = try await app.cloudPlaylists.add(songs: songs, to: id, expectedScope: scope)
                guard expected == app.roster.activeID else { return }
                result = confirmed; onAdded?(confirmed)
            } catch {
                guard expected == app.roster.activeID else { return }
                errorMessage = playlistToolboxErrorMessage(error)
            }
        }
    }
}

private struct CloudPlaylistRecoveryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var selected: PlaylistSummary?
    @State private var confirming = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("The earlier creation response was lost. Choose the playlist you verified on YouTube Music. Koda will keep its existing songs and continue the unfinished addition; it will not create another playlist.")
                        .font(.footnote)
                    Button("Refresh Cloud Playlists") { Task { await app.cloudPlaylists.refresh(force: true) } }
                    if app.cloudPlaylists.isRefreshing { ProgressView() }
                }
                Section("Matching Cloud Playlists") {
                    ForEach(app.cloudPlaylists.catalog.filter { $0.title == app.cloudPlaylists.pendingCreationTitle }) { playlist in
                        Button { selected = playlist; confirming = true } label: {
                            VStack(alignment: .leading) {
                                Text(playlist.title)
                                Text(playlist.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        .disabled(app.cloudPlaylists.isBusy)
                    }
                    if app.cloudPlaylists.catalog.allSatisfy({ $0.title != app.cloudPlaylists.pendingCreationTitle }) {
                        Text("No matching playlist is visible yet. Check YouTube Music, then refresh again.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Confirm Created Playlist")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await app.cloudPlaylists.refresh(force: true) }
            .onChange(of: app.roster.activeID) { _, _ in dismiss() }
            .confirmationDialog("Continue with This Playlist?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Keep Existing Songs and Continue") {
                    guard let selected, let scope = app.cloudPlaylists.captureScope() else { return }
                    Task {
                        do { _ = try await app.cloudPlaylists.recoverCreation(using: selected.id, expectedScope: scope); dismiss() }
                        catch { errorMessage = playlistToolboxErrorMessage(error) }
                    }
                }
            } message: {
                if let selected { Text(selected.title + "\n" + selected.id) }
            }
        }
    }
}

struct CloudPlaylistManagementView: View {
    let playlist: PlaylistSummary
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: CloudPlaylistSnapshot?
    @State private var name = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var confirmsRename = false

    var body: some View {
        NavigationStack {
            Form {
                Section { CloudPlaylistSessionNotice(); CloudPlaylistOperationView() }
                if loading { Section { ProgressView("Loading Playlists…") } }
                if let snapshot {
                    Section {
                        Label(snapshot.capabilities.canRename ? String(localized: "Editable Cloud Playlist") : String(localized: "Read-Only Cloud Playlist"),
                              systemImage: snapshot.capabilities.canRename ? "pencil" : "lock")
                        Text(snapshot.title).font(.headline)
                        Text("\(snapshot.songs.count) songs")
                    }
                    if snapshot.capabilities.canRename {
                        Section("Rename Cloud Playlist") {
                            TextField("Playlist Name", text: $name).accessibilityIdentifier("cloud.rename.name")
                            Button("Rename on YouTube Music") { confirmsRename = true }
                                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || name == snapshot.title || app.cloudPlaylists.isBusy)
                                .accessibilityIdentifier("cloud.rename.submit")
                        }
                    }
                    Section {
                        Text("Reordering and deleting cloud playlists are not currently supported in Koda. Use YouTube Music for these operations, then refresh here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let url = URL(string: "https://music.youtube.com/playlist?list=\(snapshot.id)") {
                            Link("Open in YouTube Music", destination: url)
                        }
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
                Section { Button("Refresh Cloud Playlist") { Task { await load() } }.disabled(loading || app.cloudPlaylists.isBusy) }
            }
            .navigationTitle("Cloud Playlist Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
            .onChange(of: app.roster.activeID) { _, _ in dismiss() }
            .confirmationDialog("Rename This Cloud Playlist?", isPresented: $confirmsRename, titleVisibility: .visible) {
                Button("Rename on YouTube Music") { rename() }
                    .accessibilityIdentifier("cloud.rename.confirm")
            } message: { Text(name) }
        }
    }

    private func load() async {
        let profile = app.roster.activeID
        guard let scope = app.cloudPlaylists.captureScope() else { return }
        loading = true; errorMessage = nil
        defer { loading = false }
        do {
            let value = try await app.cloudPlaylists.loadSnapshot(id: playlist.id, expectedScope: scope)
            guard !Task.isCancelled, profile == app.roster.activeID else { return }
            snapshot = value; name = value.title
        } catch {
            guard profile == app.roster.activeID else { return }
            errorMessage = playlistToolboxErrorMessage(error)
        }
    }
    private func rename() {
        guard let snapshot, !app.cloudPlaylists.isBusy, let scope = app.cloudPlaylists.captureScope() else { return }
        let profile = app.roster.activeID, title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        Task {
            do {
                guard profile == app.roster.activeID else { return }
                let result = try await app.cloudPlaylists.rename(id: snapshot.id, previousTitle: snapshot.title, title: title, expectedScope: scope)
                guard profile == app.roster.activeID else { return }
                self.snapshot = result; name = result.title
            } catch {
                guard profile == app.roster.activeID else { return }
                errorMessage = playlistToolboxErrorMessage(error)
            }
        }
    }
}
