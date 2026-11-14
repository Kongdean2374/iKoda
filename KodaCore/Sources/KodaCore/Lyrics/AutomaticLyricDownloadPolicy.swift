/// Download consent belongs to a language pair, not to each song. One cancelled or
/// unsuccessful prompt is suppressed for this app session until an explicit retry.
public struct AutomaticLyricDownloadPolicy: Sendable {
    public struct Pair: Hashable, Sendable {
        public let source: String
        public let target: String
        public init(source: String, target: String) { self.source = source; self.target = target }
    }

    private var active: [Pair: String] = [:]
    private var suppressed: Set<Pair> = []
    private var retryAfterFinish: Set<Pair> = []

    public init() {}

    public func allows(_ pair: Pair, requestID: String) -> Bool {
        !suppressed.contains(pair) && (active[pair] == nil || active[pair] == requestID)
    }

    public mutating func begin(_ pair: Pair, requestID: String) -> Bool {
        guard allows(pair, requestID: requestID), active[pair] == nil else { return false }
        active[pair] = requestID
        return true
    }

    /// An old host's completion cannot release a newer request for the same pair.
    @discardableResult
    public mutating func finish(_ pair: Pair, requestID: String, installed: Bool) -> Bool {
        guard active[pair] == requestID else { return false }
        active.removeValue(forKey: pair)
        let retried = retryAfterFinish.remove(pair) != nil
        if !installed && !retried { suppressed.insert(pair) }
        else { suppressed.remove(pair) }
        return true
    }

    /// Moving the download UI between app surfaces is not a refusal of the language
    /// download. Release only this host's claim; the next host may ask once again.
    @discardableResult
    public mutating func cancelHost(_ pair: Pair, requestID: String) -> Bool {
        guard active[pair] == requestID else { return false }
        active.removeValue(forKey: pair)
        retryAfterFinish.remove(pair)
        return true
    }

    public mutating func retry(_ pair: Pair? = nil) {
        if let pair {
            suppressed.remove(pair)
            if active[pair] != nil { retryAfterFinish.insert(pair) }
        } else {
            suppressed.removeAll()
            retryAfterFinish.formUnion(active.keys)
        }
    }
}
