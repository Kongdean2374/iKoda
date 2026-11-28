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
    private weak var previousScreen: UIScreen?
    private var restoredValue: CGFloat?

    func update(screen: UIScreen?, active: Bool, keepAwake: Bool, brightness: CGFloat?) {
        let shouldHold = active && keepAwake
        if shouldHold, Self.holders.insert(id).inserted, Self.holders.count == 1 {
            Self.previousIdleValue = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if !shouldHold, Self.holders.remove(id) != nil, Self.holders.isEmpty {
            UIApplication.shared.isIdleTimerDisabled = Self.previousIdleValue
        }
        #if !targetEnvironment(macCatalyst)
        if brightness == nil {
            restoreBrightness()
            previousScreen = nil
            restoredValue = nil
            lastRequest = nil
            systemOverride = false
            return
        }
        if !active || self.screen !== screen { restoreBrightness() }
        guard active, let brightness, let screen else { return }
        if self.screen == nil, previousScreen === screen, let restoredValue,
           abs(screen.brightness - restoredValue) > 0.015, lastRequest == brightness {
            systemOverride = true
        }
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
        if let screen {
            if let baseline, let applied {
                if abs(screen.brightness - applied) <= 0.015 {
                    screen.brightness = baseline
                } else {
                    systemOverride = true
                }
            }
            previousScreen = screen
            restoredValue = screen.brightness
        }
        #endif
        screen = nil
        baseline = nil
        applied = nil
    }
}

struct ImmersiveWindowProbe: UIViewRepresentable {
    var onChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> WindowProbe {
        let view = WindowProbe()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: WindowProbe, context: Context) { view.onChange = onChange }

    final class WindowProbe: UIView {
        var onChange: ((UIWindow?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let host = window
            Task { @MainActor [weak self] in self?.onChange?(host) }
        }
    }
}
