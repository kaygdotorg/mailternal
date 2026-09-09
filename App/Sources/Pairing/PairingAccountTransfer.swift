import Foundation
import MailternalInterfaces
import MailternalPairing
import MailternalStore
import MailternalAutomation
import MailternalWorkspace

/// Errors raised before the transport acknowledges a pairing import.
///
/// These errors intentionally describe identity and persistence failures without
/// including credentials or account contents in the user-facing message.
enum PairingAccountTransferError: LocalizedError, Sendable {
    case noAccountsSelected
    case unknownAccount(AccountID)
    case missingCredential(AccountID)
    case accountIdentityConflict(AccountID)
    case accountIdentityMigrationUnavailable
    case unsupportedWorkspaceSetting(String)

    var errorDescription: String? {
        switch self {
        case .noAccountsSelected:
            return "Select at least one account to transfer."
        case .unknownAccount:
            return "A selected account is no longer available."
        case .missingCredential:
            return "The selected account password is missing from Keychain."
        case .accountIdentityConflict:
            return "The transferred account identity conflicts with a local account."
        case .accountIdentityMigrationUnavailable:
            return "This account cannot adopt the transferred identity on this device."
        case .unsupportedWorkspaceSetting(let key):
            return "This workspace setting is not supported by this version of Mailternal: \(key)."
        }
    }
}

private func pairingNormalizedHost(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func pairingMatches(_ incoming: AccountConfig, local: AccountConfig) -> Bool {
    if incoming.accountLinkID == local.accountLinkID { return true }
    return pairingNormalizedHost(incoming.imap.host) == pairingNormalizedHost(local.imap.host)
        && incoming.imap.port == local.imap.port
        && incoming.imap.security == local.imap.security
        && incoming.username == local.username
}

func pairingMatchingAccount(
    _ incoming: AccountConfig,
    in accounts: [AccountConfig]
) -> AccountConfig? {
    accounts.first { pairingMatches(incoming, local: $0) }
}

private func pairingImportMatchingAccount(
    _ incoming: AccountConfig,
    in accounts: [AccountConfig]
) throws -> AccountConfig? {
    let endpointMatch = accounts.first {
        pairingNormalizedHost(incoming.imap.host) == pairingNormalizedHost($0.imap.host)
            && incoming.imap.port == $0.imap.port
            && incoming.imap.security == $0.imap.security
            && incoming.username == $0.username
    }
    guard let linkMatch = accounts.first(where: {
        $0.accountLinkID == incoming.accountLinkID
    }) else {
        return endpointMatch
    }
    if let endpointMatch, endpointMatch.id != linkMatch.id {
        throw PairingAccountTransferError.accountIdentityConflict(incoming.id)
    }
    return linkMatch
}

@MainActor
private func pairingCanonicalizeAccount(
    _ existing: AccountConfig,
    to incoming: AccountConfig,
    in localAccounts: [AccountConfig],
    facade: any MailFacade
) async throws -> AccountConfig {
    guard existing.accountLinkID != incoming.accountLinkID else {
        return existing
    }
    guard !localAccounts.contains(where: {
        $0.id != existing.id && $0.accountLinkID == incoming.accountLinkID
    }) else {
        throw PairingAccountTransferError.accountIdentityConflict(incoming.id)
    }
    guard let live = facade as? LiveMailFacade else {
        throw PairingAccountTransferError.accountIdentityMigrationUnavailable
    }
    try Task.checkCancellation()
    try await live.adoptAccountLinkID(
        existing.id,
        to: incoming.accountLinkID
    )
    var adopted = existing
    adopted.accountLinkID = incoming.accountLinkID
    return adopted
}

/// Replays the durable identity queue before restoring links or acknowledging
/// an import. Repeating a workspace/file migration after interruption is safe.
@MainActor
func finishPairingAccountLinkCommands(
    facade: any MailFacade,
    workspace: WorkspaceSyncController,
    readerLinks: ((AccountLinkCommand) throws -> Void)? = nil
) async throws {
    guard let live = facade as? LiveMailFacade else { return }
    let commands = try await live.pendingAccountLinkCommands()
    for command in commands {
        try Task.checkCancellation()
        try await workspace.remapAccountLinkID(
            from: command.source,
            to: command.destination
        )
        try readerLinks?(command)
        try await live.completeAccountLinkCommand(command.id)
    }
}


@MainActor
private func pairingAccounts(
    _ ids: Set<AccountID>,
    from accounts: [AccountConfig],
    facade: any MailFacade
) throws -> [PairingAccount] {
    guard !ids.isEmpty else { throw PairingAccountTransferError.noAccountsSelected }
    guard let live = facade as? LiveMailFacade else {
        throw PairingAccountTransferError.accountIdentityMigrationUnavailable
    }
    return try ids.sorted(by: { $0.rawValue < $1.rawValue }).map { id in
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw PairingAccountTransferError.unknownAccount(id)
        }
        let credential: String
        do {
            credential = try live.accountTransferCredential(for: id)
        } catch {
            throw PairingAccountTransferError.missingCredential(id)
        }
        guard !credential.isEmpty else {
            throw PairingAccountTransferError.missingCredential(id)
        }
        let smtpCredential: String?
        do {
            smtpCredential = try live.accountTransferSMTPCredential(for: id)
        } catch {
            throw PairingAccountTransferError.missingCredential(id)
        }
        return PairingAccount(
            config: account,
            credential: credential,
            smtpCredential: smtpCredential
        )
    }
}

