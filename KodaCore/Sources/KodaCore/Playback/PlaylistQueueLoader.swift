import Foundation

/// Collects playlist metadata independently of a scrolling view. Playback and shuffling can
/// begin only after `isComplete`, so every playable occurrence can be selected as the first song.
/// This does not resolve or download audio; the player's existing two-item pipeline still does that.
public enum PlaylistQueueLoader {
    public struct Page: Sendable {
        public var songs: [Song]
        public var continuation: String?

        public init(songs: [Song], continuation: String?) {
            self.songs = songs
            self.continuation = continuation?.isEmpty == true ? nil : continuation
        }
    }

    public struct Limits: Sendable {
        public var maxPages: Int
        public var maxSongs: Int

        /// Explicit safety bounds. Exceeding either fails preparation rather than silently
        /// starting a truncated collection. These bounds are not an API page-size assumption.
        public init(maxPages: Int = 200, maxSongs: Int = 20_000) {
            self.maxPages = maxPages
            self.maxSongs = maxSongs
        }
    }

    /// A successful-page boundary, kept by Player while a request is active or awaits Retry.
    /// Tokens stay in memory and must not be included in diagnostics. The source playlist and
    /// request generation belong to the caller; a checkpoint is never reused for another source.
    public struct Checkpoint: Sendable {
        public fileprivate(set) var songs: [Song] = []
        public fileprivate(set) var continuation: String?
        public fileprivate(set) var pagesLoaded = 0
        public fileprivate(set) var hasFirstPage = false
        fileprivate var completedTokens: Set<String> = []

        public init() {}

        /// Seed with the source's first page, or its complete ordered prefix and matching
        /// continuation after browsing. Never use filtered or reordered viewport rows. Pass the
        /// successfully consumed continuation tokens when available so cycles into the browsed
        /// prefix and the full page budget are checked. Without that history, the prefix counts
        /// as one known batch; its entire song count is always checked against limits.
        public init(firstPage: Page, completedTokens: Set<String> = []) {
            songs = firstPage.songs
            continuation = firstPage.continuation?.isEmpty == true ? nil : firstPage.continuation
            self.completedTokens = completedTokens
            pagesLoaded = 1 + completedTokens.count
            hasFirstPage = true
        }

        public var isComplete: Bool { hasFirstPage && continuation == nil }
        /// A browser that adopts this successful prefix must also adopt its cycle history.
        public var completedPageTokens: Set<String> { completedTokens }
    }

    public enum LoadingError: Error, Equatable, Sendable, LocalizedError {
        case repeatedContinuation
        case pageLimitExceeded(Int)
        case songLimitExceeded(Int)
        case invalidCheckpoint
        case invalidLimits

        public var errorDescription: String? {
            switch self {
            case .repeatedContinuation:
                NSLocalizedString("YouTube returned a repeated playlist page. The complete playlist could not be prepared.", bundle: KodaLocalization.bundle, comment: "")
            case .pageLimitExceeded(let limit):
                String(format: NSLocalizedString("This playlist exceeds the safe limit of %lld pages. No partial queue was started.", bundle: KodaLocalization.bundle, comment: ""), Int64(limit))
            case .songLimitExceeded(let limit):
                String(format: NSLocalizedString("This playlist exceeds the safe limit of %lld songs. No partial queue was started.", bundle: KodaLocalization.bundle, comment: ""), Int64(limit))
            case .invalidCheckpoint, .invalidLimits:
                NSLocalizedString("The playlist preparation state is invalid. Start loading the playlist again.", bundle: KodaLocalization.bundle, comment: "")
            }
        }
    }

    /// Sequentially follows every continuation, including empty pages with a valid next token.
    /// `didLoadPage` receives only validated committed pages. If fetching fails, the caller can
    /// retry from its latest checkpoint: the failed token is fetched again, earlier pages are not.
    /// Neither successful duplicate song IDs nor repeated song occurrences are deduplicated.
    public static func load(
        from checkpoint: Checkpoint = .init(),
        limits: Limits = .init(),
        fetchFirst: @Sendable () async throws -> Page,
        fetchMore: @Sendable (String) async throws -> Page,
        didLoadPage: @Sendable (Checkpoint) async -> Void = { _ in }
    ) async throws -> Checkpoint {
        try Task.checkCancellation()
        guard limits.maxPages > 0, limits.maxSongs > 0 else { throw LoadingError.invalidLimits }
        try validate(checkpoint, limits: limits)
        var state = checkpoint
        while !state.isComplete {
            try Task.checkCancellation()
            // Refuse before issuing another request once the page budget is exhausted.
            guard state.pagesLoaded < limits.maxPages else { throw LoadingError.pageLimitExceeded(limits.maxPages) }
            let requestedToken = state.hasFirstPage ? state.continuation : nil
            if let requestedToken, state.completedTokens.contains(requestedToken) {
                throw LoadingError.repeatedContinuation
            }
            let page: Page
            do {
                if let requestedToken { page = try await fetchMore(requestedToken) }
                else { page = try await fetchFirst() }
            } catch {
                // Some URL loading implementations report cancellation as URLError.cancelled.
                // The task's cancellation must still propagate as CancellationError to Player.
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            let next = page.continuation?.isEmpty == true ? nil : page.continuation
            if let next, next == requestedToken || state.completedTokens.contains(next) {
                throw LoadingError.repeatedContinuation
            }
            // Subtraction avoids an overflow from a malformed, unexpectedly large response.
            guard page.songs.count <= limits.maxSongs - state.songs.count else {
                throw LoadingError.songLimitExceeded(limits.maxSongs)
            }
            // Append only after validation; a retry cannot duplicate a partially accepted page.
            state.songs.append(contentsOf: page.songs)
            state.continuation = next
            state.pagesLoaded += 1
            state.hasFirstPage = true
            if let requestedToken { state.completedTokens.insert(requestedToken) }
            await didLoadPage(state)
            try Task.checkCancellation()
        }
        return state
    }

    private static func validate(_ checkpoint: Checkpoint, limits: Limits) throws {
        guard checkpoint.pagesLoaded >= 0,
              checkpoint.hasFirstPage == (checkpoint.pagesLoaded > 0),
              checkpoint.hasFirstPage || (checkpoint.songs.isEmpty && checkpoint.continuation == nil && checkpoint.completedTokens.isEmpty)
        else { throw LoadingError.invalidCheckpoint }
        guard checkpoint.pagesLoaded <= limits.maxPages else { throw LoadingError.pageLimitExceeded(limits.maxPages) }
        guard checkpoint.songs.count <= limits.maxSongs else { throw LoadingError.songLimitExceeded(limits.maxSongs) }
        if let token = checkpoint.continuation, checkpoint.completedTokens.contains(token) {
            throw LoadingError.repeatedContinuation
        }
    }
}
