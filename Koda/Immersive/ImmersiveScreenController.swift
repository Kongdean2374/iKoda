import SwiftUI
import UIKit

@MainActor
final class ImmersiveScreenController {
    private static var holders: Set<UUID> = []
    private static var previousIdleValue = false
    private let id = UUID()
    private weak var screen: UIScreen?
    private var baseline: CGFloat?
    private var applied: CGFloat?
    private var lastRequest: CGFloat?
    private var systemOverride = false

    func update(screen: UIScreen?, active: Bool, keepAwake: Bool, brightness: CGFloat?) {
        let shouldHold = active && keepAwake
        if shouldHold, Self.holders.insert(id).inserted, Self.holders.count == 1 {
            Self.previousIdleValue = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !shouldHold, Self.holders.remove(id) != nil, Self.holders.isEmpty {
            UIApplication.shared.isIdleTimerDisabled = Self.previousIdleValue
        }
        #if !targetEnvironment(macCatalyst)
        if self.screen !== screen || !active || brightness == nil {
            restoreBrightness()
        }
        guard active, let brightness, let screen else { return }
        self.screen = screen
        if let applied, abs(screen.brightness - applied) > 0.015 {
            // Control Center or a hardware/system change wins until the user moves
            // Koda's slider again. Keep that new level as the restoration value.
            baseline = screen.brightness
            self.applied = nil
            systemOverride = true
        }
        guard !systemOverride || lastRequest != brightness else { return }
        lastRequest = brightness
        systemOverride = false
        if baseline == nil { baseline = screen.brightness }
        guard applied != brightness else { return }
        screen.brightness = brightness
        applied = screen.brightness
        #endif
    }

    private func restoreBrightness() {
        #if !targetEnvironment(macCatalyst)
        if let screen, let baseline, let applied, abs(screen.brightness - applied) <= 0.015 {
            screen.brightness = baseline
        }
        #endif
        screen = nil
        baseline = nil
        applied = nil
        lastRequest = nil
        systemOverride = false
    }
}

struct ImmersiveDisplayProbe: UIViewRepresentable {
    var onChange: (UIScreen?) -> Void

    func makeUIView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: WindowProbe, context: Context) { view.onChange = onChange }

    final class WindowProbe: UIView {
        var onChange: ((UIScreen?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let display = window?.windowScene?.screen
            Task { @MainActor [weak self] in self?.onChange?(display) }
        }
    }
}
