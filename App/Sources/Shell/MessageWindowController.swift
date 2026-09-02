import AppKit
import SwiftUI
import MailternalInterfaces

/// Owns the independent reader windows opened from the message list.
///
/// Each reader gets a small model backed by the same facade as the main
/// window. This keeps its detail, find state, and remote-image policy
/// independent while allowing the window to outlive the main window.
@MainActor
final class MessageWindowController: NSObject, NSWindowDelegate {
    static let shared = MessageWindowController()

    private var windows: [MessageID: NSWindow] = [:]

    private override init() {
        super.init()
    }

    func show(
        messageID: MessageID,
        model: AppModel,
        title: String? = nil
    ) {
        if let window = windows[messageID] {
            if let title, !title.isEmpty {
                window.title = title
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let readerModel = AppModel(
            facade: model.facade,
            appearance: model.appearance,
            actions: model.actions
        )
        let shell = MessageWindowShellViewController(
            model: readerModel,
            messageID: messageID,
            titleChanged: { [weak self] subject in
                self?.updateTitle(subject, for: messageID)
            }
        )
        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: MessageWindowStartupConfiguration.defaultContentSize
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView,
            ],
            backing: .buffered,
            defer: false
        )
        MessageWindowStartupConfiguration.prepare(window)
        window.delegate = self
        window.title = title ?? ""
        let toolbar = NSToolbar(identifier: "Mailternal.MessageToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.contentViewController = shell
        window.setContentSize(MessageWindowStartupConfiguration.defaultContentSize)
        window.center()

        windows[messageID] = window
        readerModel.selectMessage(messageID)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let messageID = windows.first(where: { $0.value === window })?.key {
            windows.removeValue(forKey: messageID)
        }
    }

    private func updateTitle(_ subject: String, for messageID: MessageID) {
        guard let window = windows[messageID] else { return }
        window.title = subject
    }
}

@MainActor
private enum MessageWindowStartupConfiguration {
    static let defaultContentSize = NSSize(width: 720, height: 640)
    static let minimumContentSize = NSSize(width: 480, height: 400)
    static func prepare(_ window: NSWindow) {
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = minimumContentSize
    }
}

@MainActor
private final class MessageWindowShellViewController: NSViewController {
    private let model: AppModel
    private let contentHosting: NSHostingController<MessageWindowRoot>
    private var backgroundHosting: NSHostingView<WindowBackdropRoot>?

    init(
        model: AppModel,
        messageID: MessageID,
        titleChanged: @escaping (String) -> Void
    ) {
        self.model = model
        contentHosting = NSHostingController(
            rootView: MessageWindowRoot(
                model: model,
                messageID: messageID,
                titleChanged: titleChanged
            )
        )
        super.init(nibName: nil, bundle: nil)
        contentHosting.sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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

        let background = NSHostingView(
            rootView: WindowBackdropRoot(appearance: model.appearance)
        )
        background.safeAreaRegions = []
        background.sizingOptions = []
        background.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(background, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.topAnchor.constraint(equalTo: view.topAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backgroundHosting = background
    }
}

private struct MessageWindowRoot: View {
    @Bindable var model: AppModel
    let messageID: MessageID
    let titleChanged: (String) -> Void

    var body: some View {
        MessageViewer(model: model)
            .onAppear {
                publishTitle()
            }
            .onChange(of: model.detail?.id) { _, _ in
                publishTitle()
            }
            .tint(model.appearance.accent.color)
            .environment(model.appearance.accent)
            .environment(model.actions)
            .preferredColorScheme(model.appearance.mode.colorScheme)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func publishTitle() {
        guard model.detail?.id == messageID,
              let subject = model.detail?.envelope.subject else { return }
        titleChanged(subject)
    }
}
