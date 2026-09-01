import AppKit
import SwiftUI

enum WindowBackdropTreatment: Equatable {
    case opaque
    case blur
    case glass
}

struct WindowBackdropPlan: Equatable {
    var opacity: Double
    var treatment: WindowBackdropTreatment

    var fillOpacity: Double {
        switch treatment {
        case .glass: 0
        case .blur, .opaque: opacity
        }
    }

    init(
        kind: WindowBackdropKind,
        opacity: Double,
        reduceTransparency: Bool,
        isFullScreen: Bool
    ) {
        guard !reduceTransparency, !isFullScreen, opacity.isFinite else {
            self.opacity = 1
            treatment = .opaque
            return
        }
        let clamped = min(max(opacity, 0), 1)
        self.opacity = clamped
        if clamped >= 1 {
            treatment = .opaque
            return
        }
        treatment = kind == .glass ? .glass : .blur
    }
}

struct WindowBackdropRoot: View {
    let appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        WindowBackdropViewRepresentable(
            kind: appearance.usesLiquidGlass ? .glass : .blur,
            opacity: appearance.backgroundOpacity,
            reduceTransparency: reduceTransparency
        )
        .overlay {
            if shouldShowGlass {
                let shape = RoundedRectangle(
                    cornerRadius: 0,
                    style: .continuous
                )
                Color(nsColor: .windowBackgroundColor)
                    .opacity(appearance.backgroundOpacity)
                    .clipShape(shape)
                    .glassEffect(.regular, in: shape)
            }
        }
        .allowsHitTesting(false)
    }

    private var shouldShowGlass: Bool {
        WindowBackdropPlan(
            kind: appearance.usesLiquidGlass ? .glass : .blur,
            opacity: appearance.backgroundOpacity,
            reduceTransparency: reduceTransparency,
            isFullScreen: NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
        ).treatment == .glass
    }
}

private struct WindowBackdropViewRepresentable: NSViewRepresentable {
    var kind: WindowBackdropKind
    var opacity: Double
    var reduceTransparency: Bool

    func makeNSView(context: Context) -> WindowBackdropView {
        WindowBackdropView()
    }

    func updateNSView(_ nsView: WindowBackdropView, context: Context) {
        nsView.apply(kind: kind, opacity: opacity, reduceTransparency: reduceTransparency)
    }
}

@MainActor
final class WindowBackdropView: NSView {
    private var kind: WindowBackdropKind = .blur
    private var opacity: Double = 1
    private var reduceTransparency = false
    private var effectView: NSVisualEffectView?
    private var baselineOpaque: Bool?
    private var baselineColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(kind: WindowBackdropKind, opacity: Double, reduceTransparency: Bool) {
        self.kind = kind
        self.opacity = opacity
        self.reduceTransparency = reduceTransparency
        sync()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        sync()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { restore() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sync()
    }

    private func observeWindow() {
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeMainNotification,
        ] {
            center.removeObserver(self, name: name, object: window)
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
        }
    }

    @objc private func windowChanged() { sync() }

    private func plan() -> WindowBackdropPlan {
        WindowBackdropPlan(
            kind: kind,
            opacity: opacity,
            reduceTransparency: reduceTransparency,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false
        )
    }

    private func sync() {
        let plan = plan()
        guard let window else { return }
        if baselineOpaque == nil {
            baselineOpaque = window.isOpaque
            baselineColor = window.backgroundColor
        }
        let isOpaque = plan.treatment == .opaque
        if window.isOpaque != isOpaque {
            window.isOpaque = isOpaque
        }
        let background: NSColor = isOpaque
            ? .windowBackgroundColor
            : NSColor.white.withAlphaComponent(0.001)
        if window.backgroundColor != background {
            window.backgroundColor = background
        }

        let fillAlpha = plan.fillOpacity
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fillAlpha > 0
                ? NSColor.windowBackgroundColor.withAlphaComponent(fillAlpha).cgColor
                : nil
        }

        let wantsBlur = plan.treatment == .blur
        if wantsBlur {
            let effect = effectView ?? {
                let view = NSVisualEffectView(frame: bounds)
                view.material = .underWindowBackground
                view.blendingMode = .behindWindow
                view.state = .active
                view.autoresizingMask = [.width, .height]
                addSubview(view, positioned: .below, relativeTo: nil)
                effectView = view
                return view
            }()
            effect.frame = bounds
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.isHidden = false
        } else {
            effectView?.isHidden = true
        }
    }

    private func restore() {
        guard let window else { return }
        NotificationCenter.default.removeObserver(self, name: nil, object: window)
        if let baselineOpaque { window.isOpaque = baselineOpaque }
        if let baselineColor { window.backgroundColor = baselineColor }
        baselineOpaque = nil
        baselineColor = nil
    }
}
