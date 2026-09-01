import Foundation

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

    func wipeAttachmentFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files {
            try? fm.removeItem(at: file)
        }
    }
}
