import AppKit
import SwiftUI
import MailternalInterfaces

struct MainSplitRoot: View {
    @Bindable var model: AppModel
    let appearance: AppearanceSettings
    let actions: ActionSettings
    let onVisibilityBridge: @MainActor (MainSplitVisibilityBridgeView) -> Void
    var isActive: Bool = true

    init(
        model: AppModel,
        appearance: AppearanceSettings,
        actions: ActionSettings,
        onVisibilityBridge: @escaping @MainActor (MainSplitVisibilityBridgeView) -> Void = { _ in },
        isActive: Bool = true
    ) {
        self.model = model
        self.appearance = appearance
        self.actions = actions
        self.onVisibilityBridge = onVisibilityBridge
        self.isActive = isActive
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            FolderSidebar(model: model)
        } content: {
            MessageListPane(model: model)
        } detail: {
            MessageViewer(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .animation(MailMotion.sidebarToggle, value: model.columnVisibility)
        .background {
            MainSplitVisibilityBridge(
                action: { model.toggleSidebar() },
                onViewCreated: onVisibilityBridge
            )
                .frame(width: 0, height: 0)
        }
        .onChange(of: model.columnVisibility) { _, visibility in
            model.lastVisibleColumnVisibility = SidebarVisibilityPolicy.remembered(
                visibility,
                lastVisible: model.lastVisibleColumnVisibility
            )
        }
        .tint(appearance.accent.color)
        .environment(appearance.accent)
        .environment(actions)
        .preferredColorScheme(appearance.mode.colorScheme)
        .onExitCommand(perform: handleEscape)
        .task { model.start() }
        .disabled(!isActive)
    }

    private func handleEscape() {
        if model.isSearchPresented {
            model.isSearchPresented = false
            model.toasts.isSuppressed = false
        } else if model.isFindPresented {
            model.isFindPresented = false
        } else {
            model.toasts.dismissFront()
        }
    }
}
struct MainOverlayRoot: View {
    @Bindable var model: AppModel
    let appearance: AppearanceSettings
    let actions: ActionSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isSearchPresented {
                SearchPanel(model: model)
                    .transition(.opacity)
                    .zIndex(1)
            }
            ToastLayer()
                .environment(model.toasts)
                .zIndex(2)
        }
        .animation(MailMotion.searchPanel(reduceMotion: reduceMotion), value: model.isSearchPresented)
        .environment(appearance.accent)
        .environment(actions)
        .tint(appearance.accent.color)
    }
}

@MainActor
final class OverlayHostingView: NSHostingView<MainOverlayRoot> {
    required init(rootView: MainOverlayRoot) {
        super.init(rootView: rootView)
        safeAreaRegions = []
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return nil }
        return hit
    }
}

@MainActor
struct MainSplitVisibilityBridge: NSViewRepresentable {
    let action: @MainActor () -> Void
    let onViewCreated: @MainActor (MainSplitVisibilityBridgeView) -> Void

    func makeNSView(context: Context) -> MainSplitVisibilityBridgeView {
        let view = MainSplitVisibilityBridgeView(action: action)
        onViewCreated(view)
        return view
    }

    func updateNSView(_ nsView: MainSplitVisibilityBridgeView, context: Context) {
        nsView.action = action
        onViewCreated(nsView)
    }
}

@MainActor
final class MainSplitVisibilityBridgeView: NSView {
    var action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init(frame: .zero)
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func toggleSidebar(_ sender: Any?) {
        action()
    }
}

@MainActor
enum MainWindowStartupConfiguration {
    static let defaultContentSize = NSSize(
        width: MainWindowLayoutPolicy.defaultContentSize.width,
        height: MainWindowLayoutPolicy.defaultContentSize.height
    )
    static let minimumContentSize = NSSize(
        width: MainWindowLayoutPolicy.minimumContentSize.width,
        height: MainWindowLayoutPolicy.minimumContentSize.height
    )
    static let frameAutosaveName = "Mailternal.MainWindow"

    static func prepare(_ window: NSWindow) {
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier(frameAutosaveName)
        window.setAccessibilityIdentifier(UIIdentifier.mainWindow)
        window.contentMinSize = minimumContentSize
        window.setFrameAutosaveName(frameAutosaveName)
        if !window.setFrameUsingName(frameAutosaveName) || !hasValidRestoredFrame(window) {
            window.setContentSize(defaultContentSize)
            window.center()
        }
    }

