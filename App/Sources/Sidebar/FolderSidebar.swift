import AppKit
import SwiftUI
import MailternalInterfaces
import UniformTypeIdentifiers


struct FolderSidebar: View {
    @Bindable var model: AppModel
    @State private var inspectorFolder: FolderSummary?

    var body: some View {
        let roots = FolderHierarchy.make(from: model.folders)
        let specialRoots = roots.filter { $0.folder.role != .none }
        let customRoots = roots.filter { $0.folder.role == .none }

        List(selection: Binding(
            get: { model.selectedFolderID },
            set: { model.selectFolder($0) }
        )) {
            if !specialRoots.isEmpty {
                Section {
                    ForEach(specialRoots) { node in
                        folderNode(node)
                    }
                } header: {
                    sectionHeader(nil, includeAccountTitle: true)
                }
            }
            if !customRoots.isEmpty {
                Section {
                    ForEach(customRoots) { node in
                        folderNode(node)
                    }
                } header: {
                    sectionHeader("Folders", includeAccountTitle: specialRoots.isEmpty)
                }
            }
        }
        .listStyle(.sidebar)
        // The List keeps its own safe-area layout; the header carries the
        // remaining inset (PaneHeaderInsetPolicy.sidebarHeaderPadding). Never
        // inset the scroll view: SwiftUI rewrites a `.sidebar` List's content
        // insets from the safe area on every layout and any inset placed there
        // flips in and out (measured: the title jumping by 40pt).
        .background {
            ScrollEdgeEffectSuppressor()
                .allowsHitTesting(false)
        }
        .background {
            // Public-API fallback for macOS 26's sidebar material. The
            // concentric glass view hosts the sidebar content, so hiding it
            // hides the whole column; only the BlurryAlleyway layer is hidden.
            // These class-name checks are intentionally guarded: if SwiftUI
            // renames its implementation, this bridge simply does nothing.
            SidebarSystemMaterialSuppressor()
                .allowsHitTesting(false)
        }
        .mailWindowDissolve(.sidebar)
        .popover(item: $inspectorFolder, arrowEdge: .trailing) { folder in
            FolderInspector(folder: folder)
        }
        .accessibilityIdentifier(UIIdentifier.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 340)
        .overlay {
            if model.folders.isEmpty {
                EmptyMailboxState(
                    title: model.isAccountActive ? "No mailboxes" : "Add an account",
                    detail: model.isAccountActive
                        ? "Mailboxes appear after the first sync."
                        : "Set up an IMAP account to start reading mail."
                )
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String?, includeAccountTitle: Bool) -> some View {
        if includeAccountTitle, model.hasAccount {
            VStack(alignment: .leading, spacing: 4) {
                Text(AccountTitlePolicy.title(for: model.accountConfig) ?? model.listTitleAccountName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(UIIdentifier.sidebarAccountTitle)
                if let title {
                    Text(title)
                }
            }
            .padding(.top, PaneHeaderInsetPolicy.sidebarHeaderPadding)
            .padding(.bottom, PaneHeaderInsetPolicy.sidebarHeaderBottomPadding)
        } else if let title {
            Text(title)
        }
    }

    private func folderNode(_ node: FolderHierarchyNode) -> some View {
        FolderTreeNodeView(
            node: node,
            selectedID: model.selectedFolderID,
            inspectorFolder: $inspectorFolder,
            onRefresh: {
                Task { await model.refresh() }
            },
            onCopyDeepLink: model.isAccountActive
                ? { folder in
                    Task { await model.copyDeepLink(for: folder.id) }
                }
                : nil,
            onDrop: { folderID, providers in
                guard folderID != model.selectedFolderID else { return false }
                var accepted = false
                for provider in providers where provider.hasItemConformingToTypeIdentifier(MessageLinkPasteboard.type) {
                    accepted = true
                    provider.loadDataRepresentation(
                        forTypeIdentifier: MessageLinkPasteboard.type
                    ) { data, _ in
                        guard let data, let links = MessageLinkPasteboard.decode(data) else { return }
                        Task { @MainActor in
                            await model.moveDroppedLinks(links, to: folderID)
                        }
                    }
                }
                return accepted
            }
        )
    }

}

private struct SidebarSystemMaterialSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarSystemMaterialSuppressingView {
        SidebarSystemMaterialSuppressingView()
    }

    func updateNSView(
        _ nsView: SidebarSystemMaterialSuppressingView,
        context: Context
    ) {
        nsView.suppressSystemMaterial()
        nsView.scheduleSuppression()
    }
}

@MainActor
private final class SidebarSystemMaterialSuppressingView: NSView {
    private weak var observedWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: .zero)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindow()
        suppressSystemMaterial()
        scheduleSuppression()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            removeWindowObservers()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func scheduleSuppression() {
        DispatchQueue.main.async { [weak self] in
            self?.suppressSystemMaterial()
        }
    }

    func suppressSystemMaterial() {
        guard let wrapper = nearestSplitItemWrapper() else { return }
        hideSystemMaterial(in: wrapper)
    }

    private func observeWindow() {
        removeWindowObservers()
        guard let window else { return }
        observedWindow = window
        let center = NotificationCenter.default
        for name in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeMainNotification
        ] {
            center.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
        }
    }

