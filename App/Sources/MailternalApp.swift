import AppKit
import SwiftUI
import MailternalInterfaces

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
            CommandGroup(replacing: .newItem) {}
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
                Picker("Tab Style", selection: $appearance.tabStyle) {
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

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let qa = QALaunch.parse(), qa.openWindowLink == nil,
           !ProcessInfo.processInfo.arguments.contains("-qa-gui") {
            // SSH/headless: no WindowServer. Don't activate a UI session.
            NSApp.setActivationPolicy(.prohibited)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
        #else
        NSApp.setActivationPolicy(.regular)
        #endif
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
        #if DEBUG
        if let qa = QALaunch.parse(), qa.openWindowLink == nil,
           !ProcessInfo.processInfo.arguments.contains("-qa-gui") {
            // SwiftUI `.task` on MainSplitRoot may never fire without a rendered
            // window. Drive restore/engine from the delegate instead.
            QALaunch.log(
                "headless launch pid=\(ProcessInfo.processInfo.processIdentifier) footprint=\(QALaunch.footprintBytes())"
            )
            model?.start()
            if let count = QALaunch.parse()?.benchSelectCount {
                model?.runQABenchSelect(count: count)
            }
            openQAMessageWindowIfRequested()
            return
        }
        #endif
        showMainWindow()
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
        guard let model, let appearance, let actions else { return }
        QALaunch.launchPhase("shell-show-begin")
        MainWindowController.shared.show(model: model, appearance: appearance, actions: actions)
        QALaunch.launchPhase("shell-show-end")
    }

    func toggleSidebar() {
        guard let model else { return }
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
