import AppKit
import SwiftUI

/// One sender-and-subject tab in the reader strip. The model owns activation
/// and close semantics; this view only supplies the native controls and gestures.
struct ReaderTabItem: View {
    @Bindable var model: AppModel
    let tab: ReaderTab
    let subject: String
    let sender: String?
    let width: CGFloat

    let onHoverChanged: (Bool) -> Void
    /// Optional owner hook lets the strip restore focus after closing its
    /// active tab while keeping the model as the source of truth.
    var onClose: ((UUID) -> Void)? = nil


    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovered = false

    private var isActive: Bool { model.tabs.activeID == tab.id }
    private var isTransient: Bool {
        model.tabs.tabs.first(where: { $0.id == tab.id })?.isTransient ?? tab.isTransient
    }
    private var displaySubject: String {
        subject.isEmpty ? "No Subject" : subject
    }

    private var senderInitial: String {
        SenderGlyph.initials(for: sender ?? "?")
    }
    private var style: ReaderTabStyle { model.appearance.tabStyle }

    private var senderDomain: String? {
        SenderDomainPolicy.domain(from: sender)
    }

    @ViewBuilder
    private var senderGlyph: some View {
        SenderGlyph(
            favicon: senderDomain.flatMap { model.favicon(forSenderDomain: $0) },
            initials: senderInitial,
            accent: .secondary,
            diameter: 22
        )
    }

    @ViewBuilder
    private var leadingSlot: some View {
        if ReaderTabStylePolicy.showsLeadingSlot(for: style, isHovered: isHovered) {
            ZStack(alignment: .leading) {
                if !isHovered {
                    senderGlyph
                        .accessibilityHidden(true)
                }
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
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(width: 25, height: 28, alignment: .leading)
        }
    }

    private var titleLabel: some View {
        Text(displaySubject)
            .font(.subheadline)
            .italic(isTransient)
            .foregroundStyle(isActive ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, ReaderTabLayoutPolicy.subjectLeadingPadding)
            .padding(.trailing, ReaderTabLayoutPolicy.subjectTrailingPadding)
            .padding(.vertical, 7)
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
            leadingSlot

            if ReaderTabStylePolicy.showsSubject(for: style) {
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
        }
        .frame(width: width, height: 32)
        .modifier(
            ReaderTabGlassModifier(
                isActive: isActive,
                isHovered: isHovered,
                contrast: contrast
            )
        )
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
            Picker("Tab Style", selection: Bindable(model.appearance).tabStyle) {
                ForEach(ReaderTabStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style)
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

/// Active tab: tertiary fill (one step stronger than the hover wash) so the
/// selected tab reads clearly against the clear strip; hover keeps quaternary.
private struct ReaderTabGlassModifier: ViewModifier {
    let isActive: Bool
    let isHovered: Bool
    let contrast: ColorSchemeContrast

    func body(content: Content) -> some View {
        content.background {
            Capsule().fill(fill)
        }
    }

    private var fill: Color {
        if isActive {
            return Color(nsColor: .tertiarySystemFill).opacity(contrast == .increased ? 1 : 0.9)
        }
        if isHovered {
            return Color(nsColor: .quaternarySystemFill).opacity(contrast == .increased ? 0.9 : 0.72)
        }
        return .clear
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
