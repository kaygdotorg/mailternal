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
            // Never read GeometryProxy.safeAreaInsets here. AppKit changes
            // that value when any scroll view crosses the unified toolbar's
            // edge, which would move every pane's dissolve and rest depth.
            // The masked view's distance from the window top is a layout
            // fact instead: panes that ignore the top safe area sit at 0,
            // the reader sits one titlebar down. The mask is extended by that
            // distance so every policy depth is measured from the window top.
            let topOffset = max(geometry.frame(in: .global).minY, 0)
            let height = max(geometry.size.height + topOffset, 1)
            let gradient = Gradient(
                stops: policy.stops(
                    for: height,
                    safeAreaTop: MailWindowTopDissolvePolicy.titlebarDepth
                ).map { stop in
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
            .offset(y: -topOffset)
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}
