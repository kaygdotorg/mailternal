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
            #if DEBUG
            if let qa = try QALaunch.makeFacade() {
                QALaunch.log("live facade container=\(QALaunch.parse()?.containerRoot.path ?? "")")
                return qa
            }
            #endif
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
                Button("Refresh") {
                    appDelegate.showMainWindow()
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isAccountActive)
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
        if QALaunch.parse() != nil {
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
        #if DEBUG
        if QALaunch.parse() != nil {
            // SwiftUI `.task` on MainSplitRoot may never fire without a rendered
            // window. Drive restore/engine from the delegate instead.
            QALaunch.log(
                "headless launch pid=\(ProcessInfo.processInfo.processIdentifier) footprint=\(QALaunch.footprintBytes())"
            )
            model?.start()
            if let count = QALaunch.parse()?.benchSelectCount {
                model?.runQABenchSelect(count: count)
            }
            return
        }
        #endif
        showMainWindow()
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
        MainWindowController.shared.show(model: model, appearance: appearance, actions: actions)
    }
}
