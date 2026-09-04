import Foundation

/// Fetches and caches the small sender icons used by the reader tab strip.
///
/// All mutable cache state lives in the actor. Positive entries are persisted
/// at the PNG cache paths so a later launch does not need to refetch known
/// domains; failed loads are held in memory for one day to avoid repeatedly
/// retrying unavailable hosts.
actor FaviconStore {
    static let negativeCacheLifetime: TimeInterval = 24 * 60 * 60
    static let requestTimeout: TimeInterval = 5

    private enum CacheEntry {
        case image(Data)
        case negative(Date)
    }

    private let cacheDirectory: URL
    private let session: URLSession
    private let now: @Sendable () -> Date
    private var cache: [String: CacheEntry] = [:]

    init(
        cacheDirectory: URL? = nil,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cacheDirectory = cacheDirectory
            ?? FaviconStore.defaultCacheDirectory()
        self.now = now

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Returns favicon bytes for a sender domain, fetching them only when no
    /// cached image or recent negative result is available.
    func favicon(forSenderDomain rawDomain: String) async -> Data? {
        guard let domain = Self.normalizedDomain(rawDomain) else { return nil }

        if let cached = cache[domain] {
            switch cached {
            case .image(let image):
                return image
            case .negative(let failedAt):
                guard now().timeIntervalSince(failedAt) >= Self.negativeCacheLifetime else {
                    return nil
                }
                cache.removeValue(forKey: domain)
            }
        }
        let diskURL = cacheURL(for: domain)
        if let data = try? Data(contentsOf: diskURL), !data.isEmpty {
            cache[domain] = .image(data)
            return data
        }

        guard let url = URL(string: "https://\(domain)/favicon.ico") else {
            cache[domain] = .negative(now())
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  !data.isEmpty else {
                cache[domain] = .negative(now())
                return nil
            }

            try? FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try? data.write(to: cacheURL(for: domain), options: .atomic)
            cache[domain] = .image(data)
            return data
        } catch {
            cache[domain] = .negative(now())
            return nil
        }
    }

    /// Warms all requested domains concurrently and returns the positive
    /// results for the caller's synchronous UI lookup cache.
    func warmup(domains rawDomains: [String]) async -> [String: Data] {
        let domains = Set(rawDomains.compactMap(Self.normalizedDomain))
        return await withTaskGroup(of: (String, Data?).self, returning: [String: Data].self) { group in
            for domain in domains {
                group.addTask { [self] in
                    (domain, await self.favicon(forSenderDomain: domain))
                }
            }

            var images: [String: Data] = [:]
            for await (domain, image) in group {
                if let image {
                    images[domain] = image
                }
            }
            return images
        }
    }

    nonisolated static func normalizedDomain(_ rawDomain: String) -> String? {
        let domain = rawDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !domain.isEmpty, domain.count <= 253 else { return nil }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy({
                      ($0.value >= 48 && $0.value <= 57)
                          || ($0.value >= 97 && $0.value <= 122)
                          || $0.value == 45
                  }) else {
                return nil
            }
        }
        return domain
    }

    private func cacheURL(for domain: String) -> URL {
        cacheDirectory.appendingPathComponent("\(domain).png", isDirectory: false)
    }

    private static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Mailternal", isDirectory: true)
            .appendingPathComponent("favicons", isDirectory: true)
    }

}
