import ObjectiveC
import AppKit
import SwiftUI
import MailternalInterfaces
import os

private let sidebarLog = Logger(subsystem: "org.kayg.mailternal", category: "Sidebar")

/// `log show` is unusable over SSH on the QA host, so sidebar diagnostics are
/// also appended to `~/Library/Logs/Mailternal/sidebar.log` in Debug builds.
private func sidebarTrace(_ message: String) {
    sidebarLog.log("\(message, privacy: .public)")
    #if DEBUG
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Mailternal", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appending(path: "sidebar.log")
    let line = "\(Date().ISO8601Format()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
    #endif
}


struct FolderSidebar: View {
    @Bindable var model: AppModel
    @State private var inspectorFolder: FolderSummary?
    /// Account-rename edit state lives here, not in the header view: SwiftUI
    /// renders a sidebar section header twice (floating + in-row copy), and a
    /// double-click lands on whichever copy is hit-tested, so header-local
    /// @State toggled the invisible copy.
    @State private var accountRename = SidebarAccountRenameState()

    var body: some View {
        let accountOrder = model.accountConfigs.map(\.id)
        let disabledAccountIDs = Set(
            model.accountConfigs.lazy.filter { !$0.isEnabled }.map(\.id)
        )
        let accountGroups = FolderHierarchy.groupedByAccount(
            model.folders,
            accountOrder: accountOrder,
            disabledAccountIDs: disabledAccountIDs
        )

        List(selection: Binding(
            get: { model.selectedFolderID },
            set: { model.selectFolder($0, userInitiated: true) }
        )) {
            ForEach(accountGroups, id: \.account) { group in
                let roots = FolderHierarchy.make(from: group.folders)
                let specialRoots = roots.filter { $0.folder.role != .none }
                let customRoots = roots.filter { $0.folder.role == .none }
                let account = model.accountConfigs.first { $0.id == group.account }
                Section {
                    ForEach(specialRoots + customRoots) { node in
                        folderNode(node)
                    }
                } header: {
                    sectionHeader(account: account)
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                model.noteListInteraction()
            }
        )
        // SwiftUI can retain only the duplicated floating section header when
        // its title changes, dropping the section rows until relaunch. Rebuild
        // that native List identity without animation when account titles
        // change; selection remains model-owned.
        .id(model.accountConfigs)
        .transaction { transaction in
            transaction.animation = nil
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
    private func sectionHeader(account: AccountConfig?) -> some View {
        if model.hasAccount {
            SidebarAccountTitle(
                title: AccountTitlePolicy.title(for: account) ?? account?.emailAddress ?? model.listTitleAccountName,
                accountID: account?.id,
                rename: $accountRename,
                onRename: account.map { account in
                    { name in Task { await model.renameAccount(account.id, to: name) } }
                }
            )
            .padding(.top, PaneHeaderInsetPolicy.sidebarHeaderPadding)
            .padding(.bottom, PaneHeaderInsetPolicy.sidebarHeaderBottomPadding)
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
            onKeepLocally: { folder, keep in
                Task { @MainActor in
                    do {
                        try await model.facade.setKeepLocally(keep, for: folder.id)
                    } catch {
                        model.toasts.post(
                            title: "Couldn’t update cache setting",
                            detail: error.localizedDescription,
                            severity: .error
                        )
                    }
                }
            },
            onRenameFolder: { folder, name in
                await model.renameFolder(folder.id, to: name)
            },
            onDrop: { folderID, links in
                guard folderID != model.selectedFolderID, !links.isEmpty else { return false }
                Task { @MainActor in
                    await model.moveDroppedLinks(links, to: folderID)
                }
                return true
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
    let onKeepLocally: (FolderSummary, Bool) -> Void
    let onRenameFolder: (FolderSummary, String) async -> Bool
    let onDrop: (FolderID, [String]) -> Bool
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
                        onKeepLocally: onKeepLocally,
                        onRenameFolder: onRenameFolder,
                        onDrop: onDrop
                    )
                }
            } label: {
                decoratedRow
            }
        }
    }
    private var decoratedRow: some View {
        FolderRow(
            folder: node.folder,
            selected: node.folder.id == selectedID,
            onRename: { name in
                await onRenameFolder(node.folder, name)
            }
        )
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
                Toggle(
                    "Keep locally",
                    isOn: Binding(
                        get: { node.folder.keepLocally },
                        set: { onKeepLocally(node.folder, $0) }
                    )
                )
                .toggleStyle(.checkbox)
            }
            .dropDestination(for: MessageLinkPayload.self) { payloads, _ in
                guard node.folder.id != selectedID else { return false }
                return onDrop(node.folder.id, payloads.flatMap(\.links))
            } isTargeted: { targeted in
                isDropTargeted = node.folder.id != selectedID && targeted
            }
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
    let onRename: ((String) async -> Bool)?
    @Environment(AccentSource.self) private var accent
    @State private var isEditing = false

    init(
        folder: FolderSummary,
        selected: Bool,
        onRename: ((String) async -> Bool)? = nil
    ) {
        self.folder = folder
        self.selected = selected
        self.onRename = onRename
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: folder.role.systemImage)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            SidebarInline(
                value: folder.name,
                canEdit: FolderRenamePolicy.canRename(role: folder.role),
                fieldIdentifier: FolderRenamePolicy.fieldIdentifier(for: folder.id),
                onCommit: onRename,
                isEditing: $isEditing
            )
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
        // Keep the row addressable while exposing the editing field as its own
        // AX element; combining children would hide the stable field ID.
        .accessibilityElement(children: isEditing ? .contain : .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(selected ? "Selected" : "")
        // Every folder row is addressed by path in the UI tests, so the
        // identifier belongs on the row itself, hierarchy or not.
        .accessibilityIdentifier(UIIdentifier.sidebarFolder(folder.path))
    }

    @ViewBuilder
    private var backfillAccessory: some View {
        switch folder.activity {
        case .downloading, .indexing, .moving:
            ProgressView()
                .controlSize(.small)
                .tint(accent.color.opacity(0.8))
                .help(FolderActivityPolicy.tooltip(for: folder) ?? "Syncing")
                .accessibilityLabel(
                    FolderActivityPolicy.accessibilityLabel(for: folder.activity) ?? "Syncing"
                )
        case .halted:
            if let symbol = FolderActivityPolicy.symbolName(for: .halted) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .help("Sync halted")
                    .accessibilityLabel(FolderActivityPolicy.accessibilityLabel(for: .halted) ?? "Sync halted")
            }
        case .idle, .quarantinedStall:
            EmptyView()
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

/// Finder-like inline editing for the name portion of a sidebar row.
private struct SidebarInline: View {
    let value: String
    let canEdit: Bool
    let fieldIdentifier: String
    let onCommit: ((String) async -> Bool)?
    @Binding var isEditing: Bool
    @State private var draft = ""

    var body: some View {
        ZStack(alignment: .leading) {
            // Host the displayed label itself in AppKit. SwiftUI gesture
            // overlays sit outside the List row's hit-test path and are
            // therefore not reliable for double-clicks.
            SidebarRenameLabel(
                value: value,
                font: .preferredFont(forTextStyle: .body),
                identifier: nil,
                isDoubleClickEnabled: canEdit && !isEditing,
                onDoubleClick: beginEditing
            )
            .opacity(isEditing ? 0 : 1)
            .allowsHitTesting(!isEditing)
            .accessibilityHidden(isEditing)

            if isEditing {
                SidebarInlineTextField(
                    text: $draft,
                    identifier: fieldIdentifier,
                    font: .preferredFont(forTextStyle: .body),
                    commitOnFocusLoss: true,
                    onCommit: commit,
                    onCancel: cancel
                )
                .frame(minWidth: 40)
            }
        }
        .accessibilityRenameAction(
            isEnabled: canEdit && onCommit != nil,
            action: beginEditing
        )
    }

    private func beginEditing() {
        guard !isEditing, canEdit, onCommit != nil else { return }
        draft = value
        sidebarTrace("Sidebar folder rename edit began")

        isEditing = true
    }

    private func commit() {
        guard isEditing else { return }
        let candidate = draft
        isEditing = false
        guard let onCommit else { return }
        Task {
            _ = await onCommit(candidate)
        }
    }

    private func cancel() {
        isEditing = false
        draft = ""
    }
}
private struct SidebarAccessibilityRenameAction: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.accessibilityAction(named: Text("Rename")) {
                action()
            }
        } else {
            content
        }
    }
}

