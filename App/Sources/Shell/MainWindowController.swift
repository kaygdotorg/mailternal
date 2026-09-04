import AppKit
import os
import Observation
import SwiftUI

import MailternalInterfaces

private let mainWindowSignpostLog = OSLog(subsystem: "org.kayg.mailternal", category: "ShellLaunch")

@inline(__always)
private func shellLaunchPhase(_ name: String) {
    QALaunch.launchSubphase(name)
    os_signpost(.event, log: mainWindowSignpostLog, name: "shell-launch", "%{public}s", name)
}


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
        ZStack {
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
            if let facade = model.facade as? LiveMailFacade,
               case .migrating = facade.storeLoadState {
                StoreMigrationOverlay()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
    }
private struct StoreMigrationOverlay: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Updating mail database…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            .regularMaterial,
            in: RoundedRectangle(
                cornerRadius: AppShapeScale.card,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Updating mail database…")
    }
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
        if rootView.model.isSearchPresented {
            return hit ?? self
        }
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
    private var didMarkFirstLayout = false

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
        shellLaunchPhase("shell-vc-init-begin")
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
        shellLaunchPhase("shell-hosting-controller-ready")
        super.init(nibName: nil, bundle: nil)
        configureTransparentHostingView(contentHosting.view)
        contentHosting.sizingOptions = []
        shellLaunchPhase("shell-vc-init-end")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        shellLaunchPhase("shell-navsplit-attach-begin")
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
        shellLaunchPhase("shell-navsplit-attach-end")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowIfAttached()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        guard !didMarkFirstLayout else { return }
        didMarkFirstLayout = true
        shellLaunchPhase("shell-navsplit-first-layout")
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
        shellLaunchPhase("shell-materials-begin")
        let hosting = NSHostingView(rootView: WindowBackdropRoot(appearance: appearance))
        configureTransparentHostingView(hosting)
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting, positioned: .below, relativeTo: nil)
        backgroundHosting = hosting
        shellLaunchPhase("shell-materials-end")
    }

    private func configureTransparentHostingView(_ hosting: NSView) {
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
    }

}

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("Mailternal.sidebarToggle")
    static let readerTabs = NSToolbarItem.Identifier("Mailternal.readerTabs")
    static let messageActions = NSToolbarItem.Identifier(MessageToolbarPolicy.Group.messageActions.rawValue)
    static let messageArchive = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.archive.rawValue)
    static let messageTrash = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.trash.rawValue)
    static let messageFlag = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.flag.rawValue)
    static let messageSource = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.source.rawValue)
    static let messageColorScheme = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.colorScheme.rawValue)
    static let messageOverflow = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.overflow.rawValue)
}

@MainActor
private final class ReaderTabsHostingView: NSHostingView<ReaderTabBar> {
    var desiredWidth: CGFloat = 0 {
        didSet {
            guard abs(oldValue - desiredWidth) > 0.5 else { return }
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: desiredWidth, height: ReaderTabLayoutPolicy.rowHeight)
    }
}

/// Tab hover preview: a system `NSPopover` (same chrome as the QR-code
/// popover) anchored to the hovered tab. `.applicationDefined` behaviour keeps
/// it open while the pointer is over the tab or the card; the owner dismisses
/// it. The content tracks pointer entry/exit so scrolling the preview works.
@MainActor
final class ReaderTabHoverPopover: NSPopover {
    private let trackingView = ReaderTabHoverTrackingView()
    private let hostingView: NSHostingView<ReaderTabHoverCard>

    init(card: ReaderTabHoverCard, cardHovered: Binding<Bool>) {
        hostingView = NSHostingView(rootView: card)
        super.init()
        trackingView.onHoverChanged = { inside in
            cardHovered.wrappedValue = inside
        }
        trackingView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: trackingView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trackingView.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: trackingView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: trackingView.bottomAnchor)
        ])
        let controller = NSViewController()
        controller.view = trackingView
        contentViewController = controller
        contentSize = NSSize(
            width: ReaderTabTokens.previewWidth,
            height: ReaderTabTokens.previewHeight
        )
        behavior = .applicationDefined
        animates = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(card: ReaderTabHoverCard) {
        hostingView.rootView = card
    }

    /// `tabFrame` is in `view`'s SwiftUI (top-left) coordinates.
    func present(tabFrame: CGRect, in view: NSView) {
        var rect = tabFrame.intersection(view.bounds)
        if rect.isNull || rect.isEmpty { rect = view.bounds }
        if !view.isFlipped {
            rect.origin.y = view.bounds.height - rect.maxY
        }
        if isShown {
            positioningRect = rect
            return
        }
        show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func dismiss() {
        if isShown { performClose(nil) }
    }
}

