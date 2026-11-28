import KodaCore
import SwiftUI

/// Synced lyrics that follow the song. Word-timed lines fill word by word as
/// they are sung: each word lights up from its left edge, rises a touch as it
/// starts, and a long held note swells and glows. Line-timed lines light as a
/// whole. Gaps of four seconds or more show three dots that fill until the next line.
///
/// Only the line being sung redraws every frame; the list around it updates a
/// few times a second, when the line changes.
struct SyncedLyrics: View {
    let lines: [LyricLine]
    var openSources: (() -> Void)? = nil
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.lyricsPlayerChrome) private var chrome
    @State private var userScrolled = false
    /// How far the lines have scrolled up, up to `topFadeHeight`: the top fade grows with it.
    @State private var topFade: CGFloat = 0
    static let topFadeHeight: CGFloat = 56
    @State private var shareFrom: ShareStart?
    /// Each line in Latin letters, by line id, for lyrics in another script.
    @State private var pronunciations: [Int: String] = [:]
    @State private var displayedExtras = ExtrasPresentation()
    @State private var scroll = LyricsScrollTracking()
    @State private var importedTranslations: [Int: String] = [:]
    @State private var importsLoaded = false

    private var showsChineseTranslation: Bool {
        app.settings.showsLyricsTranslation
    }
    private var automaticallyTranslates: Bool {
        app.settings.automaticLyricsTranslation && app.settings.showsLyricsTranslation
    }
    private var sourceID: String { player.current?.id ?? "" }
    private var automaticTranslation: AutomaticLyricsResult {
        app.lyricsTranslation.result(songID: player.current?.id,
            lines: lines.map { LyricsTranslationText(id: $0.id, text: $0.text) },
            imported: importedTranslations, importsEnabled: app.settings.importedLyricsEnabled)
    }
    private struct ExtrasPresentation: Equatable {
        var lines: [Int: String] = [:]
        var isTranslation = false
    }
    private var desiredExtras: ExtrasPresentation {
        if showsChineseTranslation {
            return ExtrasPresentation(lines: automaticTranslation.lines, isTranslation: true)
        }
        return ExtrasPresentation(lines: app.settings.lyricsExtra == .pronunciation ? pronunciations : [:])
    }
    private struct ImportRequest: Equatable {
        var songID: String?
        var lines: [LyricLine]
        var revision: Int
        var candidateID: LyricsCandidate.Identity?
    }

    private struct ShareStart: Identifiable {
        let line: Int
        let song: Song
        var id: Int { line }
    }

    /// The listener's correction for this song; positive shows each line later.
    private var offset: TimeInterval {
        app.effectiveLyricsOffset(player.current?.id)
    }
    private var hasDuet: Bool { lines.contains { $0.voice != .lead } }

    /// Lead the audio slightly so a line lights up as it is sung, not after.
    static let lead: TimeInterval = 0.15
    /// How far past the panel's sides the lyrics may draw: Now Playing's own side margin.
    static let bleed: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            lyricContent()
            HStack {
                LyricsTranslationControl(lines: lines.map { .init(id: $0.id, text: $0.text) },
                    importedCount: importsLoaded ? importedTranslations.count : 0,
                    importedLines: importedTranslations,
                    information: !automaticallyTranslates && showsChineseTranslation && importsLoaded
                        && displayedExtras.lines.count < lines.filter({ !$0.text.isEmpty }).count
                        ? (displayedExtras.lines.isEmpty
                            ? String(localized: "No Chinese translation is available. Enable automatic translation or import a translation in Chinese Lyrics settings.")
                            : String(localized: "Some lines have no translation and show the original lyrics.")) : nil,
                    openSources: openSources)
                Spacer(minLength: 8)
                if userScrolled {
                    Button("Follow", systemImage: "arrow.down.to.line") { userScrolled = false }
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .buttonStyle(.glass)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 44)
            .padding(.top, 6)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: userScrolled)
        .onChange(of: desiredExtras, initial: true) { _, presentation in
            if scroll.isIdle { applyExtras(presentation) }
        }
        .onChange(of: showsChineseTranslation) { _, _ in applyExtras(desiredExtras) }
        .onChange(of: chrome) { _, _ in
            let current = Lyrics.index(of: player.position() + Self.lead - offset, in: lines)
            scroll.prepareLayoutChange(source: sourceID, preferredRowID: userScrolled ? nil : current)
        }
        .onChange(of: sourceID) { _, _ in scroll.reset() }
        .task(id: lines) { await readLanguage() }
        .task(id: ImportRequest(songID: player.current?.id, lines: lines, revision: app.lyricsTranslation.versions.editRevision,
                                candidateID: app.lyricsTranslation.versions.current?.id)) {
            importedTranslations = [:]
            importsLoaded = false
            guard let songID = player.current?.id else { return }
            let versions = app.lyricsTranslation.versions
            let candidate = versions.current
            let document = candidate.flatMap { versions.importedDocument(for: $0) }
            let originals = lines
            let found = await Task.detached(priority: .utility) { document?.aligned(to: originals) ?? [:] }.value
            guard !Task.isCancelled, player.current?.id == songID, versions.current?.id == candidate?.id else { return }
            importedTranslations = found
            importsLoaded = true
        }
        .sheet(item: $shareFrom) { start in
            LyricsShareSheet(lines: lines, song: start.song, startingAt: start.line,
                             translations: showsChineseTranslation ? desiredExtras.lines : [:])
                .appEnvironment(app)
                .environment(\.colorScheme, .dark)
        }
    }

    private func lyricContent() -> some View {
        @Bindable var scroll = scroll
        // An observed seek still redraws a paused clock. Resuming supplies a fresh date;
        // scheduling does not change lyric times, translation mapping or word timing.
        return TimelineView(.animation(minimumInterval: 0.1,
                                       paused: !player.wantsToPlay || scenePhase != .active)) { context in
            let time = player.position(at: context.date) + Self.lead - offset
            let current = Lyrics.index(of: time, in: lines)
            let interlude = Interlude(lines: lines, current: current, time: time)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let interlude, interlude.after == nil {
                        InterludeDots(interlude: interlude).id("interlude")
                    }
                    ForEach(lines) { line in
                        let isCurrent = line.id == current && interlude == nil
                        LyricRow(line: line, isCurrent: isCurrent, distance: current.map { abs(line.id - $0) } ?? line.id + 1,
                                 hasDuet: hasDuet, offset: offset, style: LyricsStyle(app.settings), player: player,
                                 extra: displayedExtras.lines[line.id], isTranslation: displayedExtras.isTranslation)
                            .id(line.id)
                            .lyricsRowFrame(id: line.id, revision: scroll.revision)
                            .contentShape(.rect)
                            .onTapGesture {
                                player.seek(to: max(0, line.time + offset))
                                userScrolled = false
                            }
                            .contextMenu {
                                if let song = player.current, !line.text.isEmpty {
                                    Button("Share Lyrics…", systemImage: "square.and.arrow.up") {
                                        shareFrom = ShareStart(line: line.id, song: song)
                                    }
                                    Button("Play from Here", systemImage: "play") {
                                        player.seek(to: max(0, line.time + offset))
                                        userScrolled = false
                                    }
                                }
                            }
                        if let interlude, interlude.after == line.id {
                            InterludeDots(interlude: interlude).id("interlude")
                        }
                    }
                }
                // The first line starts right under the song; the room below lets the
                // last lines still reach the reading position a third of the way down.
                .padding(.top, 12)
                .padding(.bottom, 380)
                .padding(.horizontal, SyncedLyrics.bleed)
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: current)
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: interlude?.after)
                .lyricsContentFrame(revision: scroll.revision)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scroll.position)
            .onScrollGeometryChange(for: LyricsViewport.self, of: LyricsViewport.init) { _, viewport in
                scroll.viewport = viewport
                topFade = min(max(viewport.offset + viewport.topInset, 0), Self.topFadeHeight)
            }
            .onScrollPhaseChange { _, phase in
                scroll.phaseChanged(phase)
                if phase == .interacting { userScrolled = true }
                if phase == .idle { applyExtras(desiredExtras) }
            }
            .onPreferenceChange(LyricsLayoutPreference.self) { measurement in
                scroll.accept(measurement, source: sourceID)
            }
            .onChange(of: current) { _, index in
                // Natural playback progression wins over a simultaneous layout correction.
                guard let index, !userScrolled else { return }
                // While manually reading another row, playback keeps advancing but does
                // not scroll. Keep that reader's pending layout correction in this case.
                // Fast consecutive lines can keep the native follow animation active;
                // publish queued results as part of that intended movement, rather than
                // waiting indefinitely for an idle phase between lines.
                applyExtras(desiredExtras)
                scroll.cancelCorrection()
                withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.9)) { scroll.position.scrollTo(id: index, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
            .onChange(of: userScrolled) { _, scrolled in
                guard !scrolled, let current else { return }
                scroll.cancelCorrection()
                withAnimation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.9)) { scroll.position.scrollTo(id: current, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
            .onAppear {
                if let current { scroll.position.scrollTo(id: current, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
        }
        // Lines fade as they pass under the song, but only once there are lines up there: at the
        // top a fixed fade washed out the first line, which rests right under the title.
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: topFade)
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.83), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        // The lyrics run out to the screen edges, padded back in line with the rest of the
        // player, so a glowing or swelling word at either edge is not cut off by the scroll view.
        .padding(.horizontal, -Self.bleed)
    }

    private func applyExtras(_ presentation: ExtrasPresentation) {
        guard presentation != displayedExtras else { return }
        let current = Lyrics.index(of: player.position() + Self.lead - offset, in: lines)
        scroll.prepareLayoutChange(source: sourceID, preferredRowID: userScrolled ? nil : current)
        displayedExtras = presentation
    }
}

extension SyncedLyrics {
    /// The language and the pronunciations are worked out once per lyrics, off the main thread.
    private func readLanguage() async {
        let ids = lines.map(\.id)
        let texts = lines.map(\.text)
        let said = await Task.detached(priority: .userInitiated) { () -> [Int: String] in
            let language = LyricsRomanizer.language(of: texts)
            guard LyricsRomanizer.needsRomanization(texts) else { return [:] }
            var said: [Int: String] = [:]
            for (id, text) in zip(ids, texts) {
                if let latin = LyricsRomanizer.romanize(text, language: language) { said[id] = latin }
            }
            return said
        }.value
        guard !Task.isCancelled else { return }
        pronunciations = said
    }

}

/// A gap in the singing long enough to show the dots: before the first line, or after `after`.
struct Interlude: Equatable {
    var after: Int?
    var progress: Double

    static let minimumGap: TimeInterval = 4

    init?(lines: [LyricLine], current: Int?, time: TimeInterval) {
        guard let first = lines.first else { return nil }
        guard let current else {
            guard first.time >= Self.minimumGap, time >= 0 else { return nil }
            after = nil
            progress = min(1, max(0, time / first.time))
            return
        }
        let line = lines[current]
        guard current + 1 < lines.count, let end = line.end else { return nil }
        let next = lines[current + 1].time
        guard next - end >= Self.minimumGap, time > end + 0.3 else { return nil }
        after = current
        progress = min(1, max(0, (time - end) / (next - end)))
    }
}

/// Three dots that fill in turn through an instrumental gap, breathing while they wait.
private struct InterludeDots: View {
    let interlude: Interlude
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breath = reduceMotion ? 1 : 1 + 0.08 * sin(t * 2.6)
            // The group shrinks away over the last moment so the next line takes its place.
            let ending = max(0, (interlude.progress - 0.92) / 0.08)
            HStack(spacing: 10) {
                ForEach(0..<3) { index in
                    let fill = min(1, max(0, interlude.progress * 3 - Double(index)))
                    Circle()
                        .fill(Color.primary.opacity(0.3 + 0.7 * fill))
                        .frame(width: 11, height: 11)
                }
            }
            .scaleEffect(breath * (1 - 0.6 * ending))
            .opacity(1 - ending)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
        .accessibilityLabel("Instrumental")
    }
}

