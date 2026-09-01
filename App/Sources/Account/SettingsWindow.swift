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
    let accentColor: Color

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .tint(accentColor)
        .padding(.top, 46)
    }
}

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var model: AppModel
    let appearance: AppearanceSettings
    let accentColor: Color

    var body: some View {
        Group {
            switch section {
            case .account:
                AccountSetupForm(model: model)
            case .appearance:
                AppearanceSettingsForm(appearance: appearance)
            }
        }
        .tint(accentColor)
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
                TextField("Email Address", text: $email)
                    .textContentType(.username)
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.password)
            }

            Section("IMAP") {
                TextField("Host", text: $host)
                TextField("Port", text: $port)
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
            Section("Theme") {
                Picker("Appearance", selection: $appearance.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
            Section("Window") {
                Picker("Backdrop", selection: $appearance.backdropKind) {
                    ForEach(WindowBackdropKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Slider(value: $appearance.backgroundOpacity, in: 0.4...1, step: 0.01) {
                    Text("Opacity")
                } minimumValueLabel: {
                    Text("40%")
                } maximumValueLabel: {
                    Text("100%")
                }
                .disabled(appearance.backdropKind == .opaque)
                .onChange(of: appearance.backgroundOpacity) { _, _ in
                    appearance.persistOpacity()
                }
                Text("Opaque is the default. Blur uses NSVisualEffectView. Liquid Glass is optional. Reduce Transparency and fullscreen always force opaque.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Accent") {
                Toggle("Use a custom accent", isOn: Binding(
                    get: { appearance.accentOverride != nil },
                    set: { enabled in
                        if enabled {
                            appearance.accentOverride = AccentColorValue(nsColor: .controlAccentColor)
                        } else {
                            appearance.accentOverride = nil
                        }
                    }
                ))
                if appearance.accentOverride != nil {
                    ColorPicker(
                        "Accent Color",
                        selection: Binding(
                            get: { Color(nsColor: appearance.effectiveAccentColor) },
                            set: { color in
                                appearance.accentOverride = AccentColorValue(nsColor: NSColor(color))
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
        let accent = Color(nsColor: appearance.effectiveAccentColor)
        sidebarHosting = NSHostingController(
            rootView: SettingsSourceList(selection: selection, accentColor: accent)
        )
        detailHosting = NSHostingController(
            rootView: SettingsDetailView(
                section: selection.wrappedValue ?? .account,
                model: model,
                appearance: appearance,
                accentColor: accent
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
        let accent = Color(nsColor: appearance.effectiveAccentColor)
        sidebarHosting.rootView = SettingsSourceList(selection: selection, accentColor: accent)
        detailHosting.rootView = SettingsDetailView(
            section: selection.wrappedValue ?? .account,
            model: model,
            appearance: appearance,
            accentColor: accent
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
