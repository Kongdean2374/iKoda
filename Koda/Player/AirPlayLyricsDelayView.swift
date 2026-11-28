import KodaCore
import SwiftUI

extension AppModel {
    var usesAirPlay: Bool { player.audioOutputRoute.outputs.contains { $0.kind == .airPlay } }

    func effectiveLyricsOffset(_ songID: String?, version: TimeInterval? = nil) -> TimeInterval {
        guard let songID else { return 0 }
        return LyricsDisplayTiming.correction(song: library.lyricsOffset(for: songID),
            version: version ?? lyricsTranslation.versions.offset(for: songID),
            airPlay: library.airPlayLyricsDelay, isAirPlay: usesAirPlay)
    }
}

struct AirPlayLyricsDelayView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scene

    var body: some View {
        Form {
            Section {
                if let route = player.audioOutputRoute.outputs.first(where: { $0.kind == .airPlay }) {
                    LabeledContent("AirPlay", value: route.name)
                } else { Text("AirPlay is not connected.").foregroundStyle(.secondary) }
                let value = library.airPlayLyricsDelay
                LabeledContent("AirPlay Lyrics Delay", value: value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))))
                Slider(value: Binding(get: { library.airPlayLyricsDelay }, set: { library.setAirPlayLyricsDelay($0) }),
                       in: -10...10, step: 0.1) { Text("AirPlay Lyrics Delay") }
                HStack {
                    Button("Earlier by 0.1 Seconds") { library.setAirPlayLyricsDelay(value - 0.1) }
                    Spacer()
                    Button("Later by 0.1 Seconds") { library.setAirPlayLyricsDelay(value + 0.1) }
                }
                .buttonStyle(.borderless)
                Button("Reset") { library.setAirPlayLyricsDelay(0) }
            } footer: {
                Text("Positive values show lyrics later. This delay is shared by AirPlay receivers and only applies while AirPlay is connected.")
            }
            Section("Synced Preview") {
                if let song = player.current, let candidate = app.lyricsTranslation.versions.current,
                   candidate.songID == song.id, case .synced(let lines) = candidate.lyrics {
                    TimelineView(.animation(minimumInterval: 0.12, paused: !player.wantsToPlay || scene != .active)) { context in
                        let time = player.position(at: context.date) + SyncedLyrics.lead - app.effectiveLyricsOffset(song.id)
                        if let index = Lyrics.index(of: time, in: lines) { Text(lines[index].text).font(.title3.weight(.semibold)) }
                        else { Text("Waiting for the First Line").foregroundStyle(.secondary) }
                    }
                } else { Text("No Synchronized Lyrics").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("AirPlay Lyrics Delay")
    }
}

struct InstrumentalTrackButton: View {
    let song: Song
    @Environment(Library.self) private var library

    var body: some View {
        let marked = library.instrumentalSongs[song.id] != nil
        Button {
            library.setInstrumental(song, marked: !marked)
        } label: {
            Label(marked ? "Remove Instrumental Mark" : "Mark as Instrumental",
                  systemImage: marked ? "text.bubble" : "music.note")
        }
    }
}

struct InstrumentalTracksView: View {
    @Environment(Library.self) private var library
    @State private var query = ""
    @State private var byArtist = false
    @State private var selected: Set<String> = []

    private var matches: [Song] {
        library.instrumentalSongs.values.filter {
            query.isEmpty || $0.title.localizedStandardContains(query) || $0.artistLine.localizedStandardContains(query)
        }.sorted {
            let a = byArtist ? $0.artistLine : $0.title
            let b = byArtist ? $1.artistLine : $1.title
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        List {
            ForEach(matches) { song in
                Button {
                    if !selected.insert(song.id).inserted { selected.remove(song.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(song.id) ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading) {
                            Text(song.title)
                            Text(song.artistLine).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected.contains(song.id) ? .isSelected : [])
                .swipeActions {
                    Button("Remove Instrumental Mark") {
                        library.setInstrumental(song, marked: false)
                        selected.remove(song.id)
                    }.tint(.accentColor)
                }
            }
        }
        .overlay { if matches.isEmpty { ContentUnavailableView("No Instrumental Marks", systemImage: "music.note") } }
        .searchable(text: $query)
        .navigationTitle("Instrumental Tracks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("Sort", systemImage: "arrow.up.arrow.down") {
                    Picker("Sort", selection: $byArtist) {
                        Text("Title").tag(false)
                        Text("Artist").tag(true)
                    }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Remove Selected Marks") {
                    library.unmarkInstrumental(selected)
                    selected = []
                }.disabled(selected.isEmpty)
            }
        }
    }
}