/// One line of lyrics, current or resting, on its singer's side.
struct LyricRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let distance: Int
    let hasDuet: Bool
    let offset: TimeInterval
    /// Passed in rather than read from the environment: the Mac draws a row's context-menu
    /// preview outside the window, where the app's environment objects don't reach.
    let style: LyricsStyle
    let player: Player
    /// A translation or pronunciation shown under the line.
    var extra: String? = nil
    var isTranslation = false
    @Environment(\.immersiveLyricColor) private var immersiveLyricColor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static let defaultFontSize: CGFloat = 30
    /// Where the line sits: every line on the left unless Duet Sides is on.
    private var voice: LyricVoice { style.duetSides && line.voice == .duet ? .duet : .lead }

    private var alignment: HorizontalAlignment {
        if !style.duetSides, let alignment = style.immersiveAlignment { return alignment.horizontal }
        return switch voice {
        case .lead: .leading
        case .duet: .trailing
        case .together: .center
        }
    }

    private var frameAlignment: Alignment {
        if !style.duetSides, let alignment = style.immersiveAlignment {
            return Alignment(horizontal: alignment.horizontal, vertical: .center)
        }
        return switch voice {
        case .lead: .leading
        case .duet: .trailing
        case .together: .center
        }
    }

    var body: some View {
        VStack(alignment: alignment, spacing: isTranslation ? style.translationSpacing : 6) {
            if line.isWordTimed && style.wordHighlight {
                // The resting words and the sung line swap at once, never crossfading: the resting
                // copy is fully inked (the row's own fade dims it), so a crossfade under the row's
                // spring lit the whole line for a moment before it filled from its first word.
                if isCurrent {
                    KaraokeLine(line: line, offset: offset, alignment: alignment, style: style, player: player)
                        .transition(.identity)
                } else {
                    VStack(alignment: alignment, spacing: 6) {
                        WordFlow(alignment: alignment, spacing: style.spacing) {
                            ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                                Text(word.text).font(style.font).layoutValue(key: SpaceAfter.self, value: word.spaceAfter)
                            }
                        }
                        if style.showsBackingVocals, !line.background.isEmpty {
                            WordFlow(alignment: alignment, spacing: style.backgroundSpacing) {
                                ForEach(Array(line.background.enumerated()), id: \.offset) { _, word in
                                    Text(word.text).font(style.backgroundFont).layoutValue(key: SpaceAfter.self, value: word.spaceAfter)
                                }
                            }
                            .opacity(0.7)
                        }
                    }
                    .transition(.identity)
                }
            } else {
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(style.font)
                    .multilineTextAlignment(style.duetSides ? (voice == .duet ? .trailing : voice == .together ? .center : .leading) : style.immersiveAlignment?.text ?? .leading)
                    // Line-timed lyrics light as a whole line; no word fill is invented for them.
                    .shadow(color: .white.opacity(isCurrent && colorScheme == .dark ? 0.35 : 0), radius: isCurrent ? 14 : 0)
                if style.showsBackingVocals && !line.background.isEmpty {
                    Text(line.background.map { $0.text + ($0.spaceAfter ? " " : "") }.joined())
                        .font(style.backgroundFont)
                        .opacity(0.7)
                }
            }
            if let extra { translatedText(extra) }
        }
        .foregroundStyle(immersiveLyricColor ?? Color.primary)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        // A duet's sides stop short of each other, so a wrapped line still reads as its singer's.
        .padding(voice == .duet ? .leading : .trailing, style.duetSides && hasDuet && voice != .together ? 44 : 0)
        // One layer before it fades: in the Mac's side panel the text is blended with the panel
        // behind it, and line by line that blend ignored the fade, so the lines either side of the
        // sung one (the only ones without a blur, which flattens them too) stayed fully lit.
        .compositingGroup()
        .opacity(isCurrent || !style.fadeNeighbors ? 1 : distance <= 1 ? 0.42 : 0.3)
        .blur(radius: isCurrent || !style.fadeNeighbors ? 0 : min(Double(max(distance - 1, 0)) * 0.7, 2.4))
        .scaleEffect(isCurrent || reduceMotion ? 1 : 0.97, anchor: UnitPoint(x: voice == .duet ? 1 : voice == .together ? 0.5 : 0, y: 0.5))
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: isCurrent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(extra.map { "\(line.text), \($0)" } ?? line.text)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func translatedText(_ text: String) -> some View {
        Text(text)
            .font(isTranslation ? style.translationFont : style.extraFont)
            .foregroundStyle((immersiveLyricColor ?? Color.primary).opacity(isTranslation ? style.translationOpacity : 0.7))
            .multilineTextAlignment(style.duetSides ? (voice == .duet ? .trailing : voice == .together ? .center : .leading) : style.immersiveAlignment?.text ?? .leading)
            .transition(.opacity)
    }
}

