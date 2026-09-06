import Foundation
import Observation
import MailternalInterfaces
import MailternalWorkspace

/// Errors raised while importing the canonical workspace settings map.
enum MacWorkspaceError: Error, LocalizedError, Sendable {
    case unsupportedSetting(String)
    case malformedReadingLink

    var errorDescription: String? {
        switch self {
        case .unsupportedSetting(let key):
            "This workspace setting is not supported by this version of Mailternal: \(key)."
        case .malformedReadingLink:
            "The synced reading position is malformed and was not applied."
        }
    }
}

/// macOS adapter for the durable iCloud workspace controller.
///
/// The adapter keeps the iOS key contract in one place, publishes local
/// appearance and gesture edits, and fences reading handoff to the application
/// activation boundary. Applying an iCloud value updates the existing local
/// preference object but never publishes that received value as a fresh edit.
@MainActor
@Observable
final class MacWorkspaceCoordinator {
    enum Keys {
        static let readingMode = "mailternal.appearance.email-reading"
        static let senderIcons = "mailternal.appearance.showsSenderIcons"
        // Retain the iOS settings layout during pairing; macOS has no Flat View UI yet.
        static let settingsFlatView = "mailternal.appearance.settingsFlatView"
        static let leadingSwipe = "mailternal.actions.swipe.leading"
        static let trailingSwipe = "mailternal.actions.swipe.trailing"
        static let readingLink = "mailternal.workspace.reading-link"
    }

    static let containerIdentifier = "iCloud.org.kayg.mailternal"

    static var defaultStorageURL: URL {
        if let root = QALaunch.parse()?.containerRoot {
            return root.appendingPathComponent("workspace.json", isDirectory: false)
        }
        return MailternalContainer.default.root
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    let controller: WorkspaceSyncController
    let listLayout: MailListLayoutStore
    private let appearance: AppearanceSettings
    private let actions: ActionSettings
    @ObservationIgnored private weak var model: AppModel?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var resumeRequested = false
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var readingTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var applyingRemoteReadingLink: String?
    @ObservationIgnored private var controllerObservationGeneration: UInt64 = 0
    @ObservationIgnored private var settingsObservationGeneration: UInt64 = 0
    @ObservationIgnored private var readingObservationGeneration: UInt64 = 0

    // A marker for each canonical preference suppresses publication after an
    // iCloud value is applied. It also allows first launch to seed missing
    // cloud values from the already-persisted local preferences.
    @ObservationIgnored private var appliedReadingMode: EmailReadingMode?
    @ObservationIgnored private var appliedSenderIcons: Bool?
    @ObservationIgnored private var appliedLeadingSwipe: [SwipeActionKind]?
    @ObservationIgnored private var appliedTrailingSwipe: [SwipeActionKind]?

    private(set) var actionError: String?

    init(
        appearance: AppearanceSettings,
        actions: ActionSettings,
        storageURL: URL,
        containerIdentifier: String = MacWorkspaceCoordinator.containerIdentifier
    ) {
        self.appearance = appearance
        self.actions = actions
        let controller = WorkspaceSyncController(
            storageURL: storageURL,
            containerIdentifier: containerIdentifier
        )
        self.controller = controller
        self.listLayout = MailListLayoutStore(controller: controller)
    }

    deinit {
        resumeTask?.cancel()
        readingTimeoutTask?.cancel()
    }

    /// Binds the adapter to its owning model after AppModel has initialized all
    /// stored properties. The weak reference avoids a model/coordinator cycle.
    func bind(to model: AppModel) {
        self.model = model
    }

    /// Starts observations and performs the first non-navigating synchronization.
    /// Reading handoff waits for the app's activation callback.
    func start() {
        guard !started else { return }
        started = true
        observeController()
        observeSettings()
        observeReadingSelection()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await controller.synchronize()
            applyWorkspaceValues()
            await publishLocalAppearanceAndActions()
            if resumeRequested, isActive {
                resumeRequested = false
                await resumeFromInactive()
            }
        }
    }

