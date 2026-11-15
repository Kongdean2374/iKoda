import Foundation

/// A bounded duration fit over one explicitly supplied, fully loaded playlist.
/// No listening history, account recommendations or external songs enter this API.
public enum KodaFlowPlanner {
    public struct Plan: Sendable, Equatable {
        public let sourceID: String
        public let songs: [Song]
        public let targetDuration: TimeInterval
        public let estimatedDuration: TimeInterval
        public let availableDuration: TimeInterval
        public let duplicateCount: Int
        public let unknownDurationCount: Int
        public var difference: TimeInterval { estimatedDuration - targetDuration }
        public var isSourceTooShort: Bool { availableDuration < targetDuration }
    }

    public enum PlanningError: Error, Equatable {
        case invalidTarget, missingSource, noKnownDurations
    }

    /// At most 8,192 time cells, independent of playlist size. Randomized first discovery
    /// gives equally valid arrangements variety without introducing preference weights.
    public static func makePlan(sourceID: String, songs: [Song], minutes: Int, seed: UInt64) async throws -> Plan {
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try build(sourceID: sourceID, songs: songs, minutes: minutes, seed: seed)
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
        }
    }

    private static func build(sourceID: String, songs: [Song], minutes: Int, seed: UInt64) throws -> Plan {
        try Task.checkCancellation()
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PlanningError.missingSource }
        guard (1...720).contains(minutes) else { throw PlanningError.invalidTarget }
        let target = Double(minutes * 60)
        var seen = Set<String>()
        var candidates: [Song] = []
        var duplicateCount = 0
        var unknownCount = 0
        for (index, song) in songs.enumerated() {
            if index.isMultiple(of: 128) { try Task.checkCancellation() }
            guard !song.id.isEmpty, let length = song.duration, length.isFinite, length > 0, length <= 7 * 24 * 3600 else {
                unknownCount += 1
                continue
            }
            guard seen.insert(song.id).inserted else { duplicateCount += 1; continue }
            candidates.append(song)
        }
        guard !candidates.isEmpty else { throw PlanningError.noKnownDurations }
        var random = FlowRandom(seed: seed)
        candidates.shuffle(using: &random)
        let available = candidates.reduce(0.0) { $0 + ($1.duration ?? 0) }
        if available <= target {
            return Plan(sourceID: sourceID, songs: candidates, targetDuration: target,
                        estimatedDuration: available, availableDuration: available,
                        duplicateCount: duplicateCount, unknownDurationCount: unknownCount)
        }
        // A lone longer song is considered separately, so an unusually long upload never
        // expands the DP budget. Any positive subset beyond 2×target cannot improve on it.
        let upper = target * 2
        let quantum = max(1, ceil(upper / 8192))
        let capacity = Int(ceil(upper / quantum))
        var reached = Array(repeating: false, count: capacity + 1)
        var previous = Array(repeating: -1, count: capacity + 1)
        var chosen = Array(repeating: -1, count: capacity + 1)
        var exact = Array(repeating: 0.0, count: capacity + 1)
        reached[0] = true
        var bestCell = 0
        var bestSingle: Int?
        var bestDistance = Double.greatestFiniteMagnitude
        for (index, song) in candidates.enumerated() {
            try Task.checkCancellation()
            let length = song.duration!
            let distance = abs(length - target)
            if distance < bestDistance {
                bestDistance = distance
                bestSingle = index
                bestCell = 0
            }
            guard length <= upper else { continue }
            let weight = max(1, Int(length / quantum))
            guard weight <= capacity else { continue }
            for cell in stride(from: capacity, through: weight, by: -1) {
                if cell.isMultiple(of: 1024) { try Task.checkCancellation() }
                guard !reached[cell], reached[cell - weight] else { continue }
                let total = exact[cell - weight] + length
                guard total <= upper else { continue }
                reached[cell] = true
                previous[cell] = cell - weight
                chosen[cell] = index
                exact[cell] = total
                let delta = abs(total - target)
                if delta < bestDistance {
                    bestDistance = delta
                    bestSingle = nil
                    bestCell = cell
                }
            }
            // An exact solution needs no remaining work. Different seeds still discover
            // different valid subsets/orders; all tracks remain inside the chosen source.
            if bestDistance < 0.001 { break }
        }
        var result: [Song] = []
        if let bestSingle { result = [candidates[bestSingle]] }
        else {
            var cell = bestCell
            while cell > 0 {
                let index = chosen[cell]
                guard index >= 0, previous[cell] >= 0, previous[cell] < cell else { break }
                result.append(candidates[index])
                cell = previous[cell]
            }
            result.shuffle(using: &random)
        }
        try Task.checkCancellation()
        return Plan(sourceID: sourceID, songs: result, targetDuration: target,
                    estimatedDuration: result.reduce(0) { $0 + ($1.duration ?? 0) }, availableDuration: available,
                    duplicateCount: duplicateCount, unknownDurationCount: unknownCount)
    }

    private struct FlowRandom: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
            value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
            return value ^ (value >> 31)
        }
    }
}