/// The line being sung, redrawn every frame while the song plays.
private struct KaraokeLine: View {
    let line: LyricLine
    let offset: TimeInterval
    let alignment: HorizontalAlignment
    let style: LyricsStyle
    let player: Player
    var showsLead = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var motion: Bool { style.motion && !reduceMotion }

    var body: some View {
        TimelineView(.animation(paused: !player.wantsToPlay || scenePhase != .active)) { context in
            let time = player.position(at: context.date) + SyncedLyrics.lead - offset
            VStack(alignment: alignment, spacing: 6) {
                if showsLead {
                    WordFlow(alignment: alignment, spacing: style.spacing) {
                        ForEach(Array(line.words.enumerated()), id: \.offset) { _, word in
                            KaraokeWord(word: word, time: time, font: style.font, lift: motion ? 2.5 : 0, swells: motion)
                                .layoutValue(key: SpaceAfter.self, value: word.spaceAfter)
                        }
                    }
                }
                if style.showsBackingVocals, !line.background.isEmpty {
                    WordFlow(alignment: alignment, spacing: style.backgroundSpacing) {
                        ForEach(Array(line.background.enumerated()), id: \.offset) { _, word in
                            KaraokeWord(word: word, time: time, font: style.backgroundFont, lift: motion ? 1.5 : 0, swells: false)
                                .layoutValue(key: SpaceAfter.self, value: word.spaceAfter)
                        }
                    }
                    .opacity(0.8)
                }
            }
        }
    }
}