    /// Called by the AppKit lifecycle when the app becomes active. The first
    /// activation is also a safe initial handoff because no user input has yet
    /// occurred on this device.
    func didBecomeActive() {
        isActive = true
        guard started else {
            resumeRequested = true
            return
        }
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await resumeFromInactive()
        }
    }

    /// Called before AppKit suspends interactive work. Persist the current
    /// reading anchor before the next device is allowed to hand it off.
    func willResignActive() {
        isActive = false
        resumeTask?.cancel()
        Task { @MainActor [weak self] in
            await self?.publishLocalReadingLink()
        }
    }

    var isEnabled: Bool { controller.isEnabled }
    var enabledCategories: Set<WorkspaceSyncCategory> { controller.enabledCategories }
    var pendingConflicts: Set<WorkspaceSyncCategory> { controller.pendingConflicts }
    var lastSync: Date? { controller.lastSync }
    var values: [String: WorkspaceSyncValue] { controller.values }
    var lastError: String? { actionError ?? controller.lastError }

    func setEnabled(_ enabled: Bool) async throws {
        do {
            try await controller.setEnabled(enabled)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            throw error
        }
    }

    func setCategory(_ category: WorkspaceSyncCategory, enabled: Bool) async throws {
        do {
            try await controller.setCategory(category, enabled: enabled)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            throw error
        }
    }

    func resolve(_ category: WorkspaceSyncCategory, using choice: WorkspaceSyncChoice) async throws {
        do {
            try await controller.resolve(category, using: choice)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
            throw error
        }
    }

    /// Returns only the canonical, non-secret settings accepted by this adapter.
    /// The map is safe for the pairing bridge; it contains no account metadata,
    /// passwords, server credentials, or rendered mail content.
    func exportPairingSettings() -> [String: WorkspaceSyncValue] {
        controller.values.filter { Self.category(for: $0.key) != nil }
    }

    /// Imports a user-confirmed pairing settings map through one local durable
    /// batch. Reading position is stored but deliberately not opened while the
    /// current app is active. CloudKit synchronization is queued separately so
    /// an offline device can still acknowledge the local import.
    func importPairingSettings(_ values: [String: WorkspaceSyncValue]) async throws {
        var imports: [WorkspaceSyncImportValue] = []
        imports.reserveCapacity(values.count)
        for key in values.keys.sorted() {
            guard let value = values[key], let category = Self.category(for: key) else {
                throw MacWorkspaceError.unsupportedSetting(key)
            }
            if case .string(let link) = value,
               key == Keys.readingLink,
               !link.isEmpty,
               MailternalDeepLink(string: link) == nil {
                throw MacWorkspaceError.malformedReadingLink
            }
            imports.append(
                WorkspaceSyncImportValue(
                    key: key,
                    value: value,
                    category: category
                )
            )
        }
        do {
            try Task.checkCancellation()
            try await controller.importLocalValues(imports)
            try Task.checkCancellation()
        } catch {
            actionError = error.localizedDescription
            throw error
        }
        applyWorkspaceValues()
        let controller = controller
        Task { @MainActor in
            await controller.synchronize()
        }
    }

    /// Applies values that are safe to adopt immediately. The reading/deep-link
    /// value is intentionally excluded; it is adopted only by resumeFromInactive.
    func applyWorkspaceValues() {
        if case .string(let raw) = controller.values[Keys.readingMode],
           let mode = EmailReadingMode(rawValue: raw) {
            if appearance.emailReadingMode != mode {
                appearance.emailReadingMode = mode
            }
            appliedReadingMode = mode
        }
        if case .bool(let show) = controller.values[Keys.senderIcons] {
            if appearance.showsSenderIcons != show {
                appearance.showsSenderIcons = show
            }
            appliedSenderIcons = show
        }
        if case .string(let raw) = controller.values[Keys.leadingSwipe],
           let data = raw.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            let decoded = values.compactMap(SwipeActionKind.init(rawValue:))
            if decoded != actions.swipeActions(for: .leading) {
                actions.setSwipeActions(decoded, for: .leading)
            }
            appliedLeadingSwipe = decoded
        }
        if case .string(let raw) = controller.values[Keys.trailingSwipe],
           let data = raw.data(using: .utf8),
           let values = try? JSONDecoder().decode([String].self, from: data) {
            let decoded = values.compactMap(SwipeActionKind.init(rawValue:))
            if decoded != actions.swipeActions(for: .trailing) {
                actions.setSwipeActions(decoded, for: .trailing)
            }
            appliedTrailingSwipe = decoded
        }
    }

    private func resumeFromInactive() async {
        guard started, isActive else { return }
        await controller.synchronize()
        guard isActive else { return }
        applyWorkspaceValues()
        await adoptRemoteReadingIfNeeded()
    }

    private func observeController() {
        controllerObservationGeneration &+= 1
        let generation = controllerObservationGeneration
        withObservationTracking {
            _ = controller.values
            _ = controller.isEnabled
            _ = controller.enabledCategories
            _ = controller.pendingConflicts
            _ = controller.lastSync
            _ = controller.lastError
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.controllerObservationGeneration == generation,
                      self.started else { return }
                self.applyWorkspaceValues()
                self.observeController()
            }
        }
    }

    private func observeSettings() {
        settingsObservationGeneration &+= 1
        let generation = settingsObservationGeneration
        withObservationTracking {
            _ = appearance.emailReadingMode
            _ = appearance.showsSenderIcons
            _ = actions.leadingSwipe
            _ = actions.trailingSwipe
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.settingsObservationGeneration == generation,
                      self.started else { return }
                await self.publishLocalAppearanceAndActions()
                self.observeSettings()
            }
        }
    }

    private func observeReadingSelection() {
        guard let model else { return }
        readingObservationGeneration &+= 1
        let generation = readingObservationGeneration
        withObservationTracking {
            _ = model.tabs.activeID
            _ = model.tabs.active?.message
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.readingObservationGeneration == generation,
                      self.started else { return }
                await self.readingSelectionDidChange()
                self.observeReadingSelection()
            }
        }
    }

    private func publishLocalAppearanceAndActions() async {
        if appliedReadingMode != appearance.emailReadingMode
            || controller.values[Keys.readingMode] == nil {
            do {
                try await controller.setValue(
                    .string(appearance.emailReadingMode.rawValue),
                    for: Keys.readingMode,
                    category: .appearance
                )
                appliedReadingMode = appearance.emailReadingMode
            } catch {
                actionError = error.localizedDescription
            }
        }
        if appliedSenderIcons != appearance.showsSenderIcons
            || controller.values[Keys.senderIcons] == nil {
            do {
                try await controller.setValue(
                    .bool(appearance.showsSenderIcons),
                    for: Keys.senderIcons,
                    category: .appearance
                )
                appliedSenderIcons = appearance.showsSenderIcons
            } catch {
                actionError = error.localizedDescription
            }
        }
        if appliedLeadingSwipe != actions.swipeActions(for: .leading)
            || controller.values[Keys.leadingSwipe] == nil {
            do {
                try await controller.setValue(
                    .string(actions.encodedSwipeActions(for: .leading)),
                    for: Keys.leadingSwipe,
                    category: .actions
                )
                appliedLeadingSwipe = actions.swipeActions(for: .leading)
            } catch {
                actionError = error.localizedDescription
            }
        }
        if appliedTrailingSwipe != actions.swipeActions(for: .trailing)
            || controller.values[Keys.trailingSwipe] == nil {
            do {
                try await controller.setValue(
                    .string(actions.encodedSwipeActions(for: .trailing)),
                    for: Keys.trailingSwipe,
                    category: .actions
                )
                appliedTrailingSwipe = actions.swipeActions(for: .trailing)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func readingSelectionDidChange() async {
        guard let model else { return }
        if let target = applyingRemoteReadingLink {
            if await currentReadingLink() == target {
                applyingRemoteReadingLink = nil
                readingTimeoutTask?.cancel()
                readingTimeoutTask = nil
            }
            return
        }
        guard isActive else { return }
        if model.tabs.active == nil {
            await publishLocalReadingLink(current: nil)
            return
        }
        guard let current = await currentReadingLink() else { return }
        await publishLocalReadingLink(current: current)
    }

    private func publishLocalReadingLink() async {
        await publishLocalReadingLink(current: await currentReadingLink())
    }

    private func publishLocalReadingLink(current: String?) async {
        let hasActiveMessage = model?.tabs.active != nil
        guard current != nil || !hasActiveMessage else { return }
        let localValue = current.map(WorkspaceSyncValue.string)
        let existing = controller.values[Keys.readingLink]
        guard existing != localValue || (current == nil && existing != nil) else { return }
        do {
            try await controller.setValue(
                localValue,
                for: Keys.readingLink,
                category: .workspace
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func currentReadingLink() async -> String? {
        guard let model,
              let id = model.tabs.active?.message,
              let link = try? await model.facade.makeDeepLink(for: id),
              let value = link.formattedString else { return nil }
        return value
    }

    private func adoptRemoteReadingIfNeeded() async {
        guard let model,
              case .string(let remote)? = controller.values[Keys.readingLink],
              !remote.isEmpty else { return }
        let current = await currentReadingLink()
        guard current != remote else { return }
        guard let link = MailternalDeepLink(string: remote),
              let url = link.formattedURL else {
            actionError = MacWorkspaceError.malformedReadingLink.localizedDescription
            return
        }
        applyingRemoteReadingLink = remote
        model.openURL(url)
        readingTimeoutTask?.cancel()
        readingTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, self.applyingRemoteReadingLink == remote else { return }
            self.applyingRemoteReadingLink = nil
            self.readingTimeoutTask = nil
        }
    }

    static func category(for key: String) -> WorkspaceSyncCategory? {
        switch key {
        case Keys.readingLink:
            .workspace
        case Keys.readingMode, Keys.senderIcons, Keys.settingsFlatView:
            .appearance
        case Keys.leadingSwipe, Keys.trailingSwipe:
            .actions
        default:
            MailListLayoutStore.isSupportedKey(key) ? .workspace : nil
        }
    }
}
