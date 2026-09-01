import AppKit
import SwiftUI
import MailternalInterfaces

@main
struct MailternalApp: App {
    @NSApplicationDelegateAdaptor(MailternalAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var appearance: AppearanceSettings

    init() {
        let appearance = AppearanceSettings()
        let model = AppModel(facade: Self.makeFacade(), appearance: appearance)
        _appearance = State(initialValue: appearance)
        _model = State(initialValue: model)
        MailternalAppDelegate.bootstrap(model: model, appearance: appearance)
    }

    private static func makeFacade() -> any MailFacade {
        if ProcessInfo.processInfo.arguments.contains("-mock") {
            return MockMailFacade()
        }
        do {
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

    private var model: AppModel?
    private var appearance: AppearanceSettings?

    static func bootstrap(model: AppModel, appearance: AppearanceSettings) {
        pendingModel = model
        pendingAppearance = appearance
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let model = Self.pendingModel, let appearance = Self.pendingAppearance {
            self.model = model
            self.appearance = appearance
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        showMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
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
        guard let model, let appearance else { return }
        MainWindowController.shared.show(model: model, appearance: appearance)
    }
}