private extension View {
    func accessibilityRenameAction(
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        modifier(SidebarAccessibilityRenameAction(isEnabled: isEnabled, action: action))
    }
}

private struct SidebarInlineTextField: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    let font: NSFont
    let commitOnFocusLoss: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> InlineTextFieldView {
        let field = InlineTextFieldView()
        field.isEditable = true
        field.isSelectable = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.font = font
        field.setAccessibilityIdentifier(identifier)
        field.onAppear = { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
        return field
    }

    func updateNSView(_ nsView: InlineTextFieldView, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = font
        nsView.setAccessibilityIdentifier(identifier)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SidebarInlineTextField
        private var finished = false

        init(_ parent: SidebarInlineTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard !finished, let field = obj.object as? InlineTextFieldView else { return }
            // A sidebar section header exists twice (floating + in-row copy),
            // so its field can lose focus to its own twin. Decide after the new
            // first responder is installed: a twin keeps the edit alive.
            let identifier = parent.identifier
            let commitOnFocusLoss = parent.commitOnFocusLoss
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, !self.finished else { return }
                if let responder = field?.window?.firstResponder,
                   InlineTextFieldView.isTwin(of: identifier, responder: responder) {
                    return
                }
                self.finish(commit: commitOnFocusLoss)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                finish(commit: true)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                finish(commit: false)
                return true
            }
            return false
        }

        private func finish(commit: Bool) {
            guard !finished else { return }
            finished = true
            if commit {
                parent.onCommit()
            } else {
                parent.onCancel()
            }
        }
    }
}

