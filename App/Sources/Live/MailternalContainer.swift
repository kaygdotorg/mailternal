import Foundation
import os

private let containerLog = Logger(subsystem: "org.kayg.mailternal", category: "Container")

/// On-disk layout for the live store (and therefore the sync engine).
///
/// One directory, the sandboxed Application Support container:
///
///     ~/Library/Application Support/Mailternal/
///       store.sqlite          — GRDB WAL database
///       store.sqlite-wal
///       store.sqlite-shm
///       attachments/          — content-hash attachment cache
///
/// Inside the sandbox that root is
/// `~/Library/Containers/org.kayg.mailternal/Data/Library/Application Support/Mailternal/`.
/// Engine state lives in the store; there is no second tree.
struct MailternalContainer: Sendable {
    var root: URL

    /// Production location under Application Support.
    static var `default`: MailternalContainer {
        let bases = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = bases.first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
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
