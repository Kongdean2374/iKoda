import KodaCore
import SwiftUI
import UniformTypeIdentifiers

struct LyricsVersionsView: View {
    @Environment(AppModel.self) private var app
    @State private var resetAll = false
    @State private var filter = Filter.all
    @State private var showOther = false

    private enum Filter: CaseIterable, Hashable {
        case all, word, line, plain
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .word: "Word Synced"
            case .line: "Line Synced"
            case .plain: "Plain Text Lyrics"
            }
        }
        func includes(_ candidate: LyricsCandidate) -> Bool {
            switch self {
            case .all: true
            case .word: [.partialWords, .highCoverageWords, .completeWords].contains(candidate.timing.grade)
            case .line: candidate.timing.grade == .line
            case .plain: candidate.timing.grade == .plain
            }
        }
    }
    @State private var importing = false
    @State private var importSong: Song?
    @State private var importScope = UUID()
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        List {
            if let song = versions.song {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title).font(.headline)
                            Text(song.artistLine).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        ArtworkView(artwork: song.artwork, size: 42)
                    }
                }
            }
            Section("Current Lyrics Version") {
                if let current = versions.current { candidateLink(current, identifier: "lyrics.current.version", selected: true) }
                else { Text("No Lyrics") }
                if let recommendation = versions.recommendation {
                    LabeledContent("Auto Recommendation", value: recommendation.sourceName)
                    if recommendation.id != versions.current?.id {
                        Text("A recommended version is available to switch to.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if versions.preference.selected != nil {
                    Button("Restore Automatic Selection") { Task { await versions.select(nil) } }
                        .accessibilityIdentifier("lyrics.sources.automatic")
                }
            }
            Section("Available Versions") {
                Picker("Lyrics Format", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if versions.searching { ProgressView("Searching Lyrics…") }
                if let error = versions.error { Text(error).foregroundStyle(.secondary) }
                let all = versions.candidates + (versions.preference.localVersions ?? [])
                    .filter { item in !versions.candidates.contains(where: { $0.id == item.id }) }
                let matches = all.filter(filter.includes)
                let trusted = matches.filter { !isFlagged($0) }
                let other = matches.filter(isFlagged)
                ForEach(trusted) { candidateRow($0) }
                if !other.isEmpty {
                    DisclosureGroup("Other Versions to Verify", isExpanded: $showOther) {
                        ForEach(other) { candidateRow($0) }
                    }
                }
                if !versions.searching && matches.isEmpty {
                    Text("No additional versions found.").foregroundStyle(.secondary)
                }
            }
            Section("Lyrics Source Status") {
                let results = Dictionary(uniqueKeysWithValues: versions.results.map { ($0.source, $0) })
                ForEach(versions.configuredSources, id: \.id) { source in
                    if let result = results[source.id] {
                        SourceStatusRow(result: result)
                    } else {
                        HStack {
                            Text(source.name)
                            Spacer()
                            Text(versions.searching ? "Searching Lyrics…" : "Not Searched").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                if let song = versions.song {
                    NavigationLink("Search Lyrics Manually") { LyricsManualSearchView(song: song, scope: versions.profileScope) }
                        .accessibilityIdentifier("lyrics.sources.manual")
                    Button("Import Original Lyrics…") { importSong = song; importScope = versions.profileScope; importing = true }
                    InstrumentalTrackButton(song: song)
                }
                Button("Refresh Versions") { versions.search(force: true, userInitiated: true) }
                    .disabled(!versions.canSearch)
                    .accessibilityIdentifier("lyrics.sources.refresh")
                NavigationLink("Manage Lyrics Sources") { LyricsSettingsView() }
                NavigationLink("Instrumental Tracks") { InstrumentalTracksView() }
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
    private func isFlagged(_ candidate: LyricsCandidate) -> Bool {
        let assessment = versions.assessments[candidate.id]
        return candidate.match.confidence == .conflict
            || assessment?.content == .conflict || assessment?.content == .differentRecording
            || (candidate.match.confidence == .low && assessment?.content != .verified)
    }

    private func candidateRow(_ candidate: LyricsCandidate) -> some View {
        candidateLink(candidate, recommended: candidate.id == versions.recommendation?.id,
                      selected: candidate.id == versions.current?.id, content: versions.assessments[candidate.id]?.content)
    }

}

private struct SourceStatusRow: View {
    let result: LyricsSourceResult
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(result.name)
                Text(result.state.title).font(.caption).foregroundStyle(.secondary)
                if let until = result.retryAt, until > Date() {
                    Text(until, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if result.state != .found && result.state != .empty {
                Button("Retry") { app.lyricsTranslation.versions.search(source: result.source, userInitiated: true) }
                    .buttonStyle(.borderless)
                    .disabled(!app.lyricsTranslation.versions.canSearch)
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
            ForEach(result.candidates) { candidate in
                candidateLink(candidate, recommended: showsRetry && candidate.id == app.lyricsTranslation.versions.recommendation?.id)
            }
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

@MainActor private func candidateLink(_ candidate: LyricsCandidate, identifier: String? = nil, recommended: Bool = false,
                                    selected: Bool = false, content: LyricsCandidateAssessment.Content? = nil) -> some View {
    NavigationLink {
        LyricsVersionPreview(candidate: candidate)
    } label: {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.sourceName).font(.headline)
                Text(candidate.timing.grade.title).font(.subheadline).foregroundStyle(.secondary)
                if candidate.match.confidence == .conflict || content == .differentRecording {
                    Text([candidate.metadata.title, candidate.metadata.artist].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Recording May Not Match", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                } else if let content, content != .unconfirmed {
                    Text(content.title).font(.caption).foregroundStyle(.secondary)
                }
                if recommended { Text("Auto Recommendation").font(.caption).foregroundStyle(Color.accentColor) }
            }
            Spacer(minLength: 4)
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
    }
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier(identifier ?? "lyrics.candidate.\(candidate.id.source)")
}

private extension LyricTimingQuality.Grade {
    var title: LocalizedStringKey {
        switch self {
        case .completeWords: "Complete Word Sync"
        case .highCoverageWords: "High Coverage Word Sync"
        case .partialWords: "Partial Word Sync"
        case .line: "Line Synced"
        case .plain: "Plain Text Lyrics"
        }
    }
}

private extension LyricsMatch.Confidence {
    var title: LocalizedStringKey {
        switch self {
        case .high: "Recording Identity Matched"
        case .medium: "Some Metadata Missing"
        case .low: "Recording Needs Confirmation"
        case .conflict: "Recording May Not Match"
        }
    }
}

private extension LyricsCandidateAssessment.Content {
    var title: LocalizedStringKey {
        switch self {
        case .unconfirmed: "Original Text Not Yet Verified"
        case .textAgrees: "Original Text Agrees · Timing Unconfirmed"
        case .verified: "Original Text and Timing Cross-Verified"
        case .differentRecording: "Original Text Agrees · Recording May Differ"
        case .conflict: "Original Text Conflicts"
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

struct LyricsManualSearchView: View {
    let song: Song
    let scope: UUID
    @Environment(AppModel.self) private var app
    @State private var query: LyricsSearch
    @State private var duration: String
    @State private var source: String?
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    init(song: Song, scope: UUID) {
        self.song = song
        self.scope = scope
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
                    versions.manualSearch(search, source: source, songID: song.id, scope: scope)
                }
                .disabled(query.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !versions.canSearch || versions.profileScope != scope || versions.song?.id != song.id)
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
                if versions.profileScope == scope, versions.song?.id == song.id {
                    ResultsList(results: versions.manualResults, showsRetry: false)
                }
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
    @Environment(Player.self) private var player
    @State private var filter = ""
    @State private var largeText = false
    @State private var previewing = false
    @State private var cached: [Int: String] = [:]
    @State private var calibrating = false
    @State private var editing = false
    @State private var scope: UUID?
    private var versions: LyricsVersions { app.lyricsTranslation.versions }

    var body: some View {
        List {
            Section {
                Button("Use This Version") {
                    if let scope { Task { await versions.select(candidate, expectedScope: scope) } }
                }
                .disabled(scope != versions.profileScope)
                    .accessibilityIdentifier("lyrics.candidate.use")
                Button("Edit Translation") { editing = true }
                    .accessibilityIdentifier("lyrics.candidate.edit")
                if candidate.format != .plain {
                    Button("Calibrate Lyrics Timing") { calibrating = true }
                        .accessibilityIdentifier("lyrics.candidate.calibrate")
                } else { Text("Plain text lyrics have no timing to adjust.").foregroundStyle(.secondary) }
                Toggle("Large Lyrics Text", isOn: $largeText)
                if candidate.format != .plain, player.current?.id == candidate.songID {
                    Toggle("Synced Preview", isOn: $previewing)
                }
                if let error = versions.error { Text(error).foregroundStyle(.secondary) }
            }
            if previewing, player.current?.id == candidate.songID, case .synced(let lines) = candidate.lyrics {
                Section("Synced Preview") {
                    TimelineView(.animation(minimumInterval: 0.125, paused: !player.wantsToPlay)) { context in
                        let correction = app.effectiveLyricsOffset(candidate.songID, version: versions.preference.offset(for: candidate.id))
                        let time = player.position(at: context.date) + SyncedLyrics.lead - correction
                        if let index = Lyrics.index(of: time, in: lines) {
                            LyricRow(line: lines[index], isCurrent: true, distance: 0, hasDuet: false,
                                     offset: correction, style: LyricsStyle(app.settings), player: player)
                        } else { Text("Waiting for the First Line").foregroundStyle(.secondary) }
                    }
                }
            }
            Section("Source Details") {
                LabeledContent("Lyrics Sources", value: candidate.sourceName)
                if let upstream = candidate.id.upstream ?? candidate.metadata.provenance { LabeledContent("Upstream Source", value: upstream) }
                if let recordingID = candidate.metadata.recordingID { LabeledContent("Recording ISRC", value: recordingID) }
                metadata("Title", value: candidate.metadata.title)
                metadata("Artist", value: candidate.metadata.artist)
                metadata("Album", value: candidate.metadata.album)
                if let duration = candidate.metadata.duration {
                    LabeledContent("Duration", value: duration.formatted(.number.precision(.fractionLength(1))) + " s")
                    if let played = versions.song?.duration {
                        LabeledContent("Duration Difference", value: (duration - played).formatted(.number.sign(strategy: .always()).precision(.fractionLength(1))) + " s")
                    }
                } else { metadata("Duration", value: nil) }
                LabeledContent("Recording Identity") { Text(candidate.match.confidence.title) }
                LabeledContent("Match Score", value: candidate.match.identityScore.formatted(.number.precision(.fractionLength(1))))
                ForEach(candidate.match.evidence, id: \.self) { Text($0.title).font(.caption) }
            }
            verification
            Section("Complete Lyrics") {
                let edits = versions.edits(for: candidate)
                let embedded = candidate.embeddedTranslations?.first(where: \.isChinese)?.lines ?? [:]
                ForEach(LyricsPreviewRow.make(candidate.lyrics).filter { filter.isEmpty
                    || $0.text.localizedCaseInsensitiveContains(filter)
                    || (edits[$0.id] ?? embedded[$0.id] ?? cached[$0.id] ?? "").localizedCaseInsensitiveContains(filter) }) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        if let time = row.time {
                            Text(time, format: .number.precision(.fractionLength(2)))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(row.text).font(largeText ? .title2 : .body).textSelection(.enabled)
                        if let translation = edits[row.id] ?? embedded[row.id] ?? cached[row.id] {
                            Text(translation).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle("Lyrics Preview")
        .searchable(text: $filter, prompt: "Find in Lyrics")
        .onAppear { if scope == nil { scope = versions.profileScope } }
        .task(id: candidate.id) {
            let result = await app.lyricsTranslation.cachedTranslation(for: candidate)
            if !Task.isCancelled, scope == versions.profileScope { cached = result }
        }
        .sheet(isPresented: $calibrating) {
            if let scope { NavigationStack { LyricsVersionCalibration(candidate: candidate, scope: scope) }.appEnvironment(app) }
        }
        .sheet(isPresented: $editing) {
            if let scope { NavigationStack { LyricsVersionEditor(candidate: candidate, automatic: cached, scope: scope) }.appEnvironment(app) }
        }
    }

    private var verification: some View {
        let assessment = versions.assessments[candidate.id]
        let timing = assessment?.timing ?? candidate.timing
        return Section("Lyrics Verification") {
            LabeledContent("Original Text Agreement") { Text((assessment?.content ?? .unconfirmed).title) }
            if let compared = assessment?.comparedSource { LabeledContent("Compared Source", value: compared) }
            if let sources = assessment?.independentSources, sources > 0 {
                LabeledContent("Independent Sources", value: sources.formatted())
            }
            if let similarity = assessment?.similarity {
                LabeledContent("Text Sequence Similarity", value: percentage(similarity))
            }
            LabeledContent("Relative Lyrics Completeness", value: assessment?.completeness.map(percentage) ?? String(localized: "Unknown"))
            LabeledContent("Lyrics Format") { Text(timing.grade.title) }
            if timing.grade != .plain {
                LabeledContent("Valid Word Coverage", value: percentage(timing.wordCoverage))
                LabeledContent("Fully Word-Synced Lines", value: timing.timedLines.formatted() + " / " + timing.sungLines.formatted())
                if timing.voicedLines > 0 { LabeledContent("Lines With Multiple Voices", value: timing.voicedLines.formatted()) }
                if timing.invalidTimes > 0 { LabeledContent("Invalid Timestamps", value: timing.invalidTimes.formatted()) }
                if timing.textMismatches > 0 { LabeledContent("Word Timing Text Mismatches", value: timing.textMismatches.formatted()) }
            }
            if versions.recommendation?.id == candidate.id {
                if assessment?.content == .verified {
                    Text("Recommended because the original text and timing agree with an independent source.")
                } else if candidate.match.confidence == .high || candidate.match.confidence == .medium {
                    Text("Recommended using the available recording evidence and synchronization quality.")
                } else {
                    Text("This version needs confirmation. Independent recording evidence is incomplete.")
                }
            } else if candidate.match.confidence == .conflict || assessment?.excludesAutomaticSelection == true {
                Text("This version needs review because its recording, text, or timing disagrees.")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func percentage(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0...1)))
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
                let seconds = value.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)))
                LabeledContent("Current Delay", value: seconds)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current Delay")
                    .accessibilityValue(seconds)
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
            } footer: { Text("Positive values show lyrics later. AirPlay delay is added only while AirPlay is connected.") }
            if player.current?.id == candidate.songID, case .synced(let lines) = candidate.lyrics {
                Section("Timing Preview") {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let time = player.position(at: context.date) + SyncedLyrics.lead - app.effectiveLyricsOffset(candidate.songID, version: value)
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
                    TextField("Your Translation", text: Binding(get: { edits[row.id] ?? "" }, set: { edits[row.id] = $0 }))
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
