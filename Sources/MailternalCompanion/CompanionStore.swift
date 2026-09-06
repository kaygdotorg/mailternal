import Foundation

/// Result of inserting a command on the phone. `shouldExecute` is false for a
/// duplicate already submitted or needing review, preventing a non-idempotent
/// move from being replayed merely because an acknowledgement was lost.
public struct PhoneCommandAcceptance: Sendable {
    public let record: CompanionCommandRecord
    public let shouldExecute: Bool

    public init(record: CompanionCommandRecord, shouldExecute: Bool) {
        self.record = record
        self.shouldExecute = shouldExecute
    }
}
public struct PhoneHandoffAcceptance: Sendable {
    public let record: CompanionHandoffRecord
    public let shouldRoute: Bool

    public init(record: CompanionHandoffRecord, shouldRoute: Bool) {
        self.record = record
        self.shouldRoute = shouldRoute
    }
}

/// A small actor-backed JSON store used independently by the phone and Watch.
/// Every mutation is persisted before it is reported to the UI or dispatched to
/// WatchConnectivity. The cache contains only bounded, plain-text message data.
/// An unreadable or unsupported existing journal is retained in place; the
/// store exposes the failure through `currentState()` and rejects mutations.
public actor CompanionStore {
    private let fileURL: URL
    private let maxMessages: Int
    private let maxCharacters: Int
    private var journalFailure: String?
    private var state: CompanionState

    private enum LoadResult {
        case missing
        case loaded(CompanionState)
        case failed(String)
    }

    public init(fileURL: URL, maxMessages: Int = CompanionProtocol.maximumMessageCount,
                maxCharacters: Int = CompanionProtocol.maximumCacheCharacters) {
        self.fileURL = fileURL
        self.maxMessages = max(1, min(maxMessages, CompanionProtocol.maximumMessageCount))
        self.maxCharacters = max(1, min(maxCharacters, CompanionProtocol.maximumCacheCharacters))

        var loaded: CompanionState
        var failure: String?
        switch Self.load(fileURL: fileURL) {
        case .missing:
            loaded = CompanionState()
            loaded.phoneStoreEpoch = UUID().uuidString.lowercased()
            if !Self.persist(loaded, to: fileURL) {
                failure = "Could not initialize the companion journal."
                loaded.lastError = failure
            }
        case .loaded(let state):
            loaded = state
            if loaded.phoneStoreEpoch.isEmpty {
                loaded.phoneStoreEpoch = UUID().uuidString.lowercased()
                if !Self.persist(loaded, to: fileURL) {
                    failure = "Could not initialize the companion journal."
                    loaded.lastError = failure
                }
            }
        case .failed(let error):
            loaded = CompanionState(lastError: error)
            failure = error
        }
        self.journalFailure = failure
        self.state = Self.bounded(loaded, maxMessages: self.maxMessages, maxCharacters: self.maxCharacters)
    }

    public func currentState() -> CompanionState { state }

    @discardableResult
    public func merge(_ snapshot: CompanionSnapshot) -> CompanionState {
        guard journalFailure == nil else { return state }
        guard let snapshot = snapshot.validated() else {
            state.lastError = "The phone sent an invalid companion snapshot."
            persist()
            return state
        }
        let epochChanged = !snapshot.phoneStoreEpoch.isEmpty
            && snapshot.phoneStoreEpoch != state.phoneStoreEpoch
        guard !state.phoneEpochConfirmed || !snapshot.phoneStoreEpoch.isEmpty else {
            return state
        }
        guard !epochChanged || !state.phoneEpochConfirmed else {
            return state
        }
        // Application context and queued user-info packets can arrive out of
        // order. Once an epoch is established, an older snapshot must never
        // replace the cache or make a fresh sync look stale.
        guard epochChanged
                || (state.generatedAt == nil && state.lastSnapshotRevision == 0)
                || snapshot.revision > state.lastSnapshotRevision else {
            return state
        }
        let previousState = state
        let oldAccountLinks = Set(state.folders.map(\.accountLinkID))
        if epochChanged {
            rebaseForPhoneInstallation(snapshot.phoneStoreEpoch)
        }
        let folderLinks = Set(snapshot.folders.map(\.canonicalLink))
        let accountLinks = Set(snapshot.folders.map(\.accountLinkID))

        if !epochChanged {
            for index in state.commands.indices where
                oldAccountLinks.contains(state.commands[index].command.accountLinkID)
                    && !accountLinks.contains(state.commands[index].command.accountLinkID)
                    && state.commands[index].status != .failed
                    && state.commands[index].status != .needsReview
            {
                let command = state.commands[index].command
                state.commands[index].status = .failed
                state.commands[index].failureReason = "The account was removed from iPhone."
                state.commands[index].updatedAt = Date()
                revertOptimism(command)
            }
        }

        var existingByLink: [String: CompanionMessageSnapshot] = [:]
        if !epochChanged {
            for message in state.messages where accountLinks.contains(message.accountLinkID)
                && folderLinks.contains(message.folderLink)
            {
                existingByLink[message.canonicalLink] = message
            }
        }

        // Snapshot order is the phone's effective per-folder list order. Keep
        // it as the primary sequence, then retain omitted cached messages in
        // their previous order until bounded retention trims the tail.
        var mergedMessages: [CompanionMessageSnapshot] = []
        mergedMessages.reserveCapacity(snapshot.messages.count + existingByLink.count)
        var incomingLinks: Set<String> = []
        incomingLinks.reserveCapacity(snapshot.messages.count)
        for incoming in snapshot.messages {
            var message = incoming
            if let old = existingByLink[incoming.canonicalLink] {
                message = Self.applyOutstandingOptimism(to: incoming, old: old, commands: state.commands)
            }
            mergedMessages.append(message)
            incomingLinks.insert(incoming.canonicalLink)
        }
        for message in state.messages where
            existingByLink[message.canonicalLink] != nil
                && !incomingLinks.contains(message.canonicalLink)
        {
            mergedMessages.append(message)
        }

        state.folders = snapshot.folders
        state.messages = mergedMessages
        if !snapshot.phoneStoreEpoch.isEmpty {
            state.phoneStoreEpoch = snapshot.phoneStoreEpoch
            state.phoneEpochConfirmed = true
        }
        state.lastSnapshotRevision = epochChanged ? snapshot.revision : max(state.lastSnapshotRevision, snapshot.revision)
        state.generatedAt = snapshot.generatedAt
        state.lastSyncAt = snapshot.lastSyncAt ?? snapshot.generatedAt
        if !epochChanged || state.lastError == nil {
            state.lastError = nil
        }
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return state
        }
        return state
    }

    /// Inserts a Watch command and applies its local optimistic value. The
    /// command is written before the caller sends its durable user-info packet.
    @discardableResult
    public func enqueue(_ command: CompanionCommand) -> CompanionState? {
        guard journalFailure == nil else { return nil }
        let activeCount = state.commands.filter {
            $0.status == .pendingOnWatch || $0.status == .acceptedByPhone
        }.count
        guard command.isSyntacticallyValid,
              !state.commands.contains(where: { $0.id == command.id }),
              activeCount < CompanionProtocol.maximumCommandCount else { return nil }
        let previousState = state
        state.commandSequence = max(state.commandSequence, command.sequence)
        state.commandSequence &+= 1
        let sequenced = command.withSequence(state.commandSequence)
        state.commands.append(CompanionCommandRecord(command: sequenced))
        applyOptimism(sequenced)
        state.lastError = nil
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return nil
        }
        return state
    }
    /// Applies an acknowledgement. Phone acceptance means the operation entered
    /// the phone's durable queue; submitted means it reached MailFacade's queue,
    /// not that an IMAP server completed it. `needsReview` means the phone
    /// cannot prove whether execution reached MailFacade and must not replay it.
    public func apply(_ ack: CompanionCommandAck) -> CompanionState {
        guard journalFailure == nil else { return state }
        guard let index = state.commands.firstIndex(where: { $0.id == ack.commandID }),
              state.commands[index].command.accountLinkID == ack.accountLinkID else { return state }
        if let epoch = ack.phoneStoreEpoch, !epoch.isEmpty,
           !state.phoneStoreEpoch.isEmpty,
           epoch != state.phoneStoreEpoch {
            return state
        }
        let previousState = state
        switch ack.status {
        case .acceptedByPhone:
            guard state.commands[index].status == .pendingOnWatch
                    || state.commands[index].status == .acceptedByPhone else {
                return state
            }
            state.commands[index].updatedAt = ack.receivedAt
            state.commands[index].status = .acceptedByPhone
            state.commands[index].phoneStoreEpoch = ack.phoneStoreEpoch ?? state.phoneStoreEpoch
            state.commands[index].failureReason = nil
        case .submittedToMailQueue:
            guard state.commands[index].status == .pendingOnWatch
                    || state.commands[index].status == .acceptedByPhone
                    || state.commands[index].status == .submittedToMailQueue else {
                return state
            }
            state.commands[index].updatedAt = ack.receivedAt
            state.commands[index].status = .submittedToMailQueue
            state.commands[index].execution = .submittedToFacade
            state.commands[index].phoneStoreEpoch = ack.phoneStoreEpoch ?? state.commands[index].phoneStoreEpoch
            state.commands[index].failureReason = nil
            if state.commands[index].command.mutation.isMove
                || state.commands[index].command.mutation == .archive
                || state.commands[index].command.mutation == .trash
            {
                if let messageIndex = state.messages.firstIndex(where: {
                    $0.canonicalLink == state.commands[index].command.messageLink
                }) {
                    state.messages[messageIndex].isPendingRemoval = false
                    reapplyOutstandingOptimism(for: state.commands[index].command.messageLink)
                }
            }
        case .needsReview:
            guard state.commands[index].status == .pendingOnWatch
                    || state.commands[index].status == .acceptedByPhone
                    || state.commands[index].status == .submittedToMailQueue else {
                return state
            }
            state.commands[index].updatedAt = ack.receivedAt
            state.commands[index].status = .needsReview
            state.commands[index].execution = .inFlight
            state.commands[index].phoneStoreEpoch = ack.phoneStoreEpoch ?? state.commands[index].phoneStoreEpoch
            state.commands[index].failureReason =
                ack.reason ?? "Delivery status unknown; review before retrying."
            reapplyOutstandingOptimism(for: state.commands[index].command.messageLink)
            state.lastError = state.commands[index].failureReason
        case .failed:
            guard state.commands[index].status == .pendingOnWatch
                    || state.commands[index].status == .acceptedByPhone else {
                return state
            }
            state.commands[index].updatedAt = ack.receivedAt
            state.commands[index].status = .failed
            state.commands[index].failureReason = ack.reason ?? "The phone rejected this action."
            revertOptimism(state.commands[index].command)
            reapplyOutstandingOptimism(for: state.commands[index].command.messageLink)
            state.lastError = state.commands[index].failureReason
        }
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return state
        }
        return state
    }

    /// Returns a durable phone-side acceptance. A duplicate command is accepted
    /// only when it is the same command payload; only a never-started command
    /// may be replayed after restart.
    public func acceptOnPhone(_ command: CompanionCommand) -> PhoneCommandAcceptance? {
        guard journalFailure == nil else { return nil }
        guard command.isSyntacticallyValid else { return nil }
        if let index = state.commands.firstIndex(where: { $0.id == command.id }) {
            guard state.commands[index].command == command else { return nil }
            let record = state.commands[index]
            let execute = record.status == .acceptedByPhone && record.execution == .notStarted
            return PhoneCommandAcceptance(record: record, shouldExecute: execute)
        }
        let activeCount = state.commands.filter {
            $0.status == .acceptedByPhone || $0.status == .pendingOnWatch
        }.count
        guard activeCount < CompanionProtocol.maximumCommandCount else { return nil }
        let previousState = state
        let record = CompanionCommandRecord(
            command: command,
            status: .acceptedByPhone,
            phoneStoreEpoch: state.phoneStoreEpoch
        )
        state.commandSequence = max(state.commandSequence, command.sequence)
        state.commands.append(record)
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return nil
        }
        return PhoneCommandAcceptance(record: record, shouldExecute: true)
    }
    /// Marks execution before invoking MailFacade. A crash after this point is
    /// treated as ambiguous and is deliberately not retried on restart.
    @discardableResult
    public func markExecutionStarted(commandID: String) -> Bool {
        guard journalFailure == nil else { return false }
        guard let index = state.commands.firstIndex(where: { $0.id == commandID }),
              state.commands[index].status == .acceptedByPhone,
              state.commands[index].execution == .notStarted else { return false }
        let previousState = state
        state.commands[index].execution = .inFlight
        state.commands[index].updatedAt = Date()
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return false
        }
        return true
    }

    /// Marks a command terminal once MailFacade has durably accepted it.
    public func markExecutionSubmitted(commandID: String) -> CompanionCommandAck? {
        guard journalFailure == nil else { return nil }
        guard let index = state.commands.firstIndex(where: { $0.id == commandID }),
              state.commands[index].status == .acceptedByPhone else { return nil }
        let previousState = state
        let record = state.commands[index]
        state.commands[index].status = .submittedToMailQueue
        state.commands[index].execution = .submittedToFacade
        state.commands[index].failureReason = nil
        state.commands[index].updatedAt = Date()
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return nil
        }
        return CompanionCommandAck(
            commandID: record.command.id,
            accountLinkID: record.command.accountLinkID,
            status: .submittedToMailQueue,
            phoneStoreEpoch: state.phoneStoreEpoch
        )
    }

    @discardableResult
    public func markExecutionFailed(commandID: String, reason: String) -> CompanionCommandAck? {
        guard journalFailure == nil else { return nil }
        guard let index = state.commands.firstIndex(where: { $0.id == commandID }) else { return nil }
        let previousState = state
        let record = state.commands[index]
        guard record.status == .acceptedByPhone else { return nil }
        let failureReason = String(reason.prefix(512))
        state.commands[index].status = .failed
        state.commands[index].failureReason = failureReason
        state.commands[index].updatedAt = Date()
        state.lastError = failureReason
        revertOptimism(record.command)
        reapplyOutstandingOptimism(for: record.command.messageLink)
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return nil
        }
        return CompanionCommandAck(commandID: record.command.id, accountLinkID: record.command.accountLinkID,
                                   status: .failed, reason: failureReason,
                                   phoneStoreEpoch: state.phoneStoreEpoch)
    }

    /// Commands are drained in explicit Watch sequence order, not task arrival
    /// order. Commands marked in-flight are excluded after a crash because
    /// their delivery outcome is ambiguous.
    public func nextExecutablePhoneCommand() -> CompanionCommand? {
        state.commands
            .filter { $0.status == .acceptedByPhone && $0.execution == .notStarted }
            .sorted {
                if $0.command.sequence != $1.command.sequence {
                    return $0.command.sequence < $1.command.sequence
                }
                return $0.enqueuedAt < $1.enqueuedAt
            }
            .first?.command
    }

    /// Returns accepted commands that were durably queued but never started.
    /// These are safe to execute after a restart.
    public func recoverablePhoneCommands() -> [CompanionCommand] {
        state.commands
            .filter { $0.status == .acceptedByPhone && $0.execution == .notStarted }
            .sorted {
                if $0.command.sequence != $1.command.sequence {
                    return $0.command.sequence < $1.command.sequence
                }
                return $0.enqueuedAt < $1.enqueuedAt
            }
            .map(\.command)
    }

    /// Converts commands interrupted after the durable execution marker into
    /// an explicit review outcome. The returned acknowledgements let the Watch
    /// replace its accepted/forever-queued presentation without replaying a
    /// non-idempotent operation.
    @discardableResult
    public func recoverPhoneCommands() -> [CompanionCommandAck] {
        guard journalFailure == nil else { return [] }
        let interrupted = state.commands.indices.filter {
            state.commands[$0].status == .acceptedByPhone
                && state.commands[$0].execution == .inFlight
        }
        guard !interrupted.isEmpty else { return [] }
        let previousState = state
        var acknowledgements: [CompanionCommandAck] = []
        acknowledgements.reserveCapacity(interrupted.count)
        let reason = "Delivery status unknown: iPhone stopped while applying this action. Review before retrying."
        for index in interrupted {
            state.commands[index].status = .needsReview
            state.commands[index].failureReason = reason
            state.commands[index].updatedAt = Date()
            let command = state.commands[index].command
            acknowledgements.append(CompanionCommandAck(
                commandID: command.id,
                accountLinkID: command.accountLinkID,
                status: .needsReview,
                reason: reason,
                phoneStoreEpoch: state.phoneStoreEpoch,
                receivedAt: state.commands[index].updatedAt
            ))
        }
        state.lastError = "Delivery status unknown for \(interrupted.count) action(s). Review before retrying."
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return []
        }
        return acknowledgements
    }
    /// Reconciles a phone installation handshake without waiting for a mailbox
    /// snapshot. Commands accepted by a previous installation become explicit
    /// delivery-unknown review outcomes; pending Watch commands remain retryable.
    public func reconcilePhoneStoreEpoch(_ epoch: String) -> CompanionState {
        guard journalFailure == nil else { return state }
        guard !epoch.isEmpty, epoch != state.phoneStoreEpoch else { return state }
        let previousState = state
        rebaseForPhoneInstallation(epoch)
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return state
        }
        return state
    }

    @discardableResult
    public func enqueueHandoff(messageLink: String) -> CompanionHandoffRecord? {
        guard journalFailure == nil else { return nil }
        guard let link = CompanionDeepLink(rawValue: messageLink), link.kind == .message,
              state.handoffs.filter({ $0.status == .pending }).count < CompanionProtocol.maximumCommandCount else {
            return nil
        }
        let previousState = state
        let record = CompanionHandoffRecord(messageLink: link.rawValue)
        state.handoffs.append(record)
        state.lastError = nil
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return nil
        }
        return record
    }
    /// Claims a handoff on the phone before awaiting UI routing. A duplicate
    /// request never invokes the callback a second time.
    public func acceptHandoffOnPhone(_ request: CompanionHandoffRequest) -> PhoneHandoffAcceptance? {
        guard journalFailure == nil else { return nil }
        guard request.isSyntacticallyValid else { return nil }
        if let index = state.handoffs.firstIndex(where: { $0.id == request.id }) {
            guard state.handoffs[index].messageLink == request.messageLink else { return nil }
            guard state.handoffs[index].status == .pending,
                  state.handoffs[index].routingStartedAt == nil else {
                return PhoneHandoffAcceptance(record: state.handoffs[index], shouldRoute: false)
            }
            let previousState = state
            let claimedAt = Date()
            state.handoffs[index].routingStartedAt = claimedAt
            state.handoffs[index].updatedAt = claimedAt
            state.revision &+= 1
            state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
            guard persist() else {
                restoreAfterPersistenceFailure(previousState)
                return nil
            }
            return PhoneHandoffAcceptance(record: state.handoffs[index], shouldRoute: true)
        }
        let previousState = state
        let record = CompanionHandoffRecord(
            id: request.id,
            messageLink: request.messageLink,
            routingStartedAt: Date(),
            createdAt: request.createdAt
        )
        state.handoffs.append(record)
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return nil
        }
        return PhoneHandoffAcceptance(record: record, shouldRoute: true)
    }

    @discardableResult
    public func completeHandoffOnPhone(_ ack: CompanionHandoffAck) -> CompanionState? {
        guard journalFailure == nil else { return nil }
        guard let index = state.handoffs.firstIndex(where: { $0.id == ack.requestID }),
              state.handoffs[index].messageLink == ack.messageLink,
              state.handoffs[index].status == .pending,
              state.handoffs[index].routingStartedAt != nil,
              ack.status == .accepted || ack.status == .failed else { return nil }
        let previousState = state
        state.handoffs[index].status = ack.status
        state.handoffs[index].failureReason = ack.reason
        state.handoffs[index].routingStartedAt = nil
        state.handoffs[index].updatedAt = ack.receivedAt
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return state
        }
        return state
    }

    /// A crash after claiming a handoff is ambiguous. Mark it failed on the
    /// next phone launch so a later delivery cannot silently invoke it twice.
    public func recoverPhoneHandoffs() {
        guard journalFailure == nil else { return }
        let previousState = state
        var changed = false
        for index in state.handoffs.indices where state.handoffs[index].routingStartedAt != nil {
            state.handoffs[index].routingStartedAt = nil
            state.handoffs[index].status = .failed
            state.handoffs[index].failureReason =
                "Delivery status unknown: iPhone stopped while opening this message."
            state.handoffs[index].updatedAt = Date()
            changed = true
        }
        guard changed else { return }
        state.lastError = "Delivery status unknown for a previous Continue on iPhone request."
        state.revision &+= 1
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return
        }
    }

    @discardableResult
    public func apply(_ ack: CompanionHandoffAck) -> CompanionState {
        guard journalFailure == nil else { return state }
        guard let index = state.handoffs.firstIndex(where: { $0.id == ack.requestID }),
              state.handoffs[index].messageLink == ack.messageLink,
              state.handoffs[index].status == .pending else { return state }
        let previousState = state
        state.handoffs[index].updatedAt = ack.receivedAt
        state.handoffs[index].status = ack.status
        state.handoffs[index].failureReason = ack.reason
        state.handoffs[index].routingStartedAt = nil
        if ack.status == .failed {
            state.lastError = ack.reason ?? "The phone could not open this message."
        }
        state.revision &+= 1
        state = Self.bounded(state, maxMessages: maxMessages, maxCharacters: maxCharacters)
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return state
        }
        return state
    }

    @discardableResult
    public func apply(_ notice: CompanionTransportNotice) -> CompanionState {
        guard journalFailure == nil else { return state }
        let previousState = state
        state.lastError = notice.message
        state.revision &+= 1
        guard persist() else {
            restoreAfterPersistenceFailure(previousState)
            return state
        }
        return state
    }
    private func rebaseForPhoneInstallation(_ epoch: String) {
        let unknown = state.commands.filter {
            $0.status == .acceptedByPhone || $0.status == .submittedToMailQueue
        }.count
        for index in state.commands.indices where
            state.commands[index].status == .acceptedByPhone
                || state.commands[index].status == .submittedToMailQueue
        {
            state.commands[index].status = .needsReview
            state.commands[index].failureReason =
                "Delivery status unknown: the previous iPhone installation was reset. Review before retrying."
            state.commands[index].updatedAt = Date()
        }
        for index in state.handoffs.indices where state.handoffs[index].status == .pending {
            state.handoffs[index].status = .failed
            state.handoffs[index].failureReason =
                "The previous iPhone installation was reset before this handoff was routed."
            state.handoffs[index].routingStartedAt = nil
            state.handoffs[index].updatedAt = Date()
        }
        state.phoneStoreEpoch = String(epoch.prefix(128))
        state.phoneEpochConfirmed = true
        state.lastSnapshotRevision = 0
        state.generatedAt = nil
        state.lastSyncAt = nil
        state.folders = []
        state.messages = []
        if unknown > 0 {
            state.lastError =
                "Delivery status unknown for \(unknown) action(s): the previous iPhone installation was reset."
        }
    }

    private func applyOptimism(_ command: CompanionCommand) {
        guard let index = state.messages.firstIndex(where: { $0.canonicalLink == command.messageLink }) else { return }
        switch command.mutation {
        case .markRead: state.messages[index].isRead = true
        case .markUnread: state.messages[index].isRead = false
        case .setFlagged(let value): state.messages[index].isFlagged = value
        case .archive, .trash, .move: state.messages[index].isPendingRemoval = true
        }
    }

    private func revertOptimism(_ command: CompanionCommand) {
        guard let index = state.messages.firstIndex(where: { $0.canonicalLink == command.messageLink }) else { return }
        switch command.mutation {
        case .markRead:
            if let previous = command.previousIsRead { state.messages[index].isRead = previous }
        case .markUnread:
            if let previous = command.previousIsRead { state.messages[index].isRead = previous }
        case .setFlagged:
            if let previous = command.previousIsFlagged { state.messages[index].isFlagged = previous }
        case .archive, .trash, .move: state.messages[index].isPendingRemoval = false
        }
    }
    private static func bounded(_ value: CompanionState, maxMessages: Int, maxCharacters: Int) -> CompanionState {
        var state = value
        state.folders = Array(state.folders.prefix(256))
        var retainedMessages: [CompanionMessageSnapshot] = []
        retainedMessages.reserveCapacity(min(maxMessages, state.messages.count))
        var bodyCharacters = 0
        // Never sort here: state.messages is the phone's transferred folder
        // order. Prefix retention is deterministic and keeps that order
        // intact across persistence and Watch reloads.
        for message in state.messages {
            guard retainedMessages.count < maxMessages else { break }
            var boundedMessage = message
            let messageBytes = message.bodyText?.utf8.count ?? 0
            if bodyCharacters + messageBytes <= maxCharacters {
                bodyCharacters += messageBytes
            } else {
                boundedMessage.bodyText = nil
            }
            retainedMessages.append(boundedMessage)
        }
        state.messages = retainedMessages

        // Never discard an unresolved queue entry merely to make room for
        // history. Terminal records are the only records eligible for pruning.
        let active = state.commands.filter {
            $0.status == .pendingOnWatch || $0.status == .acceptedByPhone
        }
        let terminal = state.commands
            .filter {
                $0.status == .failed
                    || $0.status == .needsReview
                    || $0.status == .submittedToMailQueue
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, CompanionProtocol.maximumCommandCount - active.count))
        state.commands = (active + Array(terminal)).sorted { $0.enqueuedAt < $1.enqueuedAt }
        return state
    }
    private func reapplyOutstandingOptimism(for messageLink: String) {
        guard let index = state.messages.firstIndex(where: { $0.canonicalLink == messageLink }) else { return }
        let records = state.commands
            .filter {
                $0.command.messageLink == messageLink
                    && ($0.status == .pendingOnWatch || $0.status == .acceptedByPhone)
            }
            .sorted {
                if $0.command.sequence != $1.command.sequence {
                    return $0.command.sequence < $1.command.sequence
                }
                return $0.enqueuedAt < $1.enqueuedAt
            }
        for record in records {
            switch record.command.mutation {
            case .markRead: state.messages[index].isRead = true
            case .markUnread: state.messages[index].isRead = false
            case .setFlagged(let value): state.messages[index].isFlagged = value
            case .archive, .trash, .move: state.messages[index].isPendingRemoval = true
            }
        }
    }

    private static func applyOutstandingOptimism(to incoming: CompanionMessageSnapshot,
                                                  old: CompanionMessageSnapshot,
                                                  commands: [CompanionCommandRecord]) -> CompanionMessageSnapshot {
        var result = incoming
        let records = commands.filter {
            $0.command.messageLink == incoming.canonicalLink
                && ($0.status == .pendingOnWatch || $0.status == .acceptedByPhone)
        }.sorted {
            if $0.command.sequence != $1.command.sequence {
                return $0.command.sequence < $1.command.sequence
            }
            return $0.command.createdAt < $1.command.createdAt
        }
        for record in records {
            switch record.command.mutation {
            case .markRead: result.isRead = true
            case .markUnread: result.isRead = false
            case .setFlagged(let value): result.isFlagged = value
            case .archive, .trash, .move: result.isPendingRemoval = true
            }
        }
        if result.bodyText == nil { result.bodyText = old.bodyText }
        if records.isEmpty { result.isPendingRemoval = old.isPendingRemoval && incoming.isPendingRemoval }
        return result
    }

    @discardableResult
    private func persist() -> Bool {
        guard journalFailure == nil else { return false }
        let succeeded = Self.persist(state, to: fileURL)
        if !succeeded {
            let error = "Could not save the companion journal."
            journalFailure = error
            state.lastError = error
        }
        return succeeded
    }

    private func restoreAfterPersistenceFailure(_ previousState: CompanionState) {
        let error = journalFailure ?? state.lastError ?? "Could not save the companion journal."
        state = previousState
        state.lastError = error
    }

    private static func persist(_ state: CompanionState, to fileURL: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    private static func load(fileURL: URL) -> LoadResult {
        let existedBeforeRead = FileManager.default.fileExists(atPath: fileURL.path)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if !existedBeforeRead {
                return .missing
            }
            return .failed("Could not read the companion journal: \(error.localizedDescription)")
        }
        do {
            let decoded = try Self.decoder.decode(CompanionState.self, from: data)
            guard decoded.schema == CompanionProtocol.schema,
                  decoded.version == CompanionProtocol.version else {
                return .failed("Unsupported companion journal schema or version.")
            }
            return .loaded(decoded)
        } catch {
            return .failed("Could not decode the companion journal: \(error.localizedDescription)")
        }
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
