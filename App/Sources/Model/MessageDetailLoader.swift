import Foundation
import MailternalInterfaces

/// Main-actor detail loading seam for reader selection and bounded local warming.
///
/// Interactive callers share one in-flight read per message, while adjacent
/// warming uses one bounded batch at a time. A cancelled or stale generation
/// can finish in the background, but it can never repopulate the cache after
/// invalidation. Protected entries are the details backing retained reader
/// surfaces; all other entries live in a bounded recent/navigation tier.
@MainActor
final class MessageDetailLoader {
    typealias Fetch = @MainActor (MessageID) async throws -> MessageDetail
    typealias BatchFetch = @MainActor ([MessageID]) async throws -> [MessageDetail]

    static let navigationCapacity = 24
    static let navigationByteBudget = 8 * 1024 * 1024
    static let speculativeBatchCapacity = 12

    private struct CacheEntry {
        let detail: MessageDetail
        let textBytes: Int
    }

    private struct Generation: Equatable {
        let global: UInt64
        let local: UInt64
    }

    private final class Request {
        let generation: Generation
        let task: Task<MessageDetail, Error>
        var interactiveWaiters = 0

        init(generation: Generation, task: Task<MessageDetail, Error>) {
            self.generation = generation
            self.task = task
        }
    }

    private final class PrefetchRequest {
        let epoch: UInt64
        let ids: [MessageID]
        let requestedIDs: Set<MessageID>
        let generations: [MessageID: Generation]
        var task: Task<[MessageDetail], Error>?
        var interactiveWaiters: [MessageID: Int] = [:]

        init(
            epoch: UInt64,
            ids: [MessageID],
            generations: [MessageID: Generation]
        ) {
            self.epoch = epoch
            self.ids = ids
            self.requestedIDs = Set(ids)
            self.generations = generations
        }
    }

    private let fetch: Fetch
    private let fetchBatch: BatchFetch
    private var values: [MessageID: CacheEntry] = [:]
    private var mruIDs: [MessageID] = []
    private var protectedIDs: Set<MessageID> = []
    private var navigationBytes = 0
    private var generations: [MessageID: UInt64] = [:]
    private var requests: [MessageID: Request] = [:]
    private var globalGeneration: UInt64 = 0

    private var prefetchEpoch: UInt64 = 0
    private var prefetchQueue: [MessageID] = []
    private var queuedPrefetchIDs: Set<MessageID> = []
    private var prefetchRequest: PrefetchRequest?

    init(fetch: @escaping Fetch, fetchBatch: @escaping BatchFetch) {
        self.fetch = fetch
        self.fetchBatch = fetchBatch
    }

    func cachedDetail(for id: MessageID) -> MessageDetail? {
        guard let entry = values[id] else { return nil }
        touch(id)
        return entry.detail
    }

    func load(_ id: MessageID) async throws -> MessageDetail {
        if let cached = cachedDetail(for: id) {
            return cached
        }
        let generation = currentGeneration(for: id)
        if let prefetch = prefetchRequest,
           let task = prefetch.task,
           !task.isCancelled,
           prefetch.generations[id] == generation {
            prefetch.interactiveWaiters[id, default: 0] += 1
            defer {
                prefetch.interactiveWaiters[id, default: 0] = max(
                    0,
                    prefetch.interactiveWaiters[id, default: 0] - 1
                )
            }

            do {
                let details = try await task.value
                try Task.checkCancellation()
                guard currentGeneration(for: id) == generation else {
                    throw CancellationError()
                }
                if let loaded = details.first(where: { $0.id == id }) {
                    return loaded
                }
            } catch {
                try Task.checkCancellation()
                guard currentGeneration(for: id) == generation else {
                    throw CancellationError()
                }
            }
            // A speculative batch can fail because of another message. Retry
            // this selection through the interactive single-message boundary.
        }

        // A selection that arrives before its queued batch must take the ID
        // out of that queue, otherwise it would issue a duplicate read later.
        removeQueuedPrefetch(id)
        let request: Request
        if let existing = requests[id], existing.generation == generation {
            request = existing
        } else {
            requests[id]?.task.cancel()
            let task = Task { @MainActor [fetch] in
                try await fetch(id)
            }
            request = Request(generation: generation, task: task)
            requests[id] = request
        }

        request.interactiveWaiters += 1
        defer {
            request.interactiveWaiters = max(0, request.interactiveWaiters - 1)
        }

        do {
            let loaded = try await request.task.value
            guard currentGeneration(for: id) == generation else {
                throw CancellationError()
            }
            guard loaded.id == id else {
                throw MessageDetailLoaderError.identityMismatch(expected: id, actual: loaded.id)
            }
            insert(loaded, for: id)
            if requests[id] === request {
                requests.removeValue(forKey: id)
            }
            startPrefetch(epoch: prefetchEpoch)
            return loaded
        } catch {
            if requests[id] === request {
                requests.removeValue(forKey: id)
            }
            startPrefetch(epoch: prefetchEpoch)
            throw error
        }
    }

