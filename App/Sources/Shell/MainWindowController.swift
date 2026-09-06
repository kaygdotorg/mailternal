import AppKit
import os
import Observation
import SwiftUI

import MailternalInterfaces

private let mainWindowSignpostLog = OSLog(subsystem: "org.kayg.mailternal", category: "ShellLaunch")
private let readerToolbarSignpostLog = OSLog(
    subsystem: "org.kayg.mailternal",
    category: "ReaderToolbar"
)

@inline(__always)
private func shellLaunchPhase(_ name: String) {
    QALaunch.launchPhase(name)
    os_signpost(.event, log: mainWindowSignpostLog, name: "shell-launch", "%{public}s", name)
}


/// Both pane arrangements retain the same model, selection, and reader tabs.
/// Only the native split orientation changes; mail mutations stay on AppModel.
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
        Group {
            switch model.listPaneLayout {
            case .sideBySide:
                NavigationSplitView(columnVisibility: $model.columnVisibility) {
                    FolderSidebar(model: model)
                } content: {
                    MessageListPane(model: model)
                } detail: {
                    MessageViewer(model: model)
                }
                .navigationSplitViewStyle(.balanced)
            case .listAboveReader:
                NavigationSplitView(columnVisibility: $model.columnVisibility) {
                    FolderSidebar(model: model)
                } detail: {
                    VSplitView {
                        MessageListPane(model: model)
                            .frame(minHeight: 180)
                        VStack(spacing: 0) {
                            ReaderPaneChrome(model: model)
                            MessageViewer(model: model)
                        }
                        .frame(minHeight: 200)
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
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
/// Reader-scoped chrome follows the lower split pane, rather than remaining
/// in the window titlebar above the message list.
private struct ReaderPaneChrome: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.tabs.active != nil && !model.isSearchPresented {
            HStack(spacing: 0) {
                if model.tabs.tabs.count > 1 {
                    ReaderTabBar(model: model)
                        .frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
                ReaderPaneActions(model: model)
                    .fixedSize()
            }
            .frame(height: ReaderTabLayoutPolicy.rowHeight)
            .padding(.horizontal, MessageViewerLayoutPolicy.horizontalPadding)
            .accessibilityIdentifier("reader-pane-toolbar")
        }
    }
}

private struct ReaderPaneActions: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> MainToolbarController {
        MainToolbarController(model: model, includesSidebarToggle: false, isPaneLocal: true)
    }

    func makeNSView(context: Context) -> NSStackView {
        context.coordinator.makePaneActions()
    }

    func updateNSView(_ nsView: NSStackView, context: Context) {
        context.coordinator.update(model: model)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSStackView, context: Context
    ) -> CGSize? {
        nsView.fittingSize
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
        let modelChanged = self.model !== model
        let appearanceChanged = self.appearance !== appearance
        let actionsChanged = self.actions !== actions
        guard modelChanged || appearanceChanged || actionsChanged else { return }
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
    static let messageArchive = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.archive.rawValue)
    static let messageTrash = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.trash.rawValue)
    static let messageOverflow = NSToolbarItem.Identifier(MessageToolbarPolicy.Identifier.overflow.rawValue)
}

@MainActor
private final class ReaderTabsHostingView: NSHostingView<ReaderTabBar> {
    var onWindowChange: ((NSWindow) -> Void)?
    private lazy var widthLimit = widthAnchor.constraint(lessThanOrEqualToConstant: 0)
    private lazy var preferredWidth = widthAnchor.constraint(equalToConstant: 0)

    required init(rootView: ReaderTabBar) {
        super.init(rootView: rootView)
        preferredWidth.priority = .defaultLow
        NSLayoutConstraint.activate([
            widthLimit,
            preferredWidth,
            heightAnchor.constraint(equalToConstant: ReaderTabLayoutPolicy.rowHeight)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindowChange?(window) }
    }

    var desiredWidth: CGFloat = 0 {
        didSet {
            guard abs(oldValue - desiredWidth) > 0.5 else { return }
            widthLimit.constant = desiredWidth
            preferredWidth.constant = desiredWidth
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ReaderTabLayoutPolicy.rowHeight)
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
    private let isPaneLocal: Bool
    private var paneButtons: [MessageToolbarPolicy.Identifier: NSButton] = [:]
    private let toggleAction: @MainActor () -> Void
    private var readerMessageSelection: Set<MessageID> {
        let messageID = includesSidebarToggle || isPaneLocal
            ? model.tabs.active?.message
            : model.selectedMessageID
        return messageID.map { [$0] } ?? []
    }

    private weak var toolbar: NSToolbar?
    private weak var layoutWindow: NSWindow?
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
        isPaneLocal: Bool = false,
        toggleAction: @escaping @MainActor () -> Void = {}
    ) {
        self.model = model
        self.includesSidebarToggle = includesSidebarToggle
        self.isPaneLocal = isPaneLocal
        self.toggleAction = toggleAction
        super.init()
        observeModelChanges()
        observeReaderTabsChanges()
    }

    func update(model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        modelObservationGeneration &+= 1
        observeModelChanges()
        observeReaderTabsChanges()
        if includesSidebarToggle {
            readerTabsHosting.rootView = ReaderTabBar(model: model)
        }
        configureMessageItems()
        configureReaderTabs()
        toolbar?.validateVisibleItems()
    }

    /// The same command/menu owner backs native pane buttons and titlebar
    /// items. Only presentation changes; mutations still go through AppModel.
    func makePaneActions() -> NSStackView {
        let archive = NSButton(
            image: NSImage(), target: self, action: #selector(archiveSelected(_:))
        )
        let trash = NSButton(
            image: NSImage(), target: self, action: #selector(trashSelected(_:))
        )
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        menuNeedsUpdate(overflowMenu)
        more.menu = overflowMenu
        (more.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        paneButtons = [.archive: archive, .trash: trash, .overflow: more]
        for (identifier, button) in paneButtons {
            button.bezelStyle = .glass
            button.imagePosition = .imageOnly
            button.setAccessibilityIdentifier(identifier.rawValue)
        }
        configureMessageItems()
        let stack = NSStackView(views: [archive, trash, more])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = ReaderTabLayoutPolicy.toolbarSpacing
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    /// AppKit's toolbar validation is not driven by SwiftUI's observation
    /// updates. Keep native message actions in step with only the state they
    /// consume, without rebuilding the reader-tabs item for list/menu changes.
    private func observeModelChanges() {
        let generation = modelObservationGeneration
        withObservationTracking {
            _ = model.tabs.active?.message
            _ = model.selectedMessageID
            _ = model.listRows
            _ = model.isShowingRawSource
            _ = model.emailReadingOverride
            _ = model.appearance.emailReadingMode
            _ = model.isSearchPresented
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.modelObservationGeneration == generation else { return }
                self.configureMessageItems()
                self.toolbar?.validateVisibleItems()
                self.observeModelChanges()
            }
        }
    }

    private func observeReaderTabsChanges() {
        let generation = modelObservationGeneration
        withObservationTracking {
            _ = model.tabs.activeID
            _ = model.tabs.tabs.count
            _ = model.isSearchPresented
            _ = model.listPaneLayout
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.modelObservationGeneration == generation else { return }
                self.configureMessageItems()
                self.configureReaderTabs()
                self.toolbar?.validateVisibleItems()
                self.observeReaderTabsChanges()
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
            MainActor.assumeIsolated { self?.scheduleReaderTabsWidthUpdate() }
        }
        NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReaderTabsWidthUpdate() }
        }
        NotificationCenter.default.addObserver(
            forName: MessageSubjectRegion.geometryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard self?.readerTabsHosting.window === window else { return }
                self?.scheduleReaderTabsWidthUpdate()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReaderTabsWidthUpdate() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReaderTabsWidthUpdate() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didDeminiaturizeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReaderTabsWidthUpdate() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReaderTabsWidthUpdate() }
        }
        // NSToolbar installs its item views after makeToolbar returns. Resolve
        // the native action boundary after installation; the earlier fallback
        // remains provisional.
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
        identifiers += MessageToolbarPolicy.defaultItemIdentifiers.map {
            NSToolbarItem.Identifier($0.rawValue)
        }
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
        identifiers += MessageToolbarPolicy.allowedItemIdentifiers.map {
            NSToolbarItem.Identifier($0.rawValue)
        }
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
        case .messageArchive:
            return archiveItem
        case .messageTrash:
            return trashItem
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
        case .messageArchive, .messageTrash, .messageOverflow:
            configureMessageItems()
            // With autovalidates enabled, AppKit owns isEnabled and applies
            // the Boolean returned by validation; assigning isEnabled above
            // is therefore not sufficient for the image action items.
            return !model.isSearchPresented && !readerMessageSelection.isEmpty
        default:
            return item.isEnabled
        }
        return item.isEnabled
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if !isPaneLocal { overflowItem.isEnabled = !readerMessageSelection.isEmpty }
        menu.removeAllItems()
        let header = NSMenuItem()
        if isPaneLocal {
            header.image = Self.toolbarSymbol("ellipsis", accessibilityDescription: "More")
        }
        menu.addItem(header)
        for policyItem in MessageToolbarPolicy.overflowItems(
            selection: readerMessageSelection,
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
            selection: readerMessageSelection,
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


    private func configureMessageItems() {
        let visibleItems = MessageToolbarPolicy.visibleItems(
            selection: readerMessageSelection,
            flagStates: flagStates,
            effectiveEmailReadingMode: model.effectiveEmailReadingMode,
            isShowingRawSource: model.isShowingRawSource
        )
        if isPaneLocal {
            for visible in visibleItems {
                guard let button = paneButtons[visible.identifier] else { continue }
                button.image = Self.toolbarSymbol(visible.imageName, accessibilityDescription: visible.title)
                button.toolTip = visible.title
                button.setAccessibilityLabel(visible.title)
                button.isEnabled = visible.isEnabled && !model.isSearchPresented
            }
            return
        }
        for visible in visibleItems {
            let item: NSToolbarItem
            switch visible.identifier {
            case .archive: item = archiveItem
            case .trash: item = trashItem
            case .overflow: item = overflowItem
            case .flag, .source, .colorScheme:
                continue
            }
            item.image = Self.toolbarSymbol(visible.imageName, accessibilityDescription: visible.title)
            item.label = visible.title
            item.paletteLabel = visible.title
            item.toolTip = visible.title
            item.isEnabled = visible.isEnabled
        }
        let hideActions = model.isSearchPresented || readerMessageSelection.isEmpty
            || (includesSidebarToggle && model.listPaneLayout == .listAboveReader)
        for item in [archiveItem, trashItem, overflowItem] {
            item.isHidden = hideActions
            item.isEnabled = !hideActions
        }
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
        hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hosting.onWindowChange = { [weak self] window in
            self?.layoutWindow = window
            self?.scheduleReaderTabsWidthUpdate()
        }
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
        item.isEnabled = false
        item.autovalidates = false
        item.visibilityPriority = .low
        return item
    }

    private func configureReaderTabs() {
        os_signpost(
            .event,
            log: readerToolbarSignpostLog,
            name: "configureReaderTabs"
        )
        guard includesSidebarToggle else { return }
        let shouldShow = model.tabs.tabs.count > 1 && !model.isSearchPresented
            && model.listPaneLayout == .sideBySide
        guard let toolbar else {
            readerTabsItem.isHidden = !shouldShow
            readerTabsItem.isEnabled = shouldShow
            return
        }
        if shouldShow {
            if !toolbar.items.contains(where: { $0.itemIdentifier == .readerTabs }) {
                let insertionIndex = toolbar.items.firstIndex {
                    $0.itemIdentifier == .messageArchive
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

    /// Width of the trailing native actions. Measure each laid-out item view
    /// and include the native spacing between adjacent toolbar items; before
    /// layout, the conservative policy fallback keeps the tabs visible.
    private var messageActionsWidth: CGFloat {
        let actionItems = [archiveItem, trashItem, overflowItem]
        let liveWidths = actionItems.compactMap { item -> CGFloat? in
            guard let view = item.view else { return nil }
            let width = view.frame.width
            return width.isFinite && width > 0 ? width : nil
        }
        if liveWidths.count == actionItems.count {
            let width = liveWidths.reduce(0, +)
                + ReaderTabLayoutPolicy.toolbarSpacing * CGFloat(actionItems.count - 1)
            cachedMessageActionsWidth = width
            return width
        }
        if let cachedMessageActionsWidth { return cachedMessageActionsWidth }
        return ReaderTabLayoutPolicy.fallbackActionsWidth
    }

    /// Leading edge of the first visible native reader action. The tab
    /// viewport ends here so its 28pt fade terminates directly against the
    /// native action capsule instead of inheriting toolbar-item margins.
    private func messageActionsLeading(in contentView: NSView) -> CGFloat? {
        guard let window = contentView.window,
              let frameView = contentView.superview else { return nil }
        // Standard image/menu items do not expose NSToolbarItem.view. Their
        // native accessibility frames include the real control/capsule insets.
        func leading(in view: NSView, insideToolbar: Bool) -> CGFloat? {
            guard view !== contentView, view !== readerTabsHosting,
                  !view.isHiddenOrHasHiddenAncestor else { return nil }
            let insideToolbar = insideToolbar || view.accessibilityRole() == .toolbar
            let role = view.accessibilityRole()
            if insideToolbar, role == .button || role == .menuButton {
                let label = view.accessibilityLabel()
                if label == archiveItem.label || label == trashItem.label || label == overflowItem.label {
                    let frame = contentView.convert(
                        window.convertFromScreen(view.accessibilityFrame()),
                        from: nil
                    )
                    if !frame.isEmpty { return frame.minX }
                }
            }
            var result: CGFloat?
            for child in view.subviews {
                if let edge = leading(in: child, insideToolbar: insideToolbar) {
                    result = min(result ?? edge, edge)
                }
            }
            return result
        }
        return leading(in: frameView, insideToolbar: false)
    }
    /// Returns the laid-out custom strip in window-content coordinates so
    /// focus-sensitive interaction routing can distinguish tabs from actions.
    func readerTabsFrame(in contentView: NSView) -> CGRect? {
        if model.listPaneLayout == .listAboveReader {
            return ReaderTabBar.frame(in: contentView)
        }
        guard readerTabsHosting.window === contentView.window,
              !readerTabsHosting.isHidden,
              readerTabsHosting.bounds.width > 0 else {
            return nil
        }
        let frame = readerTabsHosting.convert(readerTabsHosting.bounds, to: contentView)
        return frame.width > 0 && frame.height > 0 ? frame : nil
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
        os_signpost(
            .event,
            log: readerToolbarSignpostLog,
            name: "updateReaderTabsWidth"
        )
        guard includesSidebarToggle,
              let window = readerTabsHosting.window ?? layoutWindow,
              let contentView = window.contentView
        else { return }
        let actionWidth = messageActionsWidth
        let hostingFrame = readerTabsHosting.window === window
            ? readerTabsHosting.convert(readerTabsHosting.bounds, to: contentView)
            : .zero
        let cardOrigin = MessageSubjectRegion.cardFrame(in: contentView)?.minX
            ?? ((detailColumnOrigin(in: contentView, contentView: contentView) ?? 0)
                + MessageViewerLayoutPolicy.horizontalPadding)
        let fallbackActionLeading = contentView.bounds.maxX
            - actionWidth
            - ReaderTabLayoutPolicy.toolbarSpacing
        let trailingEdge = messageActionsLeading(in: contentView)
            ?? fallbackActionLeading
        let nativeGap = hostingFrame.width > 0 && !readerTabsItem.isHidden
            ? max(0, trailingEdge - hostingFrame.maxX)
            : ReaderTabLayoutPolicy.toolbarSpacing
        // Allocation flows from the pane and native actions into the strip.
        // Its resulting frame affects only the painted fade, never its own
        // width constraint, so compression cannot feed back into allocation.
        let tabViewportWidth = max(
            0,
            min(contentView.bounds.maxX, trailingEdge) - cardOrigin
                - ReaderTabLayoutPolicy.toolbarSpacing
        )
        let hidden = model.tabs.tabs.count < 2
            || model.isSearchPresented
            || tabViewportWidth < ReaderTabLayoutPolicy.minimumTabWidth
            || model.listPaneLayout == .listAboveReader
        readerTabsItem.isHidden = hidden
        readerTabsItem.isEnabled = !hidden
        readerTabsHosting.desiredWidth = hidden ? 0 : tabViewportWidth
        if abs(readerTabsHosting.rootView.trailingGap - nativeGap) > 0.5 {
            readerTabsHosting.rootView.trailingGap = nativeGap
        }
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


    static func toolbarSymbol(_ name: String, accessibilityDescription: String?) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
    }

    private func makeMessageItem(
        identifier: NSToolbarItem.Identifier,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        // Let NSToolbar create the control: AppKit owns adaptive symbol size,
        // hit target, focus, hover, pressed state, and inter-item spacing.
        item.action = action
        item.target = self
        item.isBordered = true
        item.autovalidates = true
        item.visibilityPriority = .high
        return item
    }

    private func makeOverflowItem() -> NSMenuToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: .messageOverflow)
        item.menu = overflowMenu
        item.image = Self.toolbarSymbol(
            "ellipsis",
            accessibilityDescription: "More message actions"
        )
        item.label = "More"
        item.paletteLabel = "More"
        item.toolTip = "More message actions"
        item.isBordered = true
        item.isEnabled = !readerMessageSelection.isEmpty
        item.autovalidates = false
        item.showsIndicator = false
        item.visibilityPriority = .high
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


    @objc private func trashSelected(_ sender: Any?) {
        model.perform(.trash, on: readerMessageSelection)
    }


    @objc private func toggleSidebar(_ sender: Any?) {
        toggleAction()
    }

    @objc private func archiveSelected(_ sender: Any?) {
        model.perform(.archive, on: readerMessageSelection)
    }

    @objc private func toggleRawSource(_ sender: Any?) {
        guard readerMessageSelection.count == 1 else { return }
        model.toggleRawSource()
    }

    @objc private func toggleEmailReadingOverride(_ sender: Any?) {
        guard readerMessageSelection.count == 1 else { return }
        model.toggleEmailReadingOverride()
    }

    @objc private func performOverflowAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MessageContextMenuPolicy.Action else {
            return
        }
        let selection = readerMessageSelection
        guard !selection.isEmpty else { return }
        switch action {
        case .openInNewTab:
            model.openMessages(Array(selection), permanent: true)
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
        case .markRead, .markUnread:
            model.perform(.toggleRead, on: selection)
        case .moveToJunk:
            guard let junk = model.folders.first(where: { $0.role == .junk }) else { return }
            model.move(ids: selection, to: junk.id)
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
    private var readerInteractionModel: AppModel?
    private var readerInteractionMonitor: Any?
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
            self.window = window
            MainWindowStartupConfiguration.attach(shell, to: window)
            shellLaunchPhase("shell-window-attached")
        }

        guard let window else { return }
        readerInteractionModel = model
        installReaderInteractionMonitor(for: window)
        if !didScheduleFirstFrame {
            didScheduleFirstFrame = true
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak window, model] in
                guard let self, let window, self.window === window else { return }
                QALaunch.launchPhase("first-frame")
                guard let shell = self.shell, self.toolbarController == nil else {
                    self.scheduleSettledFrameIfReady()
                    return
                }
                self.installToolbar(
                    for: model,
                    shell: shell,
                    in: window
                )
                self.scheduleSettledFrameIfReady()
            }
            window.makeKeyAndOrderFront(nil)
            CATransaction.commit()
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        QALaunch.launchPhase("window-front")
        scheduleSettledFrameIfReady()
    }
    /// Restore focus to a real, stable native view after a tab replacement.
    func focusReader() {
        guard let window, window === NSApp.keyWindow,
              let contentView = window.contentView,
              let anchor = MessageViewer.focusAnchor(in: contentView),
              window.makeFirstResponder(anchor) else { return }
        readerInteractionModel?.noteReaderInteraction()
    }

    func focusMessageList() {
        guard let window, window === NSApp.keyWindow,
              let contentView = window.contentView,
              let table = Self.findView(
                  withAccessibilityIdentifier: UIIdentifier.messageTable,
                  in: contentView
              ),
              window.makeFirstResponder(table) else { return }
        readerInteractionModel?.noteListInteraction()
    }

    /// Native text/WebKit responders and toolbar hosts are tested against
    /// visible pane bounds; the geometry anchor is a sibling, not an ancestor.
    func isReaderFocused(in window: NSWindow) -> Bool {
        guard window === self.window,
              let contentView = window.contentView,
              let responder = window.firstResponder as? NSView,
              responder.window === window else { return false }
        let frame = responder.convert(responder.visibleRect, to: contentView)
        guard !frame.isEmpty else { return false }
        if let reader = MessageViewer.focusAnchor(in: contentView),
           reader.convert(reader.bounds, to: contentView).contains(frame) {
            return true
        }
        return toolbarController?.readerTabsFrame(in: contentView)?.contains(frame) == true
    }

    private func installReaderInteractionMonitor(for window: NSWindow) {
        guard readerInteractionMonitor == nil else { return }
        readerInteractionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak window] event in
            guard let self,
                  let window,
                  event.window === window,
                  let contentView = window.contentView else {
                return event
            }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let readerFrame = MessageViewer.focusAnchor(in: contentView).map {
                $0.convert($0.bounds, to: contentView)
            }
            let tabFrame = self.toolbarController?.readerTabsFrame(in: contentView)
            if readerFrame?.contains(point) == true || tabFrame?.contains(point) == true {
                self.readerInteractionModel?.noteReaderInteraction()
            } else if Self.frame(
                of: UIIdentifier.messageTable,
                in: contentView
            )?.contains(point) == true || Self.frame(
                of: UIIdentifier.sidebar,
                in: contentView
            )?.contains(point) == true {
                self.readerInteractionModel?.noteListInteraction()
            }
            return event
        }
    }

    private static func frame(of identifier: String, in view: NSView) -> CGRect? {
        guard let target = findView(
            withAccessibilityIdentifier: identifier,
            in: view
        ) else {
            return nil
        }
        let frame = target.convert(target.bounds, to: view)
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private static func findView(
        withAccessibilityIdentifier identifier: String,
        in view: NSView
    ) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews.reversed() {
            if let match = findView(
                withAccessibilityIdentifier: identifier,
                in: subview
            ) {
                return match
            }
        }
        return nil
    }




    private func installToolbar(
        for model: AppModel,
        shell: MainShellViewController,
        in window: NSWindow
    ) {
        shellLaunchPhase("shell-toolbar-controller-begin")
        let toolbarController = MainToolbarController(
            model: model,
            toggleAction: { [weak shell] in shell?.toggleSidebar(nil) }
        )
        self.toolbarController = toolbarController
        shellLaunchPhase("shell-toolbar-controller-ready")
        window.toolbar = toolbarController.makeToolbar()
        shellLaunchPhase("shell-toolbar-install-end")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}
