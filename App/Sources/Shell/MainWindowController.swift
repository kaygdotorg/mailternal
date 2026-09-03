import AppKit
import Observation
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
        configureTransparentHostingView(contentHosting.view)
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
        configureTransparentHostingView(hosting)
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.addSubview(hosting, positioned: .below, relativeTo: nil)
        backgroundHosting = hosting
    }

    private func configureTransparentHostingView(_ hosting: NSView) {
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = nil
        hosting.layer?.isOpaque = false
    }

}

private extension NSToolbarItem.Identifier {
    static let sidebarToggle = NSToolbarItem.Identifier("Mailternal.sidebarToggle")
}

@MainActor
final class MainToolbarController: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    private var model: AppModel
    private var modelObservationGeneration: UInt64 = 0
    private let includesSidebarToggle: Bool
    private let toggleAction: @MainActor () -> Void
    private weak var toolbar: NSToolbar?
    private lazy var toggleItem = makeToggleItem()

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
        toolbar?.validateVisibleItems()
    }

    private func observeModelChanges() {
        let generation = modelObservationGeneration
        withObservationTracking {
            _ = model.isSearchPresented
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.modelObservationGeneration == generation else { return }
                self.toolbar?.validateVisibleItems()
                self.observeModelChanges()
            }
        }
    }

    func makeToolbar(identifier: String = "Mailternal.MainToolbar") -> NSToolbar {
        let toolbar = NSToolbar(identifier: identifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = false
        self.toolbar = toolbar
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        guard includesSidebarToggle else { return [] }
        return [.flexibleSpace, .sidebarToggle, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace, .space]
        if includesSidebarToggle {
            identifiers += [.sidebarToggle, .sidebarTrackingSeparator]
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
        guard identifier == .sidebarToggle, includesSidebarToggle else { return nil }
        return toggleItem
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.itemIdentifier == .sidebarToggle else { return item.isEnabled }
        item.isHidden = !includesSidebarToggle || model.isSearchPresented
        item.isEnabled = includesSidebarToggle && !model.isSearchPresented
        return item.isEnabled
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

    @objc private func toggleSidebar(_ sender: Any?) {
        toggleAction()
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
        var toolbarToInstall: MainToolbarController?
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
            self.window = window
            MainWindowStartupConfiguration.attach(shell, to: window)
            toolbarToInstall = toolbarController
        }

        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        #if DEBUG
        QALaunch.launchPhase("window-front")
        #endif

        // The shell is already attached when the window fronts. Install the
        // toolbar on the next main-actor turn so its native setup cannot delay
        // the first visible frame.
        if let toolbarToInstall {
            Task { @MainActor [weak self, weak window, toolbarToInstall] in
                guard let self, let window, self.window === window else { return }
                window.toolbar = toolbarToInstall.makeToolbar()
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}
