import Foundation
import MailternalAutomation

/// Errors returned when a pairing command no longer has a live native surface.
@MainActor
final class PairingAutomationBridge {
    enum BridgeError: LocalizedError, Equatable, Sendable {
        case unavailable
        case staleInstallation
        case disabledAction(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Pairing is not currently presented."
            case .staleInstallation:
                return "The pairing surface is no longer current."
            case .disabledAction(let action):
                return "Pairing action is unavailable in the current state: \(action)."
            }
        }
    }

    private struct Installation {
        let generation: UUID
        let snapshot: @MainActor () -> AutomationDialogState?
        let perform: @MainActor (PairingUIAction) async throws -> Void
        var dialog: AutomationDialogState?
        var actions: [AutomationActionState]
    }

    private var installation: Installation?

    /// Called after a live dialog/action snapshot changes. AppModel uses this
    /// to publish state without turning lifecycle updates into commands.
    var onStateChange: (@MainActor () -> Void)?

    var currentDialogState: AutomationDialogState? {
        installation?.dialog
    }

    var currentAvailableActions: [AutomationActionState] {
        installation?.actions ?? []
    }

    /// Installs one live view handler and returns its generation token. A
    /// subsequent presentation must not be able to receive commands intended
    /// for this installation.
    @discardableResult
    func install(
        snapshot: @escaping @MainActor () -> AutomationDialogState?,
        perform: @escaping @MainActor (PairingUIAction) async throws -> Void
    ) -> UUID {
        let generation = UUID()
        installation = Installation(
            generation: generation,
            snapshot: snapshot,
            perform: perform,
            dialog: snapshot(),
            actions: []
        )
        onStateChange?()
        return generation
    }

    /// Removes only the installation named by the token returned from
    /// `install`. An old view cannot tear down a newer presentation.
    func uninstall(_ generation: UUID) {
        guard installation?.generation == generation else { return }
        installation = nil
        onStateChange?()
    }

    /// Executes a command against the currently installed view. Missing and
    /// stale handlers fail explicitly rather than silently doing nothing.
    func perform(action: PairingUIAction) async throws {
        guard let installation else { throw BridgeError.unavailable }
        let generation = installation.generation
        guard installation.actions.contains(where: { $0.id == action.name && $0.isEnabled }) else {
            throw BridgeError.disabledAction(action.name)
        }
        try await installation.perform(action)
        // A successfully queued dismissal is allowed to uninstall its own
        // surface. It must never accept replacement by a newer presentation.
        if action == .dismiss, self.installation == nil { return }
        guard self.installation?.generation == generation else {
            throw BridgeError.staleInstallation
        }
        refresh(generation)
    }

    /// Publishes a concrete state/action snapshot for the installed view.
    /// Generation matching prevents a late callback from replacing a newer
    /// presentation's state.
    func publish(
        dialog: AutomationDialogState?,
        actions: [AutomationActionState],
        generation: UUID
    ) {
        guard var installation, installation.generation == generation else { return }
        installation.dialog = dialog
        installation.actions = actions
        self.installation = installation
        onStateChange?()
    }

    /// Refreshes the dialog provider after a command's synchronous portion.
    func refresh(_ generation: UUID) {
        guard var installation, installation.generation == generation else { return }
        installation.dialog = installation.snapshot()
        self.installation = installation
        onStateChange?()
    }
}