private final class InlineTextFieldView: NSTextField {
    var onAppear: (() -> Void)?

    /// True when `responder` is (the field editor of) another inline field
    /// carrying the same identifier, i.e. the twin copy of a section header.
    static func isTwin(of identifier: String, responder: NSResponder) -> Bool {
        let field: NSTextField?
        if let editor = responder as? NSTextView {
            field = editor.delegate as? NSTextField
        } else {
            field = responder as? NSTextField
        }
        guard let twin = field as? InlineTextFieldView else { return false }
        return twin.accessibilityIdentifier() == identifier
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byClipping
        textColor = .labelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width = max(size.width, 40)
        return size
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onAppear?()
        onAppear = nil
    }


    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { clearFieldEditorBackground() }
        return became
    }

    /// Keep the defensive clear for AppKit versions that re-apply cell
    /// attributes after the field editor becomes first responder.
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        clearFieldEditorBackground()
    }

    private func clearFieldEditorBackground() {
        guard let editor = currentEditor() as? NSTextView else { return }
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.insertionPointColor = .labelColor
        editor.enclosingScrollView?.drawsBackground = false
        DispatchQueue.main.async { [weak editor] in
            editor?.drawsBackground = false
            editor?.backgroundColor = .clear
        }
    }
}

/// NSTextField-based label that remains in the List row's hit-test path.
/// AppKit delivers the click to this view rather than to a SwiftUI overlay,
/// while ordinary clicks continue up the responder chain for row selection.
private struct SidebarRenameLabel: NSViewRepresentable {
    let value: String
    let font: NSFont
    let identifier: String?
    var isDoubleClickEnabled = true
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> SidebarRenameLabelView {
        let view = SidebarRenameLabelView()
        view.stringValue = value
        view.font = font
        view.isDoubleClickEnabled = isDoubleClickEnabled

        view.onDoubleClick = onDoubleClick
        if let identifier {
            view.setAccessibilityIdentifier(identifier)
        }
        return view
    }

    func updateNSView(_ nsView: SidebarRenameLabelView, context: Context) {
        nsView.stringValue = value
        nsView.font = font
        nsView.isDoubleClickEnabled = isDoubleClickEnabled

        nsView.onDoubleClick = onDoubleClick
        if let identifier {
            nsView.setAccessibilityIdentifier(identifier)
        }
    }
}

private final class SidebarRenameLabelView: NSTextField {
    var isDoubleClickEnabled = true

    var onDoubleClick: (() -> Void)?
    private var doubleClickMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        alignment = .left
        lineBreakMode = .byTruncatingMiddle
        cell?.usesSingleLineMode = true
        cell?.lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textColor = .labelColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        removeDoubleClickMonitor()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeDoubleClickMonitor()
        installDoubleClickRouter()
        guard window != nil else { return }

        // A Section header is not necessarily represented by an NSTableRowView.
        doubleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  event.clickCount == 2, self.isDoubleClickEnabled else {
                return event
            }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point) else { return event }
            sidebarTrace("Sidebar rename double-click detected")
            self.onDoubleClick?()
            return nil
        }

        Task { @MainActor [weak self] in
            self?.installDoubleClickRouter()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installDoubleClickRouter()
    }

    override func layout() {
        super.layout()
        installDoubleClickRouter()
    }

    private func removeDoubleClickMonitor() {
        if let doubleClickMonitor {
            NSEvent.removeMonitor(doubleClickMonitor)
            self.doubleClickMonitor = nil
        }
    }

    private func installDoubleClickRouter() {
        guard let tableView = enclosingTableView else {
            return
        }
        SidebarDoubleClickRouter.install(on: tableView)
    }


    private var enclosingTableView: NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? NSTableView {
                return tableView
            }
            ancestor = view.superview
        }
        return nil
    }
}