    func setProtectedMessageIDs(_ ids: Set<MessageID>) {
        for id in protectedIDs.subtracting(ids) {
            if let entry = values[id] {
                navigationBytes += entry.textBytes
            }
        }
        for id in ids.subtracting(protectedIDs) {
            if let entry = values[id] {
                navigationBytes -= entry.textBytes
            }
        }
        protectedIDs = ids
        trimNavigation()
    }

    /// Invalidates both completed and in-flight work for one message identity.
    /// A later request starts a fresh generation and cannot be overwritten by
    /// the invalidated request, even if the fetch implementation ignores
    /// cancellation. A batch may continue so that valid neighboring IDs can
    /// still be retained.
    func invalidate(_ id: MessageID) {
        generations[id, default: 0] &+= 1
        requests[id]?.task.cancel()
        requests.removeValue(forKey: id)
        removeCachedValue(for: id)
        removeQueuedPrefetch(id)
        startPrefetch(epoch: prefetchEpoch)
    }

    func invalidateAll() {
        globalGeneration &+= 1
        for request in requests.values {
            request.task.cancel()
        }
        requests.removeAll(keepingCapacity: true)
        generations.removeAll(keepingCapacity: true)
        values.removeAll(keepingCapacity: true)
        mruIDs.removeAll(keepingCapacity: true)
        protectedIDs.removeAll(keepingCapacity: true)
        navigationBytes = 0

        // Unlike cancelPrefetch(), global invalidation also cancels a batch
        // joined by a selection: every result from it is stale.
        prefetchEpoch &+= 1
        prefetchQueue.removeAll(keepingCapacity: true)
        queuedPrefetchIDs.removeAll(keepingCapacity: true)
        prefetchRequest?.task?.cancel()
    }

    /// Replaces the pending adjacent window and starts one bounded local
    /// batch. The active batch is intentionally retained when an interactive
    /// caller has joined it.
    /// IDs are nearest-first. Keep cached neighbors hot so replenishing the
    /// window does not evict a message that is about to be selected.
    func prefetch(_ ids: [MessageID]) {
        for id in ids.reversed() where values[id] != nil {
            touch(id)
        }
        let epoch = prefetchEpoch
        let active = prefetchRequest
        var candidates: [MessageID] = []
        for id in ids where values[id] == nil {
            // An interactive single read already owns this ID. Leave it out
            // of the speculative window instead of retrying it after failure.
            guard requests[id] == nil, !candidates.contains(id) else { continue }
            if let active,
               active.epoch == epoch,
               active.generations[id] == currentGeneration(for: id) {
                continue
            }
            candidates.append(id)
            if candidates.count == Self.navigationCapacity {
                break
            }
        }
        prefetchQueue = candidates
        queuedPrefetchIDs = Set(candidates)
        startPrefetch(epoch: epoch)
    }

    /// Stops scheduling new speculative work. An active batch remains alive
    /// when a selection has joined it; canceling that batch would cancel the
    /// interactive load as well.
    func cancelPrefetch() {
        prefetchEpoch &+= 1
        prefetchQueue.removeAll(keepingCapacity: true)
        queuedPrefetchIDs.removeAll(keepingCapacity: true)
        if let prefetch = prefetchRequest,
           !prefetch.interactiveWaiters.values.contains(where: { $0 > 0 }) {
            prefetch.task?.cancel()
        }
    }

    private func currentGeneration(for id: MessageID) -> Generation {
        Generation(
            global: globalGeneration,
            local: generations[id, default: 0]
        )
    }

    private func removeQueuedPrefetch(_ id: MessageID) {
        guard queuedPrefetchIDs.remove(id) != nil else { return }
        prefetchQueue.removeAll { $0 == id }
    }