/// One word: unsung it is dim; as it is sung the bright copy is revealed from the
/// left edge with a soft front, so the fill moves through the word with the voice.
private struct KaraokeWord: View {
    let word: LyricWord
    let time: TimeInterval
    let font: Font
    var lift: CGFloat
    var swells: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// How long a word takes to rise, in seconds; it keeps rising after the next word starts, so a line moves as a ripple.
    private static let riseDuration: TimeInterval = 0.65
    /// Notes held longer than this start to swell, fully by twice as long.
    private static let sustainStart: TimeInterval = 0.9

    var body: some View {
        let fill = min(1, max(0, (time - word.start) / word.duration))
        let rise = min(1, max(0, (time - word.start) / Self.riseDuration))
        // Ease out: quick at first, settling gently.
        let eased = 1 - pow(1 - rise, 3)
        let sustainStrength = swells ? min(1, max(0, (word.duration - Self.sustainStart) / Self.sustainStart)) : 0
        let sustain = sustainStrength * sin(.pi * fill)

        Text(word.text)
            .font(font)
            .foregroundStyle(Color.primary.opacity(0.38))
            .fixedSize()
            .overlay {
                Text(word.text)
                    .font(font)
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .mask { FillMask(progress: fill) }
            }
            // A glow only on dark colours; on a light page it would be a grey smudge.
            .shadow(color: .white.opacity(colorScheme == .dark ? 0.55 * sustain : 0), radius: 12 * sustain)
            .scaleEffect(1 + 0.045 * sustain, anchor: .bottom)
            .offset(y: -lift * eased)
    }
}

