import Foundation
import Observation
import MailternalInterfaces

/// Lazily loads and caches the unfolded raw header block for each message shown
/// by a reader. A failed fetch remains visible to the reader until an explicit
/// retry, while successful loads are retained for the lifetime of the viewer.
@MainActor
@Observable
final class MessageHeadersStore {
    enum State {
        case idle
        case loading
        case loaded(headers: [(name: String, value: String)], text: String)
        case failed(String)
    }

    let facade: any MailFacade
    private(set) var states: [MessageID: State] = [:]

    @ObservationIgnored private var tasks: [MessageID: Task<Void, Never>] = [:]

    init(facade: any MailFacade) {
        self.facade = facade
    }

    func state(for id: MessageID) -> State {
        states[id] ?? .idle
    }

    func loadIfNeeded(for id: MessageID) {
        guard case .idle = state(for: id) else { return }
        load(id, replacing: false)
    }

    func retry(_ id: MessageID) {
        load(id, replacing: true)
    }

    private func load(_ id: MessageID, replacing: Bool) {
        if !replacing, case .loading = state(for: id) {
            return
        }
        tasks[id]?.cancel()
        states[id] = .loading
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await facade.rawSource(id)
                guard !Task.isCancelled else { return }
                let headers = MessageHeaderPolicy.rawHeaders(from: source)
                let text = MessageHeaderPolicy.rawHeaderBlock(from: source)
                states[id] = .loaded(headers: headers, text: text)
                tasks[id] = nil
            } catch is CancellationError {
                tasks[id] = nil
            } catch {
                guard !Task.isCancelled else { return }
                states[id] = .failed(error.localizedDescription)
                tasks[id] = nil
            }
        }
    }
}
