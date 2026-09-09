#if canImport(WatchConnectivity) && !os(watchOS)
import Foundation
import MailternalCompanion
import MailternalInterfaces
import MailternalWorkspace
import MailternalAutomation
import MailternalMIME
@preconcurrency import WatchConnectivity

/// The iPhone endpoint of the paired companion protocol. It owns no mail
/// streams: callers feed it the latest folders snapshot they already observe.
/// Incoming commands are validated against canonical deep links, recorded in a
/// durable phone-side log, and outgoing work is routed through the shared
/// iPhone command dispatcher.
@MainActor
final class PhoneCompanionSession: NSObject, WCSessionDelegate {
    private nonisolated static let payloadKey = "mailternal.companion.payload"
    private nonisolated static let responseKey = "mailternal.companion.response"

    private let facade: any MailFacade
    /// Shared with IOSAppState so Watch snapshots use the same effective
    /// per-folder order without giving the companion its own workspace state.
    private var listLayout: MailListLayoutStore?
    private let store: CompanionStore
    private let onOpenMessage: @MainActor (String) async -> Bool
    private let onCommand: @MainActor (MailternalAutomation.Command) async throws -> CommandResult
    private var session: WCSession?
    private var updateGeneration = 0
    /// The latest completed folder generation. Outgoing-only publications may
    /// reuse wire folders only while this equals the current requested
    /// generation; otherwise a folder refresh is still in flight.
    private var committedFolderGeneration = 0
    private var outgoingGeneration = 0
    /// The latest facade folder value is retained while WatchConnectivity is
    /// activating. A demand flag ensures a pre-activation update is published
    /// once the session becomes usable.
    private var latestFolders: [FolderSummary]?
    private var latestWireFolders: [CompanionFolderSnapshot] = []
    private var latestWireMessages: [CompanionMessageSnapshot] = []
    private var hasWireSnapshot = false
    private var latestOutgoing = OutgoingState()
    private var snapshotDemanded = false
    private var knownAccountLinks: Set<String> = []
    private var removedAccountLinks: Set<String> = []
    private var hasAuthoritativeAccountSnapshot = false
    private var executionDrainTask: Task<Void, Never>?
    private var executionDrainRequested = false
    private var deferredAccountDrainRequests: Set<String> = []
    private var accountDrainTasks: [String: Task<Void, Never>] = [:]
    init(
        facade: any MailFacade,
        storageURL: URL,
        onOpenMessage: @escaping @MainActor (String) async -> Bool,
        onCommand: @escaping @MainActor (MailternalAutomation.Command) async throws -> CommandResult
    ) {
        self.facade = facade
        self.store = CompanionStore(fileURL: storageURL)
        self.onOpenMessage = onOpenMessage
        self.onCommand = onCommand
        super.init()
    }

    /// Uses the phone's workspace ordering for subsequent companion snapshots.
    func attachListLayout(_ listLayout: MailListLayoutStore) {
        self.listLayout = listLayout
    }

