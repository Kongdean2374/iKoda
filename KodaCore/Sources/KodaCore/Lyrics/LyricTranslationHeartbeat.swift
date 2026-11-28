import Foundation

/// A progress-sensitive deadline for Apple Translation's sequence of replies.
actor LyricTranslationHeartbeat {
    private let start = ContinuousClock.now
    private var response: ContinuousClock.Instant?

    func received() { response = .now }

    func waitForInactivity(_ allowance: Duration) async throws {
        let clock = ContinuousClock()
        while true {
            let lastProgress = response ?? start
            try await clock.sleep(until: lastProgress.advanced(by: allowance))
            if lastProgress == (response ?? start) { return }
        }
    }
}
