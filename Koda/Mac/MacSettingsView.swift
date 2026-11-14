import KodaCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A part of the Mac's Settings window.
enum MacSettingsPane: String, CaseIterable, Identifiable {
    case profile, playback, lyrics, appearance, lastFM, discord, privacy, storage, backup, about

    var id: Self { self }

    var title: String {
        switch self {
        case .profile: String(localized: "Profiles")
        case .playback: String(localized: "Playback")
        case .lyrics: String(localized: "Lyrics")
        case .appearance: String(localized: "Appearance")
        case .lastFM: "Last.fm"
        case .discord: "Discord"
        case .privacy: String(localized: "History & Privacy")
        case .storage: String(localized: "Storage")
        case .backup: String(localized: "Back Up & Restore")
        case .about: String(localized: "About Koda")
        }
    }

    var systemImage: String {
        switch self {
        case .profile: "person.crop.circle.fill"
        case .playback: "play.fill"
        case .lyrics: "quote.bubble.fill"
        case .appearance: "circle.lefthalf.filled"
        case .lastFM: "dot.radiowaves.left.and.right"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .privacy: "hand.raised.fill"
        case .storage: "internaldrive.fill"
        case .backup: "arrow.up.doc.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .profile: .accentColor
        case .playback: .indigo
        case .lyrics: .purple
        case .appearance: .blue
        case .lastFM: .red
        case .discord: Color(red: 0.345, green: 0.396, blue: 0.949)
        case .privacy: .teal
        case .storage: .gray
        case .backup: .green
        case .about: .secondary
        }
    }
}

/// Koda's Settings on the Mac: its own window, a sidebar of panes as System Settings has, and
/// on the right each setting on a row of its own, name and explanation on the left, its
/// control on the right, in rounded groups.
struct MacSettingsView: View {
    static let windowID = "settings"
    @Environment(AppModel.self) private var app
    @State private var pane: MacSettingsPane = .playback

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(MacSettingsPane.allCases) { item in
                    Button { pane = item } label: {
                        MacSettingsSidebarRow(pane: item, isSelected: pane == item)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 30)
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 12) {
                        MacSettingsTile(systemImage: pane.systemImage, tint: pane.tint, size: 32)
                        Text(pane.title).font(.title2.bold())
                    }
                    content
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 500)
        // Edit Profile… in the sidebar's menu opens Settings on this pane.
        .onChange(of: app.requestedSettingsPane, initial: true) { _, requested in
            guard let requested else { return }
            pane = requested
            app.requestedSettingsPane = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .profile: MacProfilePane()
        case .playback: MacPlaybackPane()
        case .lyrics: MacLyricsPane()
        case .appearance: MacAppearancePane()
        case .lastFM: MacLastFMPane()
        case .discord: MacDiscordPane()
        case .privacy: MacPrivacyPane()
        case .storage: MacStoragePane()
        case .backup: MacBackupPane()
        case .about: MacAboutPane()
        }
    }
}

// MARK: - Building blocks

/// A pane's symbol on a small coloured square, as System Settings draws them.
struct MacSettingsTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct MacSettingsSidebarRow: View {
    let pane: MacSettingsPane
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            MacSettingsTile(systemImage: pane.systemImage, tint: pane.tint)
            Text(pane.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 30)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.primary.opacity(hovering ? 0.05 : 0)))
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// A rounded group of rows, with a title above and a note below when there is one.
struct MacSettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().padding(.leading, 12) }
                        row
                    }
                }
            }
            .background(.background.secondary, in: .rect(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One setting: its name, and a line on what it does, on the left; its control on the right.
struct MacSettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
    }
}

/// A toggle row, the switch on the right as on the Mac.
struct MacSettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        MacSettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private func byteText(_ bytes: Int64?) -> String {
    bytes.map { $0.formatted(.byteCount(style: .file)) } ?? "…"
}

// MARK: - Panes

/// Every profile, a click to switch, and the selected one's name, picture and account.
private struct MacProfilePane: View {
    private var tasteSummary: String {
        let taste = library.taste
        guard !taste.isEmpty else { return String(localized: "Not set up") }
        var parts: [String] = []
        if !taste.artists.isEmpty { parts.append(taste.artists.count == 1 ? String(localized: "1 artist") : String(localized: "\(taste.artists.count) artists")) }
        if !taste.genres.isEmpty { parts.append(taste.genres.count == 1 ? String(localized: "1 genre") : String(localized: "\(taste.genres.count) genres")) }
        if !taste.songs.isEmpty { parts.append(taste.songs.count == 1 ? String(localized: "1 song") : String(localized: "\(taste.songs.count) songs")) }
        return ListFormatter.localizedString(byJoining: parts)
    }

