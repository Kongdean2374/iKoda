import KodaCore
import SwiftUI
import UniformTypeIdentifiers

extension LyricsTranslationMode {
    var title: String {
        switch self {
        case .quick: String(localized: "Quick Translation")
        case .quality: String(localized: "High Quality Translation")
        case .immersive: String(localized: "Immersive Translation")
        }
    }
}

struct LyricsVersionsView: View {
    @Environment(AppModel.self) private var app
    @State private var resetAll = false
    @State private var importing = false
    @State private var importSong: Song?
    @State private var importScope = UUID()
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        List {
            Section("Current Lyrics Version") {
                if let current = versions.current { candidateLink(current) }
                else { Text("No Lyrics") }
                if let recommendation = versions.recommendation {
                    LabeledContent("Auto Recommendation", value: recommendation.sourceName)
                }
                if versions.preference.selected != nil {
                    Button("Restore Automatic Selection") { Task { await versions.select(nil) } }
                        .accessibilityIdentifier("lyrics.sources.automatic")
                }
            }
            Section {
                if versions.searching { ProgressView("Searching Lyrics…") }
                if let error = versions.error { Text(error).foregroundStyle(.secondary) }
                if !versions.searching && versions.candidates.isEmpty {
                    Text("No additional versions found.").foregroundStyle(.secondary)
                }
                ResultsList(results: versions.results, showsRetry: true)
            } header: {
                Text("Available Versions")
            }
            Section {
                if let song = versions.song {
                    NavigationLink("Search Lyrics Manually") { LyricsManualSearchView(song: song) }
                        .accessibilityIdentifier("lyrics.sources.manual")
                    Button("Import Original Lyrics…") { importSong = song; importScope = versions.profileScope; importing = true }
                }
                Button("Refresh Versions") { versions.search(force: true, userInitiated: true) }
                    .disabled(!versions.canSearch)
                    .accessibilityIdentifier("lyrics.sources.refresh")
                NavigationLink("Manage Lyrics Sources") { LyricsSettingsView() }
                Button("Clear All Saved Version Choices", role: .destructive) { resetAll = true }
            }
        }
        .navigationTitle("Lyrics Sources")
        .task {
            let returned = Set(versions.results.map(\.source))
            if !versions.searching, versions.configuredSources.contains(where: { !returned.contains($0.id) }) {
                versions.search(userInitiated: true)
            }
        }
        .confirmationDialog("Clear All Saved Version Choices", isPresented: $resetAll, titleVisibility: .visible) {
            Button("Clear All Saved Version Choices", role: .destructive) { Task { await versions.resetAllSelections() } }
        } message: {
            Text("Version choices will return to automatic. Corrections and edited translations are kept.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .xml, .data]) { result in
            guard let song = importSong else { return }
            let scope = importScope
            Task {
                do {
                    let url = try result.get()
                    let candidate = try await Task.detached(priority: .userInitiated) {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        guard let data = try handle.read(upToCount: 1_000_001), data.count <= 1_000_000,
                              let text = String(data: data, encoding: .utf8),
                              let candidate = LyricsCandidate.imported(song: song, sourceName: String(localized: "Imported Lyrics"), text: text) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        return candidate
                    }.value
                    await versions.select(candidate, expectedScope: scope)
                } catch { versions.error = error.localizedDescription }
            }
        }
    }
}

