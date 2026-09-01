import AppKit
import SwiftUI

extension NSScrollView {
    /// Turns off the optional macOS titlebar scroll pocket for this surface.
    ///
    /// The KVC setter is guarded because this capability is not public and may
    /// move between macOS releases. Reapply it after every window move because
    /// AppKit creates the pocket for the window that owns the scroll view.
    func suppressSystemScrollEdgeEffect() {
        let setter = NSSelectorFromString(ScrollEdgeEffectPolicy.allowedPocketEdgesSetter)
        guard responds(to: setter) else { return }
        setValue(
            ScrollEdgeEffectPolicy.suppressedPocketEdges,
            forKey: ScrollEdgeEffectPolicy.allowedPocketEdgesKey
        )
    }
}

/// A zero-size AppKit bridge for SwiftUI-owned scroll views.
struct ScrollEdgeEffectSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollEdgeEffectSuppressingView {
        ScrollEdgeEffectSuppressingView()
    }

    func updateNSView(_ nsView: ScrollEdgeEffectSuppressingView, context: Context) {
        nsView.suppressAttachedScrollViews()
    }
}

@MainActor
final class ScrollEdgeEffectSuppressingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)
        alphaValue = 0
        suppressAttachedScrollViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressAttachedScrollViews()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.suppressAttachedScrollViews()
        }
    }

    func suppressAttachedScrollViews() {
        for scrollView in attachedScrollViews() {
            scrollView.suppressSystemScrollEdgeEffect()
        }
    }

    private func attachedScrollViews() -> [NSScrollView] {
        if let enclosingScrollView {
            return [enclosingScrollView]
        }

        var root: NSView = self
        while let superview = root.superview {
            if superview is NSSplitView { break }
            root = superview
            if root === window?.contentView { break }
        }

        var result: [NSScrollView] = []
        func visit(_ view: NSView) {
            if let scrollView = view as? NSScrollView {
                result.append(scrollView)
                return
            }
            for subview in view.subviews {
                visit(subview)
            }
        }
        visit(root)
        return result
    }
}
