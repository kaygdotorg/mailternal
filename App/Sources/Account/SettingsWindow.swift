import AppKit
import SwiftUI
import MailternalInterfaces

enum SettingsSection: String, CaseIterable, Identifiable {
    case account, appearance

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Account"
        case .appearance: "Appearance"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "at"
        case .appearance: "paintbrush"
        }
    }
}

struct SettingsSourceList: View {
    @Binding var selection: SettingsSection?
    let appearance: AppearanceSettings

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled(true)
        .tint(appearance.accent.color)
        .environment(appearance.accent)
        .padding(.top, 46)
    }
}

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var model: AppModel
    let appearance: AppearanceSettings

    var body: some View {
        Group {
            switch section {
            case .account:
                AccountSetupForm(model: model)
            case .appearance:
                AppearanceSettingsForm(appearance: appearance)
            }
        }
        .tint(appearance.accent.color)
        .environment(appearance.accent)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AccountSetupForm: View {
    @Bindable var model: AppModel
    @State private var presetName: String = "Custom"
    @State private var displayName = ""
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var security: IMAPEndpoint.Security = .implicitTLS
    @State private var fieldError: String?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $presetName) {
                    Text("Custom IMAP").tag("Custom")
                    ForEach(ProviderPresets.all) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .onChange(of: presetName) { _, name in
                    applyPreset(named: name)
                }
                if let preset = ProviderPresets.all.first(where: { $0.name == presetName }) {
                    Text(preset.guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Account") {
                TextField("Display Name", text: $displayName)
                    .accessibilityIdentifier(UIIdentifier.setupDisplayName)
                TextField("Email Address", text: $email)
                    .textContentType(.username)
                    .accessibilityIdentifier(UIIdentifier.setupEmail)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .accessibilityIdentifier(UIIdentifier.setupUsername)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier(UIIdentifier.setupPassword)
            }

            Section("IMAP") {
                TextField("Host", text: $host)
                    .accessibilityIdentifier(UIIdentifier.setupHost)
                TextField("Port", text: $port)
                    .accessibilityIdentifier(UIIdentifier.setupPort)
                Picker("Security", selection: Binding(
                    get: { security.rawValue },
                    set: { security = IMAPEndpoint.Security(rawValue: $0) ?? .implicitTLS }
                )) {
                    Text("SSL/TLS").tag(IMAPEndpoint.Security.implicitTLS.rawValue)
                    Text("STARTTLS").tag(IMAPEndpoint.Security.startTLS.rawValue)
                }
                Text("Transport is implicit TLS or mandatory STARTTLS. There is no insecure fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                statusRow
                HStack {
                    Button("Sign In") {
                        Task { await submit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    if case .active = model.accountState {
                        Button("Remove Account", role: .destructive) {
                            Task { try? await model.facade.removeAccount() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled({
            if case .validating = model.accountState { return true }
            return false
        }())
        .onAppear {
            if displayName.isEmpty { displayName = NSFullUserName() }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch model.accountState {
        case .none:
            if let fieldError {
                Label(fieldError, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
        case .validating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the server…")
                    .foregroundStyle(.secondary)
            }
        case .active:
            Label("Account is active.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .authFailed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .connectionFailed(let message):
            Label(message, systemImage: "wifi.slash")
                .foregroundStyle(.red)
        }
    }

    private var canSubmit: Bool {
        if case .validating = model.accountState { return false }
        return !host.isEmpty && !username.isEmpty && !password.isEmpty && Int(port) != nil
    }

    private func applyPreset(named name: String) {
        guard let preset = ProviderPresets.all.first(where: { $0.name == name }) else { return }
        host = preset.host
        port = String(preset.port)
        security = preset.security
        if username.isEmpty { username = email }
    }

    private func submit() async {
        fieldError = nil
        guard let portNumber = Int(port), (1...65_535).contains(portNumber) else {
            fieldError = "Enter a port between 1 and 65535."
            return
        }
        guard !host.isEmpty else {
            fieldError = "Enter an IMAP host."
            return
        }
        guard !username.isEmpty else {
            fieldError = "Enter a username."
            return
        }
        let config = AccountConfig(
            id: AccountID(rawValue: "account-1"),
            accountLinkID: .random(),
            displayName: displayName.isEmpty ? email : displayName,
            emailAddress: email,
            username: username,
            imap: IMAPEndpoint(host: host, port: portNumber, security: security)
        )
        do {
            try await model.facade.addAccount(config, password: password)
            password = ""
        } catch {
            fieldError = error.localizedDescription
        }
    }
}

struct AppearanceSettingsForm: View {
    @Bindable var appearance: AppearanceSettings

    var body: some View {
        Form {
            Section {
                Picker(selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text("Theme")
                    Text("System follows the macOS light or dark setting.")
                }
                Picker(selection: $appearance.emailReadingMode) {
                    ForEach(EmailReadingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    Text("Email Reading")
                    Text("Original keeps each message's colors; Dark keeps the reading canvas dark.")
                }
                .accessibilityIdentifier(UIIdentifier.emailReadingMode)
            }
            Section("Messages") {
                Picker(selection: $appearance.messageListLines) {
                    ForEach(Array(MessageListLayout.lineRange), id: \.self) { lines in
                        Text("\(lines) \(lines == 1 ? "line" : "lines")").tag(lines)
                    }
                } label: {
                    Text("Row lines")
                    Text("One line shows the subject; two adds the sender and date; more adds preview text.")
                }
                .accessibilityIdentifier(UIIdentifier.messageListLines)
            }
            Section {
                LabeledContent {
                    HStack {
                        Slider(
                            value: $appearance.backgroundOpacity,
                            in: AppearanceSettings.backgroundOpacityRange,
                            step: 0.01
                        )
                        .onChange(of: appearance.backgroundOpacity) { _, _ in
                            appearance.persistOpacity()
                        }
                        // Proportional text, in a fixed trailing slot: the
                        // readout keeps its place without monospaced digits.
                        Text(AppearanceSettings.formattedOpacityPercentage(appearance.backgroundOpacity))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                } label: {
                    Text("Opacity")
                    Text("How solid the window is. Lower lets more of the desktop show through; 100% is fully solid.")
                }
                Toggle(isOn: $appearance.usesLiquidGlass) {
                    Text("Liquid Glass")
                    Text("Refracts the desktop behind the window instead of softly blurring it. No visible effect at 100% opacity.")
                }
            } header: {
                Text("Window")
            } footer: {
                Text("The window stays solid in fullscreen, and while Reduce Transparency is on.")
            }
            Section("Accent") {
                Toggle(isOn: Binding(
                    get: { appearance.accent.accentOverride != nil },
                    set: { enabled in
                        if enabled {
                            appearance.accent.accentOverride = AccentColorValue(nsColor: appearance.accent.nsColor)
                        } else {
                            appearance.accent.accentOverride = nil
                        }
                    }
                )) {
                    Text("Use a custom accent")
                    Text(
                        appearance.accent.accentOverride == nil
                            ? "Controls and selection use the macOS accent color."
                            : "Controls and selection use the color below."
                    )
                }
                if appearance.accent.accentOverride != nil {
                    ColorPicker(
                        "Color",
                        selection: Binding(
                            get: { appearance.accent.color },
                            set: { color in
                                appearance.accent.accentOverride = AccentColorValue(nsColor: NSColor(color))
                            }
                        ),
                        supportsOpacity: false
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class SettingsSplitController: NSSplitViewController {
    private let sidebarHosting: NSHostingController<SettingsSourceList>
    private let detailHosting: NSHostingController<SettingsDetailView>
    private let sidebarItem: NSSplitViewItem
    private var backgroundEffect: NSVisualEffectView?
    private var didSetDivider = false

    init(model: AppModel, appearance: AppearanceSettings, selection: Binding<SettingsSection?>) {
        sidebarHosting = NSHostingController(
            rootView: SettingsSourceList(selection: selection, appearance: appearance)
        )
        detailHosting = NSHostingController(
            rootView: SettingsDetailView(
                section: selection.wrappedValue ?? .account,
                model: model,
                appearance: appearance
            )
        )
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 150

        sidebarItem.maximumThickness = 280
        sidebarItem.titlebarSeparatorStyle = .none
        super.init(nibName: nil, bundle: nil)
        sidebarHosting.safeAreaRegions = []
        detailHosting.safeAreaRegions = []
        addSplitViewItem(sidebarItem)
        let detailItem = NSSplitViewItem(viewController: detailHosting)
        detailItem.minimumThickness = 480
        addSplitViewItem(detailItem)
        splitView.isVertical = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(model: AppModel, appearance: AppearanceSettings, selection: Binding<SettingsSection?>) {
        sidebarHosting.rootView = SettingsSourceList(selection: selection, appearance: appearance)
        detailHosting.rootView = SettingsDetailView(
            section: selection.wrappedValue ?? .account,
            model: model,
            appearance: appearance
        )
        configureWindow()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindow()
        if !didSetDivider {
            splitView.setPosition(172, ofDividerAt: 0)
            didSetDivider = true
        }
    }

    private func configureWindow() {
        guard let window = view.window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        splitView.dividerStyle = .thin
        if backgroundEffect == nil {
            let effect = NSVisualEffectView(frame: splitView.bounds)
            effect.material = .underWindowBackground
            effect.blendingMode = .behindWindow
            effect.state = .followsWindowActiveState
            effect.autoresizingMask = [.width, .height]
            splitView.addSubview(effect, positioned: .below, relativeTo: nil)
            backgroundEffect = effect
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var selection: SettingsSection? = .account {
        didSet {
            guard oldValue != selection else { return }
            refresh()
        }
    }
    private var split: SettingsSplitController?
    private var model: AppModel?
    private var appearance: AppearanceSettings?
    private var hasShown = false

    private init() { super.init(window: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(model: AppModel, appearance: AppearanceSettings) {
        self.model = model
        self.appearance = appearance
        if case .none = model.accountState {
            selection = .account
        }
        if let split {
            split.update(model: model, appearance: appearance, selection: selectionBinding)
        } else {
            let split = SettingsSplitController(model: model, appearance: appearance, selection: selectionBinding)
            self.split = split
            split.preferredContentSize = NSSize(width: 720, height: 460)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = split
            window.title = ""
            window.setAccessibilityIdentifier(UIIdentifier.settingsWindow)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.toolbar = NSToolbar(identifier: "Mailternal.SettingsToolbar")
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.setAccessibilitySubrole(.floatingWindow)
            window.contentMinSize = NSSize(width: 660, height: 460)
            window.setContentSize(NSSize(width: 720, height: 460))
            self.window = window
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            if !hasShown {
                hasShown = true
                Task { @MainActor [weak window] in
                    await Task.yield()
                    window?.setContentSize(NSSize(width: 720, height: 460))
                    window?.center()
                }
            }
        }
        NSApp.activate()
    }

    private func refresh() {
        guard let split, let model, let appearance else { return }
        split.update(model: model, appearance: appearance, selection: selectionBinding)
    }

    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { [weak self] in self?.selection },
            set: { [weak self] value in self?.selection = value }
        )
    }
}
