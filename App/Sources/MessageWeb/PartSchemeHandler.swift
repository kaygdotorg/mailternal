#if os(macOS)
import Foundation
import WebKit
import MailternalSanitizer

typealias PartProvider = @Sendable (String) async throws -> (data: Data, mimeType: String)

/// Serves `mailternal-part://` tokens. Remote tokens get a placeholder until consent.
final class PartSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private struct State {
        var provider: PartProvider?
        var remoteAllowed = false
        var stopped: Set<ObjectIdentifier> = []
    }

    private let lock = NSLock()
    private var state = State()

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

        Task {
            if self.isStopped(id) { return }
            do {
                let (data, mime) = try await self.resolve(
                    url,
                    provider: provider,
                    remoteAllowed: remoteAllowed
                )
                if self.isStopped(id) { return }
                let response = URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: data.count,
                    textEncodingName: nil
                )
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if self.isStopped(id) { return }
                urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        state.stopped.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    private func isStopped(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.stopped.contains(id)
    }

    private func resolve(
        _ url: URL,
        provider: PartProvider?,
        remoteAllowed: Bool
    ) async throws -> (Data, String) {
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
        return (part.data, part.mimeType)
    }

    /// 1x1 transparent PNG used as the blocked-remote placeholder.
    private static let placeholderPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    )!
}
#endif