    @Environment(AppModel.self) private var app
    @State private var selected: UUID?
    @State private var photo: PhotosPickerItem?
    @State private var adding = false
    @State private var signingIn: UUID?
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var tuningTaste = false
    @Environment(Library.self) private var library

    private var profile: KodaProfile { selected.flatMap(app.roster.profile) ?? app.roster.active }

    var body: some View {
        MacSettingsGroup(title: String(localized: "Profiles"), footer: String(localized: "Each profile has its own likes, playlists, history, stats and Home.")) {
            ForEach(app.roster.profiles) { item in
                MacProfileRow(profile: item, isSelected: item.id == profile.id) { selected = item.id }
            }
            MacSettingsRow(title: "") {
                Button(String(localized: "Add Profile…"), systemImage: "plus") { adding = true }
            }
        }
        editor(profile)
            .id(profile.id)
            .sheet(isPresented: $adding) { AddProfileView().appEnvironment(app) }
            .sheet(item: Binding(get: { signingIn.map(SignInTarget.init) }, set: { signingIn = $0?.id })) { target in
                NavigationStack { YouTubeSignInView(into: target.id) { signingIn = nil } }
                    .frame(minWidth: 520, minHeight: 640)
                    .appEnvironment(app)
            }
            .onChange(of: photo) { _, item in
                guard let item else { return }
                let id = profile.id
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    app.profilePhotos.setPhoto(data, for: id)
                    photo = nil
                }
            }
    }

    @ViewBuilder
    private func editor(_ profile: KodaProfile) -> some View {
        let id = profile.id
        MacSettingsGroup(title: profile.displayName) {
            HStack(spacing: 14) {
                ProfileAvatar(profile: profile, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    TextField(String(localized: "Name"), text: Binding(get: { profile.name }, set: { name in app.roster.update(id) { $0.name = name } }))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Text(profile.subtitle).font(.system(size: 11)).foregroundStyle(profile.isExpired ? .red : .secondary)
                }
                Spacer()
            }
            .padding(12)
            MacSettingsRow(title: String(localized: "Picture")) {
                Picker(String(localized: "Picture"), selection: Binding(get: { profile.picture }, set: { picture in app.roster.update(id) { $0.picture = picture } })) {
                    Text(String(localized: "Koda Face")).tag(KodaProfile.Picture.drawn)
                    Text(String(localized: "Photo")).tag(KodaProfile.Picture.photo)
                    if profile.accountPhoto != nil { Text("Google").tag(KodaProfile.Picture.account) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch profile.picture {
            case .drawn:
                AvatarEditor(avatar: Binding(get: { profile.avatar }, set: { avatar in app.roster.update(id) { $0.avatar = avatar } }), swatch: 40)
                    .padding(12)
            case .photo:
                MacSettingsRow(title: String(localized: "Photo")) {
                    PhotosPicker(app.profilePhotos.photo(for: profile) == nil ? String(localized: "Choose Photo…") : String(localized: "Choose Another…"), selection: $photo, matching: .images)
                }
            case .account:
                EmptyView()
            }
        }
        if id == app.roster.activeID {
            MacSettingsGroup(title: String(localized: "Taste"), footer: String(localized: "The artists, genres and songs Home starts from, before and beside what you play.")) {
                MacSettingsRow(title: String(localized: "Your taste"), detail: tasteSummary) {
                    Button(library.taste.isEmpty ? String(localized: "Set Up…") : String(localized: "Edit…")) { tuningTaste = true }
                }
            }
            .sheet(isPresented: $tuningTaste) {
                OnboardingView(start: .taste, music: app.music, library: library).appEnvironment(app)
            }
        }
        MacSettingsGroup(title: "YouTube Music", footer: profile.isSignedIn
                         ? String(localized: "Home and the library follow this account. Signing out keeps the profile and everything in it on this Mac.")
                         : String(localized: "Sign in to bring your YouTube Music likes, playlists and Home to this profile. Everything already here stays.")) {
            if profile.isSignedIn {
                let syncing = app.isSyncingAccount && id == app.roster.activeID
                MacSettingsRow(title: profile.handle ?? profile.displayName,
                               detail: profile.isExpired ? String(localized: "Signed out by YouTube. Sign in again to keep in step.") : syncing ? String(localized: "Bringing in your library…") : String(localized: "Signed in")) {
                    HStack {
                        if profile.isExpired {
                            Button(String(localized: "Sign In Again…")) { signingIn = id }
                        } else if id == app.roster.activeID {
                            Button(String(localized: "Sync Now")) { app.syncAccount(force: true) }.disabled(syncing)
                        }
                        Button(String(localized: "Sign Out…")) { confirmSignOut = true }
                    }
                }
                MacSettingsToggle(title: String(localized: "Add plays to YouTube history"),
                                  detail: String(localized: "Songs played for 15 seconds appear in your YouTube Music history and shape its recommendations. Nothing is sent while listening history is off."),
                                  isOn: Binding(get: { profile.sendsPlaysToYouTube },
                                                set: { on in app.roster.update(id) { $0.sendsPlaysToYouTube = on } }))
            } else {
                MacSettingsRow(title: String(localized: "Not signed in")) {
                    Button(String(localized: "Sign In…")) { signingIn = id }
                }
            }
        }
        .confirmationDialog(String(localized: "Sign out of YouTube Music?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(String(localized: "Sign Out"), role: .destructive) { app.signOut(id) }
        } message: {
            Text("“\(profile.displayName)” stays on this Mac with its likes, playlists and history.")
        }
        if app.roster.profiles.count > 1 {
            MacSettingsGroup(footer: profile.isSignedIn
                             ? String(localized: "Deletes this profile's liked songs, playlists, history and stats from this Mac. Your YouTube Music account isn't affected.")
                             : String(localized: "Deletes this profile's liked songs, playlists, history and stats from this Mac.")) {
                MacSettingsRow(title: String(localized: "Delete Profile")) {
                    Button(String(localized: "Delete…"), role: .destructive) { confirmDelete = true }
                }
            }
            .confirmationDialog("Delete “\(profile.displayName)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(String(localized: "Delete Profile"), role: .destructive) {
                    selected = nil
                    app.deleteProfile(id)
                }
            }
        }
    }

    private struct SignInTarget: Identifiable { let id: UUID }
}

/// A profile in the Settings list: click to edit it, Switch to make it the active one.
private struct MacProfileRow: View {
    let profile: KodaProfile
    let isSelected: Bool
    let select: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            ProfileAvatar(profile: profile, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Text(profile.subtitle).font(.system(size: 11)).foregroundStyle(profile.isExpired ? .red : .secondary)
            }
            Spacer()
            if profile.id == app.roster.activeID {
                Text(String(localized: "Current")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Switch")) { app.switchProfile(to: profile.id) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MacPlaybackPane: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player

    var body: some View {
        @Bindable var player = player
        @Bindable var settings = app.settings
        MacSettingsGroup {
            MacSettingsToggle(title: String(localized: "Autoplay"), detail: String(localized: "When the queue ends, keep going with songs like the last one."),
                              isOn: $player.autoplay)
            MacSettingsToggle(title: String(localized: "Normalize volume"), detail: String(localized: "Play loud masters at a similar level to everything else."),
                              isOn: $player.normalizesVolume)
        }
        MacSettingsGroup(title: String(localized: "Song Transitions"), footer: String(localized: "With AutoMix or crossfade on, skipping a song fades it out quickly instead of cutting it off.")) {
            MacSettingsRow(title: String(localized: "Transitions"), detail: String(localized: "AutoMix blends songs like a DJ, lining up beats and skipping silence. Crossfade overlaps the end of one song with the start of the next.")) {
                Picker(String(localized: "Transitions"), selection: $player.transitions) {
                    Text(String(localized: "AutoMix")).tag(Player.Transitions.autoMix)
                    Text(String(localized: "Crossfade")).tag(Player.Transitions.crossfade)
                    Text(String(localized: "Off")).tag(Player.Transitions.off)
                }
                .labelsHidden()
                .fixedSize()
            }
            MacSettingsRow(title: String(localized: "Crossfade overlap")) {
                HStack(spacing: 8) {
                    Slider(value: $player.crossfadeDuration, in: 1...12, step: 1)
                        .frame(width: 180)
                    Text("\(Int(player.crossfadeDuration)) s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .controlSize(.small)
            }
            .disabled(player.transitions != .crossfade)
        }
        MacSettingsGroup(title: String(localized: "Sound"), footer: String(localized: "Data Saver streams use about a third of the data, and Low Data Mode always uses it. Downloads and songs kept as you play them are always high quality.")) {
            MacSettingsRow(title: String(localized: "Equalizer"), detail: String(localized: "Shapes every song you play. Boosted songs play a little quieter, so loud ones never distort.")) {
                Picker(String(localized: "Equalizer"), selection: $player.equalizer) {
                    ForEach(EqualizerPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                        if preset == .off { Divider() }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            MacSettingsRow(title: String(localized: "Streaming"), detail: String(localized: "On Wi‑Fi and Ethernet.")) {
                qualityPicker(String(localized: "Streaming"), selection: $player.unmeteredQuality)
            }
            MacSettingsRow(title: String(localized: "Streaming on a personal hotspot"), detail: String(localized: "Or any network macOS marks as metered.")) {
                qualityPicker(String(localized: "Streaming on a personal hotspot"), selection: $player.meteredQuality)
            }
        }
        MacSettingsGroup(title: String(localized: "Videos"), footer: settings.videoModeEnabled
                         ? String(localized: "Space or K plays and pauses, J and L skip 10 seconds, ← and → skip 5, F goes full screen and Esc leaves it, M mutes. Double-click a video for full screen.")
                         : nil) {
            MacSettingsToggle(title: String(localized: "Video mode"), detail: String(localized: "YouTube itself beside your music: Videos, your channels and Explore join the sidebar, with the video player."),
                              isOn: $settings.videoModeEnabled)
            if settings.videoModeEnabled {
                MacSettingsRow(title: String(localized: "Default quality"), detail: String(localized: "Videos start at this, or the best they have below it. Auto follows the connection.")) {
                    Picker(String(localized: "Default quality"), selection: $settings.videoQuality) {
                        ForEach(AppSettings.videoQualities, id: \.self) { Text(VideoQualityName.long($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                MacSettingsToggle(title: String(localized: "Autoplay next video"), detail: String(localized: "When a video ends, the next in Up Next starts after a short countdown."),
                                  isOn: $settings.autoplaysVideos)
            }
        }
        MacSettingsGroup(title: String(localized: "Skipping"), footer: String(localized: "⌥⌘← and ⌥⌘→ skip back and ahead too, with the buttons shown or not.")) {
            MacSettingsToggle(title: String(localized: "Skip buttons"), detail: String(localized: "Beside play in the player bar and Now Playing, to jump within the song."),
                              isOn: $settings.showsSkipButtons)
            MacSettingsRow(title: String(localized: "Skip by")) {
                Picker(String(localized: "Skip by"), selection: $settings.skipInterval) {
                    ForEach(AppSettings.SkipInterval.allCases) { Text("\($0.rawValue) s").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        MacSettingsGroup(title: String(localized: "Volume"), footer: String(localized: "A Mac app can't set the system volume, so this is Koda's own level, under the system's. ⌘↑ and ⌘↓ change it too.")) {
            MacSettingsRow(title: String(localized: "Koda's volume")) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        .frame(width: 180)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .controlSize(.small)
            }
        }
    }

    private func qualityPicker(_ title: String, selection: Binding<StreamQuality>) -> some View {
        Picker(title, selection: selection) {
            ForEach(StreamQuality.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct MacLyricsPane: View {
    @Environment(AppModel.self) private var app
    @State private var showsCustomSources = false

    var body: some View {
        @Bindable var settings = app.settings
        let order = settings.lyricsSourceOrder
        MacSettingsGroup(title: String(localized: "Sources"),
                         footer: String(localized: "Koda asks every source at once. Word-by-word lyrics win; among equals, the higher source wins. At least one stays on.")) {
            ForEach(Array(order.enumerated()), id: \.element) { index, source in
                MacSettingsRow(title: source.title, detail: source.detail) {
                    HStack(spacing: 4) {
                        Button { settings.lyricsSourceOrder.move(fromOffsets: [index], toOffset: index - 1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .disabled(index == 0)
                        .help(String(localized: "Move Up"))
                        Button { settings.lyricsSourceOrder.move(fromOffsets: [index], toOffset: index + 2) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .disabled(index == order.count - 1)
                        .help(String(localized: "Move Down"))
                        Toggle(source.title, isOn: Binding(get: { settings.isEnabled(source) }, set: { settings.setEnabled(source, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .disabled(settings.isEnabled(source) && settings.enabledLyricsSourceCount == 1)
                            .padding(.leading, 6)
                    }
                    .buttonStyle(.borderless)
                }
            }
            MacSettingsRow(title: String(localized: "Custom Lyrics Sources")) {
                Button("Manage") { showsCustomSources = true }
            }
        }
        .sheet(isPresented: $showsCustomSources) {
            NavigationStack {
                CustomLyricsSourcesView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsCustomSources = false }
                        }
                    }
            }
            .appEnvironment(app)
            .frame(minWidth: 440, minHeight: 480)
        }
        MacSettingsGroup(title: String(localized: "Display")) {
            MacSettingsRow(title: String(localized: "Text size")) {
                Picker(String(localized: "Text size"), selection: $settings.lyricsSize) {
                    ForEach(AppSettings.LyricsSize.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            MacSettingsToggle(title: String(localized: "Word motion"), detail: String(localized: "Each word lifts as it's sung, and long notes swell."), isOn: $settings.lyricsMotion)
            MacSettingsToggle(title: String(localized: "Backing vocals"), detail: String(localized: "Shown smaller, under their line."), isOn: $settings.showsBackingVocals)
            MacSettingsToggle(title: String(localized: "Duet sides"), detail: String(localized: "The second singer's lines sit on the right."), isOn: $settings.duetSides)
        }
        MacSettingsGroup(footer: String(localized: "Lyrics found earlier are kept until Koda quits. This forgets them, so the next song asks the sources again.")) {
            MacSettingsRow(title: String(localized: "Look up lyrics again")) {
                Button(String(localized: "Forget Found Lyrics")) { Task { await app.lyricsTranslation.clearLyricsCache() } }
            }
        }
    }
}

private struct MacAppearancePane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        MacSettingsGroup {
            MacSettingsRow(title: String(localized: "Appearance")) {
                Picker(String(localized: "Appearance"), selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
            MacSettingsToggle(title: String(localized: "Moving player colours"),
                              detail: String(localized: "The playing song's colours drift behind Now Playing. They always hold still with Reduce Motion on."),
                              isOn: $settings.animatesPlayerBackground)
            MacSettingsRow(title: String(localized: "Animated art"),
                           detail: String(localized: "Album covers that move in Now Playing, found by looking up the playing song's title and artist in Apple Music's catalogue.")) {
                Picker(String(localized: "Animated art"), selection: $settings.animatedArt) {
                    ForEach(AppSettings.AnimatedArt.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        MacSettingsGroup(title: String(localized: "Home")) {
            MacSettingsToggle(title: String(localized: "Charts on Home"),
                              detail: String(localized: "YouTube Music's global and local charts as a row on Home."),
                              isOn: $settings.showsChartsOnHome)
        }
    }
}

private struct MacLastFMPane: View {
    @Environment(AppModel.self) private var app
    @Environment(LastFM.self) private var lastFM

    var body: some View {
        MacSettingsGroup(footer: String(localized: "Keep a record of what you play on your Last.fm profile. Your account, history and connection live on the Last.fm page in the sidebar.")) {
            MacSettingsRow(title: lastFM.isConnected ? String(localized: "Connected as \(lastFM.user)") : String(localized: "Not connected"),
                           detail: lastFM.isConnected ? LastFMUI.status(lastFM) : String(localized: "Connect with your own free Last.fm API account.")) {
                Button(lastFM.isConnected ? String(localized: "Open Last.fm") : String(localized: "Connect…")) { app.requestedMacSection = .lastFM }
            }
            if lastFM.isConnected {
                MacSettingsToggle(title: String(localized: "Scrobble"), isOn: Binding(get: { lastFM.isEnabled }, set: { lastFM.setEnabled($0) }))
            }
        }
    }
}

private struct MacDiscordPane: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        MacSettingsGroup(footer: String(localized: "Your Discord profile shows “Listening to” the song, with its cover and a link to it on YouTube Music. It needs the Discord app open on this Mac, and the song leaves your profile a minute after you pause.")) {
            MacSettingsToggle(title: String(localized: "Show what you're playing"), isOn: $settings.sharesOnDiscord)
            if settings.sharesOnDiscord {
                MacSettingsRow(title: String(localized: "Status"), detail: detail) {
                    Text(status).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var status: String {
        guard app.settings.savesListeningHistory else { return String(localized: "Paused") }
        return switch app.discord?.status ?? .off {
        case .off, .waiting: String(localized: "Waiting for a song")
        case .unavailable: String(localized: "Discord isn't open")
        case .showing: String(localized: "On your profile")
        case .refused: String(localized: "Not accepted")
        }
    }

    private var detail: String? {
        guard app.settings.savesListeningHistory else { return String(localized: "Nothing is shared while listening history is off.") }
        return switch app.discord?.status ?? .off {
        case .unavailable: String(localized: "Koda keeps looking, and shows the song once Discord opens.")
        case .refused: String(localized: "Discord didn't accept this song's details.")
        default: nil
        }
    }
}

private struct MacPrivacyPane: View {
    @Environment(AppModel.self) private var app
    @Environment(Library.self) private var library
    @State private var confirm: Confirm?

    private enum Confirm: Identifiable {
        case history, searches, stats
        var id: Self { self }
    }

    var body: some View {
        @Bindable var settings = app.settings
        MacSettingsGroup(footer: String(localized: "With listening history off, songs you play don't reach Recently Played, Quick picks, Your Mix, your stats, Last.fm or Discord. What's saved stays until you clear it.")) {
            MacSettingsToggle(title: String(localized: "Save listening history"), isOn: $settings.savesListeningHistory)
            MacSettingsToggle(title: String(localized: "Save search history"), isOn: $settings.savesSearchHistory)
        }
        MacSuggestLessGroup()
        MacSettingsGroup(title: String(localized: "Clear")) {
            MacSettingsRow(title: String(localized: "Listening history"), detail: String(localized: "Recently Played and Quick picks start over.")) {
                Button(String(localized: "Clear…")) { confirm = .history }.disabled(library.recent.isEmpty)
            }
            MacSettingsRow(title: String(localized: "Search history")) {
                Button(String(localized: "Clear…")) { confirm = .searches }.disabled(library.searches.isEmpty)
            }
            MacSettingsRow(title: String(localized: "Listening stats"), detail: String(localized: "Play counts, listening time and streaks.")) {
                Button(String(localized: "Reset…")) { confirm = .stats }.disabled(library.songStats.isEmpty)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { item in
            Button(item == .stats ? String(localized: "Reset Stats") : String(localized: "Clear"), role: .destructive) {
                switch item {
                case .history:
                    library.clearHistory()
                    app.player.clearSmartShuffleHistory()
                case .searches: library.clearSearches()
                case .stats: library.clearStats()
                }
            }
        }
    }

    private var confirmTitle: String {
        switch confirm {
        case .history: String(localized: "Clear your listening history?")
        case .searches: String(localized: "Clear your search history?")
        case .stats: String(localized: "Reset your listening stats?")
        case nil: ""
        }
    }
}

private struct MacStoragePane: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    @State private var artworkBytes: Int64?
    @State private var cacheBytes: Int64?
    @State private var confirmsRemoveAll = false

    var body: some View {
        @Bindable var player = player
        @Bindable var settings = app.settings
        MacSettingsGroup(title: String(localized: "Downloads"), footer: String(localized: "Downloaded songs play without a connection and stay until you remove them.")) {
            MacSettingsRow(title: String(localized: "Downloaded songs"), detail: String(localized: "\(downloads.songs.count) songs · \(downloads.bytes.formatted(.byteCount(style: .file)))")) {
                Button(String(localized: "Remove All…")) { confirmsRemoveAll = true }.disabled(downloads.songs.isEmpty)
            }
        }
        MacSettingsGroup(title: String(localized: "Listening cache"),
                         footer: String(localized: "Songs are kept as you play them, so they start at once next time and play offline. Past the limit, the ones played longest ago go first.")) {
            MacSettingsToggle(title: String(localized: "Keep songs you play"), isOn: $player.cachesWhileStreaming)
            MacSettingsRow(title: String(localized: "Up to")) {
                Picker(String(localized: "Up to"), selection: $settings.cacheLimit) {
                    ForEach(AppSettings.CacheLimit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: settings.cacheLimit) { _, limit in
                    downloads.store.cacheLimit = limit.rawValue
                    Task { await measure() }
                }
            }
            MacSettingsRow(title: String(localized: "Used"), detail: byteText(cacheBytes)) {
                Button(String(localized: "Clear")) {
                    downloads.store.clearCache()
                    Task { await measure() }
                }
                .disabled((cacheBytes ?? 0) == 0)
            }
        }
        MacSettingsGroup(title: String(localized: "Artwork"), footer: String(localized: "Covers are kept so pages open quickly. Cleared, they download again as you browse. Never more than 300 MB.")) {
            MacSettingsRow(title: String(localized: "Used"), detail: byteText(artworkBytes)) {
                Button(String(localized: "Clear")) {
                    Task {
                        await ImagePipeline.shared.clear()
                        await measure()
                    }
                }
                .disabled((artworkBytes ?? 0) == 0)
            }
        }
        .confirmationDialog(String(localized: "Remove all downloads?"), isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button(String(localized: "Remove All Downloads"), role: .destructive) { downloads.removeAll() }
        } message: {
            Text(String(localized: "They'll play from YouTube again, which needs a connection."))
        }
        .task { await measure() }
    }

    private func measure() async {
        let artwork = await ImagePipeline.shared.diskUsage()
        let store = downloads.store
        let audio = await Task.detached { store.cacheBytes }.value
        artworkBytes = Int64(artwork)
        cacheBytes = audio
    }
}

private struct MacBackupPane: View {
    @Environment(Library.self) private var library
    @State private var exportDocument: LibraryBackupDocument?
    @State private var importing = false
    @State private var importingAndroid = false
    @State private var pendingRestore: Data?
    @State private var outcome: String?

    var body: some View {
        MacSettingsGroup(footer: String(localized: "A backup holds liked songs, your playlists, saved albums, playlists and artists, history, stats and lyric timings. Last.fm sign-in isn't included.")) {
            MacSettingsRow(title: String(localized: "Back up library"), detail: String(localized: "Save everything to one file.")) {
                Button(String(localized: "Back Up…")) {
                    if let data = library.backupData() { exportDocument = LibraryBackupDocument(data: data) }
                }
            }
            MacSettingsRow(title: String(localized: "Restore from backup"), detail: String(localized: "Replaces everything in your library with what the backup holds.")) {
                Button(String(localized: "Restore…")) { importing = true }
            }
        }
        MacSettingsGroup(title: "Koda for Android", footer: AndroidImportSummary.explanation) {
            MacSettingsRow(title: String(localized: "Import from Koda for Android"), detail: String(localized: "Choose the backup file you made in Koda on your phone.")) {
                Button(String(localized: "Import…")) { importingAndroid = true }
                    // Its own importer, on its own button: two on one view and only one opens.
                    .androidBackupImporter(isPresented: $importingAndroid, outcome: $outcome)
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json,
                      defaultFilename: String(localized: "Koda Library \(Date().formatted(.iso8601.year().month().day()))")) { result in
            if case .success = result { outcome = String(localized: "Your library is backed up.") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { pendingRestore = data } else { outcome = String(localized: "Koda couldn't read that file.") }
        }
        .confirmationDialog(String(localized: "Replace your library with this backup?"),
                            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
                            titleVisibility: .visible) {
            Button(String(localized: "Replace Library"), role: .destructive) {
                guard let data = pendingRestore else { return }
                do {
                    try library.restore(from: data)
                    outcome = String(localized: "Your library is restored.")
                } catch {
                    outcome = error.localizedDescription
                }
            }
        } message: {
            Text(String(localized: "What's in your library now is replaced."))
        }
        .alert(outcome ?? "", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {}
        }
    }
}

private struct MacAboutPane: View {
    var body: some View {
        MacSettingsGroup(footer: String(localized: "Koda is an unofficial client and isn't affiliated with YouTube or Google. Lyrics come from YouLyPlus, BetterLyrics and LRCLIB. App icon by sameerasw (github.com/sameerasw).")) {
            MacSettingsRow(title: String(localized: "Version")) {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
            MacSettingsRow(title: String(localized: "Koda on GitHub")) {
                Link(String(localized: "Open"), destination: URL(string: "https://github.com/Ivorisnoob/Koda-iOS")!)
            }
            MacSettingsRow(title: "Koda for Android") {
                Link(String(localized: "Open"), destination: URL(string: "https://github.com/Ivorisnoob/Koda")!)
            }
        }
    }
}
