#if !targetEnvironment(macCatalyst)
import AppIntents
import Foundation
#if !WIDGET_EXTENSION
import KodaCore
#endif

enum CarPlayTransportAction: String, AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playback"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .previous: "Previous Track", .toggle: "Play or Pause", .next: "Next Track",
    ]

    case previous, toggle, next
}

/// WidgetKit runs audio intents in the host app, which already owns the player.
struct CarPlayTransportIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Control Koda Playback"

    @Parameter(title: "Playback")
    var action: CarPlayTransportAction

    init() {}
    init(_ action: CarPlayTransportAction) { self.action = action }

    #if !WIDGET_EXTENSION
    @Dependency private var app: AppModel
    #endif

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        #if WIDGET_EXTENSION
        throw CarPlayIntentError.hostUnavailable
        #else
        let player = app.player
        switch action {
        case .previous:
            guard player.current != nil else { throw CarPlayIntentError.noTrack }
            player.previous()
        case .toggle:
            guard WidgetPlayback.toggle(in: app) else { throw CarPlayIntentError.noTrack }
        case .next:
            guard player.current != nil else { throw CarPlayIntentError.noTrack }
            guard player.queue.peekNext(automatic: false) != nil || (player.autoplay && player.flowSourceID == nil) else {
                throw CarPlayIntentError.noNextTrack
            }
            player.next()
        }
        return .result()
        #endif
    }
}

struct ShowCarPlayLyricsIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Show Lyrics"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Koda Lyrics")
    var activityID: String

    init() {}
    init(activityID: String) { self.activityID = activityID }

    #if !WIDGET_EXTENSION
    @Dependency private var app: AppModel
    #endif

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        #if WIDGET_EXTENSION
        throw CarPlayIntentError.hostUnavailable
        #else
        try app.carPlay.showLyrics(activityID: activityID)
        return .result()
        #endif
    }
}

enum CarPlayIntentError: LocalizedError {
    case hostUnavailable, noTrack, noNextTrack, activityUnavailable

    var errorDescription: String? {
        switch self {
        case .hostUnavailable: String(localized: "Koda playback controls are unavailable here.")
        case .noTrack: String(localized: "There is no track to control in Koda.")
        case .noNextTrack: String(localized: "There is no next track in Koda.")
        case .activityUnavailable: String(localized: "This lyrics activity has ended.")
        }
    }
}
#endif
