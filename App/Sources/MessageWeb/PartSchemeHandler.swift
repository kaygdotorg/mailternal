#if os(macOS)
import Foundation
import WebKit
import MailternalSanitizer

typealias PartProvider = @Sendable (String) async throws -> (data: Data, mimeType: String)

/// Serves `mailternal-part://` tokens. Remote tokens get a placeholder until consent.
///
/// Each `start` owns one unstructured `Task` in ``SchemeTaskRegistry``. `stop`
/// cancels that task; success, failure, and cancel all remove the entry so the
/// map cannot leak and a recycled `ObjectIdentifier` cannot inherit a stale
/// stopped flag. The handler is self-contained: it only calls the injected
/// `partProvider`.
final class PartSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private struct State {
        var provider: PartProvider?
        var remoteAllowed = false
    }

    private let lock = NSLock()
    private var state = State()
    private let registry = SchemeTaskRegistry()

    func update(provider: PartProvider?, remoteAllowed: Bool) {
        lock.lock()
        state.provider = provider
        state.remoteAllowed = remoteAllowed
        lock.unlock()
    }

    func setRemoteAllowed(_ allowed: Bool) {
        lock.lock()
        state.remoteAllowed = allowed
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        lock.lock()
        let provider = state.provider
        let remoteAllowed = state.remoteAllowed
        lock.unlock()

        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        let slot = HandleSlot()
        let task = Task<Void, Never> {
            defer {
                if let handle = slot.handle { self.registry.remove(handle) }
            }
            if Task.isCancelled { return }
            do {
                let (data, mime) = try await self.resolve(
                    url,
                    provider: provider,
                    remoteAllowed: remoteAllowed
                )
                if Task.isCancelled { return }
                // Consent reloads the same token URL; never let a blocked
                // placeholder satisfy the subsequent allowed request.
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Cache-Control": "no-store, no-cache, must-revalidate",
                        "Pragma": "no-cache",
                        "Expires": "0",
                        "Content-Type": mime,
                        "Content-Length": "\(data.count)"
                    ]
                ) ?? URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
        slot.handle = registry.register(id, task: task)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        registry.stop(ObjectIdentifier(urlSchemeTask))
    }

    func resolve(
        _ url: URL,
        provider: PartProvider?,
        remoteAllowed: Bool
    ) async throws -> (Data, String) {
        try Task.checkCancellation()
        guard let reference = PartURL.decode(url) else {
            throw URLError(.badURL)
        }
        if reference.isRemote, !remoteAllowed {
            return (Self.placeholderPNG, "image/png")
        }
        guard let provider else {
            throw URLError(.resourceUnavailable)
        }
        let part = try await provider(reference.providerKey)
        try Task.checkCancellation()
        return (part.data, part.mimeType)
    }

    /// 1x1 transparent PNG used as the blocked-remote placeholder.
    private static let placeholderPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!
}

private final class HandleSlot: @unchecked Sendable {
    var handle: SchemeTaskHandle?
}
#endif
