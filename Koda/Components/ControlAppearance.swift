import SwiftUI

/// Shared hit-area rule for compact touch controls. Symbol sizes still follow each
/// control's visual hierarchy; a small glyph need not be a small button.
enum ControlMetrics {
    static let touchTarget: CGFloat = 44
}

extension View {
    /// Keeps the existing system glass in normal use, with a solid system-colour
    /// surface for Reduce Transparency. Never stacks blur/material behind glass.
    func kodaGlassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(KodaGlassSurface(shape: shape, interactive: interactive))
    }
}

private struct KodaGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let interactive: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Color(uiColor: .secondarySystemBackground), in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        } else {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        }
    }
}
