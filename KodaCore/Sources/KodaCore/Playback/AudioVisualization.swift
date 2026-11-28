import Accelerate
import AudioToolbox
import Foundation
import os

public struct AudioVisualizationFrame: Sendable {
    public let spectrum: [Float]
    public let waveform: [Float]
    public let rms: Float
    public let peak: Float

    public init(spectrum: [Float], waveform: [Float], rms: Float, peak: Float) {
        self.spectrum = spectrum
        self.waveform = waveform
        self.rms = rms
        self.peak = peak
    }
}

public struct AudioVisualizationSamples: Sendable {
    public let values: [Float]
    public let sampleRate: Double
    public let itemTime: TimeInterval
    public let serial: UInt64
}

/// A reader on the analysis executor renews a short lease. The tap never waits
/// for the reader and stops copying as soon as that lease expires.
public final class AudioVisualizationInput: @unchecked Sendable {
    private static let capacity = 2048

    private struct Mailbox {
        var values = ContiguousArray(repeating: Float.zero, count: AudioVisualizationInput.capacity)
        var cursor = 0
        var count = 0
        var sampleRate = 0.0
        var itemTime = 0.0
        var serial: UInt64 = 0
        var updated = 0.0
        var lease = 0.0
    }

    private let mailbox = OSAllocatedUnfairLock(initialState: Mailbox())

    public func samples(after serial: UInt64? = nil, near itemTime: TimeInterval) -> AudioVisualizationSamples? {
        let now = ProcessInfo.processInfo.systemUptime
        return mailbox.withLock { state in
            state.lease = now + 0.4
            guard state.count == Self.capacity, state.serial != serial,
                  now - state.updated < 0.4, abs(state.itemTime - itemTime) < 0.6 else { return nil }
            var values = [Float]()
            values.reserveCapacity(Self.capacity)
            values.append(contentsOf: state.values[state.cursor...])
            values.append(contentsOf: state.values[..<state.cursor])
            return AudioVisualizationSamples(values: values, sampleRate: state.sampleRate,
                                             itemTime: state.itemTime, serial: state.serial)
        }
    }

    func reset() {
        mailbox.withLock {
            $0.count = 0
            $0.cursor = 0
            $0.lease = 0
        }
    }

    func capture(_ buffers: UnsafeMutableBufferPointer<AudioBuffer>, frames: Int, rate: Double, end: Double) {
        guard rate.isFinite, rate > 0, end.isFinite, let first = buffers.first,
              let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        let stride = Int(first.mNumberChannels)
        guard stride > 0 else { return }
        let available = min(frames, Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride)
        guard available > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        _ = mailbox.withLockIfAvailable { state in
            guard state.lease > now else { return }
            if state.sampleRate != rate || now - state.updated > 0.4 || abs(state.itemTime - end) > 0.6 {
                state.count = 0
                state.cursor = 0
            }
            // The first decoded channel avoids cancellation of opposite-phase
            // stereo. This measures the current item, before output-route mixing.
            for index in max(0, available - Self.capacity)..<available {
                state.values[state.cursor] = data[index * stride]
                state.cursor = (state.cursor + 1) & (Self.capacity - 1)
            }
            state.count = min(Self.capacity, state.count + available)
            state.sampleRate = rate
            state.itemTime = end
            state.updated = now
            state.serial &+= 1
        }
    }
}

/// The presentation calls this on an analysis executor, outside the audio tap.
public enum AudioVisualizationAnalysis {
    public static func analyze(_ values: [Float], sampleRate: Double) -> AudioVisualizationFrame? {
        let count = values.count
        guard (256...4096).contains(count), count.nonzeroBitCount == 1,
              sampleRate.isFinite, (8_000...384_000).contains(sampleRate) else { return nil }
        let clean = values.map { $0.isFinite ? min(1, max(-1, $0)) : 0 }
        let peak = clean.reduce(Float.zero) { max($0, abs($1)) }
        let rms = (clean.reduce(Float.zero) { $0 + $1 * $1 } / Float(count)).squareRoot()
        let waveform = stride(from: 0, to: count, by: count / 128).map { index in
            clean[index..<(index + count / 128)].max { abs($0) < abs($1) } ?? 0
        }
        var bands = [Float](repeating: 0, count: 128)
        guard peak > 0.00001 else { return .init(spectrum: bands, waveform: waveform, rms: rms, peak: peak) }
        let power = vDSP_Length(count.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(power, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var real = clean.enumerated().map { index, value in
            value * (0.5 - 0.5 * cos(2 * .pi * Float(index) / Float(count - 1)))
        }
        var imaginary = [Float](repeating: 0, count: count)
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let real = real.baseAddress, let imaginary = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: real, imagp: imaginary)
                vDSP_fft_zip(setup, &split, 1, power, FFTDirection(FFT_FORWARD))
            }
        }
        let upper = min(20_000, sampleRate / 2)
        for bin in 1..<(count / 2) {
            let frequency = Double(bin) * sampleRate / Double(count)
            guard frequency >= 20, frequency < upper else { continue }
            let band = min(127, Int(log(frequency / 20) / log(upper / 20) * 128))
            let magnitude = hypot(real[bin], imaginary[bin]) * 4 / Float(count)
            bands[band] = max(bands[band], magnitude)
        }
        return .init(spectrum: bands, waveform: waveform, rms: rms, peak: peak)
    }
}
