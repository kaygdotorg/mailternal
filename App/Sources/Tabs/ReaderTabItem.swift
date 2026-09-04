import AppKit
import SwiftUI

/// One subject-only tab in the reader strip. The model owns activation and
/// close semantics; this view only supplies the native controls and gestures.
struct ReaderTabItem: View {
    @Bindable var model: AppModel
    let tab: ReaderTab
    let subject: String
    let width: CGFloat
    let glassNamespace: Namespace.ID

    let onHoverChanged: (Bool) -> Void
    /// Optional owner hook lets the strip restore focus after closing its
    /// active tab while keeping the model as the source of truth.
    var onClose: ((UUID) -> Void)? = nil


    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isHovered = false

    private var isActive: Bool { model.tabs.activeID == tab.id }
    private var isTransient: Bool {
        model.tabs.tabs.first(where: { $0.id == tab.id })?.isTransient ?? tab.isTransient
    }
    private var displaySubject: String {
        subject.isEmpty ? "No Subject" : subject
    }

    private var titleLabel: some View {
        ZStack(alignment: .leading) {
            Text(displaySubject)
                .font(.subheadline)
                .italic(isTransient)
                .foregroundStyle(isActive ? .primary : .secondary)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .clipped()
        .contentShape(Rectangle())
    }


    private func closeTab() {
        if let onClose {
            onClose(tab.id)
        } else {
            model.tabs.close(tab.id)
        }
    }


    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                if isHovered {
                    Button {
                        closeTab()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled(true)
                    .accessibilityLabel("Close \(displaySubject)")
                    .accessibilityIdentifier(UIIdentifier.readerTabClose(tab.id))
                    .padding(.leading, 3)
                    .transition(.opacity)
                }
            }
            .frame(width: 25, height: 28, alignment: .leading)
            .animation(MailMotion.hover, value: isHovered)

            Button {
                model.activateTab(tab.id)
            } label: {
                titleLabel
            }
            .buttonStyle(.plain)
            .focusEffectDisabled(true)
            .highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded {
                        if isTransient { model.tabs.keep(tab.id) }
                        model.activateTab(tab.id)
                    }
            )
        }
        .frame(width: width, height: 32)
        .modifier(
            ReaderTabGlassModifier(
                isVisible: isActive || isHovered,
                reduceTransparency: reduceTransparency,
                contrast: contrast
            )
        )
        .glassEffectID(tab.id, in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .contentShape(RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous))
        .frame(width: width, height: ReaderTabLayoutPolicy.rowHeight)
        .focusEffectDisabled(true)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
                onHoverChanged(true)
            case .ended:
                isHovered = false
                onHoverChanged(false)
            }
        }
        .contextMenu {
            Button("Close", systemImage: "xmark") {
                closeTab()

            }
            Button("Close Others", systemImage: "rectangle.on.rectangle") {
                let wasActive = model.tabs.activeID == tab.id
                model.tabs.closeOthers(tab.id)
                if !wasActive {
                    model.activateTab(tab.id)
                }
            }
            Button("Close to the Right", systemImage: "rectangle.rightthird.inset.filled") {
                let previousActiveID = model.tabs.activeID
                model.tabs.closeToRight(tab.id)
                if model.tabs.activeID != previousActiveID,
                   let activeID = model.tabs.activeID {
                    model.activateTab(activeID)
                }
            }
            if isTransient {
                Button("Keep", systemImage: "pin") {
                    model.tabs.keep(tab.id)
                }
            }
            Divider()
            Button("Open in New Window", systemImage: "arrow.up.right.square") {
                model.openMessageWindow(tab.message)
            }
            Button("Copy Link", systemImage: "link") {
                Task { await model.copyDeepLink(for: tab.message) }
            }
        }
        .background {
            ReaderTabMiddleClickMonitor {
                closeTab()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(displaySubject)
        .accessibilityValue(isActive ? "Selected" : (isTransient ? "Temporary" : ""))
        .accessibilityIdentifier(UIIdentifier.readerTab(tab.id))
    }
}

private struct ReaderTabGlassModifier: ViewModifier {
    let isVisible: Bool
    let reduceTransparency: Bool
    let contrast: ColorSchemeContrast

    private static var debugGlassEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MAILTERNAL_DEBUG_GLASS_EFFECT"] == "1"
        #else
        false
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if !reduceTransparency && isVisible && Self.debugGlassEnabled {
            // Liquid Glass currently renders as a dark/opaque surface when
            // hosted inside an NSToolbar on macOS 26. Keep it opt-in for
            // visual debugging until the system compositor handles that host.
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background {
                Capsule()
                    .fill(
                        isVisible
                            ? Color(nsColor: .quaternarySystemFill).opacity(
                                contrast == .increased ? 0.9 : 0.72
                            )
                            : .clear
                    )
            }
        }
    }
}


/// AppKit receives middle-button events before SwiftUI's button gesture system.
/// A local monitor lets the tab keep normal left-click/context-menu behavior
/// while consuming only a middle click inside this tab's bounds.
@MainActor
private struct ReaderTabMiddleClickMonitor: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ReaderTabMiddleClickView {
        let view = ReaderTabMiddleClickView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ReaderTabMiddleClickView, context: Context) {
        nsView.action = action
    }
}

@MainActor
private final class ReaderTabMiddleClickView: NSView {
    var action: (() -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self, event.buttonNumber == 2, let window = self.window,
                  event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            self.action?()
            return nil
        }
    }


    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
