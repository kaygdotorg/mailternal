import Foundation

/// Actor-backed state fan-out. A client always receives an initial snapshot;
/// callers that reconnect with a missing history window receive a gap and
/// current snapshot instead of silently continuing with stale context.
public actor AppStateHub {
    private static let maximumHistoryLimit = 256

    public struct Subscription: Sendable {
        public let stream: AsyncStream<AppStateEvent>
        fileprivate let id: UUID

        fileprivate init(stream: AsyncStream<AppStateEvent>, id: UUID) {
            self.stream = stream
            self.id = id
        }
    }

    private struct Subscriber {
        let continuation: AsyncStream<AppStateEvent>.Continuation
        let requestedRevision: UInt64?
        var waitsForInitialSnapshot: Bool
    }

    private var current: AppState?
    private var revision: UInt64 = 0
    /// History is retained only while an observer can use it for replay. The
    /// current snapshot remains available for reconnects that require a gap.
    private var history: [AppStateEvent] = []
    private let historyLimit: Int
    private var subscribers: [UUID: Subscriber] = [:]

    /// Creates a hub with a bounded replay window. Values above the hard
    /// limit are clamped so callers cannot turn the history or stream buffers
    /// into an effectively unbounded allocation.
    public init(historyLimit: Int = 256) {
        self.historyLimit = min(
            max(1, historyLimit),
            Self.maximumHistoryLimit
        )
    }

    /// A cheap publication gate for callers that build snapshots on demand.
    public var hasSubscribers: Bool { !subscribers.isEmpty }

    /// Number of active state observers.
    public var subscriberCount: Int { subscribers.count }

    public func currentSnapshot() -> AppStateEvent? {
        guard let current else { return nil }
        return AppStateEvent(revision: revision, kind: .snapshot, state: current)
    }

    /// Publishes a changed state to active observers.
    ///
    /// Each observer has a finite oldest-first buffer. If a producer outruns
    /// that buffer, the observer is finished after the last queued event. The
    /// resulting stream termination is an explicit disconnect/resync boundary;
    /// no observer is allowed to continue after silently missing a revision.
    ///
    /// Equal states do not create a false change or consume a revision. The
    /// returned snapshot is the current event for callers that need a result.
    @discardableResult
    public func publish(_ state: AppState) -> AppStateEvent {
        if let current, current == state {
            return AppStateEvent(revision: revision, kind: .snapshot, state: current)
        }

        revision &+= 1
        current = state
        let event = AppStateEvent(revision: revision, kind: .change, state: state)

        // No subscriber can replay a change published while the hub is idle;
        // a later observer receives the current snapshot. This avoids
        // retaining full AppState values solely for a hypothetical client.
        guard !subscribers.isEmpty else {
            history.removeAll(keepingCapacity: false)
            return event
        }

        history.append(event)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        var terminatedIDs: [UUID] = []
        terminatedIDs.reserveCapacity(subscribers.count)
        for (id, subscriber) in subscribers {
            guard !subscriber.waitsForInitialSnapshot else { continue }
            switch subscriber.continuation.yield(event) {
            case .enqueued(_):
                break
            case .dropped(_), .terminated:
                // A dropped event means this observer no longer has a
                // contiguous stream. Finish it rather than sending later
                // events that could be mistaken for valid continuation.
                subscriber.continuation.finish()
                terminatedIDs.append(id)
            @unknown default:
                // Future yield outcomes are treated conservatively as a
                // disconnect so an unknown result cannot silently break
                // revision continuity.
                subscriber.continuation.finish()
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            subscribers.removeValue(forKey: id)
        }
        if subscribers.isEmpty {
            history.removeAll(keepingCapacity: false)
        }
        return event
    }

    /// Registers an observer before its owner starts constructing an initial
    /// snapshot. Publications made while that construction is suspended stay
    /// in the hub's current/history state and are delivered when the owner
    /// activates the subscription.
    public func subscribeBeforeInitialSnapshot(after requestedRevision: UInt64? = nil) -> Subscription {
        makeSubscription(
            after: requestedRevision,
            waitsForInitialSnapshot: true
        )
    }

    /// Registers an ordinary observer and returns a token so a failed refresh
    /// can explicitly release the continuation instead of relying on stream
    /// destruction.
    public func subscribe(after requestedRevision: UInt64? = nil) -> Subscription {
        makeSubscription(
            after: requestedRevision,
            waitsForInitialSnapshot: false
        )
    }

    /// Completes a subscription that its owner could not initialize.
    public func cancel(_ subscription: Subscription) {
        guard let subscriber = subscribers.removeValue(forKey: subscription.id) else { return }
        subscriber.continuation.finish()
        if subscribers.isEmpty {
            history.removeAll(keepingCapacity: false)
        }
    }

    /// Publishes the current snapshot to a deferred observer and transitions
    /// it to ordinary change delivery. The latest current state is used so a
    /// mutation that occurred during initial construction cannot be lost.
    @discardableResult
    public func activate(_ subscription: Subscription) -> Bool {
        guard var subscriber = subscribers[subscription.id],
              subscriber.waitsForInitialSnapshot,
              let current
        else {
            return false
        }
        subscriber.waitsForInitialSnapshot = false
        subscribers[subscription.id] = subscriber

        let initial = AppStateEvent(revision: revision, kind: .snapshot, state: current)
        if let requestedRevision = subscriber.requestedRevision {
            if requestedRevision == revision {
                _ = subscriber.continuation.yield(initial)
            } else if requestedRevision < revision, canReplay(after: requestedRevision) {
                for event in history where event.revision > requestedRevision {
                    _ = subscriber.continuation.yield(event)
                }
            } else {
                _ = subscriber.continuation.yield(
                    AppStateEvent(revision: revision, kind: .gap, state: current)
                )
            }
        } else {
            _ = subscriber.continuation.yield(initial)
        }
        return true
    }

    private func makeSubscription(
        after requestedRevision: UInt64?,
        waitsForInitialSnapshot: Bool
    ) -> Subscription {
        let values = AsyncStream.makeStream(
            of: AppStateEvent.self,
            bufferingPolicy: .bufferingOldest(historyLimit)
        )
        let stream = values.stream
        let continuation = values.continuation
        let id = UUID()

        subscribers[id] = Subscriber(
            continuation: continuation,
            requestedRevision: requestedRevision,
            waitsForInitialSnapshot: waitsForInitialSnapshot
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        guard !waitsForInitialSnapshot else {
            return Subscription(stream: stream, id: id)
        }
        guard let current else {
            // Do not leave a reconnecting client waiting forever for a
            // publication that may never arrive. AppModel is responsible for
            // publishing a fresh state before calling this method on restart.
            continuation.yield(
                AppStateEvent(revision: revision, kind: .gap, state: nil)
            )
            continuation.finish()
            removeSubscriber(id)
            return Subscription(stream: stream, id: id)
        }

        let initial = AppStateEvent(revision: revision, kind: .snapshot, state: current)
        guard let requestedRevision else {
            continuation.yield(initial)
            return Subscription(stream: stream, id: id)
        }

        if requestedRevision == revision {
            continuation.yield(initial)
        } else if requestedRevision < revision, canReplay(after: requestedRevision) {
            for event in history where event.revision > requestedRevision {
                continuation.yield(event)
            }
        } else {
            // This covers both a cursor older than the retained window and a
            // cursor ahead of the current revision. Never silently wait for
            // that future revision.
            continuation.yield(
                AppStateEvent(revision: revision, kind: .gap, state: current)
            )
        }
        return Subscription(stream: stream, id: id)
    }

    /// Reconnect helper for clients that explicitly detect a sequence gap.
    public func resync() -> AppStateEvent? { currentSnapshot() }

    private func canReplay(after requestedRevision: UInt64) -> Bool {
        guard let first = history.first,
              let last = history.last,
              last.revision == revision,
              requestedRevision >= first.revision - 1
        else {
            return false
        }

        var expected = requestedRevision &+ 1
        for event in history where event.revision > requestedRevision {
            guard event.revision == expected else { return false }
            expected &+= 1
        }
        return expected == revision &+ 1
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        if subscribers.isEmpty {
            history.removeAll(keepingCapacity: false)
        }
    }
}
