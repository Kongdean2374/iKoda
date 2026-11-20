#if !targetEnvironment(macCatalyst)
import Foundation
import KodaCore
import Observation
import UIKit
import WidgetKit

/// Copies only the current title, playback flags and one small cached cover.
@MainActor
final class CarPlayPlayerPublisher {
    private weak var app: AppModel?
    private let file: URL
    private var track: Track?
    private var artwork: Data?
    private var artworkTask: Task<Void, Never>?
    private var lastSnapshot: CarPlayPlayerSnapshot?

    private struct Track: Equatable {
        var profileID: UUID
        var songID: String?
        var artwork: URL?
    }

    init(app: AppModel, file: URL) {
        self.app = app
        self.file = file
    }

    func observe() {
        guard let app else { return }
        let input = withObservationTracking {
            let player = app.player
            let current = player.current
            let song = player.isPlaybackSessionFinished ? nil : current
            return (Track(profileID: app.roster.activeID, songID: song?.id, artwork: song?.artwork?.url(pixels: 600)),
                    song?.title, player.wantsToPlay, current != nil, !app.library.liked.isEmpty)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }

        if track != input.0 {
            track = input.0
            artwork = nil
            artworkTask?.cancel()
            if let url = input.0.artwork {
                let expected = input.0
                artworkTask = Task { [weak self] in
                    // Use the same decoded-image request as lock-screen Now Playing.
                    let image = await ImagePipeline.shared.image(url, pixels: 600)
                    guard let self, !Task.isCancelled, self.track == expected,
                          self.app?.roster.activeID == expected.profileID,
                          self.app?.player.current?.id == expected.songID,
                          self.app?.player.isPlaybackSessionFinished == false else { return }
                    self.artwork = image.flatMap(Self.thumbnail)
                    if let snapshot = self.lastSnapshot {
                        var updated = snapshot
                        updated.artwork = self.artwork
                        self.write(updated)
                    }
                }
            }
        }
        write(CarPlayPlayerSnapshot(nowPlayingTitle: input.1.map { String($0.prefix(160)) },
                                    wantsToPlay: input.2, hasQueueItem: input.3,
                                    hasLikedSongs: input.4, artwork: artwork))
    }

    private func write(_ snapshot: CarPlayPlayerSnapshot) {
        guard snapshot != lastSnapshot else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastSnapshot = snapshot
        } catch {
            // Avoid serving an older account's artwork if a new snapshot cannot be saved.
            try? FileManager.default.removeItem(at: file)
            lastSnapshot = nil
        }
        WidgetCenter.shared.reloadTimelines(ofKind: CarPlayPlayerSnapshot.widgetKind)
    }

    private static func thumbnail(_ image: UIImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = 144 / max(image.size.width, image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format)
            .jpegData(withCompressionQuality: 0.8) { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
#endif
