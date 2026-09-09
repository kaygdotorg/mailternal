import AppKit
import SwiftUI
import MailternalInterfaces

/// Arguments consumed by the bundled app when it is launched as the local
/// automation engine. They intentionally use a separate namespace from QA
/// switches so a normal GUI launch cannot accidentally become headless.
enum MailternalLaunchOptions {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static var isHeadlessEngine: Bool {
        arguments.contains("--mailternal-engine")
    }

    static var containerURL: URL? {
        guard let index = arguments.firstIndex(of: "--mailternal-container"),
              arguments.indices.contains(arguments.index(after: index))
        else { return nil }
        let raw = arguments[arguments.index(after: index)]
        guard !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }
}

@main
struct MailternalApp: App {
    @NSApplicationDelegateAdaptor(MailternalAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var appearance: AppearanceSettings
    @State private var actions: ActionSettings

    init() {
        QALaunch.launchPhase("app-init")
        let appearance = AppearanceSettings()
        let actions = ActionSettings()
        let model = AppModel(facade: Self.makeFacade(), appearance: appearance, actions: actions)
        _appearance = State(initialValue: appearance)
        _actions = State(initialValue: actions)
        _model = State(initialValue: model)
        MailternalAppDelegate.bootstrap(model: model, appearance: appearance, actions: actions)
    }

    private static func makeFacade() -> any MailFacade {
        if ProcessInfo.processInfo.arguments.contains("-mock") {
            return MockMailFacade()
        }
        do {
            let qaConfig = QALaunch.parse()
            if let qa = try QALaunch.makeFacade(qaConfig) {
                QALaunch.log("live facade container=\(qaConfig?.containerRoot.path ?? "")")
                return qa
            }
            if let containerURL = MailternalLaunchOptions.containerURL {
                QALaunch.log("headless engine container=\(containerURL.path)")
                return try LiveMailFacade(
                    container: MailternalContainer(root: containerURL),
                    enableNotifications: false
                )
            }
            return try LiveMailFacade()
        } catch {
            fatalError("Could not open the Mailternal store: \(error)")
        }
    }
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") {
                    let account = model.folders.first { $0.id == model.selectedFolderID }?.accountID
                    Task { await model.composer.newMessage(preferredAccountID: account) }
                }
                .keyboardShortcut("n")
                .disabled(model.accountConfigs.isEmpty || model.composer.isOpening)
                Button("Drafts & Outbox") {
                    Task { await model.composer.showLibrary() }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.accountConfigs.isEmpty)
            }
            CommandGroup(after: .textEditing) {
                Button("Find in Message") {
                    appDelegate.showMainWindow()
                    model.toggleFind()
                }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.detail == nil)
                Button("Search Mail") {
                    appDelegate.showMainWindow()
                    model.toggleSearch()
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!model.isAccountActive)
            }
            CommandGroup(after: .sidebar) {
                Button(SidebarVisibilityPolicy.isHidden(model.columnVisibility) ? "Show Sidebar" : "Hide Sidebar") {
                    appDelegate.toggleSidebar()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Menu("Layout") {
                    Picker("Edit", selection: Binding(
                        get: { model.listCustomizationTarget },
                        set: { model.setListCustomizationTarget($0) }
                    )) {
                        ForEach(MailListCustomizationTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .disabled(!model.canCustomizeCurrentFolder)
                    Divider()
                    Picker("Presentation", selection: Binding(
                        get: {
                            model.listCustomizationTarget == .global
                                ? model.globalListConfiguration.presentation
                                : model.effectiveListConfiguration.presentation
                        },
                        set: { model.setListPresentation($0) }
                    )) {
                        Text("Cards").tag(MailListPresentation.cards)
                        Text("Columns").tag(MailListPresentation.columns)
                    }
                    Picker("Pane", selection: Binding(
                        get: {
                            model.listCustomizationTarget == .global
                                ? model.globalListConfiguration.paneLayout
                                : model.effectiveListConfiguration.paneLayout
                        },
                        set: { model.setPaneLayout($0) }
                    )) {
                        Text("Side by Side").tag(MailPaneLayout.sideBySide)
                        Text("List Above Reader").tag(MailPaneLayout.listAboveReader)
                    }
                    Divider()
                    Button("Reset Current Folder Overrides") {
                        model.resetListOverrides()
                    }
                    .disabled(!model.canCustomizeCurrentFolder)
                    Button("Reset All-Folder Defaults") {
                        model.resetGlobalListSettings()
                    }
                }
                Menu("Columns") {
                    Picker("Edit", selection: Binding(
                        get: { model.listCustomizationTarget },
                        set: { model.setListCustomizationTarget($0) }
                    )) {
                        ForEach(MailListCustomizationTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    Divider()
                    ForEach(MailListColumn.allCases, id: \.self) { column in
                        Toggle(column.title, isOn: Binding(
                            get: {
                                !(model.listCustomizationTarget == .global
                                    ? model.globalListConfiguration.hiddenColumns
                                    : model.effectiveListConfiguration.hiddenColumns).contains(column)
                            },
                            set: { model.setListColumnVisible(column, visible: $0) }
                        ))
                    }
                    Divider()
                    Button("Reset Current Folder Overrides") {
                        model.resetListOverrides()
                    }
                    .disabled(!model.canCustomizeCurrentFolder)
                    Button("Reset All-Folder Defaults") {
                        model.resetGlobalListSettings()
                    }
                }
                Button("Refresh") {
                    appDelegate.showMainWindow()
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isAccountActive)
                Button("Source") {
                    appDelegate.showMainWindow()
                    model.toggleRawSource()
                }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(model.selectedMessageIDs.count != 1)
                Button("Email Colour Scheme") {
                    appDelegate.showMainWindow()
                    model.toggleEmailReadingOverride()
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model.selectedMessageIDs.count != 1)
                Picker("Tab Style", selection: Binding(
                    get: { appearance.tabStyle },
                    set: { style in
                        model.dispatchFromUI(.setSetting(AutomationPreferences.Keys.tabStyle, style.rawValue))
                    }
                )) {
                    ForEach(ReaderTabStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Close Tab") {
                    model.closeActiveTabOrWindow()
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Next Tab") {
                    appDelegate.showMainWindow()
                    model.activateNextTab()
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model.tabs.tabs.count < 2)
                Button("Previous Tab") {
                    appDelegate.showMainWindow()
                    model.activatePreviousTab()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model.tabs.tabs.count < 2)
                Button("Previous Tab") {
                    appDelegate.showMainWindow()
                    model.activatePreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.tabs.tabs.count < 2)
                Button("Next Tab") {
                    appDelegate.showMainWindow()
                    model.activateNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.tabs.tabs.count < 2)
            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
@MainActor
final class MailternalAppDelegate: NSObject, NSApplicationDelegate {
    private static var pendingModel: AppModel?
    private static var pendingAppearance: AppearanceSettings?
    private static var pendingActions: ActionSettings?

    private var model: AppModel?
    private var appearance: AppearanceSettings?
    private var actions: ActionSettings?

    static func bootstrap(model: AppModel, appearance: AppearanceSettings, actions: ActionSettings) {
        pendingModel = model
        pendingAppearance = appearance
        pendingActions = actions
    }

    private var isHeadlessLaunch: Bool {
        if MailternalLaunchOptions.isHeadlessEngine { return true }
        #if DEBUG
        if let qa = QALaunch.parse(), qa.openWindowLink == nil,
           !ProcessInfo.processInfo.arguments.contains("-qa-gui") {
            return true
        }
        #endif
        return false
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // An engine is a real app runtime without a UI session. In particular,
        // never call activateIgnoringOtherApps or construct a window here.
        NSApp.setActivationPolicy(isHeadlessLaunch ? .prohibited : .regular)
        if let model = Self.pendingModel,
           let appearance = Self.pendingAppearance,
           let actions = Self.pendingActions {
            self.model = model
            self.appearance = appearance
            self.actions = actions
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        QALaunch.launchPhase("did-finish-launching")
        QAInteractionProfile.installIfRequested()
        if isHeadlessLaunch {
            QALaunch.log(
                "headless launch pid=\(ProcessInfo.processInfo.processIdentifier) footprint=\(QALaunch.footprintBytes())"
            )
            model?.start()
            // Start the authenticated listener before clients issue their first
            // request, while leaving all window construction on the GUI path.
            model?.startAutomation()
            #if DEBUG
            if let count = QALaunch.parse()?.benchSelectCount {
                model?.runQABenchSelect(count: count)
            }
            if !MailternalLaunchOptions.isHeadlessEngine {
                openQAMessageWindowIfRequested()
            }
            #endif
            return
        }
        showMainWindow()
        model?.startAutomation()
        #if DEBUG
        openQAMessageWindowIfRequested()
        #endif
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.workspaceSync.didBecomeActive()
    }

    func applicationWillResignActive(_ notification: Notification) {
        model?.workspaceSync.willResignActive()
    }


    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isHeadlessLaunch else { return false }
        showMainWindow()
        return true
    }
    /// The sole platform entry point for deep links. AppModel owns parsing and
    /// queues the typed destination until account and folders are ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let model else { return }
        for url in urls {
            model.openURL(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let live = model?.facade as? LiveMailFacade else {
            return .terminateNow
        }
        Task {
            await live.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func showMainWindow() {
        guard !isHeadlessLaunch,
              let model, let appearance, let actions
        else { return }
        QALaunch.launchPhase("shell-show-begin")
        MainWindowController.shared.show(model: model, appearance: appearance, actions: actions)
        QALaunch.launchPhase("shell-show-end")
    }

    func toggleSidebar() {
        guard !isHeadlessLaunch, let model else { return }
        showMainWindow()
        model.toggleSidebar()
    }

    #if DEBUG
    private func openQAMessageWindowIfRequested() {
        guard let link = QALaunch.parse()?.openWindowLink else { return }
        Task { @MainActor [weak self] in
            guard let self, let model else { return }
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !model.isAccountActive, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard model.isAccountActive else {
                QALaunch.log("qa-open-window unavailable reason=account-inactive")
                return
            }
            do {
                guard let resolution = try await model.facade.resolve(link),
                      case .message(_, let messageID, _) = resolution else {
                    QALaunch.log("qa-open-window unavailable reason=message-not-found")
                    return
                }
                model.openMessageWindow(messageID)
            } catch {
                QALaunch.log("qa-open-window unavailable reason=\(error.localizedDescription)")
            }
        }
    }
    #endif
}
