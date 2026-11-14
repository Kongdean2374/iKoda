import Foundation
import Testing
@testable import KodaCore

struct OutputGainBudgetTests {
    @Test func twoOverlappingSourcesShareOneLimit() {
        let gains = OutputGainBudget.allocate(requested: [0.7, 0.7], limit: 0.5)
        #expect(abs(gains[0] - 0.25) < 0.000001)
        #expect(abs(gains[1] - 0.25) < 0.000001)
        let inPhasePeak = Double(gains[0]) + Double(gains[1])
        #expect(inPhasePeak <= 0.5)
        #expect(inPhasePeak > 0.49999)
    }

    @Test func equalPowerFadeRemainsContinuousAndPreservesItsRatio() {
        var previous: [Float]?
        var largestStep: Float = 0
        for index in 0...2000 {
            let progress = Double(index) / 2000
            let desired = [Float(cos(progress * .pi / 2)), Float(sin(progress * .pi / 2))]
            let allocated = OutputGainBudget.allocate(requested: desired, limit: 0.4)
            #expect(allocated.reduce(0.0) { $0 + Double($1) } <= Double(Float(0.4)))
            // Cross multiplication avoids dividing by the silent endpoint of a fade.
            #expect(abs(allocated[0] * desired[1] - allocated[1] * desired[0]) < 0.000001)
            if let previous {
                largestStep = max(largestStep, max(abs(previous[0] - allocated[0]), abs(previous[1] - allocated[1])))
            }
            previous = allocated
        }
        #expect(largestStep < 0.001)
        #expect(abs((previous?.last ?? 0) - 0.4) < 0.000001)
    }

    @Test func threeSourcesAndKnownDSPAmplificationStayWithinBudget() {
        let bounds: [Float] = [1, 1.5, 2]
        let allocated = OutputGainBudget.allocate(requested: [0.6, 0.7, 0.8], limit: 0.5, peakBounds: bounds)
        let worstCase = allocated.indices.reduce(0.0) { $0 + Double(allocated[$1]) * Double(bounds[$1]) }
        #expect(worstCase <= 0.5)
        #expect(worstCase > 0.49999)
        var peak: Float = 0
        for frame in 0..<48_000 {
            let t = Double(frame) / 48_000
            let samples = [Float(sin(2 * .pi * 440 * t)), 1.5 * Float(sin(2 * .pi * 880 * t)), 2 * Float(cos(2 * .pi * 220 * t))]
            let mixed = allocated.indices.reduce(Float(0)) { $0 + allocated[$1] * samples[$1] }
            peak = max(peak, abs(mixed))
        }
        #expect(peak <= 0.5)
    }

    @Test func outputBudgetIncludesCustomEQAndPostAutomationProtection() {
        var settings = SoundSettings()
        settings.customEnabled = true
        settings.gains = Array(repeating: 12, count: 10)
        settings.bassBoostDB = 12
        settings.preampDB = 12
        var first = SoundProcessor(), second = SoundProcessor()
        first.configure(settings, preset: .off, sampleRate: 48_000, smooth: false)
        second.configure(settings, preset: .off, sampleRate: 48_000, smooth: false)
        let allocated = OutputGainBudget.allocate(requested: [0.7, 0.7], limit: 0.5)
        var peak: Float = 0
        for frame in 0..<24_000 {
            let sample = Float(sin(2 * Double.pi * 64 * Double(frame) / 48_000))
            // Includes an adversarial positive automation gain. The shared post-processing
            // guard bounds each source before the coordinated AVPlayer gain is applied.
            let one = SoundSafety.limit(first.run(sample) * 1.5, ceiling: 1)
            let two = SoundSafety.limit(second.run(sample) * 2, ceiling: 1)
            peak = max(peak, abs(one * allocated[0] + two * allocated[1]))
        }
        #expect(peak <= 0.5)
        #expect(peak > 0.25, "The test must exercise audible processed samples, not a muted path")
    }

    @Test func singleSourceBypassAndZeroLimitDoNotDoubleAttenuate() {
        #expect(OutputGainBudget.allocate(requested: [0.2], limit: 0.5) == [0.2])
        #expect(OutputGainBudget.allocate(requested: [0.4, 0, 0], limit: 0.5) == [0.4, 0, 0])
        let capped = OutputGainBudget.allocate(requested: [0.8], limit: 0.5)
        #expect(capped[0] <= 0.5 && capped[0] > 0.49999)
        #expect(OutputGainBudget.allocate(requested: [1, 1], limit: 0) == [0, 0])
        #expect(OutputGainBudget.allocate(requested: [], limit: 0.5).isEmpty)
    }

    @Test func invalidInputsCannotCreateGainOrNonFiniteOutput() {
        #expect(OutputGainBudget.allocate(requested: [.nan, .infinity, -1], limit: 0.5) == [0, 0, 0])
        #expect(OutputGainBudget.allocate(requested: [1], limit: .nan) == [0])
        #expect(OutputGainBudget.allocate(requested: [1, 0.25], limit: 0.5, peakBounds: [.infinity, 1]) == [0, 0.25])
        #expect(OutputGainBudget.allocate(requested: [1], limit: 2)[0] <= 1)
    }

    @Test func handoverWritesReductionsBeforeIncreases() {
        var actual: [Float] = [0.5, 0, 0]
        let target = OutputGainBudget.allocate(requested: [0.7, 0.7, 0], limit: 0.5)
        let order = OutputGainBudget.updateOrder(current: actual, target: target)
        #expect(order.first == 0)
        for index in order {
            actual[index] = target[index]
            #expect(actual.reduce(0.0) { $0 + Double($1) } <= 0.5)
        }
        let finished: [Float] = [0, 0.5, 0]
        for index in OutputGainBudget.updateOrder(current: actual, target: finished) {
            actual[index] = finished[index]
            #expect(actual.reduce(0.0) { $0 + Double($1) } <= 0.5)
        }
        #expect(actual == finished)
    }
}
