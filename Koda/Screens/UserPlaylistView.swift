import KodaCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Older on-device playlists remain readable and exportable. They never become a
/// second destination for new playlist writes in 0.6.0.
struct UserPlaylistView: View {
    let id: UUID
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var profileID: UUID?
    @State private var migrating = false
    @State private var migrated: CloudPlaylistSnapshot?
    @State private var confirmHide = false
    @State private var exporting = false
    @State private var preparingBackup = false
    @State private var backup: LegacyPlaylistBackupDocument?
    @State private var errorMessage: String?
    @State private var remoteID: String?

    var body: some View {
        Group {
            if let playlist = library.userPlaylist(id) {
                List {
                    Section {
                        HStack(spacing: 14) {
                            PlaylistCover(playlist: playlist, size: 72)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.songs.count) songs").foregroundStyle(.secondary)
                            }
                        }
                        Text("Legacy On-Device Playlist").font(.subheadline.weight(.semibold))
                        Text("This is preserved data from an older Koda version. New playlists are stored on YouTube Music. Export a backup or choose to upload this playlist; nothing is migrated or deleted automatically.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Export Playlist Backup", systemImage: "square.and.arrow.up") { export(playlist) }
                            .disabled(preparingBackup)
                            .accessibilityIdentifier("legacy.playlist.export")
                        if let remoteID {
                            Button("Open Cloud Playlist", systemImage: "icloud") {
                                app.open(.playlist(PlaylistSummary(id: remoteID, title: playlist.name)))
                            }
                            Button("Hide Legacy Copy") { confirmHide = true }
                        } else {
                            Button("Upload to YouTube Music", systemImage: "icloud.and.arrow.up") { migrating = true }
                                .accessibilityIdentifier("legacy.playlist.upload")
                        }
                    }
                    if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
                    Section("Songs") {
                        ForEach(Array(playlist.songs.enumerated()), id: \.offset) { index, song in
                            SongRow(song: song) { player.play(playlist.songs, startAt: index) }
                        }
                    }
                }
                .navigationTitle(playlist.name)
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $migrating, onDismiss: { if migrated != nil { confirmHide = true } }) {
                    CloudPlaylistCreateView(songs: playlist.songs, suggestedTitle: playlist.name, onCreated: { confirmed in
                        guard let profileID, profileID == app.roster.activeID else { return }
                        LegacyPlaylistVisibility.recordMigration(id, remoteID: confirmed.id, profileID: profileID)
                        remoteID = confirmed.id
                        migrated = confirmed
                        migrating = false
                    }).appEnvironment(app)
                }
                .confirmationDialog("Hide the Legacy Copy?", isPresented: $confirmHide, titleVisibility: .visible) {
                    Button("Hide Legacy Copy") {
                        guard let profileID, profileID == app.roster.activeID else { return }
                        LegacyPlaylistVisibility.setHidden(id, true, profileID: profileID)
                    }
                } message: {
                    Text("The cloud playlist has been confirmed. Hiding only changes this device's archive display; the original backup data is kept and can be shown again.")
                }
            } else {
                ContentUnavailableView("Playlist Unavailable", systemImage: "music.note.list")
            }
        }
        .onAppear { profileID = app.roster.activeID; remoteID = LegacyPlaylistVisibility.remoteID(id, profileID: app.roster.activeID) }
        .onChange(of: app.roster.activeID) { _, _ in migrating = false; confirmHide = false; dismiss() }
        .fileExporter(isPresented: $exporting, document: backup, contentType: .json,
                      defaultFilename: "Koda-legacy-\(id.uuidString).json") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
    }

    private func export(_ playlist: UserPlaylist) {
        let cover = playlist.hasCover ? library.playlistCoverFile(id) : nil
        let profile = app.roster.activeID
        preparingBackup = true; errorMessage = nil
        Task {
            defer { preparingBackup = false }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try LegacyPlaylistBackupDocument(playlist: playlist, cover: cover)
                }.value
                guard profile == app.roster.activeID else { return }
                backup = document; exporting = true
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct LegacyPlaylistArchiveView: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var showsHidden = false
    @State private var hidden: Set<String> = []

    var body: some View {
        List {
            Section {
                Text("Older on-device playlists are kept for backup and optional upload. They are not used as destinations for new playlists.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Show Hidden Legacy Copies", isOn: $showsHidden)
            }
            ForEach(library.userPlaylists.filter { showsHidden || !hidden.contains($0.id.uuidString) }) { playlist in
                NavigationLink { UserPlaylistView(id: playlist.id) } label: {
                    HStack(spacing: 12) {
                        PlaylistCover(playlist: playlist, size: 44)
                        VStack(alignment: .leading) {
                            Text(playlist.name).lineLimit(2)
                            Text("\(playlist.songs.count) songs").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    if hidden.contains(playlist.id.uuidString) {
                        Button("Show Legacy Copy") {
                            LegacyPlaylistVisibility.setHidden(playlist.id, false, profileID: app.roster.activeID)
                            reload()
                        }
                    }
                }
            }
        }
        .navigationTitle("Legacy Playlist Archive")
        .onAppear(perform: reload)
        .onChange(of: app.roster.activeID) { _, _ in reload() }
    }
    private func reload() { hidden = LegacyPlaylistVisibility.hidden(profileID: app.roster.activeID) }
}

@MainActor
enum LegacyPlaylistVisibility {
    static func hidden(profileID: UUID) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "koda.legacyPlaylists.hidden.\(profileID.uuidString)") ?? [])
    }
    static func setHidden(_ id: UUID, _ hidden: Bool, profileID: UUID) {
        var values = Self.hidden(profileID: profileID)
        if hidden { values.insert(id.uuidString) } else { values.remove(id.uuidString) }
        UserDefaults.standard.set(values.sorted(), forKey: "koda.legacyPlaylists.hidden.\(profileID.uuidString)")
    }
    static func remoteID(_ id: UUID, profileID: UUID) -> String? {
        UserDefaults.standard.string(forKey: "koda.legacyPlaylists.upload.\(profileID.uuidString).\(id.uuidString)")
    }
    static func recordMigration(_ id: UUID, remoteID: String, profileID: UUID) {
        UserDefaults.standard.set(remoteID, forKey: "koda.legacyPlaylists.upload.\(profileID.uuidString).\(id.uuidString)")
    }
}

