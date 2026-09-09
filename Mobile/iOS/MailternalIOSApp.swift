import SwiftUI
import MailternalInterfaces
import MailternalAutomation

@main
@MainActor
struct MailternalIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var state: IOSAppState?
    @State private var bootstrapError: String?
    @State private var lifecycle = IOSSceneLifecycleCoordinator()

    init() {
        QALaunch.launchPhase("app-init")
        let container = MailternalContainer.default
        let root = container.root.appendingPathComponent("iOS", isDirectory: true)
        let commandURL = root.appendingPathComponent("commands.json")
        let stateURL = root.appendingPathComponent("ui-state.json")
        do {
            let qaConfig = QALaunch.parse()
            let facade: LiveMailFacade
            if let qa = try QALaunch.makeFacade(qaConfig) {
                QALaunch.log("live facade container=\(qaConfig?.containerRoot.path ?? "")")
                facade = qa
            } else {
                facade = try LiveMailFacade(container: container, enableNotifications: true)
            }
            let appState = IOSAppState(facade: facade, commandURL: commandURL, stateURL: stateURL)
            let companion = PhoneCompanionSession(
                facade: facade,
                storageURL: root.appendingPathComponent("companion.json"),
                onOpenMessage: { [weak appState] link in
                    guard let appState else { return false }
                    return await appState.openDeepLink(link)
                },
                onCommand: { [weak appState] command in
                    guard let appState else {
                        throw AutomationCommandError.appUnavailable
                    }
                    return try await appState.dispatcher.submit(command, origin: .watch)
                }
            )
            appState.attachCompanion(companion)
            _state = State(initialValue: appState)
            _bootstrapError = State(initialValue: nil)
        } catch {
            _state = State(initialValue: nil)
            _bootstrapError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let state {
                    IOSRootView(state: state)
                        .task { await state.start() }
                        .onOpenURL { url in
                            Task { _ = await state.openDeepLink(url.absoluteString) }
                        }
                } else {
                    IOSLaunchFailureView(message: bootstrapError ?? "Mailternal could not start.")
                }
            }
            .tint(.accentColor)
        }
        .onChange(of: scenePhase) { _, phase in
            guard let state,
                  let live = state.facade as? LiveMailFacade else { return }
            lifecycle.enqueue(phase, state: state, facade: live)
        }
    }
}

@MainActor
private final class IOSSceneLifecycleCoordinator {
    private var tail: Task<Void, Never>?

    func enqueue(_ phase: ScenePhase, state: IOSAppState, facade: LiveMailFacade) {
        let predecessor = tail
        tail = Task { @MainActor in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            switch phase {
            case .background:
                await facade.applicationDidEnterBackground()
            case .active:
                await facade.applicationWillEnterForeground()
                await state.resumeFromInactive()
            default:
                break
            }
        }
    }
}

private struct IOSLaunchFailureView: View {
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label("Mailternal couldn’t start", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Text("Try closing and reopening the app.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
