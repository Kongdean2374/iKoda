import KodaCore
import SwiftUI

struct ImmersiveSpectrumView: View {
    let frame: AudioVisualizationFrame?
    let profile: ImmersiveProfile
    let bandLimit: Int
    let active: Bool
    var albumColor: Color

    var body: some View {
        Canvas { context, size in
            let width = size.width * profile.visualWidth
            let x: CGFloat = switch profile.spectrumAlignment {
            case .leading: 0
            case .center: (size.width - width) / 2
            case .trailing: size.width - width
            }
            let rect = CGRect(x: x, y: 0, width: width, height: size.height)
            guard rect.width > 0, rect.height > 0, let frame else { return }
            let color = profile.spectrumColor.color.opacity(profile.spectrumOpacity)
            let album = albumColor.opacity(profile.spectrumOpacity)
            let shading: GraphicsContext.Shading = switch profile.spectrumTint {
            case .fixed: .color(color)
            case .album: .color(album)
            case .gradient:
                .linearGradient(Gradient(colors: [color, album]),
                                startPoint: CGPoint(x: rect.minX, y: rect.maxY),
                                endPoint: CGPoint(x: rect.maxX, y: rect.minY))
            }
            let gain = profile.sensitivity * 3 * profile.amplitude
            if profile.spectrum == .waveform {
                guard frame.waveform.count > 1 else { return }
                var path = Path()
                for (index, sample) in frame.waveform.enumerated() {
                    let neighborWeight = Float(profile.smoothness * 0.22)
                    let before = frame.waveform[max(0, index - 1)]
                    let after = frame.waveform[min(frame.waveform.count - 1, index + 1)]
                    let smoothed = sample * (1 - 2 * neighborWeight) + (before + after) * neighborWeight
                    let y = min(1, max(-1, Double(smoothed) * gain))
                    let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(frame.waveform.count - 1),
                                        y: rect.midY - rect.height * y * 0.48)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                return
            }
            let count = min(bandLimit, profile.bands)
            let step = max(1, frame.spectrum.count / count)
            var bands = stride(from: 0, to: frame.spectrum.count, by: step).map {
                frame.spectrum[$0..<min($0 + step, frame.spectrum.count)].max() ?? 0
            }
            if profile.reverseBands { bands.reverse() }
            if profile.bilateralBands && profile.spectrum == .bars {
                let half = Array(bands.prefix(bands.count / 2))
                bands = Array(half.reversed()) + half
            }
            guard !bands.isEmpty else { return }
            if profile.spectrum == .ring {
                let radius = min(rect.width, rect.height) / 2
                let inner = radius * profile.ringRadius
                let center = CGPoint(x: rect.midX, y: rect.midY)
                var path = Path()
                for (index, sample) in bands.enumerated() {
                    let angle = Double(index) / Double(bands.count) * 2 * .pi - .pi / 2
                    let outer = inner + (radius - inner) * min(1, Double(sample).squareRoot() * gain)
                    path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
                    path.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
                }
                context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            } else {
                let column = rect.width / Double(bands.count)
                var path = Path()
                for (index, sample) in bands.enumerated() {
                    let barHeight = rect.height * min(1, Double(sample).squareRoot() * gain)
                    let origin = profile.spectrum == .mirrored ? rect.midY - barHeight / 2 : rect.maxY - barHeight
                    let bar = CGRect(x: rect.minX + column * Double(index), y: origin,
                                     width: max(1, column - profile.gap), height: barHeight)
                    path.addRoundedRect(in: bar, cornerSize: CGSize(width: 2, height: 2))
                }
                context.fill(path, with: shading)
            }
        }
        .overlay {
            if active && frame == nil {
                Text("Audio Visualization Unavailable")
                    .font(.caption)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Capsule())
            }
        }
        .accessibilityLabel("Audio Visualization")
        .allowsHitTesting(false)
    }
}

actor ImmersiveAudioSampler {
    private var previousInput: AudioVisualizationInput?
    private var lastSerial: UInt64?
    private var frame: AudioVisualizationFrame?
    private var updated = Date.distantPast

    func read(_ input: AudioVisualizationInput, near time: TimeInterval, smooth: Double) -> AudioVisualizationFrame? {
        if previousInput !== input {
            previousInput = input
            lastSerial = nil
            frame = nil
        }
        let now = Date()
        guard let pcm = input.samples(after: lastSerial, near: time) else {
            return now.timeIntervalSince(updated) < 0.35 ? frame : nil
        }
        lastSerial = pcm.serial
        guard let analysis = AudioVisualizationAnalysis.analyze(pcm.values, sampleRate: pcm.sampleRate) else { return nil }
        let spectrum = frame.map { previous in
            zip(analysis.spectrum, previous.spectrum).map { $0.0 * Float(1 - smooth) + $0.1 * Float(smooth) }
        } ?? analysis.spectrum
        frame = .init(spectrum: spectrum, waveform: analysis.waveform, rms: analysis.rms, peak: analysis.peak)
        updated = now
        return frame
    }
}