@MainActor
private final class ReaderTabHoverTrackingView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate {
    private var model: AppModel
    private var modelObservationGeneration: UInt64 = 0
    private let includesSidebarToggle: Bool
    private let toggleAction: @MainActor () -> Void
    private weak var toolbar: NSToolbar?
    private lazy var toggleItem = makeToggleItem()
    private lazy var readerTabsHosting = makeReaderTabsHosting()
    private lazy var readerTabsItem = makeReaderTabsItem()
    private lazy var archiveItem = makeMessageItem(
        identifier: .messageArchive,
        action: #selector(archiveSelected(_:))
    )
    private lazy var trashItem = makeMessageItem(
        identifier: .messageTrash,
        action: #selector(trashSelected(_:))
    )
    private var cachedMessageActionsWidth: CGFloat?
    private var readerTabsWidthUpdateScheduled = false
    private lazy var flagItem = makeMessageItem(
        identifier: .messageFlag,
        action: #selector(flagSelected(_:))
    )
    private lazy var sourceItem = makeMessageItem(
        identifier: .messageSource,
        action: #selector(toggleRawSource(_:))
    )
    private lazy var colorSchemeItem = makeMessageItem(
        identifier: .messageColorScheme,
        action: #selector(toggleEmailReadingOverride(_:))
    )
    private lazy var overflowItem = makeOverflowItem()
    private lazy var messageActionsGroup = makeMessageGroup(.messageActions)
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
        observeModelChanges()
    }

    func update(model: AppModel) {
        self.model = model
        modelObservationGeneration &+= 1
        observeModelChanges()
        if includesSidebarToggle {
            readerTabsHosting.rootView = ReaderTabBar(model: model)
        }
        configureMessageItems()
        configureReaderTabs()
        toolbar?.validateVisibleItems()
    }

    /// AppKit's toolbar validation is not driven by SwiftUI's observation
    /// updates. Keep the native items in step with selection changes while
    /// leaving per-menu-item validation to `validateMenuItem(_:).`
    private func observeModelChanges() {
        let generation = modelObservationGeneration
        withObservationTracking {
            _ = model.selectedMessageIDs
            _ = model.listRows
            _ = model.folders
            _ = model.selectedFolderID
            _ = model.isShowingRawSource
            _ = model.emailReadingOverride
            _ = model.appearance.emailReadingMode
            _ = model.isSearchPresented
            _ = model.tabs.activeID
            _ = model.tabs.tabs.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.modelObservationGeneration == generation else { return }
                self.configureMessageItems()
                self.configureReaderTabs()
                self.toolbar?.validateVisibleItems()
                self.observeModelChanges()
            }
        }
    }

    func makeToolbar(identifier: String = "Mailternal.MainToolbar") -> NSToolbar {
        UserDefaults.standard.removeObject(forKey: "NSToolbar Configuration \(identifier)")
        let toolbar = NSToolbar(identifier: identifier)
        self.toolbar = toolbar
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsDisplayModeCustomization = false
        toolbar.allowsUserCustomization = false
        configureMessageItems()
        configureReaderTabs()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReaderTabsWidthUpdate()
        }
        NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReaderTabsWidthUpdate()
        }
        // NSToolbar installs its item views after makeToolbar returns. Cache the
        // fixed native action width only after installation, then size tabs
        // from split geometry on that stable value.
        DispatchQueue.main.async { [weak self, weak toolbar] in
            guard let self, self.toolbar === toolbar else { return }
            self.cacheMessageActionsWidth()
            self.configureReaderTabs()
            self.updateReaderTabsWidth()
        }
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = []
        if includesSidebarToggle {
            identifiers += [.flexibleSpace, .sidebarToggle, .sidebarTrackingSeparator, .flexibleSpace, .readerTabs]
        } else {
            identifiers += [.flexibleSpace]
        }
        identifiers += MessageToolbarPolicy.defaultGroupIdentifiers.map(toolbarGroupIdentifier)
        return identifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [
            .flexibleSpace,
            .space,
        ]
        if includesSidebarToggle {
            identifiers += [.sidebarToggle, .sidebarTrackingSeparator, .flexibleSpace, .readerTabs]
        }
        identifiers += MessageToolbarPolicy.allowedGroupIdentifiers.map(toolbarGroupIdentifier)
        return identifiers
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        []
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .sidebarToggle where includesSidebarToggle:
            return toggleItem
        case .readerTabs where includesSidebarToggle:
            return readerTabsItem
        case .messageActions:
            return messageActionsGroup
        case .messageArchive:
            return archiveItem
        case .messageTrash:
            return trashItem
        case .messageFlag:
            return flagItem
        case .messageSource:
            return sourceItem
        case .messageColorScheme:
            return colorSchemeItem
        case .messageOverflow:
            return overflowItem
        default:
            return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .sidebarToggle:
            item.isHidden = !includesSidebarToggle || model.isSearchPresented
            item.isEnabled = includesSidebarToggle && !model.isSearchPresented
        case .readerTabs:
            configureReaderTabs()
        case .messageActions,
             .messageArchive, .messageTrash, .messageFlag,
             .messageSource, .messageColorScheme:
            configureMessageItems()
        case .messageOverflow:
            configureMessageItems()
            item.isEnabled = !model.selectedMessageIDs.isEmpty
        default:
            return item.isEnabled
        }
        return item.isEnabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        overflowItem.isEnabled = !model.selectedMessageIDs.isEmpty
        menu.removeAllItems()
        menu.addItem(NSMenuItem())
        for policyItem in MessageToolbarPolicy.overflowItems(
            selection: model.selectedMessageIDs,
            isReadStates: readStates,
            flagStates: flagStates,
            folders: model.folders,
            current: model.selectedFolderID,
            accounts: model.accountConfigs
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
            current: model.selectedFolderID,
            accounts: model.accountConfigs
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

    private func toolbarGroupIdentifier(
        _ group: MessageToolbarPolicy.Group
    ) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(group.rawValue)
    }

    private func messageItem(
        for identifier: MessageToolbarPolicy.Identifier
    ) -> NSToolbarItem? {
        switch identifier {
        case .archive: return archiveItem
        case .trash: return trashItem
        case .flag: return flagItem
        case .source: return sourceItem
        case .colorScheme: return colorSchemeItem
        case .overflow: return overflowItem
        }
    }

    private func makeMessageGroup(
        _ group: MessageToolbarPolicy.Group
    ) -> NSToolbarItemGroup {
        let item = NSToolbarItemGroup(itemIdentifier: toolbarGroupIdentifier(group))
        item.subitems = MessageToolbarPolicy.itemIdentifiers(in: group)
            .compactMap { messageItem(for: $0) }
        item.label = "Message Actions"
        item.paletteLabel = item.label
        // A bordered NSToolbarItemGroup draws separators between its subitems
        // on macOS 26. The subitems are bordered instead: adjacent bordered
        // items share one capsule without dividers.
        item.isBordered = false
        item.isEnabled = true
        item.controlRepresentation = .expanded
        item.selectionMode = .selectAny
        item.autovalidates = false
        return item
    }

    private func configureMessageItems() {
        let visibleItems = MessageToolbarPolicy.visibleItems(
            selection: model.selectedMessageIDs,
            flagStates: flagStates,
            effectiveEmailReadingMode: model.effectiveEmailReadingMode,
            isShowingRawSource: model.isShowingRawSource
        )
        for visible in visibleItems {
            let item: NSToolbarItem
            switch visible.identifier {
            case .archive: item = archiveItem
            case .trash: item = trashItem
            case .flag: item = flagItem
            case .source: item = sourceItem
            case .colorScheme: item = colorSchemeItem
            case .overflow: item = overflowItem
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
        // Source and reading-mode state now live in More, not in the native
        // toolbar group. Keep the group purely action-oriented.
        overflowItem.isEnabled = !model.selectedMessageIDs.isEmpty
        messageActionsGroup.isHidden = model.isSearchPresented || model.selectedMessageIDs.isEmpty
        messageActionsGroup.isEnabled = !model.isSearchPresented
        toggleItem.isHidden = !includesSidebarToggle || model.isSearchPresented
        toggleItem.isEnabled = includesSidebarToggle && !model.isSearchPresented
        // The cluster width feeds the strip viewport.
        scheduleReaderTabsWidthUpdate()
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


    private func makeReaderTabsHosting() -> ReaderTabsHostingView {
        let hosting = ReaderTabsHostingView(rootView: ReaderTabBar(model: model))
        hosting.safeAreaRegions = []
        // The toolbar supplies the material behind this custom view. Do not
        // let NSHostingView install an opaque layer or size itself from the
        // SwiftUI root's intrinsic content.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.clipsToBounds = false
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.layer?.masksToBounds = false
        return hosting
    }

    private func makeReaderTabsItem() -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: .readerTabs)
        item.view = readerTabsHosting
        item.label = ""
        item.paletteLabel = ""
        item.isBordered = false
        item.minSize = NSSize(width: 0, height: ReaderTabLayoutPolicy.rowHeight)
        item.maxSize = NSSize(width: 0, height: ReaderTabLayoutPolicy.rowHeight)
        item.isEnabled = false
        item.autovalidates = false
        return item
    }

    private func configureReaderTabs() {
        let shouldShow = !model.tabs.tabs.isEmpty && !model.isSearchPresented
        guard let toolbar else {
            readerTabsItem.isHidden = !shouldShow
            readerTabsItem.isEnabled = shouldShow
            return
        }
        if shouldShow {
            if !toolbar.items.contains(where: { $0.itemIdentifier == .readerTabs }) {
                let insertionIndex = toolbar.items.firstIndex {
                    $0.itemIdentifier == .messageActions
                } ?? toolbar.items.count
                toolbar.insertItem(withItemIdentifier: .readerTabs, at: insertionIndex)
            }
            readerTabsItem.isHidden = false
            readerTabsItem.isEnabled = true
            updateReaderTabsWidth()
            // NSToolbar attaches the item view after insertItem returns; size
            // again once it is in the window.
            scheduleReaderTabsWidthUpdate()
        } else {
            if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == .readerTabs }) {
                toolbar.removeItem(at: index)
            }
            readerTabsHosting.desiredWidth = 0
        }
    }

    /// Width of the trailing native actions cluster. Measured once its item
    /// view exists; until then the policy fallback keeps the tab strip from
    /// disappearing (an unmeasured width must never hide the tabs).
    private var messageActionsWidth: CGFloat {
        // Prefer the live laid-out width: the group is measured at toolbar
        // install with no selection, when its fitting size understates the
        // visible cluster and the strip then overflows into the list column.
        if let live = messageActionsGroup.view?.frame.width, live > 0 {
            cachedMessageActionsWidth = live
            return live
        }
        if let cachedMessageActionsWidth { return cachedMessageActionsWidth }
        let width = max(
            messageActionsGroup.minSize.width,
            messageActionsGroup.view?.fittingSize.width ?? 0
        )
        if width > 0 {
            cachedMessageActionsWidth = width
            return width
        }
        return ReaderTabLayoutPolicy.fallbackActionsWidth
    }

    private func cacheMessageActionsWidth() {
        _ = messageActionsWidth
    }

    private func scheduleReaderTabsWidthUpdate() {
        guard !readerTabsWidthUpdateScheduled else { return }
        readerTabsWidthUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readerTabsWidthUpdateScheduled = false
            self.updateReaderTabsWidth()
        }
    }

    private func updateReaderTabsWidth() {
        guard includesSidebarToggle,
              let window = readerTabsHosting.window,
              let contentView = window.contentView,
              readerTabsHosting.superview != nil
        else { return }
        let actionWidth = messageActionsWidth
        let detailOrigin = detailColumnOrigin(in: contentView, contentView: contentView) ?? 0
        let detailWidth = max(0, contentView.bounds.maxX - detailOrigin)
        // NSToolbar adds inter-item spacing; without this slack the strip
        // overflows the toolbar and is shifted left into the list column.
        let tabViewportWidth = max(
            0,
            detailWidth - actionWidth - ReaderTabLayoutPolicy.toolbarSpacing * 2
        )
        let hidden = model.tabs.tabs.isEmpty
            || model.isSearchPresented
            || tabViewportWidth < ReaderTabLayoutPolicy.minimumTabWidth
        readerTabsItem.isHidden = hidden
        readerTabsItem.isEnabled = !hidden
        readerTabsHosting.desiredWidth = hidden ? 0 : tabViewportWidth
        let size = NSSize(
            width: hidden ? 0 : tabViewportWidth,
            height: ReaderTabLayoutPolicy.rowHeight
        )
        readerTabsItem.minSize = size
        readerTabsItem.maxSize = size
    }


    /// Leading edge of the reader (detail) column in window-content
    /// coordinates. The split view's detail pane is authoritative; the
    /// message table's trailing edge sits ~17 pt left of the pane divider
    /// (scroller/inset), so it is only a fallback for layouts without a
    /// measurable detail pane.
    private func detailColumnOrigin(in view: NSView, contentView: NSView) -> CGFloat? {
        if let paneOrigin = splitDetailOrigin(in: view, contentView: contentView) {
            return paneOrigin
        }
        return messageTableTrailingEdge(in: view, contentView: contentView)
    }

    private func splitDetailOrigin(in view: NSView, contentView: NSView) -> CGFloat? {
        var origin: CGFloat?
        // `subviews` also holds divider/shadow/titlebar helper views; the
        // panes are the arranged subviews and the detail pane is the last.
        if let split = view as? NSSplitView, split.arrangedSubviews.count >= 2,
           let detail = split.arrangedSubviews.last {
            let frame = detail.convert(detail.bounds, to: contentView)
            if frame.width >= 140 {
                origin = frame.minX
            }
        }
        for subview in view.subviews {
            if let childOrigin = splitDetailOrigin(in: subview, contentView: contentView) {
                origin = max(origin ?? childOrigin, childOrigin)
            }
        }
        return origin
    }

    private func messageTableTrailingEdge(in view: NSView, contentView: NSView) -> CGFloat? {
        if view.accessibilityIdentifier() == UIIdentifier.messageTable {
            let frame = view.convert(view.bounds, to: contentView)
            return frame.width > 0 ? frame.maxX : nil
        }
        for subview in view.subviews {
            if let edge = messageTableTrailingEdge(in: subview, contentView: contentView) {
                return edge
            }
        }
        return nil
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
            accessibilityDescription: "More message actions"
        )
        item.label = "More"
        item.paletteLabel = "More"
        item.toolTip = "More message actions"
        item.isBordered = true
        item.isEnabled = !model.selectedMessageIDs.isEmpty
        item.autovalidates = false
        item.showsIndicator = false
        return item
    }

    private func addMenuItem(
        _ policyItem: MessageContextMenuPolicy.Item,
        to menu: NSMenu,
        indentationLevel: Int = 0
    ) {
        if policyItem.isSeparator {
            menu.addItem(.separator())
            return
        }
        // Account groups are visual headers, not disabled submenus:
        // AppKit propagates a disabled parent's state to every descendant.
        if policyItem.action == nil,
           !policyItem.isEnabled,
           !policyItem.children.isEmpty {
            let header = NSMenuItem(title: policyItem.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.indentationLevel = indentationLevel
            menu.addItem(header)
            for child in policyItem.children {
                addMenuItem(child, to: menu, indentationLevel: indentationLevel + 1)
            }
            return
        }
        let item = NSMenuItem(
            title: policyItem.title,
            action: policyItem.action == nil ? nil : #selector(performOverflowAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.indentationLevel = indentationLevel
        item.representedObject = policyItem.action
        item.toolTip = policyItem.toolTip
        item.isEnabled = policyItem.isEnabled
        if policyItem.action == .viewRawSource {
            item.state = model.isShowingRawSource ? .on : .off
        }
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

    private func clearTransientMessageActionSelection() {
        let identifiers: [MessageToolbarPolicy.Identifier] = [.archive, .trash, .flag]
        let groupedIdentifiers = MessageToolbarPolicy.itemIdentifiers(in: .messageActions)
        for identifier in identifiers {
            guard let index = groupedIdentifiers.firstIndex(of: identifier) else { continue }
            messageActionsGroup.setSelected(false, at: index)
        }
    }

    @objc private func trashSelected(_ sender: Any?) {
        model.perform(.trash, on: model.selectedMessageIDs)
        clearTransientMessageActionSelection()
    }

    @objc private func flagSelected(_ sender: Any?) {
        model.perform(.toggleFlag, on: model.selectedMessageIDs)
        clearTransientMessageActionSelection()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        toggleAction()
    }

    @objc private func archiveSelected(_ sender: Any?) {
        model.perform(.archive, on: model.selectedMessageIDs)
        clearTransientMessageActionSelection()
    }

    @objc private func toggleRawSource(_ sender: Any?) {
        guard model.selectedMessageIDs.count == 1 else { return }
        model.toggleRawSource()
    }

    @objc private func toggleEmailReadingOverride(_ sender: Any?) {
        guard model.selectedMessageIDs.count == 1 else { return }
        model.toggleEmailReadingOverride()
    }

    @objc private func performOverflowAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MessageContextMenuPolicy.Action else {
            return
        }
        let selection = model.selectedMessageIDs
        guard !selection.isEmpty else { return }
        switch action {
        case .openInNewTab:
            guard selection.count == 1, let id = selection.first else { return }
            model.openMessage(id, permanent: true)
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
            toggleRawSource(nil)
        case .toggleEmailReadingOverride:
            toggleEmailReadingOverride(nil)
        case .flag, .unflag:
            model.perform(.toggleFlag, on: selection)
        case .delete, .archive, .reply, .replyAll, .forward:
            break
        }
    }
}
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    static let shared = MainWindowController()
    private var shell: MainShellViewController?
    private var toolbarController: MainToolbarController?
    private var didScheduleFirstFrame = false
    private var didScheduleSettledFrame = false
    private var launchDataPhases: Set<String> = []

    private init() { super.init(window: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Records the two data phases that make the initial shell useful. The
    /// completion is intentionally attached to Core Animation rather than a
    /// SwiftUI task, so QA measures a committed frame instead of model time.
    static func noteLaunchDataPhase(_ phase: String) {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" else { return }
        shared.launchDataPhases.insert(phase)
        shared.scheduleSettledFrameIfReady()
    }

    private func scheduleSettledFrameIfReady() {
        guard !didScheduleSettledFrame,
              launchDataPhases.contains("folders-snapshot"),
              launchDataPhases.contains("first-rows"),
              let window
        else { return }
        didScheduleSettledFrame = true
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            QALaunch.launchPhase("settled-frame")
        }
        window.contentView?.needsLayout = true
        CATransaction.commit()
    }

    func show(model: AppModel, appearance: AppearanceSettings, actions: ActionSettings) {
        var toolbarToInstall: MainToolbarController?
        if let shell {
            shell.update(model: model, appearance: appearance, actions: actions)
            toolbarController?.update(model: model)
        } else {
            shellLaunchPhase("shell-construction-begin")
            let shell = MainShellViewController(model: model, appearance: appearance, actions: actions)
            self.shell = shell
            shellLaunchPhase("shell-construction-end")
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
            shellLaunchPhase("shell-toolbar-controller-ready")
            self.window = window
            MainWindowStartupConfiguration.attach(shell, to: window)
            shellLaunchPhase("shell-window-attached")
            toolbarToInstall = toolbarController
        }

        guard let window else { return }
        if !didScheduleFirstFrame {
            didScheduleFirstFrame = true
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                QALaunch.launchPhase("first-frame")
            }
            window.makeKeyAndOrderFront(nil)
            CATransaction.commit()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        QALaunch.launchPhase("window-front")

        // The shell is already attached when the window fronts. Install the
        // toolbar on the next main-actor turn so its native setup cannot delay
        // the first visible frame.
        if let toolbarToInstall {
            Task { @MainActor [weak self, weak window, toolbarToInstall] in
                guard let self, let window, self.window === window else { return }
                shellLaunchPhase("shell-toolbar-install-begin")
                window.toolbar = toolbarToInstall.makeToolbar()
                shellLaunchPhase("shell-toolbar-install-end")
            }
        }
        scheduleSettledFrameIfReady()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}