#if os(macOS)

@MainActor
extension AppModel {
    /// Builds a selected-account bundle only after the user presses Send.
    /// Credentials come from the live facade's configured credential store,
    /// including isolated QA stores; workspace values use the macOS allowlist.
    func makePairingBundle(
        _ accountIDs: Set<AccountID>,
        includeSettings: Bool
    ) async throws -> PairingBundle {
        let accounts = try pairingAccounts(accountIDs, from: accountConfigs, facade: facade)
        let settings = includeSettings ? workspaceSync.exportPairingSettings() : [:]
        return PairingBundle(accounts: accounts, settings: settings)
    }

    /// Imports through the facade's durable account lifecycle. A matching local
    /// account adopts the incoming canonical link even when replacement is off;
    /// its account ID and mailbox/cache rows remain local. Workspace identities
    /// are remapped before any import acknowledgment can be sent.
    ///
    /// Settings are committed locally as one batch. CloudKit synchronization is
    /// queued separately, so an offline device can still acknowledge this
    /// durable import.
    func importPairingBundle(
        _ bundle: PairingBundle,
        selectedAccountIDs: Set<AccountID>,
        replaceExisting: Bool,
        importSettings: Bool
    ) async throws {
        guard !selectedAccountIDs.isEmpty else {
            throw PairingAccountTransferError.noAccountsSelected
        }
        let selected = bundle.accounts.filter { selectedAccountIDs.contains($0.id) }
        guard selected.count == selectedAccountIDs.count else {
            throw PairingAccountTransferError.unknownAccount(
                selectedAccountIDs.subtracting(selected.map(\.id)).first ?? AccountID(rawValue: "unknown")
            )
        }


        await preparePairingAccountLinks()
        try await recoverPairedAccountLinks()
        var localAccounts = facade.accounts
        for incoming in selected {
            try Task.checkCancellation()
            if let existing = try pairingImportMatchingAccount(incoming.config, in: localAccounts) {
                let adopted = try await pairingCanonicalizeAccount(
                    existing,
                    to: incoming.config,
                    in: localAccounts,
                    facade: facade
                )
                try await recoverPairedAccountLinks()
                if let index = localAccounts.firstIndex(where: { $0.id == existing.id }) {
                    localAccounts[index] = adopted
                }
                try Task.checkCancellation()
                guard replaceExisting else { continue }
                var replacement = incoming.config
                replacement.id = adopted.id
                // Account edits keep SMTP state behind configureSMTP, which
                // also imports the encrypted account-scoped secret.
                replacement.smtp = adopted.smtp
                try await facade.updateAccount(replacement, password: incoming.credential)
                try await facade.configureSMTP(
                    adopted.id,
                    configuration: incoming.config.smtp,
                    password: incoming.smtpCredential
                )
                if let index = localAccounts.firstIndex(where: { $0.id == adopted.id }) {
                    var updated = replacement
                    updated.smtp = incoming.config.smtp
                    localAccounts[index] = updated
                }
                continue
            }
            if localAccounts.contains(where: { $0.id == incoming.id }) {
                throw PairingAccountTransferError.accountIdentityConflict(incoming.id)
            }
            try Task.checkCancellation()
            var importedConfig = incoming.config
            importedConfig.smtp = nil
            try await facade.addAccount(importedConfig, password: incoming.credential)
            if let smtp = incoming.config.smtp {
                try await facade.configureSMTP(
                    incoming.id,
                    configuration: smtp,
                    password: incoming.smtpCredential
                )
            }
            localAccounts.append(incoming.config)
        }

        guard importSettings, !bundle.settings.isEmpty else {
            try Task.checkCancellation()
            let controller = workspaceSync.controller
            Task { @MainActor in
                await controller.synchronize()
            }
            return
        }
        try Task.checkCancellation()
        try await workspaceSync.importPairingSettings(bundle.settings)
    }
}

#elseif os(iOS)


