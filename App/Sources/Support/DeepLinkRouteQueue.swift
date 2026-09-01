import Foundation
import MailternalInterfaces

@MainActor
final class DeepLinkRouteQueue {
    private var task: Task<Void, Never>?
    private var pending: MailternalDeepLink?

    func enqueue(
        _ link: MailternalDeepLink,
        isReady: @escaping @MainActor () -> Bool,
        route: @escaping @MainActor (MailternalDeepLink) async -> Void
    ) {
        pending = link
        task?.cancel()
        task = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    guard isReady() else {
                        try await Task.sleep(for: .milliseconds(25))
                        continue
                    }
                    guard let self, self.pending == link else { return }
                    await route(link)
                    guard !Task.isCancelled, self.pending == link else { return }
                    self.pending = nil
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
