import SwiftUI

extension View {
    /// Dissolves scrolling content in one compositing mask: a top ramp whose
    /// origin the policy owns, and, for list surfaces, a bottom ramp.
    func mailWindowDissolve(_ policy: MailWindowDissolvePolicy) -> some View {
        mask {
            MailWindowDissolveMask(policy: policy)
        }
    }
}

private struct MailWindowDissolveMask: View {
    let policy: MailWindowDissolvePolicy

    var body: some View {
        GeometryReader { geometry in
            let insets = geometry.safeAreaInsets
            let height = max(geometry.size.height + insets.top + insets.bottom, 1)
            let gradient = Gradient(
                stops: policy.stops(for: height, safeAreaTop: insets.top).map { stop in
                    .init(
                        color: stop.alpha == 0
                            ? .clear
                            : .black.opacity(Double(stop.alpha)),
                        location: stop.location
                    )
                }
            )
            LinearGradient(
                gradient: gradient,
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: geometry.size.width, height: height, alignment: .top)
            // Extend only the mask through the safe-area inset, so its own top
            // edge is the physical window top and every policy depth is
            // measured from there. Resting content keeps its own layout.
            .offset(y: -insets.top)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}
