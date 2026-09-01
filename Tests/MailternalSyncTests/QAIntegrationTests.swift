#if os(macOS)
import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

private enum QA {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" }

    static let user = "qa@mailternal.test"
    static let password = "qa-password"
    static let host = "127.0.0.1"

    static func installTrust() throws {
        let env = ProcessInfo.processInfo.environment["MAILTERNAL_QA_CERT"]
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("mailternal-qa/certs/dovecot.crt")
        let url = env.map(URL.init(fileURLWithPath:)) ?? home
        let pem = try Data(contentsOf: url)
        IMAPSession.installAdditionalTrustRoots(pem: [pem])
    }

    static func config(port: Int, security: IMAPEndpoint.Security) -> AccountConfig {
        AccountConfig(
            id: AccountID(rawValue: "qa-\(port)"),
            displayName: "QA",
            emailAddress: user,
            username: user,
            imap: IMAPEndpoint(host: host, port: port, security: security)
        )
    }

    /// QA hosts a 926 GiB volume with ~49 GiB free, so the spec reserve
    /// (max(5 GiB, 10% of volume) ≈ 93 GiB) would halt immediately. Pin a
    /// spacious disk so the 100k walk is actually exercised.
    static func engine(store: MailStore, port: Int, dir: URL) -> SyncEngine {
        var settings = testSettings(dir: dir, window: SyncPolicy.defaultWindowSize)
        settings.seenPoll = .seconds(2)
        return SyncEngine(
            store: store,
            config: config(port: port, security: .startTLS),
            credentials: StaticPassword(value: password),
            clientFactory: LiveIMAPClientFactory(),
            disk: FixedDisk(
                freeBytes: 200 * 1024 * 1024 * 1024,
                volumeBytes: 500 * 1024 * 1024 * 1024
            ),
            clock: { Date() },
            settings: settings
        )
    }

    /// Fail fast on TLS/auth instead of waiting out the backfill timeout.
    static func probe(port: Int, security: IMAPEndpoint.Security) async throws {
        let session = IMAPSession(
            endpoint: IMAPEndpoint(host: host, port: port, security: security),
            username: user,
            password: password
        )
        try await session.connect()
        await session.close()
    }
}

@Suite(.serialized)
struct QAIntegrationTests {
    @Test(.enabled(if: QA.enabled))
    func fullInboxSyncSearchHorrorsAndQresyncDelta() async throws {
        try QA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QA.probe(port: 1143, security: .startTLS)
        try await withSyncStore { store, dir in
            let engine = QA.engine(store: store, port: 1143, dir: dir)
            let started = Date()
            await engine.start()
            do {
                try await waitUntil(timeout: .seconds(480), poll: .milliseconds(500)) {
                    let folders = try await store.fetchFolders(account: QA.config(port: 1143, security: .startTLS).id)
                    return folders.contains { $0.path == "INBOX" && $0.backfill == .complete && $0.totalCount >= 100_000 }
                }
                let elapsed = Date().timeIntervalSince(started)
                print("MAILTERNAL_QA INBOX 100k wall-clock: \(elapsed)s")
                #expect(elapsed < 300, "100k initial sync exceeded 5 min: \(elapsed)s")

                let account = QA.config(port: 1143, security: .startTLS).id
                let folders = try await store.fetchFolders(account: account)
                let inbox = try #require(folders.first { $0.path == "INBOX" })
                #expect(inbox.totalCount >= 100_000)
                let hits = try await store.search("mailternal", limit: 10)
                #expect(!hits.isEmpty)

                let horrors = try #require(folders.first { $0.path == "Horrors" })
                try await waitUntil(timeout: .seconds(300), poll: .milliseconds(500)) {
                    let latest = try await store.fetchFolders(account: account)
                    guard latest.contains(where: { $0.path == "Horrors" }) else { return false }
                    return latest.allSatisfy { folder in
                        switch folder.backfill {
                        case .complete, .halted: return true
                        default: return false
                        }
                    }
                }
                let horrorsSummary = try #require(await store.fetchFolderSummary(horrors.id))
                #expect(horrorsSummary.totalCount >= 1)
                var cursor: MessagePageCursor?
                var seen = 0
                var quarantined = 0
                repeat {
                    let page = try await store.page(in: horrors.id, after: cursor, limit: 50)
                    for row in page.rows {
                        let detail = try await store.detail(row.id)
                        seen += 1
                        if detail.isQuarantined { quarantined += 1 }
                    }
                    cursor = page.next
                    if page.rows.isEmpty { break }
                } while cursor != nil
                #expect(seen == horrorsSummary.totalCount)
                _ = quarantined

                let page = try await store.page(in: inbox.id, after: nil, limit: 40)
                let unread = try #require(page.rows.first { !$0.isRead })
                let ref = try #require(await store.messageRef(unread.id))
                let side = IMAPSession(
                    endpoint: IMAPEndpoint(host: QA.host, port: 1143, security: .startTLS),
                    username: QA.user,
                    password: QA.password
                )
                try await side.connect()
                _ = try await side.select("INBOX")
                try await side.storeSeen(uids: IMAPUIDSet(uid: ref.uid.rawValue))
                await side.close()
                await engine.refreshNow()
                try await waitUntil(timeout: .seconds(20), poll: .milliseconds(200)) {
                    let detail = try await store.detail(unread.id)
                    let page = try await store.page(in: inbox.id, after: nil, limit: 80)
                    return detail.envelope.subject == unread.subject
                        && page.rows.contains { $0.id == unread.id && $0.isRead }
                }
                await engine.stop()
            } catch {
                let account = QA.config(port: 1143, security: .startTLS).id
                if let folders = try? await store.fetchFolders(account: account) {
                    print("MAILTERNAL_QA timeout folders: \(folders.map { "\($0.path) backfill=\($0.backfill) count=\($0.totalCount)" })")
                }
                print("MAILTERNAL_QA elapsed: \(Date().timeIntervalSince(started))s")
                await engine.stop()
                throw error
            }
        }
    }

    @Test(.enabled(if: QA.enabled))
    func basicPathSyncViaPort2143() async throws {
        try QA.installTrust()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        try await QA.probe(port: 2143, security: .startTLS)
        try await withSyncStore { store, dir in
            let config = QA.config(port: 2143, security: .startTLS)
            let engine = QA.engine(store: store, port: 2143, dir: dir)
            await engine.start()
            try await waitUntil(timeout: .seconds(90), poll: .milliseconds(400)) {
                let folders = try await store.fetchFolders(account: config.id)
                guard let inbox = folders.first(where: { $0.path == "INBOX" }) else { return false }
                guard let gen = try await store.liveGeneration(for: inbox.id) else { return false }
                let state = try await store.fetchSyncState(for: gen)
                return state?.deltaPath == .basic && inbox.totalCount >= 200
            }
            let folders = try await store.fetchFolders(account: config.id)
            let inbox = try #require(folders.first { $0.path == "INBOX" })
            let gen = try #require(await store.liveGeneration(for: inbox.id))
            let state = try #require(await store.fetchSyncState(for: gen))
            #expect(state.deltaPath == .basic)
            #expect(inbox.totalCount >= 200)
            await engine.stop()
        }
    }
}
#endif
