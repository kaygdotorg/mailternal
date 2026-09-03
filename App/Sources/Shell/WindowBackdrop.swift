import AppKit
import SwiftUI

enum WindowBackdropTreatment: Equatable {
    case opaque
    case blur
    case glass
}

/// The one resolved answer for the window's background. Opaque, blur, and
/// glass are mutually exclusive treatments; the opacity dial only controls
/// the tint carried by the selected translucent treatment.
struct WindowBackdropPlan: Equatable {
    let opacity: Double
    let style: WindowBackdropStyle
    let treatment: WindowBackdropTreatment
    let isFullScreen: Bool

    /// Alpha for the AppKit tint layer. Glass carries its tint in SwiftUI
    /// instead, so it must never be stacked under the glass material.
    var fillOpacity: Double {
        switch treatment {
        case .opaque: 1
        case .glass: 0
        case .blur: opacity
        }
    }

    /// Alpha for the tint colour that is passed into `.glassEffect`.
    var glassTintOpacity: Double {
        treatment == .glass ? opacity : 0
    }

    init(
        style: WindowBackdropStyle,
        opacity: Double,
        reduceTransparency: Bool,
        isFullScreen: Bool
    ) {
        self.style = style
        self.isFullScreen = isFullScreen
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
        treatment = style == .frostedBlur ? .blur : .glass
    }
}
struct WindowBackdropRoot: View {
    let appearance: AppearanceSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isFullScreen = false

    private var style: WindowBackdropStyle {
        appearance.backdropStyle
    }

    private var resolvedPlan: WindowBackdropPlan {
        WindowBackdropPlan(
            style: style,
            opacity: appearance.backgroundOpacity,
            reduceTransparency: reduceTransparency,
            isFullScreen: isFullScreen
        )
    }

    var body: some View {
        let plan = resolvedPlan
        WindowBackdropViewRepresentable(
            plan: plan,
            style: style,
            opacity: appearance.backgroundOpacity,
            reduceTransparency: reduceTransparency,
            onFullScreenChanged: { isFullScreen = $0 }
        )
        .overlay {
            if plan.treatment == .glass {
                let shape = RoundedRectangle(
                    cornerRadius: 0,
                    style: .continuous
                )
                Color(nsColor: .windowBackgroundColor)
                    .opacity(plan.glassTintOpacity)
                    .clipShape(shape)
                    .glassEffect(
                        style == .clearGlass ? .clear : .regular,
                        in: shape
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct WindowBackdropViewRepresentable: NSViewRepresentable {
    let plan: WindowBackdropPlan
    let style: WindowBackdropStyle
    let opacity: Double
    let reduceTransparency: Bool
    let onFullScreenChanged: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> WindowBackdropView {
        let view = WindowBackdropView()
        view.apply(
            plan: plan,
            style: style,
            opacity: opacity,
            reduceTransparency: reduceTransparency,
            onFullScreenChanged: onFullScreenChanged
        )
        return view
    }

    func updateNSView(_ nsView: WindowBackdropView, context: Context) {
        nsView.apply(
            plan: plan,
            style: style,
            opacity: opacity,
            reduceTransparency: reduceTransparency,
            onFullScreenChanged: onFullScreenChanged
        )
    }
}

@MainActor
final class WindowBackdropView: NSView {
    private var style: WindowBackdropStyle = .frostedBlur
    private var opacity: Double = 1
    private var reduceTransparency = false
    private var requestedPlan = WindowBackdropPlan(
        style: .frostedBlur,
        opacity: 1,
        reduceTransparency: false,
        isFullScreen: false
    )
    private var onFullScreenChanged: (@MainActor (Bool) -> Void)?
    private var lastReportedFullScreen: Bool?
    private var effectView: NSVisualEffectView?
    private var tintView: NSView?
    private var baselineOpaque: Bool?
    private var baselineColor: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = false
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(
        plan: WindowBackdropPlan,
        style: WindowBackdropStyle,
        opacity: Double,
        reduceTransparency: Bool,
        onFullScreenChanged: @escaping @MainActor (Bool) -> Void
    ) {
        requestedPlan = plan
        self.style = style
        self.opacity = opacity
        self.reduceTransparency = reduceTransparency
        self.onFullScreenChanged = onFullScreenChanged
        sync()
    }

    /// Convenience entry point for AppKit callers and deterministic tests.
    func apply(style: WindowBackdropStyle, opacity: Double, reduceTransparency: Bool) {
        let plan = WindowBackdropPlan(
            style: style,
            opacity: opacity,
            reduceTransparency: reduceTransparency,
            isFullScreen: window?.styleMask.contains(.fullScreen) ?? false
        )
        apply(
            plan: plan,
            style: style,
            opacity: opacity,
            reduceTransparency: reduceTransparency,
            onFullScreenChanged: { _ in }
        )
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        guard let window else { return requestedPlan }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        reportFullScreenChange(isFullScreen)
        guard isFullScreen != requestedPlan.isFullScreen else {
            return requestedPlan
        }
        return WindowBackdropPlan(
            style: style,
            opacity: opacity,
            reduceTransparency: reduceTransparency,
            isFullScreen: isFullScreen
        )
    }

    private func reportFullScreenChange(_ isFullScreen: Bool) {
        guard lastReportedFullScreen != isFullScreen else { return }
        lastReportedFullScreen = isFullScreen
        guard isFullScreen != requestedPlan.isFullScreen,
              let onFullScreenChanged
        else { return }
        Task { @MainActor in
            onFullScreenChanged(isFullScreen)
        }
    }

    private func sync() {
        let plan = plan()
        if let window {
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
            let tint = tintView ?? {
                let view = NSView(frame: bounds)
                view.wantsLayer = true
                view.layer?.isOpaque = false
                view.autoresizingMask = [.width, .height]
                effect.addSubview(view, positioned: .above, relativeTo: nil)
                tintView = view
                return view
            }()
            tint.frame = bounds
            tint.isHidden = plan.fillOpacity <= 0
        } else {
            effectView?.isHidden = true
            tintView?.isHidden = true
        }
        syncFill(plan)
    }

    private func syncFill(_ plan: WindowBackdropPlan) {
        let fillAlpha = plan.fillOpacity
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = fillAlpha > 0
                ? NSColor.windowBackgroundColor.withAlphaComponent(fillAlpha).cgColor
                : nil
            layer?.backgroundColor = fill
            tintView?.layer?.backgroundColor = fill
        }
    }

    private func restore() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            if let baselineOpaque { window.isOpaque = baselineOpaque }
            if let baselineColor { window.backgroundColor = baselineColor }
        }
        baselineOpaque = nil
        baselineColor = nil
        lastReportedFullScreen = nil
    }
}