@MainActor
private var sidebarDoubleClickRouterKey: UInt8 = 0
@MainActor
private final class SidebarDoubleClickRouter: NSObject {
    weak var tableView: NSTableView?

    static func install(on tableView: NSTableView) {
        if let router = objc_getAssociatedObject(tableView, &sidebarDoubleClickRouterKey)
            as? SidebarDoubleClickRouter {
            router.tableView = tableView
            return
        }
        let router = SidebarDoubleClickRouter()
        router.tableView = tableView
        objc_setAssociatedObject(
            tableView,
            &sidebarDoubleClickRouterKey,
            router,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        tableView.target = router
        tableView.doubleAction = #selector(tableDoubleClicked(_:))
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        guard let tableView else { return }

        let point = tableView.window.map {
            tableView.convert($0.mouseLocationOutsideOfEventStream, from: nil)
        }
        let row = tableView.clickedRow >= 0
            ? tableView.clickedRow
            : point.map { tableView.row(at: $0) } ?? -1

        if row >= 0,
           let rowView = tableView.rowView(atRow: row, makeIfNecessary: false),
           let label = findLabel(in: rowView) {
            guard label.isDoubleClickEnabled else { return }
            sidebarTrace("Sidebar rename double-click detected in table row")
            label.onDoubleClick?()
            return
        }

        // Section headers/group rows can sit outside NSTableView's row-view
        // hierarchy. Walk the actual hit-test path as a second route.
        if let point,
           let label = findLabel(at: point, in: tableView) {
            guard label.isDoubleClickEnabled else { return }
            sidebarTrace("Sidebar rename double-click detected in table header")
            label.onDoubleClick?()
        }
    }

    private func findLabel(at point: NSPoint, in tableView: NSTableView) -> SidebarRenameLabelView? {
        guard let hitView = tableView.hitTest(point) else { return nil }
        var view: NSView? = hitView
        while let current = view {
            if let label = current as? SidebarRenameLabelView {
                return label
            }
            view = current.superview
        }
        return nil
    }

    private func findLabel(in view: NSView) -> SidebarRenameLabelView? {
        if let label = view as? SidebarRenameLabelView {
            return label
        }
        for child in view.subviews {
            if let label = findLabel(in: child) {
                return label
            }
        }
        return nil
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

/// The sidebar's account H1. Double-click swaps the text for a same-font
/// field; Return commits through `AppModel.renameAccount`, Escape or focus
/// loss cancels. Rendering stays a native label until editing starts so the
/// list header keeps its measured geometry.
struct SidebarAccountRenameState: Equatable {
    var accountID: AccountID?
    var draft = ""
    var isEditing: Bool { accountID != nil }
}

private struct SidebarAccountTitle: View {
    let title: String
    let accountID: AccountID?
    @Binding var rename: SidebarAccountRenameState
    let onRename: ((String) -> Void)?

    private var isEditing: Bool {
        rename.isEditing && rename.accountID == accountID
    }

    var body: some View {
        ZStack(alignment: .leading) {
            SidebarRenameLabel(
                value: title,
                font: .systemFont(ofSize: 26, weight: .bold),
                identifier: UIIdentifier.sidebarAccountTitle,
                isDoubleClickEnabled: !isEditing,
                onDoubleClick: beginEditing
            )
            .opacity(isEditing ? 0 : 1)
            .allowsHitTesting(!isEditing)
            .accessibilityHidden(isEditing)
            .accessibilityAddTraits(.isHeader)

            if isEditing {
                SidebarInlineTextField(
                    text: $rename.draft,
                    identifier: UIIdentifier.sidebarAccountTitleField,
                    font: .systemFont(ofSize: 26, weight: .bold),
                    commitOnFocusLoss: false,
                    onCommit: commit,
                    onCancel: cancel
                )
                .frame(minWidth: 40)
            }
        }
        .accessibilityRenameAction(
            isEnabled: accountID != nil && onRename != nil,
            action: beginEditing
        )
    }
    private func beginEditing() {
        guard !isEditing, onRename != nil, let accountID else { return }
        sidebarTrace("Sidebar account rename edit began")
        rename = SidebarAccountRenameState(accountID: accountID, draft: title)
    }

    private func commit() {
        guard isEditing else { return }
        let candidate = rename.draft
        rename = SidebarAccountRenameState()
        onRename?(candidate)
    }

    private func cancel() {
        rename = SidebarAccountRenameState()
    }
}
