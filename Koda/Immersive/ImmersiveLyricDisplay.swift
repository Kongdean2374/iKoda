import KodaCore
import SwiftUI

struct ImmersiveLyricDisplay: View {
    let profile: ImmersiveProfile
    let wide: Bool
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(Library.self) private var library
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var scale = 1.0
    @State private var imported: [Int: String] = [:]
    @State private var follows = true
    @State private var importedIdentity: LyricsCandidate.Identity?

    private var versions: LyricsVersions { app.lyricsTranslation.versions }
    private var candidate: LyricsCandidate? {
        guard let current = versions.current, current.songID == player.current?.id else { return nil }
        return current
    }
    private var offset: TimeInterval { app.effectiveLyricsOffset(player.current?.id) }
    private var style: LyricsStyle {
        var result = LyricsStyle(app.settings)
        result.fontSize = min(wide ? 92 : 72, profile.originalSize * scale)
        result.translationFontSize = min(wide ? 48 : 42, profile.translationSize * scale)
        result.translationSpacing = profile.translationSpacing
        result.wordHighlight = profile.words
        result.fadeNeighbors = profile.fadeNeighbors
        result.immersiveAlignment = profile.alignment
        result.motion = !reduceMotion && result.motion
        return result
    }

    private struct Identity: Equatable {
        var candidate: LyricsCandidate.Identity?
        var edits: Int
    }

    var body: some View {
        Group {
            if let candidate {
                let lines = Self.rows(candidate.lyrics)
                let extras = profile.translation ? app.lyricsTranslation.result(songID: candidate.songID,
                    lines: lines.map { .init(id: $0.id, text: $0.text) },
                    imported: importedIdentity == candidate.id ? imported : [:],
                    importsEnabled: app.settings.importedLyricsEnabled).lines : [:]
                switch candidate.lyrics {
                case .synced(let lines): synced(lines, extras: extras)
                case .plain:
                    ScrollView {
                        LazyVStack(spacing: profile.lineSpacing) {
                            ForEach(lines, id: \.id) { row in
                                LyricRow(line: row, isCurrent: true, distance: 0, hasDuet: false,
                                         offset: offset, style: style, player: player, extra: extras[row.id], isTranslation: true)
                            }
                        }
                    }
                    .scrollDisabled(!profile.manualScroll)
                }
            } else if player.current.map({ library.instrumentalSongs[$0.id] != nil }) == true {
                Label("Instrumental", systemImage: "music.note")
            } else if versions.searching {
                ProgressView("Searching for Lyrics")
            } else {
                Label("No Lyrics", systemImage: "quote.bubble")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(legibleLyricColor)
        .environment(\.immersiveLyricColor, legibleLyricColor)
        .task(id: Identity(candidate: candidate?.id, edits: versions.editRevision)) {
            follows = profile.autoFollow
            guard let candidate else { imported = [:]; importedIdentity = nil; return }
            let original = Self.rows(candidate.lyrics)
            let document = versions.importedDocument(for: candidate)
            let value = await Task.detached(priority: .utility) {
                guard case .synced = candidate.lyrics else { return [Int: String]() }
                return document?.aligned(to: original) ?? [:]
            }.value
            guard !Task.isCancelled, candidate.id == self.candidate?.id else { return }
            imported = value
            importedIdentity = candidate.id
        }
        .onChange(of: profile.autoFollow) { _, follow in follows = follow }
    }

    private static func rows(_ lyrics: Lyrics) -> [LyricLine] {
        switch lyrics {
        case .synced(let lines): lines
        case .plain(let text): LyricsCandidate.plainLines(text).enumerated().map {
            LyricLine(id: $0.offset, time: 0, text: $0.element)
        }
        }
    }

    private var legibleLyricColor: Color {
        let c = profile.lyricColor
        let luminance = c.red * 0.2126 + c.green * 0.7152 + c.blue * 0.0722
        return luminance < 0.50 ? Color.white : c.color
    }

    private func synced(_ lines: [LyricLine], extras: [Int: String]) -> some View {
        TimelineView(.animation(minimumInterval: 0.10, paused: !player.wantsToPlay || scene != .active)) { context in
            let index = Lyrics.index(of: player.position(at: context.date) + SyncedLyrics.lead - offset, in: lines)
            let current = index.map { lines[$0].time }
            let vector = visibleRange(lines, index: index)
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: profile.lineSpacing) {
                        ForEach(vector, id: \.self) { i in
                            let row = lines[i]
                            let lyric = LyricRow(line: row, isCurrent: current == row.time,
                                distance: abs(i - (index ?? 0)), hasDuet: true, offset: offset,
                                style: style, player: player, extra: extras[row.id], isTranslation: true)
                            if profile.seekFromLyrics {
                                Button {
                                    player.seek(to: row.time + offset)
                                } label: { lyric.contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                            } else { lyric }
                        }
                    }
                    .padding(.vertical, 5)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollDisabled(!profile.manualScroll)
                .onScrollPhaseChange { _, next in
                    if profile.manualScroll, profile.visibleLines == 0, next == .interacting { follows = false }
                }
                .onChange(of: index, initial: true) { _, value in
                    guard follows, profile.visibleLines == 0, let value else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.26)) { scroll.scrollTo(value, anchor: .center) }
                }
                .onChange(of: follows) { _, value in
                    if value, profile.visibleLines == 0, let index { scroll.scrollTo(index, anchor: .center) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !follows && profile.visibleLines == 0 {
                        Button("Follow", systemImage: "arrow.down.to.line") { follows = true }
                            .frame(minHeight: 44)
                            .buttonStyle(.glass)
                    }
                }
            }
        }
    }

    private func visibleRange(_ lines: [LyricLine], index: Int?) -> Range<Int> {
        guard profile.visibleLines > 0, !lines.isEmpty else { return lines.indices }
        let current = index ?? 0
        var start = current
        while start > 0 && lines[start - 1].time == lines[current].time { start -= 1 }
        let previous = (profile.visibleLines - 1) / 2
        let lower = max(0, start - previous)
        return lower..<min(lines.count, max(current + 1, lower + profile.visibleLines))
    }
}

extension EnvironmentValues {
    @Entry var immersiveLyricColor: Color? = nil
}
