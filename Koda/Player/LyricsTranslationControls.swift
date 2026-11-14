import KodaCore
import SwiftUI

/// The player has one translation switch; source and appearance choices live in Settings.
struct LyricsTranslationToggle: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let enabled = app.settings.showsLyricsTranslation
        Button { app.settings.showsLyricsTranslation.toggle() } label: {
            Label("Translation", systemImage: "translate")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
        }
        .buttonStyle(PlayerToggleStyle(isOn: enabled, offFill: 0.08))
        .sensoryFeedback(.selection, trigger: enabled)
        .accessibilityLabel("Translation")
        .accessibilityValue(enabled ? String(localized: "On") : String(localized: "Off"))
        .accessibilityHint("Show or hide Traditional Chinese under the original lyrics.")
        .accessibilityAddTraits(enabled ? .isSelected : [])
    }
}

/// Unsynced lyrics can still be translated, but never receive made-up timestamps or highlights.
struct PlainTranslatedLyricsView: View {
    let text: String
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var displayedTranslations: [Int: String] = [:]
    @State private var scroll = LyricsScrollTracking()

    private var lines: [LyricsTranslationText] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").enumerated().map { LyricsTranslationText(id: $0.offset, text: $0.element) }
    }
    private var enabled: Bool { app.settings.automaticLyricsTranslation && app.settings.showsLyricsTranslation }
    private var result: AutomaticLyricsResult { app.lyricsTranslation.result(songID: player.current?.id, lines: lines) }
    private var desiredTranslations: [Int: String] { enabled ? result.lines : [:] }
    private var sourceID: String { player.current?.id ?? "" }

    var body: some View {
        @Bindable var scroll = scroll
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: app.settings.translationSpacing) {
                    ForEach(lines, id: \.id) { line in
                        let presentation = LyricTranslationPresentation(mode: .bilingual,
                                                                         enabled: true, translation: displayedTranslations[line.id])
                        VStack(alignment: .leading, spacing: app.settings.translationSpacing) {
                            if presentation.showsOriginal {
                                Text(line.text.isEmpty ? " " : line.text).font(.title3.weight(.semibold))
                            }
                            if let translation = presentation.translation {
                                Text(translation)
                                    .font(.system(size: app.settings.translationFontSize, weight: .semibold))
                                    .foregroundStyle(Color.primary.opacity(app.settings.translationOpacity))
                            }
                        }
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                        .lyricsRowFrame(id: line.id, revision: scroll.revision)
                    }
                }
                .padding(.vertical, 12)
                .lyricsContentFrame(revision: scroll.revision)
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scroll.position)
            .onScrollGeometryChange(for: LyricsViewport.self, of: LyricsViewport.init) { _, viewport in
                scroll.viewport = viewport
            }
            .onScrollPhaseChange { _, phase in
                scroll.phaseChanged(phase)
                if phase == .idle { applyTranslations(desiredTranslations) }
            }
            .onPreferenceChange(LyricsLayoutPreference.self) { measurement in
                scroll.accept(measurement, source: sourceID)
            }
            HStack {
                LyricsTranslationToggle()
                if enabled {
                    LyricsTranslationFooterStatus(result: result) { app.lyricsTranslation.retry(songID: player.current?.id) }
                } else if app.settings.importedLyricsEnabled, app.settings.showsLyricsTranslation {
                    LyricsTranslationInfoButton(message: String(localized: "This song has no synced lyrics. The original text is shown; imported translations need timestamps."))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 44)
            .padding(.top, 6)
        }
        .onChange(of: desiredTranslations, initial: true) { _, translated in
            if scroll.isIdle { applyTranslations(translated) }
        }
        .onChange(of: enabled) { _, _ in applyTranslations(desiredTranslations) }
        .onChange(of: sourceID) { _, _ in scroll.reset() }
    }

    private func applyTranslations(_ translated: [Int: String]) {
        guard translated != displayedTranslations else { return }
        scroll.prepareLayoutChange(source: sourceID)
        displayedTranslations = translated
    }
}

/// Progress belongs beside the controls, not above the lyrics: changing a status
/// message must not change the timeline's content height or its reading position.
struct LyricsTranslationFooterStatus: View {
    let result: AutomaticLyricsResult
    let retry: () -> Void
    @State private var showsDetails = false

