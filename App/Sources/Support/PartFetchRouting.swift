import Foundation

/// Where a `mailternal-part` provider key should be loaded from.
///
/// Remote `http`/`https` references are never IMAP part specifiers — after
/// consent they are fetched by the app, not `SyncEngine.fetchPart`.
enum PartFetchRoute: Equatable, Sendable {
    case imap(String)
    case remote(URL)
}

enum PartFetchRouting {
    static func route(_ reference: String) -> PartFetchRoute? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .remote(url)
        }
        return .imap(trimmed)
    }

    /// Dispatches a provider key to IMAP or an app-side remote fetch.
    /// Remote URLs never invoke `imap`.
    static func dispatch(
        reference: String,
        imap: (String) async throws -> (data: Data, mimeType: String),
        remote: (URL) async throws -> (data: Data, mimeType: String)
    ) async throws -> (data: Data, mimeType: String) {
        switch route(reference) {
        case .remote(let url):
            return try await remote(url)
        case .imap(let part):
            return try await imap(part)
        case nil:
            throw URLError(.badURL)
        }
    }
}

enum RemoteImageFetchError: Error, Equatable {
    case invalidURL
    case redirectEscapedHTTP
    case tooLarge
    case notImage
}

/// Fetches a consented remote image. Ephemeral session, http(s) only,
/// no cookies/credentials/caches, 10 MiB cap, declared `image/*` only.
enum RemoteImageFetch {
    static let maxBytes = 10 * 1024 * 1024

    static func load(_ url: URL) async throws -> (data: Data, mimeType: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw RemoteImageFetchError.invalidURL
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30

        let delegate = RemoteImageSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: url)
        if delegate.redirectEscaped {
            throw RemoteImageFetchError.redirectEscapedHTTP
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemoteImageFetchError.notImage
        }
        if (300...399).contains(http.statusCode) {
            throw RemoteImageFetchError.redirectEscapedHTTP
        }
        if data.count > maxBytes {
            throw RemoteImageFetchError.tooLarge
        }
        if let length = http.value(forHTTPHeaderField: "Content-Length"),
           let declared = Int(length), declared > maxBytes {
            throw RemoteImageFetchError.tooLarge
        }
        guard let mime = declaredImageMIME(http) else {
            throw RemoteImageFetchError.notImage
        }
        return (data, mime)
    }

    static func declaredImageMIME(_ response: HTTPURLResponse) -> String? {
        let raw = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let mime = raw.split(separator: ";")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard mime.hasPrefix("image/") else { return nil }
        return mime
    }
}

final class RemoteImageSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _redirectEscaped = false

    var redirectEscaped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _redirectEscaped
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            lock.lock()
            _redirectEscaped = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
