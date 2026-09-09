import Foundation
import MailternalInterfaces
import Observation

/// The single live search workflow shared by the native panel and GUI automation.
///
/// Search state lives outside the view so a command-driven query and a human
/// keystroke use the same debounce, cancellation, and stale-result guards.
@MainActor
@Observable
final class SearchPresentation {
    private(set) var query = ""
    private(set) var results: [MessageRow] = []
    private(set) var selectedResultID: MessageID?
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    /// Called after live presentation state changes. AppModel uses this to
    /// publish only when a subscription is active; view observation remains
    /// independent of automation.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration: UInt64 = 0

    /// Starts the debounced search for a GUI command's query.
    ///
    /// The facade is supplied by the command owner rather than retained here;
    /// this keeps the presentation a state/workflow module while ensuring the
    /// native panel and automation invoke exactly the same search operation.
    func setQuery(_ text: String, using facade: any MailFacade) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        let generation = searchGeneration

        query = text
        errorMessage = nil
        guard let normalized = SearchQueryPolicy.normalizedQuery(text) else {
            results = []
            selectedResultID = nil
            isSearching = false
            onChange?()
            return
        }
        results = []
        selectedResultID = nil
        isSearching = true
        onChange?()
        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: SearchQueryPolicy.debounce)
                try Task.checkCancellation()
                let hits = try await facade.search(
                    normalized,
                    limit: 40,
                    accountLinks: nil
                )
                guard let self, self.searchGeneration == generation else { return }
                self.results = hits
                self.selectedResultID = hits.first?.id
                self.isSearching = false
                self.searchTask = nil
                self.onChange?()
            } catch is CancellationError {
                // Cancellation is expected when the query changes or the panel closes.
            } catch {
                guard let self,
                      self.searchGeneration == generation,
                      !Task.isCancelled
                else { return }
                self.errorMessage = error.localizedDescription
                self.isSearching = false
                self.searchTask = nil
                self.onChange?()
            }
        }
    }

    func selectResult(_ id: MessageID?) {
        guard id == nil || results.contains(where: { $0.id == id }),
              selectedResultID != id else { return }
        selectedResultID = id
        onChange?()
    }

    /// Cancels in-flight work when the search surface is dismissed.
    func cancel() {
        let changed = searchTask != nil || isSearching
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isSearching = false
        if changed {
            onChange?()
        }
    }
}