    static func attach(_ contentHost: NSViewController, to window: NSWindow) {
        let preparedFrame = window.frame
        let contentSize = window.contentRect(forFrameRect: preparedFrame).size
        contentHost.view.setFrameSize(contentSize)
        window.contentViewController = contentHost
        if window.frame != preparedFrame {
            window.setFrame(preparedFrame, display: false)
        }
    }

    private static func hasValidRestoredFrame(_ window: NSWindow) -> Bool {
        let frame = window.frame
        return frame.width.isFinite
            && frame.height.isFinite
            && frame.width >= window.contentMinSize.width
            && frame.height >= window.contentMinSize.height
    }
}

@MainActor
private final class MainSplitVisibilityBridgeBox {
    weak var view: MainSplitVisibilityBridgeView?
}

@MainActor
final class MainShellViewController: NSViewController {
    private var model: AppModel
    private var appearance: AppearanceSettings
    private var actions: ActionSettings
    private let visibilityBridgeBox: MainSplitVisibilityBridgeBox
    private let contentHosting: NSHostingController<MainSplitRoot>
    private var overlayHosting: OverlayHostingView?
    private var backgroundHosting: NSHostingView<WindowBackdropRoot>?

    var visibilityBridgeView: MainSplitVisibilityBridgeView? {
        visibilityBridgeBox.view
    }

    @objc func toggleSidebar(_ sender: Any?) {
        if let bridge = visibilityBridgeView {
            bridge.toggleSidebar(sender)
        } else {
            model.toggleSidebar()
        }
    }

    init(model: AppModel, appearance: AppearanceSettings, actions: ActionSettings) {
        self.model = model
        self.appearance = appearance
        self.actions = actions
        let bridgeBox = MainSplitVisibilityBridgeBox()
        visibilityBridgeBox = bridgeBox
        contentHosting = NSHostingController(
            rootView: MainSplitRoot(
                model: model,
                appearance: appearance,
                actions: actions,
                onVisibilityBridge: { bridgeBox.view = $0 }
            )
        )
        super.init(nibName: nil, bundle: nil)
        contentHosting.sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(contentHosting)
        let contentView = contentHosting.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        makeOverlay()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfAttached()
    }

    func update(model: AppModel, appearance: AppearanceSettings, actions: ActionSettings) {
        self.model = model
        self.appearance = appearance
        self.actions = actions
        let bridgeBox = visibilityBridgeBox
        contentHosting.rootView = MainSplitRoot(
            model: model,
            appearance: appearance,
            actions: actions,
            onVisibilityBridge: { bridgeBox.view = $0 }
        )
        overlayHosting?.rootView = MainOverlayRoot(model: model, appearance: appearance, actions: actions)
        backgroundHosting?.rootView = WindowBackdropRoot(appearance: appearance)
    }

    private func makeOverlay() {
        let hosting = OverlayHostingView(
            rootView: MainOverlayRoot(model: model, appearance: appearance, actions: actions)
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        overlayHosting = hosting
    }

    private func configureWindowIfAttached() {
        guard view.window != nil, backgroundHosting == nil else { return }
        let hosting = NSHostingView(rootView: WindowBackdropRoot(appearance: appearance))
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backgroundHosting = hosting
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("Mailternal.sidebarToggle")
    static let messageArchive = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.archive.rawValue)
    static let messageTrash = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.trash.rawValue)
    static let messageFlag = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.flag.rawValue)
    static let messageOverflow = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.overflow.rawValue)
}

