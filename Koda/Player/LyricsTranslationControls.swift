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
    @State private var result = AutomaticLyricsResult()
    @State private var retry = 0

    private var lines: [LyricsTranslationText] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").enumerated().map { LyricsTranslationText(id: $0.offset, text: $0.element) }
    }
    private var enabled: Bool { app.settings.automaticLyricsTranslation && app.settings.showsLyricsTranslation }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: app.settings.translationSpacing) {
                    if enabled {
                        AutomaticLyricsNotice(phase: result.phase) { retry += 1 }
                            .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
                    } else if app.settings.importedLyricsEnabled, app.settings.showsLyricsTranslation {
                        Text("This song has no synced lyrics. The original text is shown; imported translations need timestamps.")
                            .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
                    }
                    ForEach(lines, id: \.id) { line in
                        let presentation = LyricTranslationPresentation(mode: .bilingual,
                                                                         enabled: enabled, translation: result.lines[line.id])
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
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            HStack {
                LyricsTranslationToggle()
                Spacer()
            }
            .padding(.top, 6)
        }
        .background {
            AutomaticLyricsTranslationTask(songID: player.current?.id, lines: lines, enabled: enabled, retry: retry, result: $result)
        }
    }
}
