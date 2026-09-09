import Darwin
import Foundation
import MailternalInterfaces
import MailternalStore

/// Private QA launcher. Parses `-qa-account host port security`
/// and optional `-qa-container`, `-qa-cache-cap`, `-qa-bench-search`,
/// `-qa-bench-select`, `-qa-fetch-cid`, and `-qa-open-window <link>`.
///
/// Password is never an argv token: `MAILTERNAL_QA_PASSWORD` or `qa-password`.
enum QALaunch: Sendable {
    /// First-observed process uptime used on iOS, where the macOS
    /// `KERN_PROC_PID` start-time query is not a supported app API.
    private static let processStartUptime = ProcessInfo.processInfo.systemUptime
    struct Config: Sendable {
        var host: String
        var port: Int
        var security: IMAPEndpoint.Security
        var containerRoot: URL
        var cacheCap: Int64?
        var username: String
        var password: String
        var accountID: AccountID
        var benchSearch: Bool
        var benchSelectCount: Int?
        var fetchCID: Bool
        var openWindowLink: MailternalDeepLink?
        var accountConfig: AccountConfig {
            AccountConfig(
                id: accountID,
                accountLinkID: AccountLinkID(
                    uuidString: "00000000-0000-4000-8000-000000000002"
                )!,
                displayName: "QA",
                emailAddress: username,
                username: username,
                imap: IMAPEndpoint(host: host, port: port, security: security)
            )
        }
    }

    static func parse(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Config? {
        #if !DEBUG
        guard environment["MAILTERNAL_QA"] == "1" else { return nil }
        #endif
        var host: String?
        var port: Int?
        var security: IMAPEndpoint.Security?
        var container: URL?
        var cacheCap: Int64?
        var benchSearch = false
        var benchSelectCount: Int?
        var fetchCID = false
        var openWindowLink: MailternalDeepLink?
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-qa-account":
                guard index + 3 < arguments.count else { return nil }
                host = arguments[index + 1]
                port = Int(arguments[index + 2])
                security = parseSecurity(arguments[index + 3])
                index += 4
            case "-qa-container":
                guard index + 1 < arguments.count else { return nil }
                container = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                index += 2
            case "-qa-cache-cap":
                guard index + 1 < arguments.count else { return nil }
                cacheCap = Int64(arguments[index + 1])
                index += 2
            case "-qa-bench-search":
                benchSearch = true
                index += 1
            case "-qa-bench-select":
                guard index + 1 < arguments.count else { return nil }
                benchSelectCount = Int(arguments[index + 1]).map { max(0, $0) }
                index += 2
            case "-qa-fetch-cid":
                fetchCID = true
                index += 1
            case "-qa-open-window":
                guard index + 1 < arguments.count else { return nil }
                guard let link = MailternalDeepLink(string: arguments[index + 1]) else {
                    return nil
                }
                openWindowLink = link
                index += 2
            default:
                index += 1
            }
        }
        guard let host, let port, let security, port > 0, port < 65536 else { return nil }
        let username = environment["MAILTERNAL_QA_USER"] ?? "qa@mailternal.test"
        let password = environment["MAILTERNAL_QA_PASSWORD"] ?? "qa-password"
        let root = container ?? MailternalContainer.default.root
        return Config(
            host: host,
            port: port,
            security: security,
            containerRoot: root,
            cacheCap: cacheCap,
            username: username,
            password: password,
            accountID: AccountID(rawValue: "qa-\(host)-\(port)"),
            benchSearch: benchSearch,
            benchSelectCount: benchSelectCount,
            fetchCID: fetchCID,
            openWindowLink: openWindowLink
        )
    }

    static func parseSecurity(_ raw: String) -> IMAPEndpoint.Security? {
        switch raw.lowercased() {
        case "starttls", "start-tls", "startTLS":
            return .startTLS
        case "implicittls", "implicit-tls", "implicitTLS", "tls":
            return .implicitTLS
        default:
            return IMAPEndpoint.Security(rawValue: raw)
        }
    }

    static func log(_ message: String) {
        let line = "[mailternal-qa] \(message)\n"
        if let data = line.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    /// Milliseconds since process start. macOS retains the kernel start-time
    /// measurement used by the launch QA harness. iOS does not expose that
    /// query to app targets, so its QA-only fallback measures from the first
    /// call in this process.
    static func millisecondsSinceProcessStart() -> Double {
        #if os(macOS)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ProcessInfo.processInfo.processIdentifier]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let startSeconds = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return (Date().timeIntervalSince1970 - startSeconds) * 1000
        #else
        return max(0, (ProcessInfo.processInfo.systemUptime - processStartUptime) * 1000)
        #endif
    }

    /// Launch phase marker; the marker name is evaluated only in QA mode.
    static func launchPhase(_ name: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["MAILTERNAL_QA"] == "1" else { return }
        log(String(format: "launch phase=%@ t=%.1fms footprint=%lld", name(), millisecondsSinceProcessStart(), footprintBytes()))
    }

    /// Activity Monitor "memory footprint" (`phys_footprint`), or -1 if unavailable.
    static func footprintBytes() -> Int64 {
        #if os(macOS) || os(iOS)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Int64(info.phys_footprint)
        #else
        return -1
        #endif
    }

    @MainActor
    static func makeFacade(_ config: Config? = parse()) throws -> LiveMailFacade? {
        guard let config else { return nil }
        let container = MailternalContainer(root: config.containerRoot)
        let keychain = KeychainStore(service: "org.kayg.mailternal.qa", storage: .memory)
        return try LiveMailFacade(
            container: container,
            keychain: keychain,
            enableNotifications: false,
            attachmentCacheCapBytes: config.cacheCap ?? MailStore.defaultAttachmentCacheCapBytes
        )
    }
}