@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private var model: AppModel
    private let includesSidebarToggle: Bool
    private let toggleAction: @MainActor () -> Void
    private weak var toolbar: NSToolbar?
    private lazy var toggleItem = makeToggleItem()
    private lazy var archiveItem = makeMessageItem(
        identifier: .messageArchive,
        action: #selector(archiveSelected(_:))
    )
    private lazy var trashItem = makeMessageItem(
        identifier: .messageTrash,
        action: #selector(trashSelected(_:))
    )
    private lazy var flagItem = makeMessageItem(
        identifier: .messageFlag,
        action: #selector(flagSelected(_:))
    )
    private lazy var overflowItem = makeOverflowItem()
    private lazy var overflowMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }()

    init(
        model: AppModel,
        includesSidebarToggle: Bool = true,
        toggleAction: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.includesSidebarToggle = includesSidebarToggle
        self.toggleAction = toggleAction
        super.init()
    }

    func update(model: AppModel) {
        self.model = model
        configureMessageItems()
        toolbar?.validateVisibleItems()
    }

    func makeToolbar(identifier: String = "Mailternal.MainToolbar") -> NSToolbar {
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
        configureMessageItems()
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // Hermternal order: a leading flexible space pushes the toggle to the
        // sidebar column's trailing edge; the tracking separator ends that
        // column; a second flexible space pushes the message actions to the
        // window's trailing edge, over the detail column.
        var identifiers: [NSToolbarItem.Identifier] = []
        if includesSidebarToggle {
            identifiers += [.flexibleSpace, .sidebarToggle, .sidebarTrackingSeparator]
        }
        identifiers += [.flexibleSpace]
        identifiers += MessageToolbarPolicy.defaultItemIdentifiers.map(toolbarIdentifier)
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .flexibleSpace,
            .space,
            .separator,
        ]
        if includesSidebarToggle {
            identifiers += [.sidebarToggle, .sidebarTrackingSeparator]
        }
        identifiers += MessageToolbarPolicy.allowedItemIdentifiers.map(toolbarIdentifier)
        return identifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .sidebarToggle where includesSidebarToggle:
            return toggleItem
        case .messageArchive:
            return archiveItem
        case .messageTrash:
            return trashItem
        case .messageFlag:
            return flagItem
        case .messageOverflow:
            return overflowItem
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .sidebarToggle:
            item.isEnabled = includesSidebarToggle
        case .messageArchive, .messageTrash, .messageFlag:
            configureMessageItems()
            item.isEnabled = !model.selectedMessageIDs.isEmpty
        case .messageOverflow:
            configureMessageItems()
            item.isEnabled = !model.selectedMessageIDs.isEmpty
        default:
            return item.isEnabled
        }
        return item.isEnabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // NSMenuToolbarItem reserves its first item as the pull-down title.
        menu.addItem(NSMenuItem())
        for policyItem in MessageToolbarPolicy.overflowItems(
            selection: model.selectedMessageIDs,
            isReadStates: readStates,
            flagStates: flagStates,
            folders: model.folders,
            current: model.selectedFolderID
        ) {
            addMenuItem(policyItem, to: menu)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.representedObject as? MessageContextMenuPolicy.Action else {
            return menuItem.isEnabled
        }
        let policyItems = MessageToolbarPolicy.overflowItems(
            selection: model.selectedMessageIDs,
            isReadStates: readStates,
            flagStates: flagStates,
            folders: model.folders,
            current: model.selectedFolderID
        )
        let enabled = overflowItem(for: action, in: policyItems)?.isEnabled ?? false
        menuItem.isEnabled = enabled
        return enabled
    }

    private var flagStates: [MessageID: Bool] {
        Dictionary(uniqueKeysWithValues: model.listRows.map { ($0.id, $0.isFlagged) })
    }

    private var readStates: [MessageID: Bool] {
        Dictionary(uniqueKeysWithValues: model.listRows.map { ($0.id, $0.isRead) })
    }

    private func toolbarIdentifier(
        _ identifier: MessageToolbarPolicy.Identifier
    ) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(identifier.rawValue)
    }

    private func configureMessageItems() {
        let visibleItems = MessageToolbarPolicy.visibleItems(
            selection: model.selectedMessageIDs,
            flagStates: flagStates
        )
        for visible in visibleItems {
            let item: NSToolbarItem
            switch visible.identifier {
            case .archive: item = archiveItem
            case .trash: item = trashItem
            case .flag: item = flagItem
            case .overflow: continue
            }
            item.image = NSImage(
                systemSymbolName: visible.imageName,
                accessibilityDescription: visible.title
            )
            item.label = visible.title
            item.paletteLabel = visible.title
            item.toolTip = visible.title
            item.isEnabled = visible.isEnabled
        }
        overflowItem.isEnabled = !model.selectedMessageIDs.isEmpty
    }

    private func makeToggleItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .sidebarToggle)
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "Sidebar"
        )
        item.label = "Sidebar"
        item.paletteLabel = "Sidebar"
        item.toolTip = "Show or hide the sidebar"
        item.action = #selector(toggleSidebar(_:))
        item.target = self
        item.isBordered = true
        item.isEnabled = includesSidebarToggle
        item.autovalidates = false
        return item
    }

    private func makeMessageItem(
        identifier: NSToolbarItem.Identifier,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.action = action
        item.target = self
        item.isBordered = true
        item.autovalidates = true
        return item
    }

    private func makeOverflowItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .messageOverflow)
        item.menu = overflowMenu
        item.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Message actions"
        )
        item.label = "Message Actions"
        item.paletteLabel = "Message Actions"
        item.toolTip = "Message actions"
        item.isBordered = true
        item.isEnabled = false
        item.autovalidates = true
        item.showsIndicator = false
        return item
    }

    private func addMenuItem(
        _ policyItem: MessageContextMenuPolicy.Item,
        to menu: NSMenu
    ) {
        if policyItem.isSeparator {
            menu.addItem(.separator())
            return
        }
        let item = NSMenuItem(
            title: policyItem.title,
            action: policyItem.action == nil ? nil : #selector(performOverflowAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = policyItem.action
        item.toolTip = policyItem.toolTip
        item.isEnabled = policyItem.isEnabled
        if !policyItem.children.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in policyItem.children {
                addMenuItem(child, to: submenu)
            }
            item.submenu = submenu
        }
        menu.addItem(item)
    }

    private func overflowItem(
        for action: MessageContextMenuPolicy.Action,
        in items: [MessageContextMenuPolicy.Item]
    ) -> MessageContextMenuPolicy.Item? {
        for item in items {
            if item.action == action { return item }
            if let match = overflowItem(for: action, in: item.children) { return match }
        }
        return nil
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        toggleAction()
    }

    @objc private func archiveSelected(_ sender: Any?) {
        model.perform(.archive, on: model.selectedMessageIDs)
    }

    @objc private func trashSelected(_ sender: Any?) {
        model.perform(.trash, on: model.selectedMessageIDs)
    }

    @objc private func flagSelected(_ sender: Any?) {
        model.perform(.toggleFlag, on: model.selectedMessageIDs)
    }

    @objc private func performOverflowAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MessageContextMenuPolicy.Action else {
            return
        }
        let selection = model.selectedMessageIDs
        guard !selection.isEmpty else { return }
        switch action {
        case .markRead, .markUnread:
            model.perform(.toggleRead, on: selection)
        case .moveToJunk:
            guard let junk = model.folders.first(where: { $0.role == .junk }) else { return }
            model.move(ids: selection, to: junk.id)
        case .moveTo(let folder):
            model.move(ids: selection, to: folder)
        case .openInNewWindow:
            guard selection.count == 1, let id = selection.first else { return }
            model.openMessageWindow(id)
        case .copyLink:
            Task { await model.copyDeepLinks(for: selection) }
        case .copySubject:
            model.copySubjects(for: selection)
        case .viewRawSource:
            guard selection.count == 1 else { return }
            Task { await model.loadRawSource() }
        case .flag, .unflag, .delete, .archive, .reply, .replyAll, .forward:
            break
        }
    }
}
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()
    private var shell: MainShellViewController?
    private var toolbarController: MainToolbarController?


    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(model: AppModel, appearance: AppearanceSettings, actions: ActionSettings) {
        if let shell {
            shell.update(model: model, appearance: appearance, actions: actions)
            toolbarController?.update(model: model)
        } else {
            let shell = MainShellViewController(model: model, appearance: appearance, actions: actions)
            self.shell = shell
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: MainWindowStartupConfiguration.defaultContentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            MainWindowStartupConfiguration.prepare(window)
            window.delegate = self
            let toolbarController = MainToolbarController(
                model: model,
                toggleAction: { [weak shell] in shell?.toggleSidebar(nil) }
            )
            self.toolbarController = toolbarController
            window.toolbar = toolbarController.makeToolbar()
            self.window = window
            MainWindowStartupConfiguration.attach(shell, to: window)
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}
