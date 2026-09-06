import Foundation
import os

private let containerLog = Logger(subsystem: "org.kayg.mailternal", category: "Container")

/// On-disk layout for the live store (and therefore the sync engine).
///
/// On macOS this is the sandboxed Application Support container:
///
///     ~/Library/Application Support/Mailternal/
///       store.sqlite          — GRDB WAL database
///       store.sqlite-wal
///       store.sqlite-shm
///       attachments/          — content-hash attachment cache
///
/// On iOS the same relative layout is rooted in the app's sandbox:
/// `Library/Application Support/Mailternal/`. It is intentionally not
/// `Library/Caches`: the SQLite database contains the durable sync queues and
/// cursors and must survive cache eviction. Engine state lives in the store;
/// there is no second tree.
struct MailternalContainer: Sendable {
    var root: URL

    /// Production location under the platform's sandbox/Application Support.
    static var `default`: MailternalContainer {
        let bases = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base: URL
        if let applicationSupport = bases.first {
            base = applicationSupport
        } else {
            #if os(iOS)
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
            base = library.appendingPathComponent("Application Support", isDirectory: true)
            #else
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            #endif
        }
        return MailternalContainer(root: base.appendingPathComponent("Mailternal", isDirectory: true))
    }

    var databaseURL: URL {
        root.appendingPathComponent("store.sqlite", isDirectory: false)
    }

    var attachmentsDirectory: URL {
        root.appendingPathComponent("attachments", isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    }

    /// Deletes every file in `attachments/`.
    ///
    /// FileManager work runs on a detached utility task so a multi-gigabyte
    /// cache cannot freeze the MainActor. The directory itself is kept.
    /// Per-file failures are logged and do not throw.
    nonisolated func wipeAttachmentFiles() async {
        let directory = attachmentsDirectory
        let failures = await Task.detached(priority: .utility) {
            Self.removeContents(of: directory)
        }.value
        for failure in failures {
            containerLog.error("attachment wipe failed: \(failure, privacy: .public)")
        }
    }

    nonisolated private static func removeContents(of directory: URL) -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var failures: [String] = []
        for file in files {
            do {
                try fm.removeItem(at: file)
            } catch {
                failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return failures
    }
}