private nonisolated struct LegacyPlaylistBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    private struct Backup: Encodable { let version = 1; let playlist: UserPlaylist; let coverJPEG: Data? }
    init(playlist: UserPlaylist, cover: URL?) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(Backup(playlist: playlist, coverJPEG: try cover.map { try Data(contentsOf: $0) }))
    }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// A playlist's cover: the first four distinct covers in a grid, one when there are fewer, a gradient when there are none.
struct PlaylistMosaic: View {
    let songs: [Song]
    var size: CGFloat
    var cornerRadius: CGFloat = 10

    private var covers: [Artwork] {
        var seen = Set<URL>()
        return songs.compactMap(\.artwork).filter { seen.insert($0.url(pixels: 120)).inserted }.prefix(4).map { $0 }
    }

    var body: some View {
        let covers = covers
        ZStack {
            if covers.count >= 4 {
                let half = size / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ArtworkView(artwork: covers[0], size: half, cornerRadius: 0)
                        ArtworkView(artwork: covers[1], size: half, cornerRadius: 0)
                    }
                    HStack(spacing: 0) {
                        ArtworkView(artwork: covers[2], size: half, cornerRadius: 0)
                        ArtworkView(artwork: covers[3], size: half, cornerRadius: 0)
                    }
                }
            } else if let first = covers.first {
                ArtworkView(artwork: first, size: size, cornerRadius: 0)
            } else {
                LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.35)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note.list")
                    .font(.system(size: size * 0.32, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
    }
}

/// One of the listener's playlists drawn as its photo when they chose one, else its mosaic.
struct PlaylistCover: View {
    let playlist: UserPlaylist
    var size: CGFloat
    var cornerRadius: CGFloat = 10
    @Environment(Library.self) private var library

    var body: some View {
        if playlist.hasCover, let image = PlaylistCoverImages.image(for: playlist, in: library) {
            Color.clear
                .frame(width: size, height: size)
                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5))
        } else {
            PlaylistMosaic(songs: playlist.songs, size: size, cornerRadius: cornerRadius)
        }
    }
}

/// Playlist photos, read once each and kept by playlist and photo version, so a new photo is
/// never shown as the old one.
@MainActor
enum PlaylistCoverImages {
    private static var cache: [String: UIImage] = [:]

    static func image(for playlist: UserPlaylist, in library: Library) -> UIImage? {
        let key = "\(playlist.id)-\(playlist.coverVersion)"
        if let hit = cache[key] { return hit }
        guard let file = library.playlistCoverFile(playlist.id),
              let image = (try? Data(contentsOf: file)).flatMap(UIImage.init(data:)) else { return nil }
        cache[key] = image
        return image
    }

    /// A picked photo cropped to a square 1024 pixels wide, as JPEG; nil if it isn't an image.
    nonisolated static func squareJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: min(1024, side), height: min(1024, side))
        let scale = target.width / side
        let squared = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(x: -(image.size.width - side) / 2 * scale, y: -(image.size.height - side) / 2 * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
        return squared.jpegData(compressionQuality: 0.85)
    }
}

/// The colour of the playlist's first cover behind its header, as album pages have.
private struct PlaylistGlow: View {
    let songs: [Song]
    @State private var palette = PaletteModel()

    var body: some View {
        ArtworkGlow(palette: palette.palette)
            .task(id: songs.first?.artwork) { await palette.load(songs.first?.artwork) }
    }
}


/// The existing song/album/queue entry now always opens the same verified cloud picker.
struct AddToPlaylistSheet: View {
    let target: AppModel.PlaylistTarget
    var body: some View { CloudAddToPlaylistView(songs: target.songs) }
}

extension View {
    func playlistPicker(whenOnTop isOnTop: Bool) -> some View { modifier(PlaylistPickerModifier(isOnTop: isOnTop)) }
}

private struct PlaylistPickerModifier: ViewModifier {
    let isOnTop: Bool
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { isOnTop ? app.playlistTarget : nil },
                                   set: { if isOnTop { app.playlistTarget = $0 } })) { target in
            AddToPlaylistSheet(target: target).appEnvironment(app)
        }
    }
}

struct AddToPlaylistMenu: View {
    let songs: [Song]
    @Environment(AppModel.self) private var app
    var body: some View {
        Button("Add to Playlist…", systemImage: "text.badge.plus") { app.addToPlaylist(songs) }
    }
}

struct MacNewPlaylistSheet: View {
    let target: AppModel.PlaylistTarget
    var body: some View { CloudPlaylistCreateView(songs: target.songs) }
}