/// Opaque up to `progress` across the width, with a soft front edge.
private struct FillMask: View {
    let progress: Double
    private static let feather = 0.35

    var body: some View {
        // The front runs from -feather to 1 so the word is fully clear at 0 and fully filled at 1.
        let front = progress * (1 + Self.feather)
        LinearGradient(stops: [.init(color: .black, location: max(0, front - Self.feather)),
                               .init(color: .clear, location: min(1, max(front, 0.0001)))],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// Whether a space follows a word in a `WordFlow`; false between syllables of one word.
nonisolated struct SpaceAfter: LayoutValueKey {
    static let defaultValue = true
}

/// Words set left to right and wrapped like text, so a line breaks the same way
/// whether it is being sung or resting.
struct WordFlow: Layout {
    var alignment: HorizontalAlignment = .leading
    /// The width of a space in the lyric font; a quarter of its size.
    var spacing: CGFloat = LyricRow.defaultFontSize * 0.25
    var lineSpacing: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.midX - row.width / 2
            default: x = bounds.minX
            }
            for item in row.items {
                // Placed at its own size: proposing exactly the measured width can truncate a word to "…".
                subviews[item.index].place(at: CGPoint(x: x, y: y + row.height - item.size.height), proposal: .unspecified)
                x += item.size.width + item.gap
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item { var index: Int; var size: CGSize; var gap: CGFloat }
    private struct Row { var items: [Item] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    /// Breaks only where there is a space, so a word split into syllables never wraps mid-word.
    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        // Group syllables into whole words first.
        var words: [[Item]] = [[]]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let joins = !subviews[index][SpaceAfter.self]
            words[words.count - 1].append(Item(index: index, size: size, gap: joins ? 0 : spacing))
            if !joins { words.append([]) }
        }
        var rows: [Row] = [Row()]
        func place(_ word: [Item]) {
            let wordWidth = word.dropLast().reduce(0) { $0 + $1.size.width + $1.gap } + (word.last?.size.width ?? 0)
            let current = rows[rows.count - 1]
            let needed = current.items.isEmpty ? wordWidth : current.width + (current.items.last?.gap ?? 0) + wordWidth
            if needed > width, !current.items.isEmpty { rows.append(Row()) }
            var row = rows[rows.count - 1]
            if let last = row.items.last { row.width += last.gap }
            for item in word {
                row.items.append(item)
                row.width += item.size.width + (item.index == word.last?.index ? 0 : item.gap)
                row.height = max(row.height, item.size.height)
            }
            rows[rows.count - 1] = row
        }
        for word in words where !word.isEmpty {
            let wordWidth = word.dropLast().reduce(0) { $0 + $1.size.width + $1.gap } + (word.last?.size.width ?? 0)
            // Japanese and Chinese have no spaces, so a whole line can be one "word": wider than
            // the line, it breaks between its syllables, as those languages break anywhere.
            if wordWidth > width, word.count > 1 {
                for item in word { place([item]) }
            } else {
                place(word)
            }
        }
        return rows.filter { !$0.items.isEmpty }
    }
}

/// Placeholder lines that shimmer while lyrics load.
struct LyricsLoading: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach([0.82, 0.64, 0.9, 0.5, 0.72], id: \.self) { fraction in
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.14))
                        .frame(width: geometry.size.width * fraction)
                }
                .frame(height: 26)
            }
        }
        .padding(.top, 16)
        .shimmer()
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityLabel("Loading lyrics")
    }
}