private struct ResultsList: View {
    let results: [LyricsSourceResult]
    let showsRetry: Bool
    @Environment(AppModel.self) private var app
    var body: some View {
        ForEach(results, id: \.source) { result in
            if result.state != .found {
                HStack {
                    VStack(alignment: .leading) {
                        Text(result.name)
                        Text(result.state.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if showsRetry {
                        Button("Retry") { app.lyricsTranslation.versions.search(source: result.source, userInitiated: true) }
                            .buttonStyle(.borderless)
                            .disabled(!app.lyricsTranslation.versions.canSearch)
                    }
                }
            }
            ForEach(result.candidates) { candidateLink($0) }
        }
    }
}

private extension LyricsSourceResult.State {
    var title: LocalizedStringKey {
        switch self {
        case .found: "Lyrics Found"
        case .empty: "No Lyrics"
        case .timedOut: "Source Timed Out"
        case .invalid: "Invalid Lyrics Response"
        case .rateLimited: "Source Rate Limited"
        case .failed: "Source Unavailable"
        case .cancelled: "Search Cancelled"
        }
    }
}

@MainActor private func candidateLink(_ candidate: LyricsCandidate) -> some View {
    NavigationLink {
        LyricsVersionPreview(candidate: candidate)
    } label: {
        VStack(alignment: .leading, spacing: 5) {
            Text(candidate.metadata.title ?? candidate.sourceName).font(.headline)
            Text([candidate.sourceName, candidate.id.upstream].compactMap { $0 }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(candidate.format.title)
                Text("\(candidate.lineCount) Lines")
                Text(candidate.match.confidence.title)
                    .foregroundStyle(candidate.match.confidence == .conflict ? Color.orange : Color.secondary)
            }
            .font(.caption)
        }
    }
    .accessibilityIdentifier("lyrics.candidate.\(candidate.id.source)")
}

private extension LyricsCandidate.Format {
    var title: LocalizedStringKey {
        switch self {
        case .word: "Word Synced"
        case .line: "Line Synced"
        case .plain: "Plain Text Lyrics"
        }
    }
}

private extension LyricsMatch.Confidence {
    var title: LocalizedStringKey {
        switch self {
        case .high: "High Confidence"
        case .medium: "Medium Confidence"
        case .low: "Low Confidence"
        case .conflict: "Recording May Not Match"
        }
    }
}

private extension LyricsMatch.Evidence {
    var title: LocalizedStringKey {
        switch self {
        case .title: "Matching Title"
        case .artist: "Matching Artist"
        case .duration: "Matching Duration"
        case .recording: "Matching Recording Version"
        case .album: "Matching Album"
        case .differentTitle: "Different Title"
        case .differentArtist: "Different Artist"
        case .differentDuration: "Different Duration"
        case .differentRecording: "Different Recording Version"
        case .missingMetadata: "Some Source Details Are Missing"
        }
    }
}

private struct LyricsManualSearchView: View {
    let song: Song
    @Environment(AppModel.self) private var app
    @State private var query: LyricsSearch
    @State private var duration: String
    @State private var source: String?
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    init(song: Song) {
        self.song = song
        _query = State(initialValue: LyricsSearch(song: song))
        _duration = State(initialValue: song.duration.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $query.title)
                TextField("Artist", text: $query.artist)
                TextField("Album", text: Binding(get: { query.album ?? "" }, set: { query.album = $0.isEmpty ? nil : $0 }))
                TextField("Duration in Seconds", text: $duration)
                Picker("Lyrics Sources", selection: $source) {
                    Text("All Enabled Sources").tag(String?.none)
                    ForEach(versions.configuredSources, id: \.id) { item in Text(item.name).tag(Optional(item.id)) }
                }
                Button("Search") {
                    var search = query
                    search.credits = []
                    search.duration = duration.isEmpty ? nil : (try? Double(duration, format: .number))
                    versions.manualSearch(search, source: source)
                }
                .disabled(query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !versions.canSearch)
                .accessibilityIdentifier("lyrics.manual.submit")
                Button("Clear Search Fields") {
                    query.title = ""; query.artist = ""; query.album = nil; duration = ""; source = nil
                }
                Button("Restore Song Details") {
                    query = .init(song: song)
                    duration = song.duration?.formatted(.number.precision(.fractionLength(0...1))) ?? ""
                    source = nil
                }
            }
            Section("Manual Search Results") {
                if versions.searchingManually { ProgressView("Searching Lyrics…") }
                else if versions.manualResults.isEmpty { Text("No additional versions found.") }
                ResultsList(results: versions.manualResults, showsRetry: false)
            }
        }
        .navigationTitle("Search Lyrics Manually")
    }
}

struct LyricsPreviewRow: Identifiable, Sendable {
    let id: Int
    let text: String
    let time: TimeInterval?

    static func make(_ lyrics: Lyrics) -> [Self] {
        switch lyrics {
        case .plain(let text): LyricsCandidate.plainLines(text).enumerated().map { .init(id: $0.offset, text: $0.element, time: nil) }
        case .synced(let lines): lines.map { .init(id: $0.id, text: $0.text, time: $0.time) }
        }
    }
}

