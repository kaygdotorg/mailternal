import Foundation
import Observation
import MailternalInterfaces

/// Loads and caches unfolded raw header items on explicit reader demand.
///
/// Ordinary envelope rendering never starts a raw-source request. A failed
/// fetch remains visible to the reader until an explicit retry, while loaded
/// states use the same small MRU bound as retained reader surfaces.
@MainActor
@Observable
final class MessageHeadersStore {
    enum State {
        case idle
        case loading
        case loaded(headers: [MessageHeaderPolicy.HeaderItem], text: String)
        case failed(String)
    }

    private static let capacity = 8

    private let fetchRawSource: @MainActor (MessageID) async throws -> String
    private(set) var states: [MessageID: State] = [:]

    @ObservationIgnored private var tasks: [MessageID: Task<Void, Never>] = [:]
    @ObservationIgnored private var taskGenerations: [MessageID: UInt64] = [:]
    @ObservationIgnored private var nextTaskGeneration: UInt64 = 0
    @ObservationIgnored private var mruIDs: [MessageID] = []

    init(fetchRawSource: @escaping @MainActor (MessageID) async throws -> String) {
        self.fetchRawSource = fetchRawSource
    }

    func state(for id: MessageID) -> State {
        guard let state = states[id] else { return .idle }
        touch(id)
        return state
    }

    /// Returns the complete fetched list when available, otherwise the
    /// envelope fields already present in message detail. Source mode can
    /// therefore show useful headers in the same render that reveals the mode,
    /// while the raw body continues loading.
    func headers(for id: MessageID, fallback envelope: Envelope) -> [MessageHeaderPolicy.HeaderItem]? {
        switch state(for: id) {
        case .loaded(let headers, _):
            return headers
        case .idle, .loading:
            let headers = MessageHeaderPolicy.detailHeaders(for: envelope)
            return headers.isEmpty ? nil : headers
        case .failed:
            return nil
        }
    }

    /// Starts a raw-header request only for an explicit header demand.
    ///
    /// A source already fetched by the reader is parsed locally and does not
    /// issue another facade request. The source remains optional because raw
    /// header mode may be requested before the raw-body mode has completed.
    func loadIfNeeded(for id: MessageID, cachedSource: String? = nil) {
        cancelLoads(except: id)
        switch state(for: id) {
        case .loaded(_, _):
            return
        case .loading where cachedSource == nil:
            return
        case .loading:
            cancelTask(for: id)
        case .idle:
            break
        case .failed(_) where cachedSource == nil:
            return
        case .failed(_):
            break
        }
        load(id, replacing: false, cachedSource: cachedSource)
    }

    func retry(_ id: MessageID, cachedSource: String? = nil) {
        cancelLoads(except: id)
        load(id, replacing: true, cachedSource: cachedSource)
    }

    /// Cancels requests for messages that are no longer the explicit header
    /// demand. Cancellation resets loading state to idle; it is not an error.
    func cancelLoads(except retainedID: MessageID? = nil) {
        let supersededIDs = tasks.keys.filter { $0 != retainedID }
        for id in supersededIDs {
            cancelTask(for: id)
        }
    }

    /// Cancels one message's pending request without disturbing a newly
    /// presented message that may have started loading during view removal.
    func cancelLoad(for id: MessageID) {
        cancelTask(for: id)
    }

    private func load(
        _ id: MessageID,
        replacing: Bool,
        cachedSource: String?
    ) {
        if !replacing, case .loading = state(for: id) {
            return
        }
        if replacing {
            cancelTask(for: id)
        }

        if let cachedSource {
            states[id] = loadedState(from: cachedSource)
            touch(id)
            trim()
            return
        }

        states[id] = .loading
        touch(id)
        trim()
        nextTaskGeneration &+= 1
        let generation = nextTaskGeneration
        taskGenerations[id] = generation
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await fetchRawSource(id)
                guard !Task.isCancelled,
                      self.taskGenerations[id] == generation
                else { return }
                states[id] = loadedState(from: source)
                touch(id)
                trim()
                tasks[id] = nil
                taskGenerations[id] = nil
            } catch is CancellationError {
                finishCancellation(id, generation: generation)
            } catch {
                guard !Task.isCancelled,
                      taskGenerations[id] == generation
                else { return }
                states[id] = .failed(error.localizedDescription)
                touch(id)
                trim()
                tasks[id] = nil
                taskGenerations[id] = nil
            }
        }
    }

    private func loadedState(from source: String) -> State {
        let headers = MessageHeaderPolicy.rawHeaders(from: source)
        return .loaded(
            headers: headers,
            text: MessageHeaderPolicy.rawHeaderBlock(from: headers)
        )
    }

    private func cancelTask(for id: MessageID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        taskGenerations[id] = nil
        if case .loading = states[id] {
            states[id] = nil
            mruIDs.removeAll { $0 == id }
        }
    }

    private func finishCancellation(_ id: MessageID, generation: UInt64) {
        guard taskGenerations[id] == generation else { return }
        tasks[id] = nil
        taskGenerations[id] = nil
        if case .loading = states[id] {
            states[id] = nil
            mruIDs.removeAll { $0 == id }
        }
    }

    private func trim() {
        while mruIDs.count > Self.capacity,
              let evictedID = mruIDs.last {
            mruIDs.removeLast()
            states.removeValue(forKey: evictedID)
            tasks[evictedID]?.cancel()
            tasks[evictedID] = nil
            taskGenerations[evictedID] = nil
        }
    }

    private func touch(_ id: MessageID) {
        mruIDs.removeAll { $0 == id }
        mruIDs.insert(id, at: 0)
    }
}