    var body: some View {
        Group {
            switch result.phase {
            case .preparing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Preparing Translation…")
                }
            case .translating:
                VStack(alignment: .leading, spacing: 3) {
                    Text("Translated \(result.completed) of \(result.total)").monospacedDigit()
                    ProgressView(value: Double(result.completed), total: Double(max(1, result.total)))
                        .tint(.primary)
                }
            case .needsLanguage:
                Button("Prepare Translation", systemImage: "arrow.down.circle", action: retry)
            case .paused:
                Label("Translation Paused", systemImage: "pause")
            case .unavailable, .failed:
                Button("Translation Details", systemImage: "info.circle") { showsDetails = true }
            case .ready:
                Label("Translation Ready", systemImage: "checkmark")
            case .idle:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .leading)
        .popover(isPresented: $showsDetails) {
            AutomaticLyricsNotice(result: result, retry: retry)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
    }
}

struct LyricsTranslationInfoButton: View {
    let message: String
    @State private var showsMessage = false
    var body: some View {
        Button("Translation Details", systemImage: "info.circle") { showsMessage = true }
            .font(.caption)
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 36)
            .popover(isPresented: $showsMessage) {
                Text(message).padding().presentationCompactAdaptation(.popover)
            }
    }
}

nonisolated struct LyricsViewport: Equatable, Sendable {
    var offset: CGFloat = 0
    var height: CGFloat = 0
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    init() {}
    init(_ geometry: ScrollGeometry) {
        offset = geometry.contentOffset.y
        height = geometry.containerSize.height
        topInset = geometry.contentInsets.top
        bottomInset = geometry.contentInsets.bottom
    }
}

nonisolated struct LyricsLayoutMeasurement: Equatable, Sendable {
    var revision = -1
    var rows: [Int: CGRect] = [:]
    var contentHeight: CGFloat = 0
}

nonisolated struct LyricsLayoutPreference: PreferenceKey {
    static let defaultValue = LyricsLayoutMeasurement()
    static func reduce(value: inout LyricsLayoutMeasurement, nextValue: () -> LyricsLayoutMeasurement) {
        let next = nextValue()
        guard next.revision >= 0 else { return }
        if value.revision != next.revision { value = next; return }
        value.rows.merge(next.rows) { _, new in new }
        value.contentHeight = max(value.contentHeight, next.contentHeight)
    }
}

extension View {
    func lyricsRowFrame(id: Int, revision: Int) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: LyricsLayoutPreference.self,
                    value: LyricsLayoutMeasurement(revision: revision,
                        rows: [id: geometry.frame(in: .named("KodaLyricsContent"))]))
            }
        }
    }

    func lyricsContentFrame(revision: Int) -> some View {
        coordinateSpace(name: "KodaLyricsContent")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: LyricsLayoutPreference.self,
                        value: LyricsLayoutMeasurement(revision: revision, contentHeight: geometry.size.height))
                }
            }
    }
}

/// Measurement changes are not observed: only a new translation layout, scroll phase
/// or explicit scroll command redraws the parent. The karaoke clock does not drive this.
@MainActor
@Observable
final class LyricsScrollTracking {
    var position = ScrollPosition()
    private(set) var revision = 0
    private(set) var isIdle = true
    @ObservationIgnored var viewport = LyricsViewport()
    @ObservationIgnored private var rows: [Int: CGRect] = [:]
    @ObservationIgnored private var pending: LyricScrollAnchor?
    @ObservationIgnored private var pendingRevision: Int?

    func prepareLayoutChange(source: String, preferredRowID: Int? = nil) {
        pending = isIdle ? LyricScrollAnchor(source: source, rows: coreRows(rows),
            offset: Double(viewport.offset), viewportHeight: Double(viewport.height), preferredRowID: preferredRowID) : nil
        revision += 1
        pendingRevision = pending == nil ? nil : revision
    }

    func phaseChanged(_ phase: ScrollPhase) {
        isIdle = phase == .idle
        if !isIdle { cancelCorrection() }
    }

    func cancelCorrection() {
        pending = nil
        pendingRevision = nil
    }

    func reset() {
        cancelCorrection()
        rows = [:]
        viewport = LyricsViewport()
    }

    func accept(_ measurement: LyricsLayoutMeasurement, source: String) {
        guard measurement.revision == revision else { return }
        rows = measurement.rows
        guard isIdle, pendingRevision == measurement.revision, let anchor = pending else { return }
        cancelCorrection()
        guard let target = anchor.restoredOffset(source: source, rows: coreRows(measurement.rows),
            currentOffset: Double(viewport.offset), contentHeight: Double(measurement.contentHeight),
            viewportHeight: Double(viewport.height), topInset: Double(viewport.topInset),
            bottomInset: Double(viewport.bottomInset)) else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        transaction.scrollPositionUpdatePreservesVelocity = true
        withTransaction(transaction) { position.scrollTo(y: CGFloat(target)) }
    }

    private func coreRows(_ frames: [Int: CGRect]) -> [LyricScrollAnchor.Row] {
        frames.map { LyricScrollAnchor.Row(id: $0.key, minY: Double($0.value.minY), maxY: Double($0.value.maxY)) }
    }
}
