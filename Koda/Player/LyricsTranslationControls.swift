import KodaCore
import SwiftUI

/// One circle owns display toggling; its exclusive long press opens progress/settings.
/// Keeping this in the fixed footer prevents either interaction from covering lyric rows.
struct LyricsTranslationControl: View {
    let lines: [LyricsTranslationText]
    var importedCount = 0
    var information: String?
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var showsDetails = false
    @State private var holdFeedback = 0

    private var result: AutomaticLyricsResult {
        app.lyricsTranslation.result(songID: player.current?.id, lines: lines)
    }
    private var enabled: Bool { app.settings.showsLyricsTranslation }
    private var status: LocalizedStringKey {
        LyricsTranslationStatus.label(shown: enabled, automatic: app.settings.automaticLyricsTranslation,
            importsEnabled: app.settings.importedLyricsEnabled, importedCount: importedCount,
            originalCount: lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            result: result)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { app.settings.showsLyricsTranslation.toggle() } label: {
                Image(systemName: "translate")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(LyricsTranslationOrbStyle(isOn: enabled, onHold: {
                holdFeedback &+= 1
                showsDetails = true
            }, showDetails: { showsDetails = true }))
            .sensoryFeedback(.selection, trigger: enabled)
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: holdFeedback)
            .accessibilityLabel("Translation")
            .accessibilityValue(enabled ? String(localized: "On") : String(localized: "Off"))
            .accessibilityHint("Tap to show or hide translation. Touch and hold for progress and settings.")
            .accessibilityAddTraits(enabled ? .isSelected : [])
            .accessibilityAction { app.settings.showsLyricsTranslation.toggle() }
            .accessibilityAction(named: Text("Translation Details")) { showsDetails = true }

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .sheet(isPresented: $showsDetails) {
            NavigationStack {
                LyricsTranslationDetails(lines: lines, importedCount: importedCount, information: information)
            }
            .appEnvironment(app)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

/// A primitive style replaces Button's default touch handling. ExclusiveGesture permits
/// only one successful branch: releasing a recognized hold cannot also trigger a tap.
private struct LyricsTranslationOrbStyle: PrimitiveButtonStyle {
    let isOn: Bool
    let onHold: () -> Void
    let showDetails: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        LyricsTranslationOrbSurface(label: configuration.label, isOn: isOn,
                                    activate: configuration.trigger, onHold: onHold, showDetails: showDetails)
    }
}

private struct LyricsTranslationOrbSurface<Label: View>: View {
    let label: Label
    let isOn: Bool
    let activate: () -> Void
    let onHold: () -> Void
    let showDetails: () -> Void
    @GestureState private var isPressed = false

    var body: some View {
        label
            .foregroundStyle(isOn ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
            .background {
                Circle().fill(Color.primary.opacity(isOn ? (isPressed ? 0.85 : 1) : (isPressed ? 0.2 : 0.08)))
            }
            .contentShape(.circle)
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.2), value: isPressed)
            .animation(.smooth(duration: 0.25), value: isOn)
            .gesture(
                LongPressGesture(minimumDuration: 0.5, maximumDistance: 12)
                    .exclusively(before: TapGesture())
                    .updating($isPressed) { _, pressed, _ in pressed = true }
                    .onEnded { gesture in
                        switch gesture {
                        case .first(true): onHold()
                        case .second: activate()
                        default: break
                        }
                    }
            )
            .focusable()
            .onKeyPress(keys: [.space, .return], phases: .down) { _ in activate(); return .handled }
            .onKeyPress(.downArrow, phases: .down) { _ in showDetails(); return .handled }
    }
}

private enum LyricsTranslationStatus {
    static func label(shown: Bool, automatic: Bool, importsEnabled: Bool, importedCount: Int,
                      originalCount: Int, result: AutomaticLyricsResult) -> LocalizedStringKey {
        guard shown else { return "Off" }
        guard automatic else {
            guard importsEnabled, importedCount > 0 else { return "No Translation" }
            return importedCount >= originalCount ? "Translated" : "Partially Translated"
        }
        switch result.phase {
        case .idle, .preparing: return "Preparing…"
        case .translating: return "Translating…"
        case .ready: return "Translated"
        case .needsLanguage: return "Language Needed"
        case .paused: return "Translation Paused"
        case .unavailable: return result.lines.isEmpty ? "Unavailable" : "Partially Translated"
        case .failed: return "Translation Failed"
        }
    }
}

/// Read the shared coordinator here, rather than saving a snapshot when the sheet opens:
/// progress and model readiness continue updating for as long as the details are visible.
private struct LyricsTranslationDetails: View {
    let lines: [LyricsTranslationText]
    let importedCount: Int
    let information: String?
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    private var result: AutomaticLyricsResult {
        app.lyricsTranslation.result(songID: player.current?.id, lines: lines)
    }
    private var status: LocalizedStringKey {
        LyricsTranslationStatus.label(shown: app.settings.showsLyricsTranslation,
            automatic: app.settings.automaticLyricsTranslation,
            importsEnabled: app.settings.importedLyricsEnabled, importedCount: importedCount,
            originalCount: lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            result: result)
    }

    var body: some View {
        Form {
            Section("Translation Progress") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(status).foregroundStyle(.secondary)
                }
                if app.settings.automaticLyricsTranslation {
                    if result.total > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Translated \(result.completed) of \(result.total)").monospacedDigit()
                            ProgressView(value: Double(result.completed), total: Double(max(1, result.total)))
                        }
                    }
                    if app.settings.showsLyricsTranslation, result.phase != .translating {
                        AutomaticLyricsNotice(result: result) {
                            app.lyricsTranslation.retry(songID: player.current?.id)
                        }
                    }
                }
                if let information { Text(information).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                NavigationLink {
                    LyricsTranslationSettingsView(showsDisplayToggle: false)
                } label: {
                    Label("Translation Settings", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Tap the translation icon to show or hide translations. Completed translations are kept.")
            }
        }
        .navigationTitle("Translation Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
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
                LyricsTranslationControl(lines: lines,
                    information: app.settings.importedLyricsEnabled
                        ? String(localized: "This song has no synced lyrics. The original text is shown; imported translations need timestamps.") : nil)
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
