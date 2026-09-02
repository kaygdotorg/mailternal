import AppKit
import SwiftUI
import MailternalInterfaces

enum SettingsSection: String, CaseIterable, Identifiable {
    case account, appearance, actions

    var id: Self { self }

    var title: String {
        switch self {
        case .account: "Account"
        case .appearance: "Appearance"
        case .actions: "Actions"
        }
    }

    var systemImage: String {
        switch self {
        case .account: "at"
        case .appearance: "paintbrush"
        case .actions: "hand.draw"
        }
    }
}


struct SettingsSourceList: View {
    @Binding var selection: SettingsSection?
    let appearance: AppearanceSettings
    let actions: ActionSettings

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .focusEffectDisabled(true)
        .environment(actions)
        .tint(appearance.accent.color)
        .environment(appearance.accent)
        .padding(.top, 46)
    }
}

struct SettingsDetailView: View {
    let section: SettingsSection
    @Bindable var model: AppModel
    let appearance: AppearanceSettings
    let actions: ActionSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title)
                .font(.title)
                .fontWeight(.semibold)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .accessibilityIdentifier(UIIdentifier.settingsSectionTitle)

            Group {
                switch section {
                case .account:
                    AccountSetupForm(model: model)
                case .appearance:
                    AppearanceSettingsForm(appearance: appearance)
                case .actions:
                    ActionSettingsForm(actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(appearance.accent.color)
        .environment(appearance.accent)
        .environment(actions)
    }
}

struct ActionSettingsForm: View {
    @Bindable var actions: ActionSettings

    var body: some View {
        Form {
            Section {
                swipeGroup(title: "Swipe left", edge: .trailing, limit: ActionSettings.trailingSwipeLimit)
                swipeGroup(title: "Swipe right", edge: .leading, limit: ActionSettings.leadingSwipeLimit)
            } header: {
                Text("Gestures")
            } footer: {
                Text("Swipe actions apply to messages in the message list.")
            }
            .accessibilityIdentifier(UIIdentifier.actionsSection)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func swipeGroup(title: String, edge: SwipeEdge, limit: Int) -> some View {
        Text(title)
            .font(.headline)
        // Both edges share one Section; plain indices would collide and
        // SwiftUI would reuse the first edge's rows for the second.
        ForEach(0..<limit, id: \.self) { index in
            Picker(selection: pickerBinding(for: edge, at: index)) {
                Text("None").tag(nil as SwipeActionKind?)
                ForEach(SwipeActionKind.allCases) { kind in
                    Text(kind.title).tag(Optional(kind))
                }
            } label: {
                Text("Action \(index + 1)")
            }
            .id(pickerIdentifier(for: edge, at: index))
            .accessibilityIdentifier(pickerIdentifier(for: edge, at: index))
        }
    }

    private func pickerBinding(for edge: SwipeEdge, at index: Int) -> Binding<SwipeActionKind?> {
        Binding(
            get: {
                actions.swipeActions(for: edge).indices.contains(index)
                    ? actions.swipeActions(for: edge)[index]
                    : nil
            },
            set: { actions.setSwipeAction($0, at: index, edge: edge) }
        )
    }

    private func pickerIdentifier(for edge: SwipeEdge, at index: Int) -> String {
        switch edge {
        case .leading: UIIdentifier.actionsSwipeLeading(index)
        case .trailing: UIIdentifier.actionsSwipeTrailing(index)
        }
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

    private var editingConfig: AccountConfig? {
        model.accountConfig
    }

    private var isEditing: Bool {
        editingConfig != nil
    }

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
                SecureField(
                    "Password",
                    text: $password,
                    prompt: isEditing ? Text("unchanged") : nil
                )
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
                    Button(isEditing ? "Save Changes" : "Sign In") {
                        Task { await submit() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier(isEditing ? UIIdentifier.accountSave : "")
                    if case .active = model.accountState {
                        Button("Remove Account", role: .destructive) {
                            Task { try? await model.facade.removeAccount() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .disabled({
            if case .validating = model.accountState { return true }
            return false
        }())
        .onAppear(perform: loadFields)
        .onChange(of: model.accountConfig) { _, _ in
            loadFields()
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
        let hasPassword = isEditing || !password.isEmpty
        return !host.isEmpty && !username.isEmpty && hasPassword && Int(port) != nil
    }

    private func applyPreset(named name: String) {
        guard let preset = ProviderPresets.all.first(where: { $0.name == name }) else { return }
        host = preset.host
        port = String(preset.port)
        security = preset.security
        if username.isEmpty { username = email }
    }

    private func loadFields() {
        guard let config = editingConfig else {
            if displayName.isEmpty { displayName = NSFullUserName() }
            return
        }
        presetName = "Custom"
        displayName = config.displayName
        email = config.emailAddress
        username = config.username
        host = config.imap.host
        port = String(config.imap.port)
        security = config.imap.security
        password = ""
        fieldError = nil
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
        let existing = editingConfig
        let config = AccountConfig(
            id: existing?.id ?? AccountID(rawValue: "account-1"),
            accountLinkID: existing?.accountLinkID ?? .random(),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            emailAddress: email,
            username: username,
            imap: IMAPEndpoint(host: host, port: portNumber, security: security)
        )
        do {
            if existing != nil {
                try await model.updateAccount(
                    config,
                    password: password.isEmpty ? nil : password
                )
            } else {
                try await model.facade.addAccount(config, password: password)
            }
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
        .scrollContentBackground(.hidden)
    }
}

@MainActor
final class SettingsSplitController: NSSplitViewController {
    private let sidebarHosting: NSHostingController<SettingsSourceList>
    private let detailHosting: NSHostingController<SettingsDetailView>
    private let sidebarItem: NSSplitViewItem
    private var backgroundEffect: NSVisualEffectView?
    private var didSetDivider = false

    init(
        model: AppModel,
        appearance: AppearanceSettings,
        actions: ActionSettings,
        selection: Binding<SettingsSection?>
    ) {
        sidebarHosting = NSHostingController(
            rootView: SettingsSourceList(selection: selection, appearance: appearance, actions: actions)
        )
        detailHosting = NSHostingController(
            rootView: SettingsDetailView(
                section: selection.wrappedValue ?? .account,
                model: model,
                appearance: appearance,
                actions: actions
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
    func update(
        model: AppModel,
        appearance: AppearanceSettings,
        actions: ActionSettings,
        selection: Binding<SettingsSection?>
    ) {
        sidebarHosting.rootView = SettingsSourceList(selection: selection, appearance: appearance, actions: actions)
        detailHosting.rootView = SettingsDetailView(
            section: selection.wrappedValue ?? .account,
            model: model,
            appearance: appearance,
            actions: actions
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
    private var actions: ActionSettings?
    private var split: SettingsSplitController?
    private var model: AppModel?
    private var appearance: AppearanceSettings?
    private var hasShown = false

    private init() { super.init(window: nil) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(model: AppModel, appearance: AppearanceSettings, actions: ActionSettings) {
        self.model = model
        self.appearance = appearance
        self.actions = actions
        if case .none = model.accountState {
            selection = .account
        }
        if let split {
            split.update(
                model: model,
                appearance: appearance,
                actions: actions,
                selection: selectionBinding
            )
        } else {
            let split = SettingsSplitController(
                model: model,
                appearance: appearance,
                actions: actions,
                selection: selectionBinding
            )
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
        guard let split, let model, let appearance, let actions else { return }
        split.update(
            model: model,
            appearance: appearance,
            actions: actions,
            selection: selectionBinding
        )
    }

    private var selectionBinding: Binding<SettingsSection?> {
        Binding(
            get: { [weak self] in self?.selection },
            set: { [weak self] value in self?.selection = value }
        )
    }
}
