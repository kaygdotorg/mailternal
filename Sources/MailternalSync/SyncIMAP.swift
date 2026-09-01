import Foundation
import MailternalIMAP
import MailternalInterfaces

/// Session seam used by `SyncEngine`. Production wraps `IMAPSession`;
/// unit tests inject a scripted client.
package protocol IMAPClient: Sendable {
    nonisolated var events: AsyncStream<IMAPMailboxEvent> { get }
    func capabilities() async -> IMAPCapabilities
    func selectedMailbox() async -> IMAPSelectedMailbox?
    func connect() async throws
    func close() async
    func listFolders() async throws -> IMAPFolderDiscovery
    func select(_ mailbox: String, qresync: IMAPQResyncSelect?) async throws -> IMAPSelectedMailbox
    func enableQResync() async throws
    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage]
    func storeSeen(uids: IMAPUIDSet) async throws
    func beginIdle() async throws -> IMAPIdle
    func endIdle() async throws
    func renewIdle() async throws -> IMAPIdle
}

package protocol IMAPClientFactory: Sendable {
    func makeClient(endpoint: IMAPEndpoint, username: String, password: String) -> any IMAPClient
}

struct LiveIMAPClient: IMAPClient {
    let session: IMAPSession

    nonisolated var events: AsyncStream<IMAPMailboxEvent> { session.events }

    func capabilities() async -> IMAPCapabilities { await session.capabilities }
    func selectedMailbox() async -> IMAPSelectedMailbox? { await session.selected }
    func connect() async throws { try await session.connect() }
    func close() async { await session.close() }
    func listFolders() async throws -> IMAPFolderDiscovery { try await session.listFolders() }
    func select(_ mailbox: String, qresync: IMAPQResyncSelect?) async throws -> IMAPSelectedMailbox {
        try await session.select(mailbox, qresync: qresync)
    }
    func enableQResync() async throws { try await session.enableQResync() }
    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        try await session.fetch(request)
    }
    func storeSeen(uids: IMAPUIDSet) async throws { try await session.storeSeen(uids: uids) }
    func beginIdle() async throws -> IMAPIdle { try await session.beginIdle() }
    func endIdle() async throws { try await session.endIdle() }
    func renewIdle() async throws -> IMAPIdle { try await session.renewIdle() }
}

package struct LiveIMAPClientFactory: IMAPClientFactory {
    package func makeClient(endpoint: IMAPEndpoint, username: String, password: String) -> any IMAPClient {
        LiveIMAPClient(session: IMAPSession(endpoint: endpoint, username: username, password: password))
    }
}

/// Serializes every command on one IMAP connection. Ending IDLE is automatic
/// before a non-idle command so a multiplexed fallback stays correct.
///
/// `IMAPSession.send` keeps a single tagged waiter; actor reentrancy through
/// this channel (backfill + `refreshNow` + seen drain) must not overlap.
actor SyncChannel {
    private(set) var client: any IMAPClient
    nonisolated let events: AsyncStream<IMAPMailboxEvent>
    private var idling = false
    private(set) var selectedPath: String?
    private var commandBusy = false
    private var commandWaiters: [CheckedContinuation<Void, Never>] = []

    init(client: any IMAPClient) {
        self.client = client
        self.events = client.events
    }

    func eventStream() -> AsyncStream<IMAPMailboxEvent> { events }

    func capabilities() async -> IMAPCapabilities { await client.capabilities() }

    func selectedMailbox() async -> IMAPSelectedMailbox? { await client.selectedMailbox() }

    func connect() async throws {
        try await withCommand {
            try await self.client.connect()
        }
    }

    func close() async {
        // Do not endIdle here: waitForTagged would steal an in-flight send waiter.
        // Session.close() fails waiters immediately and drops the socket.
        idling = false
        await client.close()
        selectedPath = nil
    }

    func listFolders() async throws -> IMAPFolderDiscovery {
        try await withCommand {
            try await self.leaveIdleUnlocked()
            return try await self.client.listFolders()
        }
    }

    func enableQResync() async throws {
        try await withCommand {
            try await self.leaveIdleUnlocked()
            try await self.client.enableQResync()
        }
    }

    func select(_ path: String, qresync: IMAPQResyncSelect? = nil) async throws -> IMAPSelectedMailbox {
        try await withCommand {
            try await self.leaveIdleUnlocked()
            // Always re-SELECT. A cached mailbox misses UIDNEXT / VANISHED /
            // EXISTS that arrived on the IDLE socket (or since the last SELECT),
            // which breaks CONDSTORE and basic delta ingestion.
            let selected = try await self.client.select(path, qresync: qresync)
            self.selectedPath = path
            return selected
        }
    }

    func fetch(_ request: IMAPFetchRequest) async throws -> [IMAPFetchedMessage] {
        try await withCommand {
            try await self.leaveIdleUnlocked()
            return try await self.client.fetch(request)
        }
    }

    func storeSeen(uids: IMAPUIDSet) async throws {
        try await withCommand {
            try await self.leaveIdleUnlocked()
            try await self.client.storeSeen(uids: uids)
        }
    }

    func beginIdle() async throws -> IMAPIdle {
        try await withCommand {
            try await self.leaveIdleUnlocked()
            self.idling = true
            do {
                return try await self.client.beginIdle()
            } catch {
                self.idling = false
                throw error
            }
        }
    }

    func renewIdle() async throws -> IMAPIdle {
        try await withCommand {
            self.idling = true
            do {
                return try await self.client.renewIdle()
            } catch {
                self.idling = false
                throw error
            }
        }
    }

    func leaveIdle() async throws {
        try await withCommand {
            try await self.leaveIdleUnlocked()
        }
    }

    private func leaveIdleUnlocked() async throws {
        guard idling else { return }
        try await client.endIdle()
        idling = false
    }

    private func acquireCommand() async {
        if commandBusy {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                commandWaiters.append(cont)
            }
            return
        }
        commandBusy = true
    }

    private func releaseCommand() {
        if commandWaiters.isEmpty {
            commandBusy = false
        } else {
            commandWaiters.removeFirst().resume()
        }
    }

    private func withCommand<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        await acquireCommand()
        do {
            let value = try await body()
            releaseCommand()
            return value
        } catch {
            releaseCommand()
            throw error
        }
    }
}
