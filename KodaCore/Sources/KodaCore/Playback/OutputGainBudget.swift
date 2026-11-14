import Foundation

/// Coordinates the gains of Koda's simultaneously audible AVPlayers. Capping each player
/// separately is insufficient: two in-phase 0.7 signals would otherwise sum above a 0.5 cap.
/// A common factor preserves the relative fade envelopes and each song's normalization.
/// This is a gain budget, not a hardware or inter-sample true-peak measurement.
nonisolated enum OutputGainBudget {
    /// `peakBounds` describes a proven bound after each source's processing, never an RMS or
    /// recent peak measurement. The normal decoder/tap contract is a unit-magnitude source;
    /// callers can supply a larger bound for a processing stage with a known amplification.
    static func allocate(requested: [Float], limit: Float, peakBounds: [Float]? = nil) -> [Float] {
        let ceiling = limit.isFinite ? min(1, max(0, limit)) : 0
        guard ceiling > 0 else { return Array(repeating: 0, count: requested.count) }
        var gains = requested.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        var bounds = Array(repeating: Float(1), count: gains.count)
        for index in gains.indices {
            guard let supplied = peakBounds, supplied.indices.contains(index) else { continue }
            let bound = supplied[index]
            // An unknown/non-finite bound fails closed for that source.
            if !bound.isFinite || bound < 0 { gains[index] = 0 }
            else { bounds[index] = bound }
        }
        let total = gains.indices.reduce(0.0) { $0 + Double(gains[$1]) * Double(bounds[$1]) }
        guard total > Double(ceiling) else { return gains }
        // Round the common multiplier down twice, reserving an extra ULP for the subsequent
        // Float products so rounding cannot overshoot the aggregate budget.
        let factor = max(0, Float(Double(ceiling) / total).nextDown.nextDown)
        return gains.map { $0 * factor }
    }

    /// AVPlayer volumes are written one at a time. All reductions must precede increases,
    /// including when an incoming player is started, to avoid an intermediate over-budget mix.
    /// The caller still must budget every audible player and set a new player's gain before play.
    static func updateOrder(current: [Float], target: [Float]) -> [Int] {
        let indices = Array(target.indices)
        let decreases = indices.filter { index in
            let before = current.indices.contains(index) ? current[index] : 0
            return !before.isFinite || target[index] < before
        }
        let decreased = Set(decreases)
        return decreases + indices.filter { !decreased.contains($0) }
    }
}