    private func removeWindowObservers() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }

    @objc private func windowChanged() {
        suppressSystemMaterial()
        scheduleSuppression()
    }

    private func nearestSplitItemWrapper() -> NSView? {
        var ancestor = superview
        while let view = ancestor {
            let name = NSStringFromClass(type(of: view))
            if name.contains("SplitViewItemViewWrapper") {
                return view
            }
            ancestor = view.superview
        }
        return nil
    }

    private func hideSystemMaterial(in wrapper: NSView) {
        func visit(_ view: NSView) {
            for subview in view.subviews {
                // Only the pure material view. The concentric glass
                // container HOSTS the sidebar content (measured hierarchy:
                // NSContainerConcentricGlassEffectView > ContentHolderView >
                // NSHostingView), so hiding it removes the sidebar itself.
                let name = NSStringFromClass(type(of: subview))
                if name.contains("BlurryAlleyway") {
                    subview.isHidden = true
                    continue
                }
                visit(subview)
            }
        }
        visit(wrapper)
    }
}

private struct FolderTreeNodeView: View {
    let node: FolderHierarchyNode
    let selectedID: FolderID?
    @Binding var inspectorFolder: FolderSummary?
    let onRefresh: () -> Void
    let onCopyDeepLink: ((FolderSummary) -> Void)?
    let onDrop: (FolderID, [NSItemProvider]) -> Bool
    @State private var isExpanded = true
    @State private var isDropTargeted = false
    var body: some View {
        if node.children.isEmpty {
            decoratedRow
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(node.children) { child in
                    FolderTreeNodeView(
                        node: child,
                        selectedID: selectedID,
                        inspectorFolder: $inspectorFolder,
                        onRefresh: onRefresh,
                        onCopyDeepLink: onCopyDeepLink,
                        onDrop: onDrop
                    )
                }
            } label: {
                decoratedRow
            }
        }
    }

    private var decoratedRow: some View {
        FolderRow(folder: node.folder, selected: node.folder.id == selectedID)
            .tag(node.folder.id)
            .contextMenu {
                Button("Get Info…") {
                    inspectorFolder = node.folder
                }
                Button("Refresh", action: onRefresh)
                Button("Copy Folder Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.folder.name, forType: .string)
                }
                if let onCopyDeepLink {
                    Button("Copy Deep Link") {
                        onCopyDeepLink(node.folder)
                    }
                }
            }
            .onDrop(
                of: [UTType(exportedAs: MessageLinkPasteboard.type)],
                isTargeted: Binding(
                    get: { isDropTargeted },
                    set: { isDropTargeted = node.folder.id != selectedID && $0 }
                ),
                perform: { providers in
                    guard node.folder.id != selectedID else { return false }
                    return onDrop(node.folder.id, providers)
                }
            )
            .overlay {
                if isDropTargeted, node.folder.id != selectedID {
                    RoundedRectangle(cornerRadius: AppShapeScale.row, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(.horizontal, 2)
                }
            }
    }
}

struct FolderRow: View {
    let folder: FolderSummary
    let selected: Bool
    @Environment(AccentSource.self) private var accent
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.role.systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(folder.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            backfillAccessory
            if folder.unreadCount > 0 {
                Text(folder.unreadCount > 99 ? "99+" : "\(folder.unreadCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(badgeForeground)
                    .background(accent.color, in: Capsule())
                    .accessibilityLabel("\(folder.unreadCount) unread")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .focusEffectDisabled(true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "")
        // Every folder row is addressed by path in the UI tests, so the
        // identifier belongs on the row itself, hierarchy or not.
        .accessibilityIdentifier(UIIdentifier.sidebarFolder(folder.path))
    }

    @ViewBuilder
    private var backfillAccessory: some View {
        if case .syncing = folder.backfill {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Syncing")
        }
    }

    private var badgeForeground: Color {
        OutgoingForegroundPolicy.prefersBlackText(on: accent.nsColor) ? .black : .white
    }

    private var accessibilityLabel: String {
        var parts = [folder.name]
        if folder.unreadCount > 0 { parts.append("\(folder.unreadCount) unread") }
        switch folder.backfill {
        case .halted:
            parts.append("sync halted")
        case .syncing:
            parts.append("syncing")
        default:
            break
        }
        return parts.joined(separator: ", ")
    }
}

private struct FolderInspector: View {
    let folder: FolderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(folder.name)
                .font(.headline)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 7) {
                LabeledContent("Name", value: folder.name)
                LabeledContent("Path", value: folder.path)
                LabeledContent("Role", value: folder.role.rawValue.capitalized)
                LabeledContent("Messages", value: "\(folder.totalCount)")
                LabeledContent("Unread", value: "\(folder.unreadCount)")
                LabeledContent("Sync", value: syncDescription)
            }
        }
        .padding(16)
        .frame(minWidth: 260, alignment: .leading)
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(folder.name) folder information")
    }

    private var syncDescription: String {
        switch folder.backfill {
        case .idle:
            "Waiting to sync"
        case .complete:
            "Complete"
        case .syncing(let progress):
            progress.map { "Syncing \(Int(($0 * 100).rounded()))%" } ?? "Syncing…"
        case .halted(let date):
            "Halted; synced through \(MailDateFormat.syncedThrough(date))"
        }
    }
}

struct EmptyMailboxState: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