private struct LyricsVersionPreview: View {
    let candidate: LyricsCandidate
    @Environment(AppModel.self) private var app
    @State private var filter = ""
    @State private var largeText = false
    @State private var cached: [Int: String] = [:]
    @State private var calibrating = false
    @State private var editing = false
    @State private var scope = UUID()
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        List {
            Section {
                Button("Use This Version") { Task { await versions.select(candidate, expectedScope: scope) } }
                    .accessibilityIdentifier("lyrics.candidate.use")
                Button("Edit Translation") { editing = true }
                    .accessibilityIdentifier("lyrics.candidate.edit")
                if candidate.format != .plain {
                    Button("Calibrate Lyrics Timing") { calibrating = true }
                        .accessibilityIdentifier("lyrics.candidate.calibrate")
                } else { Text("Plain text lyrics have no timing to adjust.").foregroundStyle(.secondary) }
                Toggle("Large Lyrics Text", isOn: $largeText)
                if let error = versions.error { Text(error).foregroundStyle(.secondary) }
            }
            Section("Source Details") {
                LabeledContent("Lyrics Sources", value: candidate.sourceName)
                if let upstream = candidate.id.upstream { LabeledContent("Upstream Source", value: upstream) }
                metadata("Title", value: candidate.metadata.title)
                metadata("Artist", value: candidate.metadata.artist)
                metadata("Album", value: candidate.metadata.album)
                if let duration = candidate.metadata.duration {
                    LabeledContent("Duration", value: duration.formatted(.number.precision(.fractionLength(1))) + " s")
                    if let played = versions.song?.duration {
                        LabeledContent("Duration Difference", value: (duration - played).formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " s")
                    }
                } else { metadata("Duration", value: nil) }
                LabeledContent("Lyrics Format") { Text(candidate.format.title) }
                LabeledContent("Match Confidence") { Text(candidate.match.confidence.title) }
                LabeledContent("Match Score", value: candidate.match.score.formatted(.number.precision(.fractionLength(1))))
                ForEach(candidate.match.evidence, id: \.self) { Text($0.title).font(.caption) }
            }
            Section("Complete Lyrics") {
                let edits = versions.edits(for: candidate)
                ForEach(LyricsPreviewRow.make(candidate.lyrics).filter { filter.isEmpty
                    || $0.text.localizedCaseInsensitiveContains(filter)
                    || (edits[$0.id] ?? cached[$0.id] ?? "").localizedCaseInsensitiveContains(filter) }) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        if let time = row.time {
                            Text(time, format: .number.precision(.fractionLength(2)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(row.text).font(largeText ? .title2 : .body).textSelection(.enabled)
                        if let translation = edits[row.id] ?? cached[row.id] {
                            Text(translation).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Lyrics Preview")
        .searchable(text: $filter, prompt: "Find in Lyrics")
        .onAppear { scope = versions.profileScope }
        .task(id: app.settings.lyricsTranslationMode) {
            cached = await app.lyricsTranslation.cachedTranslation(for: candidate, mode: app.settings.lyricsTranslationMode)
        }
        .sheet(isPresented: $calibrating) { NavigationStack { LyricsVersionCalibration(candidate: candidate, scope: scope) }.appEnvironment(app) }
        .sheet(isPresented: $editing) { NavigationStack { LyricsVersionEditor(candidate: candidate, automatic: cached, scope: scope) }.appEnvironment(app) }
    }

    private func metadata(_ title: LocalizedStringKey, value: String?) -> some View {
        LabeledContent(title) {
            if let value { Text(value) } else { Text("Unknown") }
        }
    }
}

private struct LyricsVersionCalibration: View {
    let candidate: LyricsCandidate
    let scope: UUID
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 0
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        Form {
            Section {
                LabeledContent("Current Delay", value: value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))))
                    .accessibilityIdentifier("lyrics.calibration.value")
                Slider(value: $value, in: -30...30, step: 0.1) { Text("Calibrate Lyrics Timing") }
                ForEach([[-1.0, -0.5, -0.1], [0.1, 0.5, 1.0]], id: \.self) { group in
                    HStack {
                        ForEach(group, id: \.self) { amount in
                            Button(amount.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)))) {
                                value = min(30, max(-30, ((value + amount) * 10).rounded() / 10))
                            }
                            .buttonStyle(.borderless)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .accessibilityIdentifier("lyrics.calibration.\(amount)")
                        }
                    }
                }
                Button("Reset Delay") { value = 0 }
            } footer: { Text("Positive values show lyrics later on both displays. The phone and CarPlay delays are added separately.") }
            if player.current?.id == candidate.songID, case .synced(let lines) = candidate.lyrics {
                Section("Timing Preview") {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let time = player.position(at: context.date) - value - library.lyricsOffset(for: candidate.songID)
                        if let index = Lyrics.index(of: time, in: lines) { Text(lines[index].text) }
                        else { Text("Waiting for the next lyric…") }
                    }
                }
            }
            if let error = versions.error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Calibrate Lyrics Timing")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { if await versions.saveOffset(value, for: candidate, expectedScope: scope) { dismiss() } } }
                    .accessibilityIdentifier("lyrics.calibration.save")
            }
        }
        .onAppear { value = versions.preference.offset(for: candidate.id) }
    }
}

private struct LyricsVersionEditor: View {
    let candidate: LyricsCandidate
    let automatic: [Int: String]
    let scope: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var edits: [Int: String] = [:]
    @State private var resetAll = false
    @State private var saving = false
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        Form {
            ForEach(LyricsPreviewRow.make(candidate.lyrics)) { row in
                Section {
                    Text(row.text).font(.headline)
                    TextField("Your Translation", text: Binding(get: { edits[row.id] ?? "" }, set: { edits[row.id] = $0 }), axis: .vertical)
                        .accessibilityIdentifier("lyrics.edit.line.\(row.id)")
                    if let translated = automatic[row.id] { Text(translated).foregroundStyle(.secondary) }
                    if edits[row.id] != nil {
                        Button("Restore Automatic Line") { edits[row.id] = nil }
                    }
                }
            }
            Button("Restore All Automatic Lines", role: .destructive) { resetAll = true }
            if let error = versions.error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle("Edit Translation")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saving = true
                    Task {
                        if await versions.saveEdits(edits, for: candidate, expectedScope: scope) { dismiss() }
                        saving = false
                    }
                }
                .disabled(saving)
                .accessibilityIdentifier("lyrics.edit.save")
            }
        }
        .confirmationDialog("Restore All Automatic Lines", isPresented: $resetAll, titleVisibility: .visible) {
            Button("Restore All Automatic Lines", role: .destructive) { edits = [:] }
        }
        .onAppear { edits = versions.edits(for: candidate) }
    }
}