    private func startPrefetch(epoch: UInt64) {
        guard epoch == prefetchEpoch, prefetchRequest == nil else { return }

        var batchIDs: [MessageID] = []
        var remaining: [MessageID] = []
        batchIDs.reserveCapacity(Self.speculativeBatchCapacity)
        for id in prefetchQueue {
            guard values[id] == nil else { continue }
            if batchIDs.count < Self.speculativeBatchCapacity,
               requests[id] == nil {
                batchIDs.append(id)
            } else {
                remaining.append(id)
            }
        }
        prefetchQueue = remaining
        queuedPrefetchIDs = Set(remaining)
        guard !batchIDs.isEmpty else { return }

        let generationByID = Dictionary(
            uniqueKeysWithValues: batchIDs.map { ($0, currentGeneration(for: $0)) }
        )
        let prefetch = PrefetchRequest(
            epoch: epoch,
            ids: batchIDs,
            generations: generationByID
        )
        prefetchRequest = prefetch
        prefetch.task = Task { @MainActor [weak self, weak prefetch] in
            guard let self, let prefetch else {
                throw CancellationError()
            }
            do {
                let details = try await self.fetchBatch(prefetch.ids)
                // This synchronous section is deliberately the only cache
                // publication point for the whole batch. The next batch is
                // scheduled only after every valid result is considered.
                self.completePrefetch(prefetch, details: details)
                return details
            } catch {
                self.failPrefetch(prefetch)
                throw error
            }
        }
    }

    private func completePrefetch(
        _ prefetch: PrefetchRequest,
        details: [MessageDetail]
    ) {
        guard prefetchRequest === prefetch else { return }

        var detailsByID: [MessageID: MessageDetail] = [:]
        detailsByID.reserveCapacity(details.count)
        for detail in details where prefetch.requestedIDs.contains(detail.id) {
            if detailsByID[detail.id] == nil {
                detailsByID[detail.id] = detail
            }
        }

        let currentEpoch = prefetchEpoch
        for id in prefetch.ids {
            guard let detail = detailsByID[id],
                  prefetch.generations[id] == currentGeneration(for: id) else {
                continue
            }
            let joinedInteractiveLoad = (prefetch.interactiveWaiters[id] ?? 0) > 0
            guard prefetch.epoch == currentEpoch || joinedInteractiveLoad else {
                continue
            }
            insert(detail, for: id)
        }

        prefetchRequest = nil
        startPrefetch(epoch: currentEpoch)
    }

    private func failPrefetch(_ prefetch: PrefetchRequest) {
        guard prefetchRequest === prefetch else { return }
        prefetchRequest = nil
        startPrefetch(epoch: prefetchEpoch)
    }

    private func insert(_ detail: MessageDetail, for id: MessageID) {
        let entry = CacheEntry(detail: detail, textBytes: Self.estimatedTextBytes(detail))
        if let old = values.updateValue(entry, forKey: id), !protectedIDs.contains(id) {
            navigationBytes -= old.textBytes
        }
        touch(id)
        if !protectedIDs.contains(id) {
            navigationBytes += entry.textBytes
        }
        trimNavigation()
    }

    private func removeCachedValue(for id: MessageID) {
        guard let old = values.removeValue(forKey: id) else { return }
        if !protectedIDs.contains(id) {
            navigationBytes -= old.textBytes
        }
        mruIDs.removeAll { $0 == id }
    }

    private func trimNavigation() {
        while navigationIDs.count > Self.navigationCapacity || navigationBytes > Self.navigationByteBudget {
            guard let id = mruIDs.last(where: { !protectedIDs.contains($0) }) else { return }
            removeCachedValue(for: id)
        }
    }

    private var navigationIDs: [MessageID] {
        mruIDs.filter { !protectedIDs.contains($0) && values[$0] != nil }
    }

    private func touch(_ id: MessageID) {
        mruIDs.removeAll { $0 == id }
        mruIDs.insert(id, at: 0)
    }

    private static func estimatedTextBytes(_ detail: MessageDetail) -> Int {
        (detail.bodyText?.utf8.count ?? 0) + (detail.sanitizedHTML?.utf8.count ?? 0)
    }
}

enum MessageDetailLoaderError: Error, Equatable {
    case identityMismatch(expected: MessageID, actual: MessageID)
    case missing(MessageID)
}