/// The lyric settings a line is drawn with.
struct LyricsStyle {
    var fontSize: CGFloat
    var motion: Bool
    var showsBackingVocals: Bool
    var duetSides: Bool
    var translationFontSize: CGFloat
    var translationOpacity: Double
    var translationSpacing: CGFloat
    var immersiveAlignment: ImmersiveAlignment?
    var wordHighlight = true
    var fadeNeighbors = true

    @MainActor
    init(_ settings: AppSettings) {
        fontSize = settings.lyricsSize.fontSize
        motion = settings.lyricsMotion
        showsBackingVocals = settings.showsBackingVocals
        duetSides = settings.duetSides
        translationFontSize = CGFloat(min(32, max(12, settings.translationFontSize)))
        translationOpacity = min(1, max(0.3, settings.translationOpacity))
        translationSpacing = CGFloat(min(20, max(2, settings.translationSpacing)))
    }

    var translationFont: Font { .system(size: translationFontSize, weight: .semibold) }
    var font: Font { .system(size: fontSize, weight: .bold) }
    var backgroundFont: Font { .system(size: fontSize * 0.7, weight: .semibold) }
    /// A translation or pronunciation under a line.
    var extraFont: Font { .system(size: fontSize * 0.6, weight: .semibold) }
    /// A space is about a quarter of the type size.
    var spacing: CGFloat { fontSize * 0.25 }
    var backgroundSpacing: CGFloat { fontSize * 0.7 * 0.25 }
}