@MainActor
extension IOSAppState {
    /// Builds a selected-account bundle from the facade's configured credential
    /// store and the canonical workspace key contract shared with macOS.
    func makePairingBundle(
        _ accountIDs: Set<AccountID>,
        includeSettings: Bool
    ) async throws -> PairingBundle {
        let pairingAccountsValue = try pairingAccounts(accountIDs, from: accounts, facade: facade)
        let settings = includeSettings
            ? workspace.values.filter { IOSAppState.WorkspaceKeys.category(for: $0.key) != nil }
            : [:]
        return PairingBundle(accounts: pairingAccountsValue, settings: settings)
    }

    /// Imports each selected account through the persisted iOS command journal.
    /// A matching local account adopts the incoming canonical link while
    /// preserving its local account ID and mailbox/cache rows. Workspace
    /// identities are remapped before an import acknowledgment is possible.
    ///
    /// Settings use one local durable batch and queue CloudKit work separately,
    /// so this operation remains usable while iCloud is offline.
    func importPairingBundle(
        _ bundle: PairingBundle,
        selectedAccountIDs: Set<AccountID>,
        replaceExisting: Bool,
        importSettings: Bool
    ) async throws {
        guard !selectedAccountIDs.isEmpty else {
            throw PairingAccountTransferError.noAccountsSelected
        }
        let selected = bundle.accounts.filter { selectedAccountIDs.contains($0.id) }
        guard selected.count == selectedAccountIDs.count else {
            throw PairingAccountTransferError.unknownAccount(
                selectedAccountIDs.subtracting(selected.map(\.id)).first ?? AccountID(rawValue: "unknown")
            )
        }

        var importedSettings: [WorkspaceSyncImportValue] = []
        if importSettings {
            importedSettings.reserveCapacity(bundle.settings.count)
            for key in bundle.settings.keys.sorted() {
                guard let value = bundle.settings[key],
                      let category = IOSAppState.WorkspaceKeys.category(for: key) else {
                    throw PairingAccountTransferError.unsupportedWorkspaceSetting(key)
                }
                if key == IOSAppState.WorkspaceKeys.readingLink {
                    guard case .string(let link) = value,
                          link.isEmpty || MailternalDeepLink(string: link) != nil else {
                        throw PairingAccountTransferError.unsupportedWorkspaceSetting(key)
                    }
                }
                importedSettings.append(
                    WorkspaceSyncImportValue(
                        key: key,
                        value: value,
                        category: category
                    )
                )
            }
        }

        try await finishPairingAccountLinkCommands(facade: facade, workspace: workspace)
        var localAccounts = facade.accounts
        for incoming in selected {
            try Task.checkCancellation()
            if let existing = try pairingImportMatchingAccount(incoming.config, in: localAccounts) {
                let adopted = try await pairingCanonicalizeAccount(
                    existing,
                    to: incoming.config,
                    in: localAccounts,
                    facade: facade
                )
                try await finishPairingAccountLinkCommands(facade: facade, workspace: workspace)
                if let index = localAccounts.firstIndex(where: { $0.id == existing.id }) {
                    localAccounts[index] = adopted
                }
                try Task.checkCancellation()
                guard replaceExisting else { continue }
                var replacement = incoming.config
                replacement.id = adopted.id
                replacement.smtp = adopted.smtp
                try await dispatcher.submit(
                    .saveAccount(replacement, hasPassword: true),
                    secret: incoming.credential
                )
                _ = try await dispatcher.submit(
                    .configureSMTP(adopted.id, incoming.config.smtp, hasPassword: incoming.smtpCredential != nil),
                    secret: incoming.smtpCredential
                )
                if let index = localAccounts.firstIndex(where: { $0.id == adopted.id }) {
                    var updated = replacement
                    updated.smtp = incoming.config.smtp
                    localAccounts[index] = updated
                }
                continue
            }
            if localAccounts.contains(where: { $0.id == incoming.id }) {
                throw PairingAccountTransferError.accountIdentityConflict(incoming.id)
            }
            try Task.checkCancellation()
            var importedConfig = incoming.config
            importedConfig.smtp = nil
            try await dispatcher.submit(
                .saveAccount(importedConfig, hasPassword: true),
                secret: incoming.credential
            )
            if let smtp = incoming.config.smtp {
                _ = try await dispatcher.submit(
                    .configureSMTP(incoming.id, smtp, hasPassword: incoming.smtpCredential != nil),
                    secret: incoming.smtpCredential
                )
            }
            localAccounts.append(incoming.config)
        }
        guard importSettings, !importedSettings.isEmpty else {
            try Task.checkCancellation()
            applyWorkspaceValues()
            try Task.checkCancellation()
            let controller = workspace
            Task { @MainActor in
                await controller.synchronize()
            }
            return
        }
        try Task.checkCancellation()
        try await workspace.importLocalValues(importedSettings)
        try Task.checkCancellation()
        applyWorkspaceValues()
        let controller = workspace
        Task { @MainActor in
            await controller.synchronize()
        }
    }
}

#endif