    /// Installs the delegate before activation. Activation is intentionally
    /// idempotent so the app may call this once from its lifetime root.
    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        self.session = session
        session.activate()
        if session.activationState == .activated {
            Task { @MainActor [weak self] in
                await self?.publishInstallationAndRecover()
            }
        }
    }

    /// Publishes a bounded recent-mail snapshot. This method never observes a
    /// facade stream; the phone UI supplies the one current folder value.
    /// Calls made while WatchConnectivity is activating are retained and
    /// published from `activationDidCompleteWith`.
    func update(folders: [FolderSummary]) async {
        latestFolders = folders
        snapshotDemanded = true
        requestExecutionDrain()
        updateGeneration &+= 1
        let generation = updateGeneration
        var wireFolders: [CompanionFolderSnapshot] = []
        var wireMessages: [CompanionMessageSnapshot] = []
        var remainingMessages = CompanionProtocol.maximumMessageCount
        var remainingBodyBytes = CompanionProtocol.maximumCacheCharacters

        for folder in folders {
            guard let folderLink = try? await facade.makeDeepLink(for: folder.id),
                  let folderString = folderLink.formattedString,
                  let parsedFolder = CompanionDeepLink(rawValue: folderString),
                  parsedFolder.kind == .folder else { continue }
            let folderSnapshot = CompanionFolderSnapshot(
                canonicalLink: folderString,
                accountLinkID: parsedFolder.accountLinkID,
                name: folder.name,
                role: folder.role.rawValue,
                unreadCount: folder.unreadCount,
                totalCount: folder.totalCount
            )
            wireFolders.append(folderSnapshot)

            guard remainingMessages > 0,
                  let page = try? await facade.page(
                      in: folder.id,
                      after: nil,
                      limit: min(remainingMessages, 40),
                      sort: effectiveSort(for: folder)
                  ) else { continue }
            let rows = page.rows
            let details = (try? await facade.details(rows.map(\.id))) ?? []
            var detailsByID: [MessageID: MessageDetail] = [:]
            detailsByID.reserveCapacity(details.count)
            for detail in details { detailsByID[detail.id] = detail }

            for row in rows {
                guard remainingMessages > 0,
                      let link = try? await facade.makeDeepLink(for: row.id),
                      let messageString = link.formattedString,
                      let parsedMessage = CompanionDeepLink(rawValue: messageString),
                      parsedMessage.kind == .message,
                      parsedMessage.folderLink == folderString else { continue }
                let detailBody = detailsByID[row.id]?.bodyText
                let body: String?
                if let detailBody, detailBody.utf8.count <= remainingBodyBytes {
                    body = detailBody
                    remainingBodyBytes -= detailBody.utf8.count
                } else {
                    body = nil
                }
                wireMessages.append(CompanionMessageSnapshot(
                    canonicalLink: messageString,
                    folderLink: folderString,
                    accountLinkID: parsedMessage.accountLinkID,
                    sender: row.from,
                    senderAddress: row.senderAddress,
                    subject: row.subject,
                    preview: row.preview,
                    receivedAt: row.date,
                    isRead: row.isRead,
                    isFlagged: row.isFlagged,
                    hasAttachments: row.hasAttachments,
                    bodyText: body
                ))
                remainingMessages -= 1
            }
        }

        guard generation == updateGeneration else { return }
        let allAccountLinks = Set(wireFolders.map(\.accountLinkID))
            .union(facade.accounts.map { $0.accountLinkID.uuidString.lowercased() })
        if hasAuthoritativeAccountSnapshot {
            removedAccountLinks.formUnion(knownAccountLinks.subtracting(allAccountLinks))
        }
        removedAccountLinks.subtract(allAccountLinks)
        knownAccountLinks = allAccountLinks
        hasAuthoritativeAccountSnapshot = true
        latestWireFolders = wireFolders
        latestWireMessages = wireMessages
        hasWireSnapshot = true
        committedFolderGeneration = generation
        await publishSnapshot(expectedGeneration: generation)

    }

    /// Outgoing state is already a bounded projection from the shared mail
    /// runtime. Publishing it reuses the last completed mail snapshot so SMTP
    func update(outgoing: OutgoingState) async {
        latestOutgoing = outgoing
        outgoingGeneration &+= 1
        let generation = outgoingGeneration
        guard hasWireSnapshot else { return }
        await publishSnapshot(expectedOutgoingGeneration: generation)
    }
    nonisolated func session(_ session: WCSession,
                            activationDidCompleteWith activationState: WCSessionActivationState,
                            error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard error == nil, activationState == .activated else { return }
            await self.publishInstallationAndRecover()
            if self.snapshotDemanded, let folders = self.latestFolders {
                await self.update(folders: folders)
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in
            _ = await self?.receive(data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[Self.payloadKey] as? Data else { return }
        Task { @MainActor [weak self] in
            _ = await self?.receive(data)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in
            _ = await self?.receive(messageData)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                            replyHandler: @escaping @Sendable ([String: Any]) -> Void) {
        guard let data = message[Self.payloadKey] as? Data else {
            replyHandler(["ok": false])
            return
        }
        Task { @MainActor [weak self] in
            guard let response = await self?.receive(data) else {
                replyHandler(["ok": false])
                return
            }
            replyHandler([Self.responseKey: response])
        }
    }

    private func receive(_ data: Data) async -> Data? {
        guard let message = try? CompanionCodec.decode(data) else { return nil }
        switch message {
        case .command(let command):
            let ack = await accept(command)
            return try? CompanionCodec.encode(.acknowledgment(ack))
        case .handoff(let request):
            let ack = await handleHandoff(request)
            send(.handoffAcknowledgment(ack))
            return try? CompanionCodec.encode(.handoffAcknowledgment(ack))
        case .snapshot, .phoneInstallation, .acknowledgment, .handoffAcknowledgment, .notice:
            return nil
        }
    }

    private func accept(_ command: CompanionCommand) async -> CompanionCommandAck {
        guard let acceptance = await store.acceptOnPhone(command) else {
            let epoch = await store.currentState().phoneStoreEpoch
            let ack = CompanionCommandAck(
                commandID: command.id,
                accountLinkID: command.accountLinkID,
                status: .failed,
                reason: "The command was rejected as a duplicate or malformed request.",
                phoneStoreEpoch: epoch
            )
            send(.acknowledgment(ack))
            return ack
        }
        switch acceptance.record.status {
        case .failed:
            let failed = CompanionCommandAck(
                commandID: command.id,
                accountLinkID: command.accountLinkID,
                status: .failed,
                reason: acceptance.record.failureReason ?? "The phone previously rejected this command.",
                phoneStoreEpoch: acceptance.record.phoneStoreEpoch
            )
            send(.acknowledgment(failed))
            return failed
        case .needsReview:
            let review = CompanionCommandAck(
                commandID: command.id,
                accountLinkID: command.accountLinkID,
                status: .needsReview,
                reason: acceptance.record.failureReason
                    ?? "Delivery status unknown; review before retrying.",
                phoneStoreEpoch: acceptance.record.phoneStoreEpoch
            )
            send(.acknowledgment(review))
            return review
        case .submittedToMailQueue:
            let submitted = CompanionCommandAck(
                commandID: command.id,
                accountLinkID: command.accountLinkID,
                status: .submittedToMailQueue,
                phoneStoreEpoch: acceptance.record.phoneStoreEpoch
            )
            send(.acknowledgment(submitted))
            return submitted
        case .pendingOnWatch, .acceptedByPhone:
            break
        }

        let epoch: String
        if let acceptedEpoch = acceptance.record.phoneStoreEpoch {
            epoch = acceptedEpoch
        } else {
            epoch = await store.currentState().phoneStoreEpoch
        }
        let accepted = CompanionCommandAck(
            commandID: command.id,
            accountLinkID: command.accountLinkID,
            status: .acceptedByPhone,
            phoneStoreEpoch: epoch
        )
        send(.acknowledgment(accepted))
        if acceptance.shouldExecute {
            requestExecutionDrain()
        }
        return accepted
    }
    private func requestExecutionDrain() {
        deferredAccountDrainRequests.formUnion(accountDrainTasks.keys)
        guard executionDrainTask == nil else {
            executionDrainRequested = true
            return
        }
        executionDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.executionDrainTask = nil
                if self.executionDrainRequested {
                    self.executionDrainRequested = false
                    self.requestExecutionDrain()
                }
            }
            let commands = await self.store.recoverablePhoneCommands()
            var accountLinks = Set<String>()
            for command in commands {
                accountLinks.insert(command.accountLinkID)
            }
            for accountLinkID in accountLinks where self.accountDrainTasks[accountLinkID] == nil {
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer {
                        let shouldRetry = self.deferredAccountDrainRequests.remove(accountLinkID) != nil
                        self.accountDrainTasks[accountLinkID] = nil
                        if shouldRetry {
                            self.requestExecutionDrain()
                        }
                    }
                    await self.drainAccount(accountLinkID: accountLinkID)
                }
                self.accountDrainTasks[accountLinkID] = task
            }
        }
    }

    private func drainAccount(accountLinkID: String) async {
        while !Task.isCancelled {
            guard let command = (await store.recoverablePhoneCommands()).first(where: {
                $0.accountLinkID == accountLinkID
            }) else {
                return
            }
            guard await execute(command) else {
                return
            }
        }
    }

    private func execute(_ command: CompanionCommand) async -> Bool {
        var executionStarted = false
        do {
            let allowsDisabled: Bool
            switch command.mutation {
            case .retrySubmission, .cancelSubmission: allowsDisabled = true
            default: allowsDisabled = false
            }
            switch await waitForFacadeReadiness(
                accountLinkID: command.accountLinkID, allowsDisabled: allowsDisabled
            ) {
            case .ready:
                break
            case .deferred, .cancelled:
                return false
            case .unavailable:
                throw PhoneCompanionError.targetUnavailable
            }
            guard await store.markExecutionStarted(commandID: command.id) else { return true }
            executionStarted = true

            if command.mutation.isOutgoing {
                try await executeOutgoing(command)
            } else {
                guard let messageLink = command.messageLink,
                      let link = MailternalDeepLink(string: messageLink),
                      link.accountLinkID.uuidString.lowercased() == command.accountLinkID,
                      let account = facade.accounts.first(where: {
                          $0.accountLinkID == link.accountLinkID && $0.isEnabled
                      }),
                      facadeAccountCanAcceptCommands(facade.accountState(for: account.id)),
                      let resolution = try await facade.resolve(link),
                      case .message(_, let messageID, _) = resolution else {
                    throw PhoneCompanionError.targetUnavailable
                }

                switch command.mutation {
                case .markRead:
                    _ = try await onCommand(.markRead(.explicit([messageID])))
                case .markUnread:
                    _ = try await onCommand(.markUnread(.explicit([messageID])))
                case .setFlagged(let value):
                    _ = try await onCommand(.setFlagged(.explicit([messageID]), value))
                case .archive:
                    _ = try await onCommand(.archive(.explicit([messageID])))
                case .trash:
                    _ = try await onCommand(.trash(.explicit([messageID])))
                case .move(let destinationLink):
                    guard let destination = MailternalDeepLink(string: destinationLink),
                          destination.accountLinkID == link.accountLinkID,
                          case .folder = destination,
                          let destinationResolution = try await facade.resolve(destination),
                          case .folder(let folderID) = destinationResolution else {
                        throw PhoneCompanionError.destinationUnavailable
                    }
                    let outcome: MoveOutcome = try decodeCommandResult(
                        await onCommand(.move(.explicit([messageID]), folderID))
                    )
                    guard outcome.movedCount == 1 else { throw PhoneCompanionError.moveRejected }
                case .send, .retrySubmission, .cancelSubmission:
                    throw PhoneCompanionError.targetUnavailable
                }
            }
            if let ack = await store.markExecutionSubmitted(commandID: command.id) {
                send(.acknowledgment(ack))
            }
            if command.mutation.isOutgoing {
                await publishSnapshot()
            } else {
                await publishSnapshotAfterMutation()
            }
        } catch let error as MailternalAutomation.CommandEffectAppliedError {
            guard !Task.isCancelled else { return false }
            let reason = "The iPhone accepted this action but could not confirm completion: \(error.message). Review before sending another copy."
            if let ack = await store.markExecutionNeedsReview(
                commandID: command.id,
                reason: reason
            ) {
                send(.acknowledgment(ack))
            }
            if executionStarted {
                if command.mutation.isOutgoing {
                    await publishSnapshot()
                } else {
                    await publishSnapshotAfterMutation()
                }
            }
        } catch {
            guard !Task.isCancelled else { return false }
            if let ack = await store.markExecutionFailed(
                commandID: command.id,
                reason: error.localizedDescription
            ) {
                send(.acknowledgment(ack))
            }
            if executionStarted {
                if command.mutation.isOutgoing {
                    await publishSnapshot()
                } else {
                    await publishSnapshotAfterMutation()
                }
            }
        }
        return true
    }


    private func executeOutgoing(_ command: CompanionCommand) async throws {
        guard let account = facade.accounts.first(where: {
            $0.accountLinkID.uuidString.lowercased() == command.accountLinkID
        }) else {
            throw PhoneCompanionError.targetUnavailable
        }

        switch command.mutation {
        case .send(let content):
            guard account.isEnabled else {
                throw PhoneCompanionError.targetUnavailable
            }
            guard content.isSyntacticallyValid else {
                throw OutgoingMailError.invalidContent("The Watch message is no longer valid.")
            }

            guard let commandID = UUID(uuidString: command.id) else {
                throw OutgoingMailError.invalidContent("The Watch submission identifier is invalid.")
            }
            let draft: MailDraft
            switch content.kind {
            case .newMessage:
                guard command.messageLink == nil else {
                    throw OutgoingMailError.invalidContent("A new Watch message has an invalid link.")
                }
                let initial = DraftContent(
                    from: MailAddress(
                        displayName: account.displayName.isEmpty ? nil : account.displayName,
                        address: account.emailAddress
                    ),
                    to: MIMEParser.parseEditableAddresses(content.to),
                    cc: MIMEParser.parseEditableAddresses(content.cc),
                    bcc: MIMEParser.parseEditableAddresses(content.bcc),
                    subject: content.subject,
                    plainText: content.body,
                    html: nil
                )
                draft = try decodeCommandResult(await onCommand(
                    .createDraft(id: commandID, accountID: account.id, content: initial)
                ))
            case .reply, .replyAll, .forward:
                guard let messageLink = command.messageLink,
                      let link = MailternalDeepLink(string: messageLink),
                      link.accountLinkID == account.accountLinkID,
                      let resolution = try await facade.resolve(link),
                      case .message(_, let messageID, _) = resolution else {
                    throw PhoneCompanionError.targetUnavailable
                }
                let create: MailternalAutomation.Command
                switch content.kind {
                case .reply:
                    create = .createReplyDraft(id: commandID, .local(messageID), replyAll: false)
                case .replyAll:
                    create = .createReplyDraft(id: commandID, .local(messageID), replyAll: true)
                case .forward:
                    create = .createForwardDraft(id: commandID, .local(messageID))
                case .newMessage:
                    throw PhoneCompanionError.targetUnavailable
                }
                let initial: MailDraft = try decodeCommandResult(await onCommand(create))
                var edited = initial.content
                switch content.kind {
                case .reply, .replyAll:
                    if !content.body.isEmpty {
                        edited.plainText = Self.prepend(content.body, to: edited.plainText)
                    }
                    edited.html = nil
                    let saved: DraftSaveResult = try decodeCommandResult(await onCommand(.saveDraft(
                        id: initial.id,
                        expectedRevision: initial.revision,
                        content: edited
                    )))
                    draft = saved.saved
                case .forward:
                    edited.to = MIMEParser.parseEditableAddresses(content.to)
                    edited.cc = MIMEParser.parseEditableAddresses(content.cc)
                    edited.bcc = MIMEParser.parseEditableAddresses(content.bcc)
                    if !content.body.isEmpty {
                        edited.plainText = Self.prepend(content.body, to: edited.plainText)
                        edited.html = nil
                    }
                    let saved: DraftSaveResult = try decodeCommandResult(await onCommand(.saveDraft(
                        id: initial.id,
                        expectedRevision: initial.revision,
                        content: edited
                    )))
                    draft = saved.saved
                case .newMessage:
                    throw PhoneCompanionError.targetUnavailable
                }
            }
            _ = try await onCommand(.sendDraft(
                id: commandID,
                draftID: draft.id,
                expectedRevision: draft.revision
            ))

        case .retrySubmission(let submissionID, let acknowledgeDuplicateRisk):
            guard command.messageLink == nil,
                  let id = UUID(uuidString: submissionID),
                  let submission = try await facade.outbox(id: id),
                  submission.accountID == account.id else {
                throw PhoneCompanionError.targetUnavailable
            }
            _ = try await onCommand(.retrySubmission(
                id,
                acknowledgeDuplicateRisk: acknowledgeDuplicateRisk
            ))

        case .cancelSubmission(let submissionID):
            guard command.messageLink == nil,
                  let id = UUID(uuidString: submissionID),
                  let submission = try await facade.outbox(id: id),
                  submission.accountID == account.id else {
                throw PhoneCompanionError.targetUnavailable
            }
            _ = try await onCommand(.cancelSubmission(id))

        default:
            throw PhoneCompanionError.targetUnavailable
        }
    }

    private static func prepend(_ prefix: String, to quoted: String) -> String {
        guard !quoted.isEmpty else { return prefix }
        return "\(prefix)\n\n\(quoted)"
    }

    private func decodeCommandResult<Value: Decodable>(_ result: CommandResult) throws -> Value {
        guard let data = result.data else {
            throw OutgoingMailError.invalidContent("iPhone did not return the prepared draft.")
        }
        return try AutomationLineCodec.decode(Value.self, from: data)
    }
    private func publishSnapshot(
        expectedGeneration: Int? = nil,
        expectedOutgoingGeneration: Int? = nil
    ) async {
        guard hasWireSnapshot,
              committedFolderGeneration == updateGeneration else { return }
        snapshotDemanded = true
        let capturedFolderGeneration = committedFolderGeneration
        let capturedOutgoingGeneration = outgoingGeneration
        let folders = latestWireFolders
        let messages = latestWireMessages
        let accounts = accountSnapshots()
        let allFacadeAccountLinks = Set(facade.accounts.map {
            $0.accountLinkID.uuidString.lowercased()
        })
        let outgoing = outgoingSnapshots()
        let phoneState = await store.currentState()
        let revision = phoneState.lastSnapshotRevision &+ 1
        guard capturedFolderGeneration == committedFolderGeneration,
              capturedFolderGeneration == updateGeneration,
              capturedOutgoingGeneration == outgoingGeneration,
              expectedGeneration == nil || expectedGeneration == committedFolderGeneration,
              expectedOutgoingGeneration == nil || expectedOutgoingGeneration == outgoingGeneration
        else { return }
        guard let snapshot = await Self.boundedSnapshot(
            revision: revision,
            phoneStoreEpoch: phoneState.phoneStoreEpoch,
            folders: folders,
            messages: messages,
            accounts: accounts,
            allFacadeAccountLinks: allFacadeAccountLinks,
            outgoing: outgoing
        ) else {
            let notice = CompanionTransportNotice(
                message: "The phone could not fit the mail snapshot within the Watch transfer limit."
            )
            guard capturedFolderGeneration == committedFolderGeneration,
                  capturedFolderGeneration == updateGeneration,
                  capturedOutgoingGeneration == outgoingGeneration else { return }
            snapshotDemanded = false
            _ = await store.apply(notice)
            send(.notice(notice))
            return
        }
        guard capturedFolderGeneration == committedFolderGeneration,
              capturedFolderGeneration == updateGeneration,
              capturedOutgoingGeneration == outgoingGeneration else { return }
        guard snapshot.validated() != nil else {
            let notice = CompanionTransportNotice(message: "The phone produced an invalid mail snapshot.")
            guard capturedFolderGeneration == committedFolderGeneration,
                  capturedFolderGeneration == updateGeneration,
                  capturedOutgoingGeneration == outgoingGeneration else { return }
            snapshotDemanded = false
            _ = await store.apply(notice)
            send(.notice(notice))
            return
        }
        guard session?.activationState == .activated else { return }
        _ = await store.merge(snapshot)
        guard capturedFolderGeneration == committedFolderGeneration,
              capturedFolderGeneration == updateGeneration,
              capturedOutgoingGeneration == outgoingGeneration else {
            await publishSnapshot()
            return
        }
        snapshotDemanded = false
        send(.snapshot(snapshot))

    }
    private func accountSnapshots() -> [CompanionAccountSnapshot] {
        facade.accounts.prefix(32).map {
                CompanionAccountSnapshot(
                    id: $0.accountLinkID.uuidString.lowercased(),
                    name: $0.displayName,
                    email: $0.emailAddress,
                    canSend: $0.isEnabled && $0.smtp != nil
                )
            }
    }

    private func outgoingSnapshots() -> [CompanionOutgoingSnapshot] {
        let accountLinks = Dictionary(uniqueKeysWithValues: facade.accounts.map {
            ($0.id, $0.accountLinkID.uuidString.lowercased())
        })
        return latestOutgoing.outbox.prefix(50).compactMap { item in
            guard let accountLinkID = accountLinks[item.accountID] else {
                return nil
            }
            let state: CompanionOutboxState
            switch item.state {
            case .queued: state = .queued
            case .preparing: state = .preparing
            case .sending: state = .sending
            case .awaitingAcceptance: state = .awaitingAcceptance
            case .deliveryUnknown: state = .deliveryUnknown
            case .failed: state = .failed
            case .cancelled: state = .cancelled
            case .sentCopyPending: state = .sentCopyPending
            case .sent: state = .sent
            }
            return CompanionOutgoingSnapshot(
                id: item.id.uuidString.lowercased(),
                accountLinkID: accountLinkID,
                subject: item.subject,
                state: state,
                failureReason: item.failure?.message
            )
        }
    }


    /// A Watch mutation can change message flags without changing folder
    /// aggregates. Reuse the latest folder demand so the refreshed page is
    /// visible even when the ordinary folder stream stays quiet.
    private func publishSnapshotAfterMutation() async {
        guard let folders = latestFolders else { return }
        snapshotDemanded = true
        await update(folders: folders)
    }

    private func facadeAccountCanAcceptCommands(_ state: AccountState) -> Bool {
        switch state {
        case .none, .validating:
            return false
        case .active, .authFailed, .connectionFailed:
            return true
        }
    }

    /// Performs one readiness check. Deferred commands remain durably accepted
    /// and are retried by existing account/folder update and activation
    /// callbacks rather than by a polling loop that can starve another lane.
    private func waitForFacadeReadiness(
        accountLinkID: String, allowsDisabled: Bool
    ) async -> FacadeReadiness {
        guard !Task.isCancelled else { return .cancelled }
        if removedAccountLinks.contains(accountLinkID) {
            return .unavailable
        }
        if let account = facade.accounts.first(where: {
            $0.accountLinkID.uuidString.lowercased() == accountLinkID
        }) {
            if allowsDisabled { return .ready }
            guard account.isEnabled else { return .deferred }
            return facadeAccountCanAcceptCommands(facade.accountState(for: account.id))
                ? .ready
                : .deferred
        }
        if hasAuthoritativeAccountSnapshot && !facade.accounts.isEmpty {
            return .unavailable
        }
        return .deferred
    }

    private func publishInstallationAndRecover() async {
        await store.recoverPhoneHandoffs()
        let recoveredCommands = await store.recoverPhoneCommands()
        let current = await store.currentState()
        send(.phoneInstallation(CompanionPhoneInstallation(epoch: current.phoneStoreEpoch)))
        for ack in recoveredCommands {
            send(.acknowledgment(ack))
        }
        requestExecutionDrain()
    }

    private func handleHandoff(_ request: CompanionHandoffRequest) async -> CompanionHandoffAck {
        guard let link = CompanionDeepLink(rawValue: request.messageLink), link.kind == .message else {
            return CompanionHandoffAck(requestID: request.id, messageLink: request.messageLink,
                                       status: .failed, reason: "The message link is invalid.")
        }
        guard let acceptance = await store.acceptHandoffOnPhone(request) else {
            return CompanionHandoffAck(requestID: request.id, messageLink: link.rawValue,
                                       status: .failed, reason: "The handoff request was rejected.")
        }
        guard acceptance.shouldRoute else {
            let record = acceptance.record
            let status: CompanionHandoffStatus =
                record.routingStartedAt == nil ? record.status : .pending
            return CompanionHandoffAck(
                requestID: request.id,
                messageLink: link.rawValue,
                status: status,
                reason: record.failureReason
            )
        }
        let opened = await onOpenMessage(link.rawValue)
        let ack = CompanionHandoffAck(
            requestID: request.id,
            messageLink: link.rawValue,
            status: opened ? .accepted : .failed,
            reason: opened ? nil : "The message is no longer available on iPhone."
        )
        guard await store.completeHandoffOnPhone(ack) != nil else {
            return CompanionHandoffAck(
                requestID: request.id,
                messageLink: link.rawValue,
                status: .failed,
                reason: "iPhone could not persist the handoff result."
            )
        }
        return ack
    }
    private func effectiveSort(for folder: FolderSummary) -> MailListSort {
        guard let listLayout else {
            // The Watch is a recent-mail companion, not an independent layout
            // owner. If the iPhone shell is unavailable, its deliberate
            // platform adaptation is newest-first rather than a second
            // unsynchronized workspace authority.
            return .newest
        }
        guard let account = facade.accounts.first(where: { $0.id == folder.accountID }),
              !folder.path.isEmpty else {
            return listLayout.configuration(for: .global).sort
        }
        return listLayout.configuration(
            for: .folder(account: account.accountLinkID, path: folder.path)
        ).sort
    }
    private nonisolated static func boundedSnapshot(
        revision: Int,
        phoneStoreEpoch: String,
        folders: [CompanionFolderSnapshot],
        messages: [CompanionMessageSnapshot],
        accounts: [CompanionAccountSnapshot],
        allFacadeAccountLinks: Set<String>,
        outgoing: [CompanionOutgoingSnapshot]
    ) async -> CompanionSnapshot? {
        guard !Task.isCancelled else { return nil }
        let worker = Task.detached(priority: .userInitiated) { () -> CompanionSnapshot? in
            guard !Task.isCancelled else { return nil }
            return Self.fitBoundedSnapshot(
                revision: revision,
                phoneStoreEpoch: phoneStoreEpoch,
                folders: folders,
                messages: messages,
                accounts: accounts,
                allFacadeAccountLinks: allFacadeAccountLinks,
                outgoing: outgoing
            )
        }
        return await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    private nonisolated static func fitBoundedSnapshot(
        revision: Int,
        phoneStoreEpoch: String,
        folders: [CompanionFolderSnapshot],
        messages: [CompanionMessageSnapshot],
        accounts: [CompanionAccountSnapshot],
        allFacadeAccountLinks: Set<String>,
        outgoing: [CompanionOutgoingSnapshot]
    ) -> CompanionSnapshot? {
        let boundedFolders = Array(folders.prefix(256))
        let boundedAccounts = Array(accounts.prefix(32))
        let boundedOutgoing = Array(outgoing.prefix(20))
        let allowedFolderLinks = Set(boundedFolders.map(\.canonicalLink))
        let candidates = messages.filter { allowedFolderLinks.contains($0.folderLink) }
        let generatedAt = Date()

        func selectedMessages(count: Int, retainingBodies: Int) -> [CompanionMessageSnapshot] {
            var selected = Array(candidates.prefix(count))
            var remainingBodies = retainingBodies
            for index in selected.indices where selected[index].bodyText != nil {
                guard remainingBodies > 0 else {
                    selected[index].bodyText = nil
                    continue
                }
                remainingBodies -= 1
            }
            return selected
        }

        func makeSnapshot(
            folderCount: Int,
            messageCount: Int,
            retainingBodies: Int,
            accountCount: Int = boundedAccounts.count,
            outgoingCount: Int = boundedOutgoing.count
        ) -> CompanionSnapshot {
            let selectedFolders = Array(boundedFolders.prefix(folderCount))
            let folderLinks = Set(selectedFolders.map(\.canonicalLink))
            let selected = selectedMessages(
                count: messageCount,
                retainingBodies: retainingBodies
            ).filter { folderLinks.contains($0.folderLink) }
            let selectedAccounts = Array(boundedAccounts.prefix(accountCount))
            let emittedAccountLinks = Set(selectedAccounts.map(\.id))
                .union(selectedFolders.map(\.accountLinkID))
            let accountDisplayEntriesComplete =
                allFacadeAccountLinks.isSubset(of: Set(selectedAccounts.map(\.id)))
            return CompanionSnapshot(
                revision: revision,
                phoneStoreEpoch: phoneStoreEpoch,
                generatedAt: generatedAt,
                lastSyncAt: generatedAt,
                folders: selectedFolders,
                messages: selected,
                accounts: selectedAccounts,
                outgoing: Array(boundedOutgoing.prefix(outgoingCount)),
                accountsComplete: allFacadeAccountLinks.isSubset(of: emittedAccountLinks),
                accountDisplayEntriesComplete: accountDisplayEntriesComplete
            )
        }

        func fits(_ snapshot: CompanionSnapshot) -> Bool {
            guard !Task.isCancelled,
                  let encoded = try? CompanionCodec.encode(.snapshot(snapshot)) else {
                return false
            }
            return encoded.count <= CompanionProtocol.maximumTransferBytes
        }

        var accountCount = boundedAccounts.count
        var outgoingCount = boundedOutgoing.count
        let allFoldersWithoutMessages = makeSnapshot(
            folderCount: boundedFolders.count,
            messageCount: 0,
            retainingBodies: 0
        )
        if !fits(allFoldersWithoutMessages) {
            // Fixed metadata is reduced in a stable order: outgoing entries
            // first, then account display entries. Folder-account identity is
            // tracked separately, so this never means an account was removed.
            while !fits(makeSnapshot(
                folderCount: boundedFolders.count,
                messageCount: 0,
                retainingBodies: 0,
                accountCount: accountCount,
                outgoingCount: outgoingCount
            )) {
                guard !Task.isCancelled else { return nil }
                if outgoingCount > 0 {
                    outgoingCount -= 1
                } else if accountCount > 0 {
                    accountCount -= 1
                } else {
                    break
                }
            }
            let reduced = makeSnapshot(
                folderCount: boundedFolders.count,
                messageCount: 0,
                retainingBodies: 0,
                accountCount: accountCount,
                outgoingCount: outgoingCount
            )
            guard fits(reduced) else {
                var lower = 0
                var upper = boundedFolders.count
                while lower < upper {
                    guard !Task.isCancelled else { return nil }
                    let middle = (lower + upper + 1) / 2
                    if fits(makeSnapshot(
                        folderCount: middle,
                        messageCount: 0,
                        retainingBodies: 0,
                        accountCount: 0,
                        outgoingCount: 0
                    )) {
                        lower = middle
                    } else {
                        upper = middle - 1
                    }
                }
                let result = makeSnapshot(
                    folderCount: lower,
                    messageCount: 0,
                    retainingBodies: 0,
                    accountCount: 0,
                    outgoingCount: 0
                )
                return fits(result) ? result : nil
            }
        }

        var lower = 0
        var upper = candidates.count
        while lower < upper {
            guard !Task.isCancelled else { return nil }
            let middle = (lower + upper + 1) / 2
            if fits(makeSnapshot(
                folderCount: boundedFolders.count,
                messageCount: middle,
                retainingBodies: 0,
                accountCount: accountCount,
                outgoingCount: outgoingCount
            )) {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        let maximumMessageCount = lower
        let maximumBodyCount = candidates.prefix(maximumMessageCount).reduce(into: 0) {
            if $1.bodyText != nil { $0 += 1 }
        }
        lower = 0
        upper = maximumBodyCount
        while lower < upper {
            guard !Task.isCancelled else { return nil }
            let middle = (lower + upper + 1) / 2
            if fits(makeSnapshot(
                folderCount: boundedFolders.count,
                messageCount: maximumMessageCount,
                retainingBodies: middle,
                accountCount: accountCount,
                outgoingCount: outgoingCount
            )) {
                lower = middle
            } else {
                upper = middle - 1
            }
        }
        let result = makeSnapshot(
            folderCount: boundedFolders.count,
            messageCount: maximumMessageCount,
            retainingBodies: lower,
            accountCount: accountCount,
            outgoingCount: outgoingCount
        )
        return fits(result) ? result : nil
    }

    private func send(_ message: CompanionWireMessage) {
        guard let session, let data = try? CompanionCodec.encode(message),
              data.count <= CompanionProtocol.maximumTransferBytes else { return }
        let payload: [String: Any] = [Self.payloadKey: data]
        var contextErrorNotice: CompanionTransportNotice?
        if case .snapshot = message {
            do {
                try session.updateApplicationContext(payload)
            } catch {
                contextErrorNotice = CompanionTransportNotice(
                    message: "The Watch snapshot could not be stored: \(error.localizedDescription)"
                )
            }
        }
        session.transferUserInfo(payload)
        if let contextErrorNotice,
           let noticeData = try? CompanionCodec.encode(.notice(contextErrorNotice)),
           noticeData.count <= CompanionProtocol.maximumTransferBytes
        {
            session.transferUserInfo([Self.payloadKey: noticeData])
        }
    }
}

private enum FacadeReadiness: Sendable {
    case ready
    case deferred
    case unavailable
    case cancelled
}

private enum PhoneCompanionError: LocalizedError, Sendable {
    case targetUnavailable
    case destinationUnavailable
    case moveRejected

    var errorDescription: String? {
        switch self {
        case .targetUnavailable: "The message account is no longer available on iPhone."
        case .destinationUnavailable: "The destination folder is no longer available on iPhone."
        case .moveRejected: "The message move was not accepted by iPhone."
        }
    }
}
#endif
