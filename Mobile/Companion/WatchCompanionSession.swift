#if canImport(WatchConnectivity) && os(watchOS)
import Combine
import Foundation
import MailternalCompanion
@preconcurrency import WatchConnectivity

public enum WatchCompanionConnection: String, Sendable {
    case unavailable
    case activating
    case disconnected
    case reachable
}

/// Watch-side transport and state owner. The actor-backed store is updated
/// before every command or handoff transfer, allowing actions to survive
/// disconnects, force quits, and Watch restarts without claiming server work.
@MainActor
public final class WatchCompanionSession: NSObject, ObservableObject, WCSessionDelegate {
    private nonisolated static let payloadKey = "mailternal.companion.payload"
    private nonisolated static let responseKey = "mailternal.companion.response"

    @Published public private(set) var state = CompanionState()
    @Published public private(set) var connection: WatchCompanionConnection = .activating
    @Published public private(set) var isReachable = false

    private let store: CompanionStore
    private var session: WCSession?

    public init(storageURL: URL = WatchCompanionSession.defaultStorageURL()) {
        store = CompanionStore(fileURL: storageURL)
        super.init()
    }

    public static func defaultStorageURL() -> URL {
        URL.applicationSupportDirectory
            .appendingPathComponent("MailternalCompanion", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    /// Installs the Watch delegate and restores the durable cache/queue.
    public func activate() {
        guard WCSession.isSupported() else {
            connection = .unavailable
            isReachable = false
            return
        }
        let session = WCSession.default
        session.delegate = self
        self.session = session
        guard session.isCompanionAppInstalled else {
            connection = .unavailable
            isReachable = false
            Task { @MainActor [weak self] in
                await self?.recordNotice("The iPhone companion app is not installed.")
            }
            session.activate()
            return
        }
        isReachable = session.isReachable
        connection = session.isReachable ? .reachable : .disconnected
        session.activate()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshState()
            await self.sendPendingCommandsIfReachable()
        }
    }

    /// Queues a user mutation in the local durable log before transferring it.
    public func queue(_ message: CompanionMessageSnapshot, mutation: CompanionMutation) {
        let command = CompanionCommand(
            accountLinkID: message.accountLinkID,
            messageLink: message.canonicalLink,
            mutation: mutation,
            previousIsRead: message.isRead,
            previousIsFlagged: message.isFlagged
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let queuedState = await self.store.enqueue(command),
                  let queued = queuedState.commands.first(where: { $0.id == command.id }) else {
                await self.refreshState()
                return
            }
            self.state = queuedState
            self.send(queued.command)
        }
    }

    /// Persists an identified handoff before transfer. A reachable request gets
    /// a reply; an unreachable request remains pending in durable user-info.
    public func continueOnPhone(_ messageLink: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let record = await self.store.enqueueHandoff(messageLink: messageLink) else {
                await self.recordNotice("This message could not be queued for iPhone.")
                return
            }
            await self.refreshState()
            self.sendHandoff(record)
        }
    }
    nonisolated public func session(_ session: WCSession,
                                    activationDidCompleteWith activationState: WCSessionActivationState,
                                    error: Error?) {
        let activationError = error?.localizedDescription
        let activationSucceeded = error == nil && activationState == .activated
        let companionInstalled = session.isCompanionAppInstalled
        let sessionReachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard activationSucceeded else {
                self.connection = .unavailable
                self.isReachable = false
                if let activationError {
                    await self.recordNotice("iPhone companion activation failed: \(activationError)")
                }
                return
            }
            guard companionInstalled else {
                self.connection = .unavailable
                self.isReachable = false
                return
            }
            self.isReachable = sessionReachable
            self.connection = sessionReachable ? .reachable : .disconnected
            await self.refreshState()
            await self.sendPendingCommandsIfReachable()
        }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let companionInstalled = session.isCompanionAppInstalled
        let sessionReachable = session.isReachable
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard companionInstalled else {
                self.connection = .unavailable
                self.isReachable = false
                return
            }
            self.isReachable = sessionReachable
            self.connection = sessionReachable ? .reachable : .disconnected
            await self.sendPendingCommandsIfReachable()
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let data = context[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in
            await self?.receive(data)
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in
            await self?.receive(data)
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in
            await self?.receive(data)
        }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in
            await self?.receive(messageData)
        }
    }

    private func receive(_ data: Data) async {
        guard let message = try? CompanionCodec.decode(data) else {
            await recordNotice("The phone sent an invalid companion message.")
            return
        }
        switch message {
        case .snapshot(let snapshot):
            state = await store.merge(snapshot)
        case .phoneInstallation(let installation):
            state = await store.reconcilePhoneStoreEpoch(installation.epoch)
            await sendPendingCommandsIfReachable()
        case .acknowledgment(let ack):
            state = await store.apply(ack)
        case .handoffAcknowledgment(let ack):
            state = await store.apply(ack)
        case .notice(let notice):
            state = await store.apply(notice)
        case .command:
            await recordNotice("The phone sent an unsupported command.")
        case .handoff:
            await recordNotice("The phone sent an unsupported handoff request.")
        }
    }

    private func refreshState() async {
        state = await store.currentState()
    }

    private func sendPendingCommandsIfReachable() async {
        guard isReachable, session != nil else { return }
        let current = await store.currentState()
        let pendingCommands = current.commands
            .filter { $0.status == .pendingOnWatch }
            .sorted {
                if $0.command.sequence != $1.command.sequence {
                    return $0.command.sequence < $1.command.sequence
                }
                return $0.enqueuedAt < $1.enqueuedAt
            }
        for record in pendingCommands {
            send(record.command)
        }
        for record in current.handoffs where record.status == .pending {
            sendHandoff(record)
        }
    }

    private func send(_ command: CompanionCommand) {
        guard let session, let data = try? CompanionCodec.encode(.command(command)),
              data.count <= CompanionProtocol.maximumTransferBytes else {
            Task { @MainActor [weak self] in
                await self?.recordNotice("This action could not be transferred to iPhone.")
            }
            return
        }
        session.transferUserInfo([Self.payloadKey: data])
    }

    private func sendHandoff(_ record: CompanionHandoffRecord) {
        guard let session,
              let data = try? CompanionCodec.encode(.handoff(
                  CompanionHandoffRequest(id: record.id, messageLink: record.messageLink,
                                          createdAt: record.createdAt))),
              data.count <= CompanionProtocol.maximumTransferBytes else {
            Task { @MainActor [weak self] in
                await self?.recordNotice("Continue on iPhone could not be transferred.")
            }
            return
        }
        if session.isReachable {
            session.sendMessage(
                [Self.payloadKey: data],
                replyHandler: { [weak self] reply in
                    guard let response = reply[Self.responseKey] as? Data else {
                        Task { @MainActor in
                            guard let self else { return }
                            await self.recordNotice("iPhone did not acknowledge Continue on iPhone.")
                            self.session?.transferUserInfo([Self.payloadKey: data])
                        }
                        return
                    }
                    Task { @MainActor in
                        guard let self else { return }
                        guard let message = try? CompanionCodec.decode(response),
                              case .handoffAcknowledgment(let ack) = message else {
                            await self.recordNotice("iPhone returned an invalid Continue on iPhone response.")
                            self.session?.transferUserInfo([Self.payloadKey: data])
                            return
                        }
                        self.state = await self.store.apply(ack)
                    }
                },
                errorHandler: { [weak self] error in
                    let errorMessage = "Continue on iPhone could not connect: \(error.localizedDescription)"
                    Task { @MainActor in
                        guard let self else { return }
                        await self.recordNotice(errorMessage)
                        self.session?.transferUserInfo([Self.payloadKey: data])
                    }
                }
            )
        } else {
            session.transferUserInfo([Self.payloadKey: data])
        }
    }

    private func recordNotice(_ message: String) async {
        state = await store.apply(CompanionTransportNotice(message: message))
    }
}
#endif
