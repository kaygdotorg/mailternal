import AppKit
import Foundation
import MailternalAutomation
import MailternalInterfaces
import MailternalPairing
import MailternalWorkspace


/// AppModel is the sole adapter between the native UI/runtime and the shared
/// automation interface. The adapter keeps command payloads and GUI-only
/// mechanics out of MailFacade.
extension AppModel {
    /// Starts the local listener asynchronously. The setup task is retained
    /// so startup can await the same ownership result instead of racing it.
    func startAutomation() {
        guard automationServer == nil, automationSetupTask == nil else { return }
        automationSetupTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            let acquired = await self.startAutomationListener()
            if !acquired, self.isHeadlessEngineMode {
                self.scheduleHeadlessTermination()
            }
            return acquired
        }
    }

    /// Startup uses this result as the engine-ownership gate. A failed lease
    /// must leave the facade stopped rather than starting a second drainer.
    func waitForAutomationOwnership() async -> Bool {
        if automationServer != nil { return true }
        guard let task = automationSetupTask else { return false }
        return await task.value
    }

    func setAutomationReady(_ ready: Bool) {
        automationReady = ready
        guard !automationReadinessWaiters.isEmpty else { return }
        let waiters = automationReadinessWaiters
        automationReadinessWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: ready)
        }
    }

    func waitForAutomationReady() async -> Bool {
        if automationReady { return true }
        // A live headless listener with a non-ready flag is in orderly
        // shutdown; do not leave newly accepted requests waiting forever.
        if isHeadlessEngineMode, automationServer != nil { return false }
        return await withCheckedContinuation { continuation in
            automationReadinessWaiters.append(continuation)
        }
    }

    /// Pairing completes by registering a capability grant for the remote
    /// client identity. Grants are memory-only until the pairing layer chooses
    /// its protected persistence mechanism.
    func setAutomationGrant(_ grant: AutomationGrant, for clientID: String) {
        guard !clientID.isEmpty else { return }
        automationGrants[clientID] = grant
    }

    func automationSnapshot() async throws -> AppState {
        let event = try await makeAutomationStateAndPublish(force: true)
        guard let state = event.state else {
            throw AutomationCommandError.appUnavailable
        }
        return state
    }

    func automationEvents(after revision: UInt64? = nil) async throws -> AsyncStream<AppStateEvent> {
        if await automationStateHub.currentSnapshot() == nil {
            let subscription = await automationStateHub.subscribeBeforeInitialSnapshot(after: revision)
            do {
                repeat {
                    let generation = automationPublicationGeneration
                    _ = try await makeAutomationStateAndPublish(force: true)
                    if generation == automationPublicationGeneration {
                        break
                    }
                } while !Task.isCancelled
                guard !Task.isCancelled,
                      await automationStateHub.activate(subscription)
                else {
                    throw AutomationCommandError.appUnavailable
                }
                return subscription.stream
            } catch {
                await automationStateHub.cancel(subscription)
                throw error
            }
        }

        let subscription = await automationStateHub.subscribe(after: revision)
        do {
            _ = try await makeAutomationStateAndPublish(force: true)
            return subscription.stream
        } catch {
            await automationStateHub.cancel(subscription)
            throw error
        }
    }

    /// Publishes only when an observer is present. Snapshot construction can
    /// resolve links and therefore must not run for an idle automation hub.
    /// A generation bump coalesces changes that arrive while link resolution
    /// is suspended, guaranteeing a final publication without spawning one
    /// task per mutation.
    func scheduleAutomationStatePublication() {
        automationPublicationGeneration &+= 1
        guard !suppressAutomationStatePublication,
              automationPublicationTask == nil else { return }
        automationPublicationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.automationPublicationTask = nil }
            var retryMilliseconds: Int64 = 10
            while !Task.isCancelled {
                guard await self.automationStateHub.hasSubscribers else { return }
                let generation = self.automationPublicationGeneration
                do {
                    _ = try await self.makeAutomationStateAndPublish()
                    retryMilliseconds = 10
                } catch {
                    guard await self.automationStateHub.hasSubscribers else { return }
                    if generation == self.automationPublicationGeneration {
                        try? await Task.sleep(for: .milliseconds(retryMilliseconds))
                        retryMilliseconds = min(retryMilliseconds * 2, 250)
                    }
                    continue
                }
                guard await self.automationStateHub.hasSubscribers else { return }
                guard generation == self.automationPublicationGeneration else { continue }
                return
            }
        }
    }

    /// One public command seam for native UI and authenticated transports.
    /// The FIFO is deliberately iterative: an executing command never enqueues
    /// another command and cannot await itself.
    func dispatchFromUI(_ command: Command) {
        let selectionGeneration: UInt64?
        switch command {
        case .openMessage, .selectMessages, .selectAll, .clearSelection, .selectFolder:
            listSelectionIntentGeneration &+= 1
            selectionGeneration = listSelectionIntentGeneration
            if !isListSelectionPending { isListSelectionPending = true }
        default:
            selectionGeneration = nil
        }
        let operation = enqueueCommand(command, origin: .app, grant: .local, clientID: nil, secret: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let selectionGeneration,
                   self.listSelectionIntentGeneration == selectionGeneration {
                    self.isListSelectionPending = false
                }
            }
            do {
                _ = try await operation.value
            } catch {
                toasts.post(title: "Couldn’t apply command", detail: redactedError(error), severity: .error)
            }
        }
    }

    @discardableResult
    func dispatch(
        _ command: Command,
        origin: CommandOrigin = .app,
        grant: AutomationGrant = .local,
        clientID: UUID? = nil,
        secret: String? = nil
    ) async throws -> CommandResult {
        guard !isHeadlessEngineMode || automationReady else {
            throw AutomationCommandError.appUnavailable
        }
        return try await enqueueCommand(
            command,
            origin: origin,
            grant: grant,
            clientID: clientID,
            secret: secret
        ).value
    }

    private func isCoalesciblePreview(
        _ command: Command,
        origin: CommandOrigin,
        grant: AutomationGrant,
        secret: String?
    ) -> Bool {
        guard origin == .app, grant == .local, secret == nil else { return false }
        guard case .openMessage(_, let permanent) = command else { return false }
        return !permanent
    }

    private func enqueueCommand(
        _ command: Command,
        origin: CommandOrigin,
        grant: AutomationGrant,
        clientID: UUID?,
        secret: String?
    ) -> Task<CommandResult, Error> {
        let coalescible = isCoalesciblePreview(
            command,
            origin: origin,
            grant: grant,
            secret: secret
        )
        if !coalescible {
            // A later command creates a hard FIFO boundary. A future preview
            // must queue after it rather than rewrite the earlier slot.
            pendingAutomationPreview = nil
        }
        if coalescible,
           let pending = pendingAutomationPreview,
           let operation = pending.operation {
            pending.command = command
            pending.origin = origin
            pending.grant = grant
            pending.secret = secret
            return operation
        }

        let previous = automationDispatchTail
        let operation: Task<CommandResult, Error>
        if coalescible {
            let pending = PendingAutomationPreview(
                command: command,
                origin: origin,
                grant: grant,
                secret: secret
            )
            // The mutable preview payload has one owner. Do not also capture
            // the original command across suspension, and release the slot's
            // task handle before executing so the task never retains itself.
            operation = Task { @MainActor [weak self] in
                _ = await previous?.value
                pending.operation = nil
                guard let self else { throw AutomationCommandError.appUnavailable }
                if self.pendingAutomationPreview === pending {
                    self.pendingAutomationPreview = nil
                }
                return try await self.dispatchNow(
                    pending.command,
                    origin: pending.origin,
                    grant: pending.grant,
                    clientID: nil,
                    secret: pending.secret
                )
            }
            pending.operation = operation
            pendingAutomationPreview = pending
        } else {
            operation = Task { @MainActor [weak self] in
                _ = await previous?.value
                guard let self else { throw AutomationCommandError.appUnavailable }
                return try await self.dispatchNow(
                    command,
                    origin: origin,
                    grant: grant,
                    clientID: clientID,
                    secret: secret
                )
            }
        }
        automationDispatchTail = Task { @MainActor in
            _ = try? await operation.value
        }
        return operation
    }

    private func dispatchNow(
        _ command: Command,
        origin: CommandOrigin,
        grant: AutomationGrant,
        clientID: UUID?,
        secret: String?
    ) async throws -> CommandResult {
        if command.access != .read {
            guard automationServer != nil, automationReady else {
                throw AutomationCommandError.appUnavailable
            }
        }
        if case .selectFolder(let id) = command,
           let folderID = id,
           !folders.contains(where: { $0.id == folderID }) {
            throw AutomationCommandError.unsupported("folder is unavailable")
        }
        try await authorize(command, origin: origin, grant: grant)
        try validateQueryLimit(command)
        if let context = selectionContext(in: command) {
            try validateSelection(context)
        }

        let journalRecord: CommandJournalRecord?
        if command.access != .read {
            let record = try await commandJournal.append(
                origin: origin,
                action: command.name.rawValue,
                targetIDs: commandTargetIDs(command)
            )
            do {
                try await commandJournal.begin(record.id)
            } catch {
                // The append is intentionally left durable and pending. A
                // later recovery pass can resolve it without claiming effect.
                throw error
            }
            journalRecord = record
        } else {
            journalRecord = nil
        }

        let payload: Data?
        do {
            payload = try await execute(
                command,
                secret: secret,
                origin: origin,
                grant: grant,
                clientID: clientID,
                commandID: journalRecord?.id
            )
        } catch {
            if error is CommandEffectAppliedError {
                throw error
            }
            if let journalRecord {
                do {
                    try await commandJournal.fail(journalRecord.id, error: redactedError(error))
                } catch let persistenceError {
                    throw persistenceError
                }
            }
            throw error
        }
        if let journalRecord {
            // A successful effect with an unpersisted completion is an
            // ambiguous outcome. Surface the typed error; leave the running
            // record for recovery rather than claiming it failed.
            do {
                try await commandJournal.complete(journalRecord.id, outcome: "accepted")
            } catch {
                throw CommandEffectAppliedError(
                    commandID: journalRecord.id,
                    message: "The command effect may have been applied, but completion could not be recorded: \(error.localizedDescription)"
                )
            }
        }
        let stateRevision: UInt64?
        do {
            stateRevision = try await makeAutomationStateAndPublish().revision
        } catch {
            // The effect and its durable completion already succeeded. A
            // failed observer snapshot must not invite a duplicate mutation.
            stateRevision = nil
            scheduleAutomationStatePublication()
        }
        return CommandResult(command: command.name, data: payload, stateRevision: stateRevision)
    }

    private func startAutomationListener() async -> Bool {
        guard automationServer == nil else { return true }
        let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
        let handler: @Sendable (AutomationRequest, AutomationClientContext) async -> AutomationResponse = { [weak self] request, context in
            guard let self else {
                return AutomationResponse(
                    requestID: request.requestID,
                    ok: false,
                    error: AutomationCommandError.appUnavailable.localizedDescription,
                    failure: .unavailable
                )
            }
            return await self.handleAutomationRequest(request, context: context)
        }
        let events: @Sendable (AutomationRequest, AutomationClientContext) async -> AsyncStream<AutomationResponse> = { [weak self] request, context in
            guard let self else {
                return AsyncStream { continuation in
                    continuation.yield(
                        AutomationResponse(
                            requestID: request.requestID,
                            ok: false,
                            error: AutomationCommandError.appUnavailable.localizedDescription,
                            failure: .unavailable
                        )
                    )
                    continuation.finish()
                }
            }
            return await self.automationResponseEvents(for: request, context: context)
        }
        automationHandler = handler
        automationEventsHandler = events

        enum Acquisition: Sendable {
            case acquired(AutomationRuntimeLease, AutomationTokenStore, AutomationSocketServer)
            case busy
            case failed
        }
        let journal = commandJournal
        let acquireAndStart: @Sendable () async -> Acquisition = {
            await Task.detached(priority: .utility) {
                let tokenStore = AutomationTokenStore(endpoint: endpoint)
                let lease = AutomationRuntimeLease(endpoint: endpoint)
                do {
                    try lease.acquire()
                } catch AutomationSecurityError.runtimeOwned {
                    return .busy
                } catch {
                    return .failed
                }
                do {
                    try await journal.reload()
                    _ = try await journal.recoverInterrupted()
                    _ = try tokenStore.create()
                    let server = AutomationSocketServer(endpoint: endpoint, tokenStore: tokenStore)
                    try await server.start(handler: handler, events: events)
                    return .acquired(lease, tokenStore, server)
                } catch {
                    lease.release()
                    return .failed
                }
            }.value
        }

        var acquisition = await acquireAndStart()
        if case .busy = acquisition, !isHeadlessEngineMode {
            // GUI has precedence over a headless daemon. Ask only an actual
            // lease owner to drain, then poll the lock for bounded handoff.
            await requestDaemonYield(endpoint: endpoint)
            for _ in 0..<30 {
                acquisition = await acquireAndStart()
                if case .busy = acquisition {
                    try? await Task.sleep(for: .milliseconds(100))
                } else {
                    break
                }
            }
        }
        guard case .acquired(let lease, let tokenStore, let server) = acquisition else { return false }
        automationRuntimeLease = lease
        automationTokenStore = tokenStore
        automationServer = server
        await startRemoteAutomation(endpoint: endpoint, handler: handler, events: events)
        return true
    }

    private func requestDaemonYield(endpoint: AutomationEndpoint) async {
        guard let token = try? AutomationTokenStore(endpoint: endpoint).read() else { return }
        let request = AutomationRequest(
            token: token,
            origin: .localCLI,
            control: .engineShutdown
        )
        _ = try? await Task.detached(priority: .utility) {
            try AutomationSocketClient(endpoint: endpoint).request(request)
        }.value
    }

    private func startRemoteAutomation(
        endpoint: AutomationEndpoint,
        handler: @escaping AutomationSocketServer.Handler,
        events: @escaping AutomationSocketServer.Events
    ) async {
        guard automationRemoteListener == nil else { return }
        let configurationStore = AutomationRemoteConfigurationStore(endpoint: endpoint)
        guard let configuration = try? configurationStore.load(), configuration.enabled else { return }
        guard let pairings = try? AutomationPairingStore(endpoint: endpoint) else {
            QALaunch.log("automation remote unavailable reason=pairing-store")
            return
        }
        let listener = AutomationTLSListener(endpoint: endpoint, configuration: configuration, pairings: pairings)
        do {
            try await listener.start(handler: handler, events: events)
            automationPairingStore = pairings
            automationRemoteListener = listener
        } catch {
            listener.stop()
            QALaunch.log("automation remote unavailable reason=\(error.localizedDescription)")
        }
    }

    private var automationContainerURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--mailternal-container"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        if let root = QALaunch.parse()?.containerRoot { return root }
        return MailternalContainer.default.root
    }
    private var isHeadlessEngineMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--mailternal-engine")
    }

    /// AppKit waits for asynchronous delegate shutdown. Enter its termination
    /// loop outside a MainActor task so that task cannot block the delegate.
    private func scheduleHeadlessTermination() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    private func stopAutomationRuntime() async {
        automationRemoteListener?.stop()
        automationRemoteListener = nil
        automationPairingStore = nil
        automationServer?.stop()
        automationServer = nil
        automationTokenStore = nil
        await automationTransferRegistry.shutdown()
        automationRuntimeLease?.release()
        automationRuntimeLease = nil
    }

    private func handleAutomationRequest(
        _ request: AutomationRequest,
        context: AutomationClientContext
    ) async -> AutomationResponse {
        do {
            if let control = request.control {
                switch control {
                case .pairingCreate:
                    guard context.origin == .app || context.origin == .localCLI,
                          context.grant.canMutate
                    else {
                        throw AutomationCommandError.permissionDenied(.mutate)
                    }
                    guard automationRemoteListener != nil else {
                        throw AutomationCommandError.appUnavailable
                    }
                    let grant = request.pairingGrant ?? AutomationGrant(
                        accountLinkIDs: Set(accountConfigs.map(\.accountLinkID)),
                        canRead: true
                    )
                    guard !grant.accountLinkIDs.isEmpty else {
                        throw AutomationCommandError.invalidPayload("pairing account scope")
                    }
                    let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
                    let pairings = try (automationPairingStore ?? AutomationPairingStore(endpoint: endpoint))
                    let offer = try pairings.createOffer(grant: grant)
                    let config = try AutomationRemoteConfigurationStore(endpoint: endpoint).load()
                    let identity = try AutomationTLSIdentityStore(endpoint: endpoint).loadOrCreate()
                    let result = AutomationPairingOfferResult(
                        code: offer.code,
                        offerID: offer.offer.id,
                        expiresAt: offer.offer.expiresAt,
                        host: config.bindHost,
                        port: config.port,
                        fingerprint: identity.fingerprint
                    )
                    automationPairingStore = pairings
                    return AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(result)
                    )
                case .pairingClaim:
                    guard context.origin == .app || context.origin == .localCLI,
                          context.grant.canMutate,
                          let code = request.pairingCode,
                          !code.isEmpty
                    else {
                        throw AutomationCommandError.permissionDenied(.mutate)
                    }
                    let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
                    let pairings = try (automationPairingStore ?? AutomationPairingStore(endpoint: endpoint))
                    let material = try pairings.consumeOffer(code: code)
                    let config = try AutomationRemoteConfigurationStore(endpoint: endpoint).load()
                    let identity = try AutomationTLSIdentityStore(endpoint: endpoint).loadOrCreate()
                    let pairedEndpoint = try AutomationPairedEndpoint(
                        clientID: material.client.id,
                        host: config.bindHost,
                        port: config.port,
                        bearerToken: material.bearerToken,
                        pinnedFingerprint: identity.fingerprint
                    )
                    automationPairingStore = pairings
                    return AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(AutomationPairingClaimResult(endpoint: pairedEndpoint))
                    )
                case .engineStatus:
                    return AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(
                            AutomationRuntimeStatus(
                                kind: isHeadlessEngineMode ? .daemon : .app,
                                processID: ProcessInfo.processInfo.processIdentifier,
                                ready: automationReady
                            )
                        )
                    )
                case .remoteStatus:
                    guard isLocalOrigin(context.origin) else {
                        throw AutomationCommandError.permissionDenied(.mutate)
                    }
                    let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
                    let configuration = try AutomationRemoteConfigurationStore(endpoint: endpoint).load()
                    let status = AutomationRemoteStatus(
                        enabled: configuration.enabled,
                        running: automationRemoteListener != nil,
                        host: configuration.bindHost,
                        port: configuration.port
                    )
                    return AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(status)
                    )
                case .engineShutdown:
                    guard isHeadlessEngineMode,
                          context.origin == .app || context.origin == .localCLI
                    else {
                        throw AutomationCommandError.permissionDenied(.mutate)
                    }
                    guard context.grant.canMutate else {
                        throw AutomationCommandError.permissionDenied(.mutate)
                    }
                    guard await waitForAutomationReady() else {
                        throw AutomationCommandError.appUnavailable
                    }
                    setAutomationReady(false)
                    if let tail = automationDispatchTail {
                        _ = await tail.value
                    }
                    if let live = facade as? LiveMailFacade {
                        await live.shutdown()
                    }
                    let status = AutomationRuntimeStatus(
                        kind: .daemon,
                        processID: ProcessInfo.processInfo.processIdentifier,
                        ready: false
                    )
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(for: .milliseconds(100))
                        await stopAutomationRuntime()
                        scheduleHeadlessTermination()
                    }
                    return AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(status)
                    )
                case .transferCreate:
                    guard let size = request.transferTotalBytes,
                          let filename = request.transferFilename,
                          let contentType = request.transferContentType
                    else {
                        throw AutomationCommandError.invalidPayload("transfer request")
                    }
                    let descriptor = try await automationTransferRegistry.createUpload(
                        size: size, filename: filename, contentType: contentType, context: context
                    )
                    return AutomationResponse(
                        requestID: request.requestID, ok: true,
                        result: try encodeAutomation(descriptor)
                    )
                case .transferWrite:
                    guard let transferID = request.transferID,
                          let sequence = request.transferSequence,
                          let offset = request.transferOffset,
                          let totalBytes = request.transferTotalBytes,
                          let data = request.transferData,
                          let final = request.transferFinal
                    else {
                        throw AutomationCommandError.invalidPayload("transfer request")
                    }
                    try await automationTransferRegistry.write(
                        transferID: transferID, sequence: sequence, offset: offset,
                        totalBytes: totalBytes, data: data, final: final, context: context
                    )
                    return AutomationResponse(requestID: request.requestID, ok: true)
                case .transferRead:
                    guard let transferID = request.transferID,
                          let offset = request.transferOffset,
                          let length = request.transferLength
                    else {
                        throw AutomationCommandError.invalidPayload("transfer request")
                    }
                    let chunk = try await automationTransferRegistry.read(
                        transferID: transferID,
                        offset: offset,
                        length: length,
                        context: context
                    )
                    return AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(chunk)
                    )
                case .transferCancel:
                    guard let transferID = request.transferID else {
                        throw AutomationCommandError.invalidPayload("transfer request")
                    }
                    try await automationTransferRegistry.cancel(transferID: transferID, context: context)
                    return AutomationResponse(requestID: request.requestID, ok: true)
                }
            }
            guard await waitForAutomationReady() else {
                throw AutomationCommandError.appUnavailable
            }
            if request.wantsState {
                guard grantAllows(.read, context.grant) else {
                    throw AutomationCommandError.permissionDenied(.read)
                }
                if !isLocalOrigin(context.origin) && context.grant.accountLinkIDs.isEmpty {
                    throw AutomationCommandError.permissionDenied(.read)
                }
                if request.wantsGUIState && !context.grant.canControlGUI && !isLocalOrigin(context.origin) {
                    throw AutomationCommandError.permissionDenied(.gui)
                }
                let published = try await makeAutomationStateAndPublish(force: true)
                guard let publishedState = published.state else {
                    throw AutomationCommandError.appUnavailable
                }
                let state = scopedAutomationState(
                    publishedState,
                    for: context,
                    wantsGUIState: request.wantsGUIState
                )
                let event = AppStateEvent(revision: published.revision, kind: .snapshot, state: state)
                return AutomationResponse(
                    requestID: request.requestID,
                    ok: true,
                    result: try encodeAutomation(event)
                )
            }
            guard let command = request.command else {
                throw AutomationCommandError.invalidPayload("command")
            }
            if isHeadlessEngineMode, command.requiresGUI {
                throw AutomationCommandError.appUnavailable
            }
            let dispatched = try await dispatch(
                command,
                origin: context.origin,
                grant: context.grant,
                clientID: context.clientID,
                secret: request.secret
            )
            do {
                let result: CommandResult
                if let payload = dispatched.data,
                   payload.count > AutomationTransferPolicy.inlinePayloadBytes,
                   command.name != .fetchAttachment
                {
                    let descriptor = try await automationTransferRegistry.create(
                        data: payload,
                        kind: .commandResult,
                        context: context
                    )
                    result = CommandResult(
                        command: dispatched.command,
                        data: try encodeAutomation(descriptor),
                        stateRevision: dispatched.stateRevision
                    )
                } else {
                    result = dispatched
                }
                return AutomationResponse(
                    requestID: request.requestID,
                    ok: true,
                    result: try encodeAutomation(result)
                )
            } catch {
                guard command.access != .read else { throw error }
                throw CommandEffectAppliedError(
                    commandID: request.requestID,
                    message: "The command effect may have been applied, but its response could not be encoded: \(error.localizedDescription)"
                )
            }
        } catch let error as AutomationCommandError {
            return AutomationResponse(
                requestID: request.requestID,
                ok: false,
                error: redactedError(error),
                failure: error.failure
            )
        } catch {
            return AutomationResponse(
                requestID: request.requestID,
                ok: false,
                error: redactedError(error),
                failure: automationFailure(for: error)
            )
        }
    }

    private func automationResponseEvents(
        for request: AutomationRequest,
        context: AutomationClientContext
    ) async -> AsyncStream<AutomationResponse> {
        func failure(_ error: Error) -> AsyncStream<AutomationResponse> {
            let values = AsyncStream.makeStream(
                of: AutomationResponse.self,
                bufferingPolicy: .bufferingOldest(2)
            )
            values.continuation.yield(
                AutomationResponse(
                    requestID: request.requestID,
                    ok: false,
                    error: self.redactedError(error),
                    failure: self.automationFailure(for: error)
                )
            )
            values.continuation.finish()
            return values.stream
        }

        guard request.observesState else {
            return failure(AutomationCommandError.invalidPayload("state observation request"))
        }
        guard grantAllows(.read, context.grant) else {
            return failure(AutomationCommandError.permissionDenied(.read))
        }
        if !isLocalOrigin(context.origin) && context.grant.accountLinkIDs.isEmpty {
            return failure(AutomationCommandError.permissionDenied(.read))
        }
        if request.wantsGUIState && !context.grant.canControlGUI && !isLocalOrigin(context.origin) {
            return failure(AutomationCommandError.permissionDenied(.gui))
        }

        let source: AsyncStream<AppStateEvent>
        do {
            source = try await automationEvents(after: request.afterRevision)
        } catch {
            return failure(error)
        }
        let values = AsyncStream.makeStream(
            of: AutomationResponse.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        let continuation = values.continuation
        let task = Task { @MainActor [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            for await event in source {
                guard !Task.isCancelled else { break }
                do {
                    let scopedEvent = AppStateEvent(
                        revision: event.revision,
                        kind: event.kind,
                        state: event.state.map {
                            scopedAutomationState(
                                $0,
                                for: context,
                                wantsGUIState: request.wantsGUIState
                            )
                        }
                    )
                    let response = AutomationResponse(
                        requestID: request.requestID,
                        ok: true,
                        result: try encodeAutomation(scopedEvent)
                    )
                    switch continuation.yield(response) {
                    case .enqueued:
                        break
                    case .dropped, .terminated:
                        // A dropped response breaks revision continuity.
                        // Force reconnect/resync instead of silently skipping.
                        continuation.finish()
                        return
                    @unknown default:
                        continuation.finish()
                        return
                    }
                } catch {
                    continuation.yield(
                        AutomationResponse(
                            requestID: request.requestID,
                            ok: false,
                            error: redactedError(error),
                            failure: automationFailure(for: error)
                        )
                    )
                    break
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return values.stream
    }


    private func automationLinks(
        for ids: [MessageID],
        cache: Bool = true
    ) async throws -> [MessageID: String] {
        let requestedIDs = Array(Set(ids))
        guard !requestedIDs.isEmpty else { return [:] }
        let uncached = cache
            ? requestedIDs.filter { messageDeepLinks[$0] == nil }
            : requestedIDs
        var links: [MessageID: String] = [:]
        links.reserveCapacity(requestedIDs.count)
        if cache {
            for id in requestedIDs {
                if let link = messageDeepLinks[id] {
                    links[id] = link
                }
            }
        }
        if !uncached.isEmpty {
            let states = try await facade.messageMutationStates(uncached)
            for state in states {
                guard let link = state.link?.formattedString else { continue }
                links[state.id] = link
                if cache {
                    messageDeepLinks[state.id] = link
                }
            }
        }
        if cache, messageDeepLinks.count > 2_048 {
            let evictedIDs = Array(messageDeepLinks.keys.prefix(messageDeepLinks.count - 2_048))
            for id in evictedIDs {
                messageDeepLinks.removeValue(forKey: id)
            }
        }
        return links
    }

    private func automationRows(
        _ rows: [MessageRow],
        links: [MessageID: String]
    ) -> [AutomationMessageRow] {
        rows.compactMap { row in
            guard let link = links[row.id] else { return nil }
            return AutomationMessageRow(row: row, link: link)
        }
    }

    private func automationMessagePage(
        _ page: MessagePage,
        cache: Bool
    ) async throws -> AutomationMessagePage {
        let links = try await automationLinks(for: page.rows.map(\.id), cache: cache)
        return AutomationMessagePage(
            rows: automationRows(page.rows, links: links),
            next: page.next
        )
    }

    private func makeAutomationState() async throws -> AppState {
        let allIDs = listRows.map(\.id) + searchPresentation.results.map(\.id) + tabs.tabs.map(\.message)
        let links = try await automationLinks(for: allIDs)
        var tabStates: [AutomationReaderTabState] = []
        tabStates.reserveCapacity(tabs.tabs.count)
        for (order, tab) in tabs.tabs.enumerated() {
            tabStates.append(
                AutomationReaderTabState(
                    id: tab.id,
                    messageID: tab.message,
                    link: links[tab.message],
                    isTransient: tab.isTransient,
                    order: order,
                    scrollOffset: Double(tabs.scrollOffset(for: tab.id))
                )
            )
        }
        let states = Dictionary(uniqueKeysWithValues: accountConfigs.map { account in
            (account.id, automationAccountState(accountStates[account.id] ?? .none))
        })
        let windows = automationWindows()
        let focusedSurface = windows.first(where: \.isKey)?.focusedSurface ?? "mail"
        return AppState(
            accounts: accountConfigs,
            accountStates: states,
            folders: folders.map(automationFolderState),
            selectedFolderID: selectedFolderID,
            selectedMessageIDs: selectedMessageIDs.sorted { $0.rawValue < $1.rawValue },
            selectedMessageID: selectedMessageID,
            selectionRevision: selectionRevision,
            listRows: automationRows(listRows, links: links),
            listCursor: listCursor,
            activeListSort: activeListSort,
            readerTabs: tabStates,
            activeTabID: tabs.activeID,
            focusedSurface: focusedSurface,
            visibleSearchQuery: searchPresentation.query,
            isSearchPresented: isSearchPresented,
            isFindPresented: isFindPresented,
            findQuery: isFindPresented ? findQuery : nil,
            isRawSourcePresented: isShowingRawSource,
            emailReadingMode: (emailReadingOverride ?? appearance.emailReadingMode).rawValue,
            allowRemoteImages: allowRemoteImages,
            syncOnline: syncStatus.isOnline,
            syncMode: automationSyncMode(syncStatus),
            listConfiguration: effectiveListConfiguration,
            windows: windows,
            dialogs: automationDialogs(),
            availableActions: try await automationAvailableActions(),
            settings: automationSettings(),
            searchResults: automationRows(searchPresentation.results, links: links),
            isSearchLoading: searchPresentation.isSearching,
            searchError: searchPresentation.errorMessage,
            selectedSearchResultID: searchPresentation.selectedResultID,
            searchFieldFocused: searchFieldFocused,
            outgoing: outgoingState
        )
    }

    private func makeAutomationStateAndPublish(force: Bool = false) async throws -> AppStateEvent {
        if !force {
            guard await automationStateHub.hasSubscribers else {
                return await automationStateHub.currentSnapshot()
                    ?? AppStateEvent(revision: 0, kind: .snapshot, state: nil)
            }
        }
        let state = try await makeAutomationState()
        return await automationStateHub.publish(state)
    }
    private func scopedAutomationState(
        _ state: AppState,
        for context: AutomationClientContext,
        wantsGUIState: Bool = false
    ) -> AppState {
        let local = isLocalOrigin(context.origin)
        let allowedLinks = local
            ? Set(state.accounts.map(\.accountLinkID))
            : context.grant.accountLinkIDs
        let gui = wantsGUIState && (local || context.grant.canControlGUI)
        if local && gui { return state }
        let allowedAccountIDs = Set(
            state.accounts.filter { allowedLinks.contains($0.accountLinkID) }.map(\.id)
        )
        let scopedOutgoing = OutgoingState(
            drafts: state.outgoing.drafts.filter { allowedAccountIDs.contains($0.accountID) },
            outbox: state.outgoing.outbox.filter { allowedAccountIDs.contains($0.accountID) }
        )
        let visibleFolders = state.folders.filter { allowedAccountIDs.contains($0.accountID) }
        let visibleFolderIDs = Set(visibleFolders.map(\.id))
        let visibleRows = state.listRows.filter { row in
            guard let folderID = row.folderID else { return false }
            return visibleFolderIDs.contains(folderID)
        }
        let visibleSearchResults = state.searchResults.filter { row in
            guard let folderID = row.folderID else { return false }
            return visibleFolderIDs.contains(folderID)
        }
        let visibleSearchIDs = Set(visibleSearchResults.map(\.id))
        let visibleMessageIDs = Set(visibleRows.map(\.id)).union(visibleSearchIDs)
        let selectedFolder = state.selectedFolderID.flatMap { visibleFolderIDs.contains($0) ? $0 : nil }
        let selectedIDs = state.selectedMessageIDs.filter(visibleMessageIDs.contains)
        let selectedID = state.selectedMessageID.flatMap { visibleMessageIDs.contains($0) ? $0 : nil }
        let visibleTabs = state.readerTabs.filter { tab in
            guard let rawLink = tab.link,
                  let link = MailternalDeepLink(string: rawLink),
                  case .message(_, _, _, _) = link
            else {
                return false
            }
            return allowedLinks.contains(link.accountLinkID)
        }
        let allAccountsCovered = Set(
            state.accounts.map(\.accountLinkID)
        ).isSubset(of: allowedLinks)
        let selectedFolderLink = selectedFolder.flatMap { folderID in
            visibleFolders.first(where: { $0.id == folderID }).flatMap { folder in
                state.accounts.first(where: { $0.id == folder.accountID })?.accountLinkID
            }
        }
        let selectedAccountCovered = selectedFolderLink.map(allowedLinks.contains) ?? false
        let scopedActions: [AutomationActionState] = gui
            ? state.availableActions
                .filter { !$0.id.hasPrefix("pairing.") }
                .filter {
                    local || pairedActionAllowed($0, state: state, grant: context.grant)
                }
                .map { action in
                    let enabled: Bool
                    if action.requiresSelection {
                        enabled = !selectedIDs.isEmpty
                    } else if action.id == CommandName.selectAll.rawValue {
                        enabled = selectedFolder != nil
                    } else {
                        enabled = action.isEnabled
                    }
                    return AutomationActionState(
                        id: action.id,
                        isEnabled: enabled,
                        requiresSelection: action.requiresSelection,
                        requiresGUI: action.requiresGUI
                    )
                }
            : []
        return AppState(
            accounts: state.accounts.filter { allowedAccountIDs.contains($0.id) },
            accountStates: state.accountStates.filter { allowedAccountIDs.contains($0.key) },
            folders: visibleFolders,
            selectedFolderID: gui ? selectedFolder : nil,
            selectedMessageIDs: gui ? selectedIDs : [],
            selectedMessageID: gui ? selectedID : nil,
            selectionRevision: gui ? state.selectionRevision : 0,
            listRows: gui ? visibleRows : [],
            listCursor: gui && selectedFolder == state.selectedFolderID ? state.listCursor : nil,
            activeListSort: gui ? state.activeListSort : .newest,
            readerTabs: gui ? visibleTabs : [],
            activeTabID: gui
                ? state.activeTabID.flatMap { active in visibleTabs.contains(where: { $0.id == active }) ? active : nil }
                : nil,
            focusedSurface: gui
                ? (
                    allAccountsCovered || !["search", "search-field"].contains(state.focusedSurface)
                        ? state.focusedSurface
                        : "mail"
                )
                : "mail",
            visibleSearchQuery: gui && allAccountsCovered ? state.visibleSearchQuery : nil,
            isSearchPresented: gui && allAccountsCovered && state.isSearchPresented,
            isFindPresented: gui && (allAccountsCovered || selectedAccountCovered) && state.isFindPresented,
            findQuery: gui && (allAccountsCovered || selectedAccountCovered) ? state.findQuery : nil,
            isRawSourcePresented: gui && (allAccountsCovered || selectedAccountCovered) && state.isRawSourcePresented,
            emailReadingMode: gui && allAccountsCovered ? state.emailReadingMode : nil,
            allowRemoteImages: gui && (allAccountsCovered || selectedAccountCovered) ? state.allowRemoteImages : false,
            syncOnline: local ? state.syncOnline : false,
            syncMode: local ? state.syncMode : "scoped",
            listConfiguration: gui && (allAccountsCovered || selectedAccountCovered)
                ? state.listConfiguration
                : .default,
            // Detached windows are exposed remotely only when their explicit
            // account ownership is in the granted scope; global dialogs remain
            // unavailable to account-scoped clients.
            windows: gui ? automationWindows(scopedTo: allowedLinks) : [],
            dialogs: [],
            availableActions: scopedActions,
            settings: [:],
            searchResults: gui && allAccountsCovered ? visibleSearchResults : [],
            isSearchLoading: gui && allAccountsCovered && state.isSearchLoading,
            selectedSearchResultID: gui && allAccountsCovered
                ? state.selectedSearchResultID.flatMap { visibleSearchIDs.contains($0) ? $0 : nil }
                : nil,
            searchFieldFocused: gui && allAccountsCovered && state.searchFieldFocused,
            outgoing: scopedOutgoing
        )
    }


    private func automationWindows() -> [AutomationWindowState] {
        NSApp.windows.compactMap { window in
            let objectID = ObjectIdentifier(window)
            let id: UUID
            if let identifier = window.identifier?.rawValue,
               let parsed = UUID(uuidString: identifier) {
                id = parsed
            } else if let existing = automationWindowIDs[objectID] {
                id = existing
            } else {
                let generated = UUID()
                automationWindowIDs[objectID] = generated
                id = generated
            }
            let focusedSurface: String?
            if !window.isKeyWindow {
                focusedSurface = nil
            } else if window === MainWindowController.shared.window {
                focusedSurface = searchFieldFocused ? "search-field"
                    : (readerHasFocus(in: window) ? "reader" : (isSearchPresented ? "search" : "message-list"))
            } else {
                focusedSurface = MainWindowController.shared.isReaderFocused(in: window) ? "reader" : "mail"
            }
            return AutomationWindowState(
                id: id,
                kind: window.className,
                title: window.title.isEmpty ? nil : window.title,
                isVisible: window.isVisible,
                isKey: window.isKeyWindow,
                focusedSurface: focusedSurface
            )
        }
    }
    private func automationWindows(scopedTo accountLinks: Set<AccountLinkID>) -> [AutomationWindowState] {
        let windows = automationWindows()
        let ownedIDs = Set(NSApp.windows.compactMap { window -> UUID? in
            guard let accountLinkID = automationWindowAccountLinkID(for: window),
                  accountLinks.contains(accountLinkID)
            else {
                return nil
            }
            return automationWindowIDs[ObjectIdentifier(window)]
        })
        return windows.filter { ownedIDs.contains($0.id) }
    }

    private func automationDialogs() -> [AutomationDialogState] {
        var dialogs = [
            AutomationDialogState(id: "search", kind: "search", isPresented: isSearchPresented),
            AutomationDialogState(id: "find", kind: "find", isPresented: isFindPresented),
            AutomationDialogState(id: "raw-source", kind: "raw-source", isPresented: isShowingRawSource)
        ]
        if let pairing = pairingAutomation.currentDialogState {
            dialogs.append(pairing)
        } else if isPairingPresented {
            dialogs.append(AutomationDialogState(id: "pairing", kind: "pairing", isPresented: true))
        }
        return dialogs
    }

    private func automationAvailableActions() async throws -> [AutomationActionState] {
        let hasSelection = !selectedMessageIDs.isEmpty
        let hasFolder = selectedFolderID != nil
        let hasDetail = detail != nil
        let hasSearchResults = !searchPresentation.results.isEmpty
        let hasTabs = !tabs.tabs.isEmpty
        let undoEnabled = try await facade.canUndo(allowedAccountLinks: nil)
        func action(
            _ name: CommandName,
            _ enabled: Bool,
            selection: Bool = false,
            gui: Bool = true
        ) -> AutomationActionState {
            AutomationActionState(
                id: name.rawValue,
                isEnabled: enabled,
                requiresSelection: selection,
                requiresGUI: gui
            )
        }

        var actions = [
            action(.markRead, hasSelection, selection: true, gui: false),
            action(.markUnread, hasSelection, selection: true, gui: false),
            action(.setFlagged, hasSelection, selection: true, gui: false),
            action(.archive, hasSelection, selection: true, gui: false),
            action(.trash, hasSelection, selection: true, gui: false),
            action(.move, hasSelection && hasFolder, selection: true, gui: false),
            action(.refresh, true, gui: false),
            action(.undo, undoEnabled, gui: false),
            action(.selectFolder, !folders.isEmpty),
            action(.selectMessages, !listRows.isEmpty, selection: true),
            action(.selectAll, hasFolder),
            action(.clearSelection, hasSelection),
            action(.openMessage, !listRows.isEmpty),
            action(.openSearchResult, hasSearchResults),
            action(.openWindow, !listRows.isEmpty),
            action(.activateTab, hasTabs),
            action(.closeTab, hasTabs),
            action(.closeOthers, hasTabs),
            action(.closeToRight, hasTabs),
            action(.keepTab, hasTabs),
            action(.moveTab, hasTabs),
            action(.nextTab, tabs.tabs.count > 1),
            action(.previousTab, tabs.tabs.count > 1),
            action(.toggleSearch, isAccountActive),
            action(.toggleFind, hasDetail),
            action(.setFindQuery, hasDetail),
            action(.setFindPresented, hasDetail),
            action(.toggleSidebar, true),
            action(.showSettings, true),
            action(.toggleRawSource, hasDetail),
            action(.setReadingMode, hasDetail),
            action(.setRemoteImages, hasDetail),
            action(.setListCustomizationTarget, hasFolder),
            action(.setListPaneLayout, hasFolder || listCustomizationTarget == .global),
            action(.setListPresentation, hasFolder || listCustomizationTarget == .global),
            action(.setListColumnOrder, hasFolder || listCustomizationTarget == .global),
            action(.setListColumnVisible, hasFolder || listCustomizationTarget == .global),
            action(.setListColumnWidth, hasFolder || listCustomizationTarget == .global),
            action(.setListSort, hasFolder || listCustomizationTarget == .global),
            action(.resetListSettings, hasFolder),
            action(.resetGlobalListSettings, true),
            action(.setWorkspaceSync, true),
            action(.setWorkspaceSyncCategory, true),
            action(.resolveWorkspaceSyncConflict, !workspaceSync.pendingConflicts.isEmpty),
            action(.setSearchQuery, isAccountActive),
            action(.selectSearchResult, hasSearchResults),
            action(.setSearchFieldFocused, isAccountActive),
            action(.cancelSearch, isSearchPresented),
            action(.setPairingPresented, true)
        ]
        actions.append(contentsOf: pairingAutomation.currentAvailableActions)
        return actions
    }

    private func pairedActionAllowed(
        _ action: AutomationActionState,
        state: AppState,
        grant: AutomationGrant
    ) -> Bool {
        guard let name = CommandName(rawValue: action.id),
              !action.id.hasPrefix("pairing.")
        else { return false }
        let allAccountsCovered = Set(
            state.accounts.map(\.accountLinkID)
        ).isSubset(of: grant.accountLinkIDs)
        let visibleAccountIDs = Set(
            state.accounts
                .filter { grant.accountLinkIDs.contains($0.accountLinkID) }
                .map(\.id)
        )
        let visibleFolderIDs = Set(
            state.folders
                .filter { visibleAccountIDs.contains($0.accountID) }
                .map(\.id)
        )
        let selectedFolderLink = state.selectedFolderID.flatMap { folderID in
            state.folders.first(where: { $0.id == folderID }).flatMap { folder in
                state.accounts.first(where: { $0.id == folder.accountID })?.accountLinkID
            }
        }
        let selectedAccountCovered = selectedFolderLink.map(grant.accountLinkIDs.contains) ?? false
        let hasVisibleRows = state.listRows.contains { row in
            guard let folderID = row.folderID else { return false }
            return visibleFolderIDs.contains(folderID)
        } || state.searchResults.contains { row in
            guard let folderID = row.folderID else { return false }
            return visibleFolderIDs.contains(folderID)
        }
        let hasVisibleTabs = state.readerTabs.contains { tab in
            guard let rawLink = tab.link,
                  let link = MailternalDeepLink(string: rawLink),
                  case .message(_, _, _, _) = link
            else {
                return false
            }
            return grant.accountLinkIDs.contains(link.accountLinkID)
        }
        let hasVisibleFolders = state.folders.contains { folder in
            visibleAccountIDs.contains(folder.accountID)
        }

        switch name {
        case .undo:
            return false
        case .markRead, .markUnread, .setFlagged, .archive, .trash, .move:
            return grant.canMutate && hasVisibleRows
        case .refresh:
            return grant.canMutate && allAccountsCovered
        case .selectFolder:
            return grant.canControlGUI && hasVisibleFolders
        case .selectMessages, .openMessage, .openSearchResult, .openWindow:
            return grant.canControlGUI && hasVisibleRows
        case .selectAll, .clearSelection:
            return grant.canControlGUI && selectedFolderLink != nil && selectedAccountCovered
        case .activateTab, .closeTab, .closeOthers, .closeToRight, .keepTab, .moveTab,
             .nextTab, .previousTab:
            return grant.canControlGUI && hasVisibleTabs
        case .toggleFind, .setFindQuery, .setFindPresented, .toggleRawSource,
             .setReadingMode, .setRemoteImages:
            return grant.canControlGUI && selectedAccountCovered
        case .setListCustomizationTarget:
            return grant.canControlGUI && selectedAccountCovered
        case .setListPaneLayout, .setListPresentation, .setListColumnOrder,
             .setListColumnVisible, .setListColumnWidth, .setListSort, .resetListSettings:
            return grant.canControlGUI
                && listCustomizationTarget != .global
                && selectedAccountCovered
        case .resetGlobalListSettings:
            return false
        case .toggleSearch, .setSearchQuery, .setSearchFieldFocused, .cancelSearch,
             .toggleSidebar, .showSettings,
             .setWorkspaceSync, .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict:
            return false
        case .setPairingPresented, .pairingUI:
            return false
        default:
            return false
        }
    }

    private func automationSettings() -> [String: String] {
        AutomationPreferences.snapshot(appearance: appearance, actions: actions)
    }
    private func execute(
        _ command: Command,
        secret: String?,
        origin: CommandOrigin,
        grant: AutomationGrant,
        clientID: UUID?,
        commandID: UUID?
    ) async throws -> Data? {
        var effectApplied = false
        func applyEffect<Value>(
            _ operation: () async throws -> Value
        ) async throws -> Value {
            let value = try await operation()
            effectApplied = true
            return value
        }
        func encodeEffect<Value: Encodable>(
            _ operation: () async throws -> Value
        ) async throws -> Data {
            let value = try await applyEffect(operation)
            return try encodeAutomation(value)
        }
        func postEffectError(_ error: Error) -> CommandEffectAppliedError {
            if let error = error as? CommandEffectAppliedError {
                return error
            }
            return CommandEffectAppliedError(
                commandID: commandID ?? UUID(),
                message: "The command effect may have been applied, but completion could not be recorded: \(error.localizedDescription)"
            )
        }

        do {
            switch command {
        case .saveAccount(let config, let hasPassword):
            let password = hasPassword ? secret : nil
            guard !hasPassword || (password?.isEmpty == false) else {
                throw AutomationCommandError.unsupported("account save requires a transient password")
            }
            if accountConfigs.contains(where: { $0.id == config.id }) {
                try await applyEffect {
                    try await facade.updateAccount(config, password: password)
                }
            } else if let password {
                try await applyEffect {
                    try await facade.addAccount(config, password: password)
                }
            } else {
                throw AutomationCommandError.unsupported("account add requires a transient password")
            }
            return nil
        case .configureSMTP(let accountID, let configuration, let hasPassword):
            guard accountConfigs.contains(where: { $0.id == accountID }) else {
                throw AutomationCommandError.unsupported("account is unavailable")
            }
            let password = hasPassword ? secret : nil
            guard !hasPassword || (password?.isEmpty == false) else {
                throw AutomationCommandError.unsupported("SMTP configuration requires a transient password")
            }
            try await applyEffect {
                try await facade.configureSMTP(accountID, configuration: configuration, password: password)
            }
            return nil
        case .createDraft(let id, let accountID, let content):
            guard accountConfigs.contains(where: { $0.id == accountID }) else {
                throw AutomationCommandError.unsupported("account is unavailable")
            }
            return try await encodeEffect {
                try await facade.createDraft(id: id, accountID: accountID, content: content)
            }
        case .createReplyDraft(let id, let reference, let replyAll):
            return try await encodeEffect {
                try await facade.createReplyDraft(
                    id: id, messageID: try await resolve(reference, origin: origin), replyAll: replyAll
                )
            }
        case .createForwardDraft(let id, let reference):
            return try await encodeEffect {
                try await facade.createForwardDraft(
                    id: id, messageID: try await resolve(reference, origin: origin)
                )
            }
        case .saveDraft(let id, let expectedRevision, let content):
            return try await encodeEffect {
                try await facade.saveDraft(id: id, expectedRevision: expectedRevision, content: content)
            }
        case .deleteDraft(let id, let expectedRevision):
            try await applyEffect {
                try await facade.deleteDraft(id: id, expectedRevision: expectedRevision)
            }
            return nil
        case .getDraft(let id):
            return try encodeAutomation(try await facade.draft(id: id))
        case .listDrafts(let accountID, let limit):
            let scope: Set<AccountID>? = isLocalOrigin(origin)
                ? nil
                : Set(accountConfigs.filter { grant.accountLinkIDs.contains($0.accountLinkID) }.map(\.id))
            if let accountID {
                guard scope == nil || scope?.contains(accountID) == true else {
                    throw AutomationCommandError.permissionDenied(.read)
                }
            }
            let selectedAccounts: Set<AccountID>? = accountID.map { Set([$0]) } ?? scope
            return try encodeAutomation(
                try await facade.drafts(accounts: selectedAccounts, limit: limit)
            )
        case .importDraftAttachment(let id, let accountID, let source, let filename, let mimeType):
            guard accountConfigs.contains(where: { $0.id == accountID }) else {
                throw AutomationCommandError.unsupported("account is unavailable")
            }
            let context = AutomationClientContext(origin: origin, grant: grant, clientID: clientID)
            let url: URL
            let transferID: UUID?
            switch source {
            case .localFile(let localURL):
                guard isLocalOrigin(origin) else {
                    throw AutomationCommandError.permissionDenied(.mutate)
                }
                url = localURL
                transferID = nil
            case .transfer(let id):
                url = try await automationTransferRegistry.finalizeUpload(
                    transferID: id, context: context
                )
                transferID = id
            }
            do {
                let attachment = try await applyEffect {
                    try await facade.importDraftAttachment(
                        id: id, accountID: accountID, sourceURL: url, filename: filename, mimeType: mimeType
                    )
                }
                if let transferID {
                    try? await automationTransferRegistry.release(transferID: transferID, context: context)
                }
                return try encodeAutomation(attachment)
            } catch {
                if let transferID {
                    try? await automationTransferRegistry.release(transferID: transferID, context: context)
                }
                throw error
            }
        case .getDraftAttachment(let accountID, let id):
            guard accountConfigs.contains(where: { $0.id == accountID }) else {
                throw AutomationCommandError.unsupported("account is unavailable")
            }
            let url = try await facade.draftAttachmentURL(id: id, accountID: accountID)
            let context = AutomationClientContext(origin: origin, grant: grant, clientID: clientID)
            let descriptor = try await automationTransferRegistry.create(
                fileURL: url, kind: .attachment, context: context
            )
            return try encodeAutomation(descriptor)
        case .sendDraft(let id, let draftID, let expectedRevision):
            return try await encodeEffect {
                try await facade.enqueueSubmission(id: id, draftID: draftID, expectedRevision: expectedRevision)
            }
        case .retrySubmission(let id, let acknowledgeDuplicateRisk):
            return try await encodeEffect {
                try await facade.retrySubmission(
                    id: id, acknowledgeDuplicateRisk: acknowledgeDuplicateRisk
                )
            }
        case .cancelSubmission(let id):
            return try await encodeEffect {
                try await facade.cancelSubmission(id: id)
            }
        case .getSubmission(let id):
            return try encodeAutomation(try await facade.outbox(id: id))
        case .listOutbox(let accountID, let limit):
            let scope: Set<AccountID>? = isLocalOrigin(origin)
                ? nil
                : Set(accountConfigs.filter { grant.accountLinkIDs.contains($0.accountLinkID) }.map(\.id))
            if let accountID {
                guard scope == nil || scope?.contains(accountID) == true else {
                    throw AutomationCommandError.permissionDenied(.read)
                }
            }
            let selectedAccounts: Set<AccountID>? = accountID.map { Set([$0]) } ?? scope
            return try encodeAutomation(
                try await facade.outbox(accounts: selectedAccounts, limit: limit)
            )
        case .removeAccount(let id):
            try await applyEffect {
                try await facade.removeAccount(id)
            }
            return nil
        case .setAccountEnabled(let id, let enabled):
            try await applyEffect {
                try await facade.setAccountEnabled(id, enabled)
            }
            return nil
        case .exportAccounts(let ids, let includeSettings):
            guard let secret, !secret.isEmpty else {
                throw AutomationCommandError.unsupported("account export requires a transient passphrase")
            }
            let selectedIDs = ids.isEmpty ? Set(accountConfigs.map(\.id)) : Set(ids)
            let bundle = try await makePairingBundle(selectedIDs, includeSettings: includeSettings)
            let encrypted = try PairingFileTransfer.encrypt(bundle, passphrase: secret)
            return try encodeAutomation(encrypted)
        case .importAccounts(let encrypted, let ids, let replaceExisting, let importSettings):
            guard let secret, !secret.isEmpty else {
                throw AutomationCommandError.unsupported("account import requires a transient passphrase")
            }
            let bundle = try PairingFileTransfer.decrypt(encrypted, passphrase: secret)
            let selectedIDs = ids.isEmpty ? Set(bundle.accounts.map(\.id)) : Set(ids)
            try await applyEffect {
                try await importPairingBundle(
                    bundle,
                    selectedAccountIDs: selectedIDs,
                    replaceExisting: replaceExisting,
                    importSettings: importSettings
                )
            }
            return nil
        case .renameAccount(let id, let name):
            let renamed = await renameAccountDirect(id, to: name)
            guard renamed else {
                throw AutomationCommandError.unsupported("account rename failed")
            }
            effectApplied = true
            return nil
        case .selectFolder(let id):
            guard id == nil || folders.contains(where: { $0.id == id }) else {
                throw AutomationCommandError.unsupported("folder is unavailable")
            }
            selectFolderDirect(id)
            effectApplied = true
            return nil
        case .renameFolder(let id, let name):
            let renamed = await renameFolderDirect(id, to: name)
            guard renamed else {
                throw AutomationCommandError.unsupported("folder rename failed")
            }
            effectApplied = true
            return nil
        case .setRetention(let id, let keep):
            try await applyEffect {
                try await facade.setKeepLocally(keep, for: id)
            }
            return nil
        case .list(let folder, let cursor, let limit, let sort):
            guard let folder = folder ?? selectedFolderID else {
                return try encodeAutomation(AutomationMessagePage(rows: [], next: nil))
            }
            let page = try await facade.page(in: folder, after: cursor, limit: limit, sort: sort)
            return try encodeAutomation(
                try await automationMessagePage(page, cache: isLocalOrigin(origin))
            )
        case .read(let reference):
            return try encodeAutomation(try await facade.detail(try await resolve(reference, origin: origin)))
        case .raw(let reference):
            return try encodeAutomation(try await facade.rawSource(try await resolve(reference, origin: origin)))
        case .fetchAttachment(let reference, let part):
            let url = try await facade.fetchAttachment(
                try await resolve(reference, origin: origin),
                part: part
            )
            let context = AutomationClientContext(
                origin: origin,
                grant: grant,
                clientID: clientID
            )
            let descriptor = try await automationTransferRegistry.create(
                fileURL: url,
                kind: .attachment,
                context: context
            )
            return try encodeAutomation(descriptor)
        case .search(let query, let limit):
            let scope: Set<AccountLinkID>? = isLocalOrigin(origin) ? nil : grant.accountLinkIDs
            let rows = try await facade.search(query, limit: limit, accountLinks: scope)
            let links = try await automationLinks(for: rows.map(\.id), cache: isLocalOrigin(origin))
            return try encodeAutomation(automationRows(rows, links: links))
        case .markRead(let target):
            let ids = try await resolve(target, origin: origin)
            try await applyEffect { try await facade.markRead(ids) }
            return nil
        case .markUnread(let target):
            let ids = try await resolve(target, origin: origin)
            try await applyEffect { try await facade.markUnread(ids) }
            return nil
        case .setFlagged(let target, let flagged):
            let ids = try await resolve(target, origin: origin)
            try await applyEffect { try await facade.setFlagged(ids, flagged) }
            return nil
        case .archive(let target):
            let ids = try await resolve(target, origin: origin)
            try await applyEffect {
                if origin == .app {
                    try await moveToRoleDirect(ids: ids, role: .archive)
                } else {
                    try await facade.archive(ids)
                }
            }
            return nil
        case .trash(let target):
            let ids = try await resolve(target, origin: origin)
            try await applyEffect {
                if origin == .app {
                    try await moveToRoleDirect(ids: ids, role: .trash)
                } else {
                    try await facade.trash(ids)
                }
            }
            return nil
        case .move(let target, let folder):
            let ids = try await resolve(target, origin: origin)
            let outcome = try await applyEffect {
                if origin == .app {
                    return try await moveDirect(ids: Set(ids), to: folder)
                } else {
                    return try await facade.move(ids, to: folder)
                }
            }
            return try encodeAutomation(outcome)
        case .selectMessages(let target, let anchor):
            let ids = try await resolve(target, origin: origin)
            let anchorID: MessageID?
            if let anchor {
                anchorID = try await resolve(anchor, origin: origin)
            } else {
                anchorID = nil
            }
            selectMessagesDirect(Set(ids), anchor: anchorID)
            return nil
        case .selectAll:
            try await selectAllMessagesDirect()
            return nil
        case .clearSelection:
            selectMessage(nil)
            return nil
        case .refresh:
            await refreshDirect()
            return nil
        case .undo:
            let allowedLinks: Set<AccountLinkID>? = isLocalOrigin(origin) ? nil : grant.accountLinkIDs
            do {
                guard try await facade.canUndo(allowedAccountLinks: allowedLinks) else {
                    throw AutomationCommandError.unsupported("no reversible operation is available")
                }
                try await applyEffect {
                    try await facade.undo(allowedAccountLinks: allowedLinks)
                }
            } catch let error as MailUndoError {
                switch error {
                case .permissionDenied:
                    throw AutomationCommandError.permissionDenied(.mutate)
                case .unavailable:
                    throw AutomationCommandError.unsupported("no reversible operation is available")
                case .irreversible(let reason):
                    throw AutomationCommandError.unsupported(reason)
                }
            }
            return nil
        case .openMessage(let reference, let permanent):
            openMessagesDirect([try await resolve(reference, origin: origin)], permanent: permanent)
            return nil
        case .openSearchResult(let reference):
            openSearchResultDirect(try await resolve(reference, origin: origin))
            return nil
        case .openWindow(let reference):
            openMessageWindowDirect(try await resolve(reference, origin: origin))
            return nil
        case .activateTab(let id):
            activateTabDirect(id)
            return nil
        case .closeTab(let id):
            closeReaderTabDirect(id)
            return nil
        case .closeOthers(let id):
            tabs.closeOthers(id)
            return nil
        case .closeToRight(let id):
            tabs.closeToRight(id)
            return nil
        case .keepTab(let id):
            tabs.keep(id)
            return nil
        case .moveTab(let id, let index):
            tabs.move(id, to: index)
            return nil
        case .nextTab:
            activateNextTabDirect()
            return nil
        case .previousTab:
            activatePreviousTabDirect()
            return nil
        case .toggleSearch:
            toggleSearchDirect()
            return nil
        case .toggleFind:
            toggleFindDirect()
            return nil
        case .toggleSidebar:
            toggleSidebarDirect()
            return nil
        case .showSettings:
            showSettingsDirect()
            return nil
        case .setFindQuery(let value):
            findQuery = value
            return nil
        case .setFindPresented(let presented):
            setFindPresentedDirect(presented)
            return nil
        case .setSearchQuery(let value):
            searchPresentation.setQuery(value, using: facade)
            return nil
        case .selectSearchResult(let reference):
            let id: MessageID?
            if let reference {
                id = try await resolve(reference, origin: origin)
            } else {
                id = nil
            }
            searchPresentation.selectResult(id)
            return nil
        case .setSearchFieldFocused(let focused):
            if focused {
                guard isAccountActive else {
                    searchFieldFocused = false
                    throw AutomationCommandError.appUnavailable
                }
                if !isSearchPresented {
                    toggleSearchDirect()
                }
                guard isSearchPresented else {
                    searchFieldFocused = false
                    throw AutomationCommandError.unsupported("search is unavailable")
                }
                MainWindowController.shared.focusSearchField()
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self, self.searchFieldFocused, self.isSearchPresented else { return }
                    MainWindowController.shared.focusSearchField()
                }
                searchFieldFocused = true
            } else {
                searchFieldFocused = false
                MainWindowController.shared.focusMessageList()
            }
            return nil
        case .cancelSearch:
            searchPresentation.cancel()
            return nil
        case .setPairingPresented(let presented):
            guard isLocalOrigin(origin) else {
                throw AutomationCommandError.permissionDenied(.gui)
            }
            if presented {
                showSettingsDirect()
            }
            isPairingPresented = presented
            return nil
        case .toggleRawSource:
            toggleRawSourceDirect()
            return nil
        case .pairingUI(let action):
            guard isLocalOrigin(origin) else {
                throw AutomationCommandError.permissionDenied(.gui)
            }
            try await pairingAutomation.perform(action: action)
            return nil
        case .setReadingMode(let mode):
            setReadingModeDirect(mode)
            return nil
        case .setRemoteImages(let allowed):
            allowRemoteImages = allowed
            return nil
        case .setListCustomizationTarget(let target):
            try await setListCustomizationTargetDirect(target == .global ? .global : .currentFolder)
            return nil
        case .setListPaneLayout(let layout):
            try await setPaneLayoutDirect(layout)
            return nil
        case .setListPresentation(let presentation):
            try await setListPresentationDirect(presentation)
            return nil
        case .setListColumnOrder(let order):
            try await setListColumnOrderDirect(order)
            return nil
        case .setListColumnVisible(let column, let visible):
            try await setListColumnVisibleDirect(column, visible: visible)
            return nil
        case .setListColumnWidth(let column, let value):
            try await setListColumnWidthDirect(column, width: value)
            return nil
        case .setListSort(let value):
            try await setListSortDirect(value)
            return nil
        case .resetListSettings:
            try await resetListOverridesDirect()
            return nil
        case .resetGlobalListSettings:
            try await resetGlobalListSettingsDirect()
            return nil
        case .setWorkspaceSync(let enabled):
            try await workspaceSync.setEnabled(enabled)
            return nil
        case .setWorkspaceSyncCategory(let category, let enabled):
            try await workspaceSync.setCategory(category, enabled: enabled)
            return nil
        case .resolveWorkspaceSyncConflict(let category, let choice):
            try await workspaceSync.resolve(category, using: choice)
            return nil
        case .getSetting(let key):
            guard AutomationPreferences.supports(key) else {
                throw AutomationCommandError.unsupported("setting \(key)")
            }
            return try encodeAutomation(AutomationPreferences.value(for: key, appearance: appearance, actions: actions))
        case .setSetting(let key, let value):
            if key == "automation.remote.reload" {
                guard isLocalOrigin(origin) else {
                    throw AutomationCommandError.permissionDenied(.mutate)
                }
                try await reloadAutomationRemote()
            } else {
                try AutomationPreferences.apply(key: key, value: value, appearance: appearance, actions: actions)
            }
            return nil
        case .configureRemote(let configuration):
            try await configureAutomationRemote(configuration)
            return nil
        case .revokeAutomationClient(let clientID):
            guard isLocalOrigin(origin) else {
                throw AutomationCommandError.permissionDenied(.mutate)
            }
            let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
            let pairings = try (automationPairingStore ?? AutomationPairingStore(endpoint: endpoint))
            guard try pairings.revoke(clientID: clientID) else {
                throw AutomationCommandError.unsupported("automation client is not paired")
            }
            automationPairingStore = pairings
            return nil
        case .getSettings:
            return try encodeAutomation(AutomationPreferences.snapshot(appearance: appearance, actions: actions))
        }
        } catch {
            if effectApplied {
                throw postEffectError(error)
            }
            throw error
        }
    }

    private func isLocalOrigin(_ origin: CommandOrigin) -> Bool {
        origin == .app || origin == .localCLI
    }

    private func authorize(
        _ command: Command,
        origin: CommandOrigin,
        grant: AutomationGrant
    ) async throws {
        let localAuthority = isLocalOrigin(origin)
        if !localAuthority && command.isCredentialTransfer {
            throw AutomationCommandError.permissionDenied(.mutate)
        }
        guard localAuthority || grantAllows(command.access, grant) else {
            throw AutomationCommandError.permissionDenied(command.access)
        }
        if !localAuthority && containsLocalMessageIdentity(command) {
            // Paired clients must address messages by canonical deep links.
            // Reject local store IDs before any metadata lookup.
            throw AutomationCommandError.permissionDenied(command.access)
        }
        guard !localAuthority else { return }
        guard !grant.accountLinkIDs.isEmpty else {
            throw AutomationCommandError.permissionDenied(command.access)
        }
        switch command {
        case .configureRemote, .revokeAutomationClient, .setPairingPresented, .pairingUI:
            // Listener administration, pairing, and credential transfer stay
            // on the local authority even when a bearer can control GUI.
            throw AutomationCommandError.permissionDenied(command.access)
        case .search:
            // Search is account-scoped in SQL.
            return
        case .refresh:
            try authorizeAllConfiguredAccounts(grant, access: command.access)
            return
        case .toggleSearch, .setSearchQuery, .setSearchFieldFocused, .cancelSearch,
             .toggleSidebar, .showSettings,
             .setWorkspaceSync, .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict:
            // Paired grants are account-scoped; these controls mutate or
            // expose global GUI/workspace state.
            throw AutomationCommandError.permissionDenied(command.access)
        case .setReadingMode, .setRemoteImages:
            try authorizeCurrentAccount(grant, access: command.access)
            return
        case .getSetting, .getSettings:
            try authorizeAllConfiguredAccounts(grant, access: command.access)
            return
        case .setSetting:
            throw AutomationCommandError.permissionDenied(command.access)
        case .setFindPresented, .toggleFind, .setFindQuery, .toggleRawSource,
             .selectAll, .clearSelection, .resetListSettings:
            try authorizeCurrentAccount(grant, access: command.access)
            return
        case .resetGlobalListSettings:
            throw AutomationCommandError.permissionDenied(command.access)
        case .setListCustomizationTarget(let target):
            if target == .global {
                throw AutomationCommandError.permissionDenied(command.access)
            }
            try authorizeCurrentAccount(grant, access: command.access)
            return
        case .setListPaneLayout, .setListPresentation, .setListColumnOrder,
             .setListColumnVisible, .setListColumnWidth, .setListSort:
            guard listCustomizationTarget != .global else {
                throw AutomationCommandError.permissionDenied(command.access)
            }
            try authorizeCurrentAccount(grant, access: command.access)
            return
        case .selectFolder(nil):
            // Clearing the current folder does not select or disclose another
            // account and remains a supported GUI command.
            return
        default:
            break
        }

        let links = try await commandAccountLinks(command)
        guard !links.isEmpty, links.isSubset(of: grant.accountLinkIDs) else {
            throw AutomationCommandError.permissionDenied(command.access)
        }
    }

    private func authorizeAllConfiguredAccounts(
        _ grant: AutomationGrant,
        access: AutomationAccess
    ) throws {
        let requiredLinks = Set(accountConfigs.map(\.accountLinkID))
        guard requiredLinks.isSubset(of: grant.accountLinkIDs) else {
            throw AutomationCommandError.permissionDenied(access)
        }
    }

    private func authorizeCurrentAccount(
        _ grant: AutomationGrant,
        access: AutomationAccess
    ) throws {
        guard let link = selectedFolderID.flatMap(folderAccountLink),
              grant.accountLinkIDs.contains(link)
        else {
            throw AutomationCommandError.permissionDenied(access)
        }
    }
    private func containsLocalMessageIdentity(_ command: Command) -> Bool {
        func referenceIsLocal(_ reference: MessageReference) -> Bool {
            if case .local(_) = reference { return true }
            return false
        }
        func targetIsLocal(_ target: MessageTarget) -> Bool {
            if case .explicit(_) = target { return true }
            return false
        }
        switch command {
        case .read(let reference), .raw(let reference), .fetchAttachment(let reference, _),
             .openMessage(let reference, _), .openSearchResult(let reference), .openWindow(let reference):
            return referenceIsLocal(reference)
        case .markRead(let target), .markUnread(let target), .setFlagged(let target, _),
             .archive(let target), .trash(let target), .move(let target, _):
            return targetIsLocal(target)
        case .selectMessages(let target, let anchor):
            return targetIsLocal(target) || anchor.map(referenceIsLocal) == true
        case .selectSearchResult(let reference):
            return reference.map(referenceIsLocal) == true
        case .createReplyDraft(_, let reference, _), .createForwardDraft(_, let reference):
            return referenceIsLocal(reference)
        default:
            return false
        }
    }

    private func resolve(
        _ reference: MessageReference,
        origin: CommandOrigin
    ) async throws -> MessageID {
        switch reference {
        case .local(let id):
            guard isLocalOrigin(origin) else {
                throw AutomationCommandError.permissionDenied(.read)
            }
            return id
        case .link(let link):
            guard case .message(_, _, _, _) = link,
                  let resolution = try await facade.resolve(link),
                  case .message(_, let id, _) = resolution
            else {
                throw AutomationCommandError.unsupported("message link is unavailable")
            }
            return id
        }
    }

    private func resolve(
        _ target: MessageTarget,
        origin: CommandOrigin
    ) async throws -> [MessageID] {
        switch target {
        case .explicit(let ids):
            guard isLocalOrigin(origin) else {
                throw AutomationCommandError.permissionDenied(.mutate)
            }
            return ids
        case .links(let links):
            guard links.allSatisfy({ if case .message(_, _, _, _) = $0 { return true }; return false }) else {
                throw AutomationCommandError.invalidPayload("message target")
            }
            var ids: [MessageID] = []
            ids.reserveCapacity(links.count)
            for link in links {
                ids.append(try await resolve(.link(link), origin: origin))
            }
            return ids
        case .selection(let context):
            return context.messageIDs
        }
    }

    private func moveToRoleDirect(ids: [MessageID], role: FolderRole) async throws {
        let uniqueIDs = Set(ids)
        guard !uniqueIDs.isEmpty else { return }
        let states = try await facade.messageMutationStates(Array(uniqueIDs))
        guard states.count == uniqueIDs.count else {
            throw AutomationCommandError.unsupported("message is unavailable")
        }

        var destinations: [(ids: Set<MessageID>, folder: FolderID)] = []
        let accountLinks = Set(states.map(\.accountLinkID)).sorted {
            $0.uuidString < $1.uuidString
        }
        destinations.reserveCapacity(accountLinks.count)
        for accountLink in accountLinks {
            guard let account = accountConfigs.first(where: { $0.accountLinkID == accountLink }),
                  let destination = folders.first(where: {
                      $0.accountID == account.id && $0.role == role
                  })?.id
            else {
                throw AutomationCommandError.unsupported("\(role.rawValue) folder is unavailable")
            }
            destinations.append((
                ids: Set(states.filter { $0.accountLinkID == accountLink }.map(\.id)),
                folder: destination
            ))
        }

        for destination in destinations {
            _ = try await moveDirect(ids: destination.ids, to: destination.folder)
        }
    }
    private func commandTargetIDs(_ command: Command) -> [String] {
        var values: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            values.append(value)
        }
        func appendAccount(_ id: AccountID) {
            append("account:\(id.rawValue)")
        }
        func appendFolder(_ id: FolderID) {
            append("folder:\(id.rawValue)")
        }
        func appendMessage(_ id: MessageID) {
            append("message:\(id.rawValue)")
        }
        func appendLink(_ link: MailternalDeepLink) {
            guard case .message(_, _, _, _) = link,
                  let value = link.formattedString
            else { return }
            append("message:\(value)")
        }
        func appendReference(_ reference: MessageReference) {
            switch reference {
            case .local(let id):
                appendMessage(id)
            case .link(let link):
                appendLink(link)
            }
        }
        func appendTarget(_ target: MessageTarget) {
            switch target {
            case .explicit(let ids):
                ids.forEach(appendMessage)
            case .links(let links):
                links.forEach(appendLink)
            case .selection(let context):
                if let folderID = context.folderID {
                    appendFolder(folderID)
                }
                context.messageIDs.forEach(appendMessage)
            }
        }

        switch command {
        case .saveAccount(let config, _):
            appendAccount(config.id)
            append("account-link:\(config.accountLinkID.uuidString)")
        case .removeAccount(let id), .setAccountEnabled(let id, _), .renameAccount(let id, _):
            appendAccount(id)
        case .exportAccounts(let ids, _):
            ids.forEach(appendAccount)
        case .importAccounts(_, let ids, _, _):
            ids.forEach(appendAccount)
        case .configureSMTP(let accountID, _, _):
            appendAccount(accountID)
        case .createDraft(let id, let accountID, _):
            append("draft:\(id.uuidString.lowercased())")
            appendAccount(accountID)
        case .createReplyDraft(let id, let reference, _),
             .createForwardDraft(let id, let reference):
            append("draft:\(id.uuidString.lowercased())")
            appendReference(reference)
        case .saveDraft(let id, _, _), .deleteDraft(let id, _), .getDraft(let id):
            append("draft:\(id.uuidString.lowercased())")
        case .listDrafts(let accountID, _):
            accountID.map(appendAccount)
        case .importDraftAttachment(let id, let accountID, let source, _, _):
            appendAccount(accountID)
            append("attachment:\(id.uuidString.lowercased())")
            if case .transfer(let id) = source {
                append("transfer:\(id.uuidString.lowercased())")
            }
        case .getDraftAttachment(let accountID, let id):
            appendAccount(accountID)
            append("attachment:\(id.uuidString.lowercased())")
        case .sendDraft(let id, let draftID, _):
            append("submission:\(id.uuidString.lowercased())")
            append("draft:\(draftID.uuidString.lowercased())")
        case .retrySubmission(let id, _), .cancelSubmission(let id), .getSubmission(let id):
            append("submission:\(id.uuidString.lowercased())")
        case .listOutbox(let accountID, _):
            accountID.map(appendAccount)
        case .selectFolder(let id):
            id.map(appendFolder)
        case .renameFolder(let id, _), .setRetention(let id, _):
            appendFolder(id)
        case .list(let folder, _, _, _):
            folder.map(appendFolder)
        case .read(let reference), .raw(let reference), .fetchAttachment(let reference, _),
             .openMessage(let reference, _), .openSearchResult(let reference), .openWindow(let reference):
            appendReference(reference)
        case .search(_, _):
            break
        case .markRead(let target), .markUnread(let target), .archive(let target),
             .trash(let target):
            appendTarget(target)
        case .setFlagged(let target, _):
            appendTarget(target)
        case .move(let target, let folder):
            appendTarget(target)
            appendFolder(folder)
        case .configureRemote:
            append("automation-remote")
        case .revokeAutomationClient(let id):
            append("automation-client:\(id.uuidString.lowercased())")
        case .selectMessages(let target, let anchor):
            appendTarget(target)
            anchor.map(appendReference)
        case .selectAll, .clearSelection, .refresh, .undo:
            break
        case .activateTab(let id), .closeTab(let id), .closeOthers(let id),
             .closeToRight(let id), .keepTab(let id), .moveTab(let id, _):
            append("tab:\(id.uuidString.lowercased())")
        case .nextTab, .previousTab, .toggleSearch, .toggleFind, .setFindQuery,
             .setFindPresented, .toggleSidebar, .showSettings, .toggleRawSource,
             .setReadingMode, .setRemoteImages, .setListCustomizationTarget,
             .setListPaneLayout, .setListPresentation, .setListColumnOrder,
             .setListColumnVisible, .setListColumnWidth, .setListSort,
             .resetListSettings, .resetGlobalListSettings, .setWorkspaceSync,
             .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict,
             .getSetting, .setSetting, .setSearchQuery, .setSearchFieldFocused,
             .cancelSearch, .setPairingPresented, .pairingUI, .getSettings:
            break
        case .selectSearchResult(let reference):
            reference.map(appendReference)
        }
        return values
    }

    private func automationFailure(for error: Error) -> AutomationFailure {
        if let error = error as? AutomationCommandError {
            return error.failure
        }
        if let error = error as? AutomationSecurityError {
            switch error {
            case .invalidToken, .notPaired:
                return .authorization
            case .invalidConfiguration, .malformedFrame, .requestTooLarge:
                return .domain
            case .runtimeOwned, .runtimeNotOwned, .socketUnavailable, .pathTooLong,
                 .connectionLimit, .remoteDisabled, .tlsUnavailable, .responseTooLarge,
                 .insecurePermissions:
                return .unavailable
            }
        }
        return .domain
    }

    private func grantAllows(_ access: AutomationAccess, _ grant: AutomationGrant) -> Bool {
        switch access {
        case .read: grant.canRead
        case .mutate: grant.canMutate
        case .send: grant.canSend
        case .gui: grant.canControlGUI
        }
    }
    private func validateQueryLimit(_ command: Command) throws {
        let limit: Int?
        switch command {
        case .list(_, _, let value, _), .search(_, let value),
             .listDrafts(_, let value), .listOutbox(_, let value):
            limit = value
        default:
            limit = nil
        }
        guard let limit else { return }
        guard (1...AutomationProtocol.maximumQueryLimit).contains(limit) else {
            throw AutomationCommandError.invalidPayload("query limit")
        }
    }

    private func selectionContext(in command: Command) -> SelectionContext? {
        switch command {
        case .markRead(let target), .markUnread(let target), .setFlagged(let target, _),
             .archive(let target), .trash(let target), .move(let target, _),
             .selectMessages(let target, _):
            return target.selectionContext
        default:
            return nil
        }
    }

    private func validateSelection(_ context: SelectionContext) throws {
        guard context.revision == selectionRevision else {
            throw AutomationCommandError.staleSelection(
                expected: context.revision,
                actual: selectionRevision
            )
        }
        let expectedIDs = Set(context.messageIDs)
        guard context.messageIDs.count == expectedIDs.count,
              context.folderID == selectedFolderID,
              expectedIDs == selectedMessageIDs
        else {
            throw AutomationCommandError.staleSelection(
                expected: context.revision,
                actual: selectionRevision
            )
        }
    }

    private func folderAccountLink(_ folderID: FolderID) -> AccountLinkID? {
        guard let folder = folders.first(where: { $0.id == folderID }),
              let account = accountConfigs.first(where: { $0.id == folder.accountID })
        else { return nil }
        return account.accountLinkID
    }

    private func messageAccountLinks(_ ids: [MessageID]) async throws -> Set<AccountLinkID> {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return [] }
        let states = try await facade.messageMutationStates(uniqueIDs)
        guard states.count == uniqueIDs.count else { return [] }
        return Set(states.map(\.accountLinkID))
    }

    private func messageReferenceAccountLinks(_ reference: MessageReference) async throws -> Set<AccountLinkID> {
        switch reference {
        case .link(let link):
            guard case .message(_, _, _, _) = link else { return [] }
            return [link.accountLinkID]
        case .local(let id):
            return try await messageAccountLinks([id])
        }
    }

    private func targetAccountLinks(_ target: MessageTarget) async throws -> Set<AccountLinkID> {
        switch target {
        case .links(let links):
            guard !links.isEmpty,
                  links.allSatisfy({ if case .message(_, _, _, _) = $0 { return true }; return false })
            else { return [] }
            return Set(links.map(\.accountLinkID))
        case .explicit(let ids):
            return try await messageAccountLinks(ids)
        case .selection(let context):
            let messageLinks = try await messageAccountLinks(context.messageIDs)
            guard let folderID = context.folderID,
                  let folderLink = folderAccountLink(folderID),
                  !context.messageIDs.isEmpty,
                  messageLinks == Set([folderLink])
            else { return [] }
            return messageLinks
        }
    }

    private func tabAccountLinks(_ id: UUID) async throws -> Set<AccountLinkID> {
        guard let tab = tabs.tabs.first(where: { $0.id == id }) else { return [] }
        return try await messageAccountLinks([tab.message])
    }

    private func commandAccountLinks(_ command: Command) async throws -> Set<AccountLinkID> {
        switch command {
        case .list(let folder, _, _, _):
            guard let folder else { return [] }
            return folderAccountLink(folder).map { [$0] }.map(Set.init) ?? []
        case .selectFolder(let folder):
            guard let folder else { return [] }
            return folderAccountLink(folder).map { [$0] }.map(Set.init) ?? []
        case .renameFolder(let folder, _), .setRetention(let folder, _):
            return folderAccountLink(folder).map { [$0] }.map(Set.init) ?? []
        case .move(let target, let destination):
            var links = try await targetAccountLinks(target)
            guard let destinationLink = folderAccountLink(destination) else { return [] }
            links.insert(destinationLink)
            return links
        case .removeAccount(let id), .setAccountEnabled(let id, _), .renameAccount(let id, _):
            guard let account = accountConfigs.first(where: { $0.id == id }) else { return [] }
            return [account.accountLinkID]
        case .read(let reference), .raw(let reference), .fetchAttachment(let reference, _),
             .openMessage(let reference, _), .openSearchResult(let reference), .openWindow(let reference):
            return try await messageReferenceAccountLinks(reference)
        case .markRead(let target), .markUnread(let target), .setFlagged(let target, _),
             .archive(let target), .trash(let target):
            return try await targetAccountLinks(target)
        case .selectMessages(let target, let anchor):
            var links = try await targetAccountLinks(target)
            if let anchor {
                links.formUnion(try await messageReferenceAccountLinks(anchor))
            }
            return links
        case .selectSearchResult(let reference):
            guard let reference else { return [] }
            return try await messageReferenceAccountLinks(reference)
        case .activateTab(let id), .closeTab(let id), .keepTab(let id):
            return try await tabAccountLinks(id)
        case .moveTab:
            return try await messageAccountLinks(tabs.tabs.map(\.message))
        case .closeOthers(let id):
            guard tabs.tabs.contains(where: { $0.id == id }) else { return [] }
            return try await messageAccountLinks(tabs.tabs.map(\.message))
        case .closeToRight(let id):
            guard let index = tabs.tabs.firstIndex(where: { $0.id == id }) else { return [] }
            return try await messageAccountLinks(tabs.tabs.dropFirst(index + 1).map(\.message))
        case .nextTab, .previousTab:
            guard let activeID = tabs.activeID,
                  let activeIndex = tabs.tabs.firstIndex(where: { $0.id == activeID }),
                  let destination = ReaderTabsPolicy.adjacentID(
                      in: tabs.tabs,
                      activeID: activeID,
                      forward: command.name == .nextTab,
                      id: \.id
                  ),
                  let destinationTab = tabs.tabs.first(where: { $0.id == destination })
            else { return [] }
            var links = try await messageAccountLinks([tabs.tabs[activeIndex].message])
            links.formUnion(try await messageAccountLinks([destinationTab.message]))
            return links
        case .configureSMTP(let accountID, _, _),
             .createDraft(_, let accountID, _),
             .importDraftAttachment(_, let accountID, _, _, _),
             .getDraftAttachment(let accountID, _):
            guard let account = accountConfigs.first(where: { $0.id == accountID }) else { return [] }
            return [account.accountLinkID]
        case .listDrafts(let accountID, _), .listOutbox(let accountID, _):
            guard let accountID,
                  let account = accountConfigs.first(where: { $0.id == accountID }) else { return [] }
            return [account.accountLinkID]
        case .createReplyDraft(_, let reference, _), .createForwardDraft(_, let reference):
            return try await messageReferenceAccountLinks(reference)
        case .saveDraft(let id, _, _), .deleteDraft(let id, _), .getDraft(let id):
            guard let draft = try await facade.draft(id: id),
                  let account = accountConfigs.first(where: { $0.id == draft.accountID })
            else { return [] }
            return [account.accountLinkID]
        case .sendDraft(_, let draftID, _):
            guard let draft = try await facade.draft(id: draftID),
                  let account = accountConfigs.first(where: { $0.id == draft.accountID })
            else { return [] }
            return [account.accountLinkID]
        case .retrySubmission(let id, _), .cancelSubmission(let id), .getSubmission(let id):
            guard let submission = try await facade.outbox(id: id),
                  let account = accountConfigs.first(where: { $0.id == submission.accountID })
            else { return [] }
            return [account.accountLinkID]
        case .saveAccount(let config, _):
            return [config.accountLinkID]
        case .exportAccounts, .importAccounts, .configureRemote, .revokeAutomationClient:
            return []
        case .selectAll, .clearSelection, .refresh, .undo,
             .toggleSearch, .toggleFind, .setFindQuery, .setFindPresented,
             .setSearchQuery, .setSearchFieldFocused, .cancelSearch, .setPairingPresented,
             .pairingUI, .toggleSidebar, .showSettings, .toggleRawSource,
             .setReadingMode, .setRemoteImages, .setListCustomizationTarget,
             .setListPaneLayout, .setListPresentation, .setListColumnOrder,
             .setListColumnVisible, .setListColumnWidth, .setListSort,
             .resetListSettings, .resetGlobalListSettings, .setWorkspaceSync,
             .setWorkspaceSyncCategory, .resolveWorkspaceSyncConflict,
             .getSetting, .setSetting, .getSettings, .search:
            return []
        }
    }

    private func configureAutomationRemote(_ configuration: AutomationRemoteConfiguration) async throws {
        guard automationHandler != nil, automationEventsHandler != nil else {
            throw AutomationCommandError.appUnavailable
        }
        let validated = try AutomationRemoteConfiguration(
            enabled: configuration.enabled,
            bindHost: configuration.bindHost,
            port: configuration.port,
            allowWildcard: configuration.allowWildcard
        )
        let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
        let store = AutomationRemoteConfigurationStore(endpoint: endpoint)
        let previous = try store.load()
        try store.save(validated)
        do {
            try await reloadAutomationRemote()
        } catch let reloadError {
            do {
                try store.save(previous)
                try await reloadAutomationRemote()
            } catch {
                throw reloadError
            }
            throw reloadError
        }
    }

    private func reloadAutomationRemote() async throws {
        guard let handler = automationHandler,
              let events = automationEventsHandler
        else {
            throw AutomationCommandError.appUnavailable
        }
        automationRemoteListener?.stop()
        automationRemoteListener = nil
        automationPairingStore = nil
        let endpoint = AutomationEndpoint(containerURL: automationContainerURL)
        let store = AutomationRemoteConfigurationStore(endpoint: endpoint)
        let configuration = try store.load()
        guard configuration.enabled else { return }
        guard let pairings = try? AutomationPairingStore(endpoint: endpoint) else {
            throw AutomationSecurityError.invalidConfiguration
        }
        let listener = AutomationTLSListener(endpoint: endpoint, configuration: configuration, pairings: pairings)
        do {
            try await listener.start(handler: handler, events: events)
            automationPairingStore = pairings
            automationRemoteListener = listener
        } catch {
            listener.stop()
            throw error
        }
    }

    private func automationFolderState(_ folder: FolderSummary) -> AutomationFolderState {
        AutomationFolderState(
            id: folder.id, accountID: folder.accountID, name: folder.name, path: folder.path,
            role: folder.role, unreadCount: folder.unreadCount, totalCount: folder.totalCount,
            keepLocally: folder.keepLocally, activity: automationActivity(folder.activity)
        )
    }

    private func automationActivity(_ activity: FolderActivity) -> String {
        switch activity {
        case .downloading: "downloading"
        case .indexing: "indexing"
        case .moving: "moving"
        case .idle: "idle"
        case .halted: "halted"
        case .quarantinedStall: "quarantined-stall"
        }
    }

    private func automationAccountState(_ state: AccountState) -> String {
        switch state {
        case .none: "none"
        case .validating: "validating"
        case .active: "active"
        case .authFailed: "auth-failed"
        case .connectionFailed: "connection-failed"
        }
    }

    private func automationSyncMode(_ status: SyncStatus) -> String {
        switch status.mode {
        case .fullHistory: "full-history"
        case .windowed(let date): "windowed-since-\(ISO8601DateFormatter().string(from: date))"
        }
    }

    func redactedError(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "The command could not be completed."
    }

    private func encodeAutomation<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}
