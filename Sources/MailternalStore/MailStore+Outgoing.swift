import Foundation
import GRDB

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class OutgoingImportRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var activeIDs = Set<String>()
    private var lastOrphanSweep: ContinuousClock.Instant?

    func begin(_ id: String) {
        lock.lock()
        activeIDs.insert(id)
        lock.unlock()
    }

    func end(_ id: String) {
        lock.lock()
        activeIDs.remove(id)
        lock.unlock()
    }


    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return activeIDs
    }

    func claimOrphanSweep() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if let lastOrphanSweep, lastOrphanSweep.duration(to: now) < .seconds(3600) {
            return false
        }
        lastOrphanSweep = now
        return true
    }
}

private let outgoingAttachmentMaximumBytes: Int64 = 256 * 1024 * 1024
private let outgoingAccountStagingMaximumBytes: Int64 = 1 * 1024 * 1024 * 1024
private let outgoingGlobalStagingMaximumBytes: Int64 = 4 * 1024 * 1024 * 1024
private let outgoingAccountStagingMaximumFiles = 64
private let outgoingGlobalStagingMaximumFiles = 256
private let outgoingStagingLifetime: TimeInterval = 24 * 60 * 60

private let outgoingChunkSize = 64 * 1024

#if canImport(Darwin)
@inline(__always) private func outgoingOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    Darwin.open(path, flags, mode)
}
@inline(__always) private func outgoingRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Darwin.read(fd, buffer, count)
}
@inline(__always) private func outgoingWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Darwin.write(fd, buffer, count)
}
@inline(__always) private func outgoingSync(_ fd: Int32) -> Int32 { Darwin.fsync(fd) }
@inline(__always) private func outgoingClose(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#elseif canImport(Glibc)
@inline(__always) private func outgoingOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    Glibc.open(path, flags, mode)
}
@inline(__always) private func outgoingRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    Glibc.read(fd, buffer, count)
}
@inline(__always) private func outgoingWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.write(fd, buffer, count)
}
@inline(__always) private func outgoingSync(_ fd: Int32) -> Int32 { Glibc.fsync(fd) }
@inline(__always) private func outgoingClose(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#endif

#if canImport(Darwin)
@inline(__always) private func outgoingFStat(_ fd: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32 {
    Darwin.fstat(fd, status)
}
@inline(__always) private func outgoingFChmod(_ fd: Int32, _ mode: mode_t) -> Int32 {
    Darwin.fchmod(fd, mode)
}
#elseif canImport(Glibc)
@inline(__always) private func outgoingFStat(_ fd: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32 {
    Glibc.fstat(fd, status)
}
@inline(__always) private func outgoingFChmod(_ fd: Int32, _ mode: mode_t) -> Int32 {
    Glibc.fchmod(fd, mode)
}
#endif

extension MailStore {
    // MARK: - Durable spool

    /// Creates the private durable spool. The path is derived from the database
    /// file, so a cloned database cannot accidentally share outgoing files.
    static func prepareOutgoingDirectories(at root: URL) throws {
        let fileManager = FileManager.default
        try createSecureDirectory(root, fileManager: fileManager)
        try createSecureDirectory(root.appendingPathComponent("attachments", isDirectory: true), fileManager: fileManager)
        try createSecureDirectory(root.appendingPathComponent("submissions", isDirectory: true), fileManager: fileManager)
    }

    private static func createSecureDirectory(_ url: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        let descriptor = try openNoFollow(url, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        defer { _ = outgoingClose(descriptor) }
        var status = stat()
        guard outgoingFStat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              outgoingFChmod(descriptor, mode_t(0o700)) == 0 else {
            throw OutgoingMailError.invalidContent("Outgoing spool path is not a private directory.")
        }
    }
    private static func secureFileError(_ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: path])
    }

    private static func openNoFollow(_ url: URL, flags: Int32, mode: mode_t = 0o600) throws -> Int32 {
        guard url.isFileURL else {
            throw OutgoingMailError.invalidContent("Outgoing files must use a local file URL.")
        }
        let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { throw OutgoingMailError.invalidContent("Outgoing path is invalid.") }
            return outgoingOpen(path, flags, mode)
        }
        guard descriptor >= 0 else {
            throw secureFileError(url.path)
        }
        return descriptor
    }

    private static func regularFileSize(_ descriptor: Int32, path: URL) throws -> Int64 {
        var status = stat()
        guard outgoingFStat(descriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              status.st_size >= 0 else {
            throw OutgoingMailError.invalidContent("Outgoing file is not a regular file.")
        }
        return Int64(status.st_size)
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = try openNoFollow(url, flags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        defer { _ = outgoingClose(descriptor) }
        guard outgoingSync(descriptor) == 0 else { throw secureFileError(url.path) }
    }

    private static func synchronizeSubmissionFile(id: UUID, root: URL, expectedByteCount: Int64) throws {
        let url = submissionPath(id, root: root)
        let descriptor: Int32
        do {
            descriptor = try openNoFollow(url, flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        } catch {
            throw OutgoingMailError.invalidContent("Submission file is unavailable.")
        }
        defer { _ = outgoingClose(descriptor) }
        guard outgoingFChmod(descriptor, mode_t(0o600)) == 0 else {
            throw secureFileError(url.path)
        }
        guard try regularFileSize(descriptor, path: url) == expectedByteCount else {
            throw OutgoingMailError.invalidContent("Submission file size does not match its durable record.")
        }
        guard outgoingSync(descriptor) == 0 else {
            throw secureFileError(url.path)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func copyImportedFile(from sourceURL: URL, to destinationURL: URL) throws -> Int64 {
        let source = try openNoFollow(sourceURL, flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        var sourceOpen = true
        var destination: Int32 = -1
        var destinationOpen = false
        var destinationCreated = false
        do {
            let sourceSize = try regularFileSize(source, path: sourceURL)
            guard sourceSize <= outgoingAttachmentMaximumBytes else {
                throw OutgoingMailError.invalidContent("Attachment exceeds the 256 MiB size limit.")
            }
            destination = try openNoFollow(
                destinationURL,
                flags: O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
            )
            destinationOpen = true
            destinationCreated = true
            guard outgoingFChmod(destination, mode_t(0o600)) == 0 else {
                throw secureFileError(destinationURL.path)
            }
            _ = try regularFileSize(destination, path: destinationURL)

            var buffer = [UInt8](repeating: 0, count: outgoingChunkSize)
            var copied: Int64 = 0
            while true {
                guard !Task.isCancelled else { throw CancellationError() }
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return -1 }
                    return outgoingRead(source, baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw secureFileError(sourceURL.path)
                }

                var offset = 0
                while offset < count {
                    guard !Task.isCancelled else { throw CancellationError() }
                    let written = buffer.withUnsafeBytes { bytes -> Int in
                        guard let baseAddress = bytes.baseAddress else { return -1 }
                        return outgoingWrite(destination, baseAddress.advanced(by: offset), count - offset)
                    }
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw secureFileError(destinationURL.path)
                    }
                    guard written > 0 else { throw secureFileError(destinationURL.path) }
                    offset += written
                }
                copied += Int64(count)
                guard copied <= outgoingAttachmentMaximumBytes else {
                    throw OutgoingMailError.invalidContent("Attachment exceeds the 256 MiB size limit.")
                }
                guard try regularFileSize(source, path: sourceURL) == sourceSize else {
                    throw OutgoingMailError.invalidContent("Attachment source changed during import.")
                }
                guard !Task.isCancelled else { throw CancellationError() }
            }

            let finalSourceSize = try regularFileSize(source, path: sourceURL)
            guard finalSourceSize == sourceSize, copied == sourceSize else {
                throw OutgoingMailError.invalidContent("Attachment source changed during import.")
            }
            guard !Task.isCancelled else { throw CancellationError() }
            guard outgoingSync(destination) == 0 else { throw secureFileError(destinationURL.path) }
            guard outgoingClose(destination) == 0 else { throw secureFileError(destinationURL.path) }
            destinationOpen = false
            try syncDirectory(destinationURL.deletingLastPathComponent())
            guard !Task.isCancelled else { throw CancellationError() }
            guard outgoingClose(source) == 0 else { throw secureFileError(sourceURL.path) }
            sourceOpen = false
            return copied
        } catch {
            if destinationOpen { _ = outgoingClose(destination) }
            if sourceOpen { _ = outgoingClose(source) }
            if destinationCreated {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            throw error
        }
    }

    private static func validateAttachmentInput(filename: String, mimeType: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0"),
              !filename.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw OutgoingMailError.invalidContent("Attachment filename is invalid.")
        }
        guard !mimeType.isEmpty,
              !mimeType.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw OutgoingMailError.invalidContent("Attachment MIME type is invalid.")
        }
    }

    private static func attachmentPath(_ id: UUID, root: URL) -> URL {
        root.appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
    }

    private static func submissionPath(_ id: UUID, root: URL) -> URL {
        root.appendingPathComponent("submissions", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension("eml")
    }

    private static func uuid(from raw: String) throws -> UUID {
        guard let value = UUID(uuidString: raw) else {
            throw OutgoingMailError.invalidContent("Outgoing record has an invalid identifier.")
        }
        return value
    }

    private static func optionalUUID(_ raw: String?) -> UUID? {
        raw.flatMap(UUID.init(uuidString:))
    }

    private static func validateAttachments(
        _ db: Database,
        accountID: AccountID,
        attachments: [DraftAttachment]
    ) throws {
        var seen = Set<UUID>()
        for attachment in attachments {
            guard seen.insert(attachment.id).inserted else {
                throw OutgoingMailError.invalidContent("A draft cannot reference an attachment more than once.")
            }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_id, filename, mime_type, byte_count,
                           unreferenced_at, reclaiming_at
                    FROM draft_attachments
                    WHERE id = ?
                    """,
                arguments: [attachment.id.uuidString.lowercased()]
            ) else {
                throw OutgoingMailError.attachmentNotFound
            }
            let owner: String = row["account_id"]
            let filename: String = row["filename"]
            let mimeType: String = row["mime_type"]
            let byteCount: Int64 = row["byte_count"]
            let reclaimingAt: Double? = row["reclaiming_at"]
            guard reclaimingAt == nil,
                  owner == accountID.rawValue,
                  filename == attachment.filename,
                  mimeType == attachment.mimeType,
                  byteCount == attachment.byteCount else {
                throw OutgoingMailError.invalidContent("Draft attachment metadata does not match its registered file.")
            }
        }
    }

    private static func replaceAttachmentReferences(
        _ db: Database,
        accountID: AccountID,
        sourceKind: String,
        sourceID: UUID,
        sourceRevision: Int64,
        attachments: [DraftAttachment],
        at: Date
    ) throws {
        let rawSourceID = sourceID.uuidString.lowercased()
        let previousIDs = try String.fetchAll(
            db,
            sql: """
                SELECT attachment_id
                FROM attachment_references
                WHERE source_kind = ? AND source_id = ?
                """,
            arguments: [sourceKind, rawSourceID]
        )
        try db.execute(
            sql: "DELETE FROM attachment_references WHERE source_kind = ? AND source_id = ?",
            arguments: [sourceKind, rawSourceID]
        )
        for attachment in attachments {
            try db.execute(
                sql: """
                    INSERT INTO attachment_references
                    (attachment_id, account_id, source_kind, source_id, source_revision)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    attachment.id.uuidString.lowercased(), accountID.rawValue,
                    sourceKind, rawSourceID, sourceRevision
                ]
            )
            try db.execute(
                sql: """
                    UPDATE draft_attachments
                    SET unreferenced_at = NULL, reclaiming_at = NULL
                    WHERE id = ?
                    """,
                arguments: [attachment.id.uuidString.lowercased()]
            )
        }
        let newIDs = Set(attachments.map { $0.id.uuidString.lowercased() })
        for previousID in previousIDs where !newIDs.contains(previousID) {
            try db.execute(
                sql: """
                    UPDATE draft_attachments
                    SET unreferenced_at = ?, reclaiming_at = NULL
                    WHERE id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM attachment_references
                          WHERE attachment_id = ?
                      )
                    """,
                arguments: [
                    at.timeIntervalSince1970, previousID, previousID
                ]
            )
        }
    }

    private static func markAttachmentReferencesRemoved(
        _ db: Database,
        ids: [String],
        at: Date
    ) throws {
        for id in ids {
            try db.execute(
                sql: """
                    UPDATE draft_attachments
                    SET unreferenced_at = ?, reclaiming_at = NULL
                    WHERE id = ?
                      AND NOT EXISTS (
                          SELECT 1 FROM attachment_references
                          WHERE attachment_id = ?
                      )
                    """,
                arguments: [at.timeIntervalSince1970, id, id]
            )
        }
    }

    private static func stagingTotals(
        _ db: Database,
        accountID: String?
    ) throws -> (bytes: Int64, files: Int) {
        var stagingPredicate = """
            unreferenced_at IS NOT NULL
            AND reclaiming_at IS NULL
            """
        var reservationPredicate = "1 = 1"
        var arguments = StatementArguments()
        if let accountID {
            stagingPredicate += " AND account_id = ?"
            reservationPredicate = "account_id = ?"
            arguments += [accountID]
        }
        let stagingBytes = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(byte_count), 0) FROM draft_attachments WHERE \(stagingPredicate)",
            arguments: arguments
        ) ?? 0
        let stagingFiles = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM draft_attachments WHERE \(stagingPredicate)",
            arguments: arguments
        ) ?? 0
        var reservationArguments = StatementArguments()
        if let accountID {
            reservationArguments += [accountID]
        }
        let reservationBytes = try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(byte_count), 0) FROM attachment_import_reservations WHERE \(reservationPredicate)",
            arguments: reservationArguments
        ) ?? 0
        let reservationFiles = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM attachment_import_reservations WHERE \(reservationPredicate)",
            arguments: reservationArguments
        ) ?? 0
        return (stagingBytes + reservationBytes, stagingFiles + reservationFiles)
    }

    private static func enforceStagingAdmission(
        _ db: Database,
        accountID: AccountID,
        byteCount: Int64
    ) throws {
        let accountTotals = try stagingTotals(db, accountID: accountID.rawValue)
        guard accountTotals.bytes <= outgoingAccountStagingMaximumBytes - byteCount,
              accountTotals.files < outgoingAccountStagingMaximumFiles else {
            throw OutgoingMailError.invalidContent("The account attachment staging limit has been reached.")
        }
        let globalTotals = try stagingTotals(db, accountID: nil)
        guard globalTotals.bytes <= outgoingGlobalStagingMaximumBytes - byteCount,
              globalTotals.files < outgoingGlobalStagingMaximumFiles else {
            throw OutgoingMailError.invalidContent("The global attachment staging limit has been reached.")
        }
    }

    private static func processIdentifier() -> Int64 {
        Int64(ProcessInfo.processInfo.processIdentifier)
    }

    private static func processIsAlive(_ pid: Int64) -> Bool {
        if pid == processIdentifier() { return true }
        #if canImport(Darwin)
        let result = Darwin.kill(pid_t(pid), 0)
        #elseif canImport(Glibc)
        let result = Glibc.kill(pid_t(pid), 0)
        #else
        let result = -1
        #endif
        return result == 0 || errno == EPERM
    }



    private func collectOutgoingStorage(at now: Date) async throws {
        let cutoff = now.timeIntervalSince1970 - outgoingStagingLifetime
        // Recovery may be supplied a deterministic logical clock. Files and
        // import leases use wall time so a future recovery pass cannot mistake
        // a newly created concurrent import for an old crash orphan.
        let orphanCutoff = Date().timeIntervalSince1970 - outgoingStagingLifetime
        let activeImports = outgoingImportRegistry.snapshot()
        let attachmentIDs = try await durableWrite { db -> [String] in
            try db.execute(
                sql: """
                    UPDATE draft_attachments
                    SET reclaiming_at = ?
                    WHERE reclaiming_at IS NULL
                      AND unreferenced_at IS NOT NULL
                      AND unreferenced_at <= ?
                      AND NOT EXISTS (
                          SELECT 1 FROM attachment_references
                          WHERE attachment_id = draft_attachments.id
                      )
                    """,
                arguments: [now.timeIntervalSince1970, cutoff]
            )
            let attachmentIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM draft_attachments WHERE reclaiming_at IS NOT NULL"
            )
            let reservationRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, owner_pid
                    FROM attachment_import_reservations
                    WHERE started_at <= ?
                    """,
                arguments: [orphanCutoff]
            )
            for row in reservationRows {
                let id: String = row["id"]
                let ownerPID: Int64 = row["owner_pid"]
                guard !activeImports.contains(id), !Self.processIsAlive(ownerPID) else { continue }
                try db.execute(
                    sql: "DELETE FROM attachment_import_reservations WHERE id = ?",
                    arguments: [id]
                )
            }
            return attachmentIDs
        }

        var deletedAttachmentIDs = Set<String>()
        for rawID in attachmentIDs {
            guard let id = UUID(uuidString: rawID) else { continue }
            let url = Self.attachmentPath(id, root: outgoingDirectory)
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                deletedAttachmentIDs.insert(rawID)
            } catch {
                // Leave reclaiming rows in place for a later recovery pass.
            }
        }
        if !deletedAttachmentIDs.isEmpty {
            let finalizedIDs = deletedAttachmentIDs
            try await durableWrite { db in
                for id in finalizedIDs {
                    try db.execute(
                        sql: """
                            DELETE FROM draft_attachments
                            WHERE id = ?
                              AND reclaiming_at IS NOT NULL
                              AND NOT EXISTS (
                                  SELECT 1 FROM attachment_references
                                  WHERE attachment_id = ?
                              )
                            """,
                        arguments: [id, id]
                    )
                }
            }
        }

        // Draft autosaves collect indexed staging rows, not the entire spool.
        // An orphan directory sweep is needed only periodically or on reopen.
        guard outgoingImportRegistry.claimOrphanSweep() else { return }

        let protectedIDs = try await read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                    SELECT id FROM draft_attachments
                    UNION
                    SELECT id FROM attachment_import_reservations
                    """
            ))
        }
        let attachmentDirectory = outgoingDirectory.appendingPathComponent("attachments", isDirectory: true)
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: attachmentDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for file in files {
            let rawID = file.lastPathComponent.lowercased()
            guard UUID(uuidString: rawID) != nil,
                  !protectedIDs.contains(rawID),
                  !activeImports.contains(rawID),
                  let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified.timeIntervalSince1970 <= orphanCutoff else {
                continue
            }
            try? fileManager.removeItem(at: file)
        }
    }

    private static func isSendReady(_ content: DraftContent) -> Bool {
        !content.from.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!content.to.isEmpty || !content.cc.isEmpty || !content.bcc.isEmpty)
    }

    // MARK: - Row decoding

    private static func draft(from row: Row) throws -> MailDraft {
        let id = try uuid(from: row["id"])
        let accountID = AccountID(rawValue: row["account_id"])
        let content: DraftContent = try StoreJSON.decode(DraftContent.self, from: row["content_json"])
        return MailDraft(
            id: id,
            accountID: accountID,
            revision: row["revision"],
            content: content,
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            conflictOf: optionalUUID(row["conflict_of"])
        )
    }

    private static func draftSummary(from row: Row) throws -> DraftSummary {
        DraftSummary(
            id: try uuid(from: row["id"]),
            accountID: AccountID(rawValue: row["account_id"]),
            revision: row["revision"],
            subject: row["subject"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
            conflictOf: optionalUUID(row["conflict_of"]),
            attachmentCount: row["attachment_count"]
        )
    }

    private static func outbox(from row: Row) throws -> OutboxRecord {
        guard let state = OutboxState(rawValue: row["state"]) else {
            throw OutgoingMailError.invalidContent("Outbox record has an invalid state.")
        }
        let envelope: SMTPEnvelope?
        if let raw: String = row["envelope_json"] {
            envelope = try StoreJSON.decode(SMTPEnvelope.self, from: raw)
        } else {
            envelope = nil
        }
        let failure: SMTPSubmissionError?
        if let raw: String = row["failure_json"] {
            failure = try StoreJSON.decode(SMTPSubmissionError.self, from: raw)
        } else {
            failure = nil
        }
        let nextAttemptAt: Double? = row["next_attempt_at"]
        let acceptedAt: Double? = row["accepted_at"]
        return OutboxRecord(
            id: try uuid(from: row["id"]),
            accountID: AccountID(rawValue: row["account_id"]),
            draftID: try uuid(from: row["draft_id"]),
            draftRevision: row["draft_revision"],
            content: try StoreJSON.decode(DraftContent.self, from: row["content_json"]),
            messageID: row["message_id"],
            messageDate: Date(timeIntervalSince1970: row["message_date"]),
            state: state,
            attemptID: optionalUUID(row["attempt_id"]),
            attemptCount: row["attempt_count"],
            nextAttemptAt: nextAttemptAt.map { Date(timeIntervalSince1970: $0) },
            envelope: envelope,
            byteCount: row["byte_count"],
            acceptedAt: acceptedAt.map { Date(timeIntervalSince1970: $0) },
            failure: failure
        )
    }

    private static func outboxSummary(from row: Row) throws -> OutboxSummary {
        guard let state = OutboxState(rawValue: row["state"]) else {
            throw OutgoingMailError.invalidContent("Outbox record has an invalid state.")
        }
        let failure: SMTPSubmissionError?
        if let raw: String = row["failure_json"] {
            failure = try StoreJSON.decode(SMTPSubmissionError.self, from: raw)
        } else {
            failure = nil
        }
        let nextAttemptAt: Double? = row["next_attempt_at"]
        let acceptedAt: Double? = row["accepted_at"]
        return OutboxSummary(
            id: try uuid(from: row["id"]),
            accountID: AccountID(rawValue: row["account_id"]),
            draftID: try uuid(from: row["draft_id"]),
            draftRevision: row["draft_revision"],
            subject: row["subject"],
            state: state,
            attemptCount: row["attempt_count"],
            nextAttemptAt: nextAttemptAt.map { Date(timeIntervalSince1970: $0) },
            acceptedAt: acceptedAt.map { Date(timeIntervalSince1970: $0) },
            failure: failure
        )
    }
    private static func fetchDraftSummaries(
        _ db: Database,
        account: AccountID?,
        limit: Int
    ) throws -> [DraftSummary] {
        guard limit > 0 else { return [] }
        var sql = """
            SELECT id, account_id, revision, subject, updated_at, conflict_of, attachment_count
            FROM drafts
            """
        var predicates: [String] = []
        var arguments = StatementArguments()
        if let account {
            predicates.append("account_id = ?")
            arguments += [account.rawValue]
        }
        predicates.append(
            """
            NOT EXISTS (
                SELECT 1
                FROM outbox
                WHERE outbox.draft_id = drafts.id
                  AND outbox.draft_revision = drafts.revision
                  AND outbox.state IN (?, ?)
            )
            """
        )
        arguments += [OutboxState.sentCopyPending.rawValue, OutboxState.sent.rawValue]
        sql += " WHERE " + predicates.joined(separator: " AND ")
        sql += " ORDER BY updated_at DESC, id DESC LIMIT ?"
        arguments += [min(limit, 1_000)]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.draftSummary(from:))
    }

    private static func fetchOutboxSummaries(
        _ db: Database,
        account: AccountID?,
        limit: Int
    ) throws -> [OutboxSummary] {
        guard limit > 0 else { return [] }
        var sql = """
            SELECT id, account_id, draft_id, draft_revision, subject, state,
                   attempt_count, next_attempt_at, accepted_at, failure_json
            FROM outbox
            """
        var arguments = StatementArguments()
        if let account {
            sql += " WHERE account_id = ?"
            arguments += [account.rawValue]
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        arguments += [min(limit, 1_000)]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.outboxSummary(from:))
    }

    private static func requireOutbox(_ db: Database, id: UUID) throws -> Row {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM outbox WHERE id = ?",
            arguments: [id.uuidString.lowercased()]
        ) else {
            throw OutgoingMailError.submissionNotFound
        }
        return row
    }

    private static func requireAttempt(_ row: Row, _ attemptID: UUID) throws {
        guard let stored: String = row["attempt_id"],
              stored.caseInsensitiveCompare(attemptID.uuidString) == .orderedSame else {
            throw OutgoingMailError.invalidTransition
        }
    }

    // MARK: - Drafts

    /// Creates the first revision of a draft. Incomplete editor values are
    /// retained; send-time validation happens when the value is frozen.
    public func createDraft(
        id: UUID,
        accountID: AccountID,
        content: DraftContent,
        at: Date
    ) async throws -> MailDraft {
        let contentJSON = try StoreJSON.encode(content)
        let result = try await durableWrite { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM accounts WHERE id = ?",
                arguments: [accountID.rawValue]
            ) != nil else {
                throw MailStoreError.accountNotFound
            }
            try Self.validateAttachments(db, accountID: accountID, attachments: content.attachments)
            let rawID = id.uuidString.lowercased()
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM drafts WHERE id = ?", arguments: [rawID]) == nil else {
                throw OutgoingMailError.invalidContent("A draft with this identifier already exists.")
            }
            try db.execute(
                sql: """
                    INSERT INTO drafts (
                        id, account_id, revision, subject, attachment_count,
                        content_json, updated_at, conflict_of
                    ) VALUES (?, ?, 1, ?, ?, ?, ?, NULL)
                    """,
                arguments: [rawID, accountID.rawValue, content.subject, content.attachments.count, contentJSON, at.timeIntervalSince1970]
            )
            try Self.replaceAttachmentReferences(
                db, accountID: accountID, sourceKind: "draft", sourceID: id,
                sourceRevision: 1, attachments: content.attachments, at: at
            )
            return MailDraft(id: id, accountID: accountID, revision: 1, content: content, updatedAt: at)
        }
        try await collectOutgoingStorage(at: Date())
        return result
    }

    /// Saves an editor revision. A stale complete snapshot is retained as a
    /// conflict fork, while the current draft remains untouched.
    public func saveDraft(
        id: UUID,
        expectedRevision: Int64,
        content: DraftContent,
        at: Date
    ) async throws -> DraftSaveResult {
        let contentJSON = try StoreJSON.encode(content)
        let result = try await durableWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE id = ?", arguments: [id.uuidString.lowercased()]) else {
                throw OutgoingMailError.draftNotFound
            }
            let current = try Self.draft(from: row)
            try Self.validateAttachments(db, accountID: current.accountID, attachments: content.attachments)
            guard current.revision == expectedRevision else {
                let forkID = UUID()
                let forkRawID = forkID.uuidString.lowercased()
                let forkRevision: Int64 = 1
                try db.execute(
                    sql: """
                        INSERT INTO drafts (
                            id, account_id, revision, subject, attachment_count,
                            content_json, updated_at, conflict_of
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        forkRawID, current.accountID.rawValue, forkRevision, content.subject,
                        content.attachments.count, contentJSON, at.timeIntervalSince1970, id.uuidString.lowercased()
                    ]
                )
                try Self.replaceAttachmentReferences(
                    db, accountID: current.accountID, sourceKind: "draft", sourceID: forkID,
                    sourceRevision: forkRevision, attachments: content.attachments, at: at
                )
                let saved = MailDraft(
                    id: forkID,
                    accountID: current.accountID,
                    revision: forkRevision,
                    content: content,
                    updatedAt: at,
                    conflictOf: id
                )
                return DraftSaveResult(saved: saved, conflictWith: current)
            }

            let nextRevision = current.revision + 1
            try db.execute(
                sql: """
                    UPDATE drafts
                    SET revision = ?, subject = ?, attachment_count = ?,
                        content_json = ?, updated_at = ?
                    WHERE id = ? AND revision = ?
                    """,
                arguments: [
                    nextRevision, content.subject, content.attachments.count,
                    contentJSON, at.timeIntervalSince1970, id.uuidString.lowercased(), expectedRevision
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.revisionConflict }
            try Self.replaceAttachmentReferences(
                db, accountID: current.accountID, sourceKind: "draft", sourceID: id,
                sourceRevision: nextRevision, attachments: content.attachments, at: at
            )
            let saved = MailDraft(
                id: id,
                accountID: current.accountID,
                revision: nextRevision,
                content: content,
                updatedAt: at,
                conflictOf: current.conflictOf
            )
            return DraftSaveResult(saved: saved)
        }
        try await collectOutgoingStorage(at: Date())
        return result
    }

    /// Loads one full draft body and attachment metadata by durable identifier.
    public func draft(id: UUID) async throws -> MailDraft? {
        try await read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE id = ?", arguments: [id.uuidString.lowercased()]) else {
                return nil
            }
            return try Self.draft(from: row)
        }
    }

    /// Lists bounded lightweight draft projections without decoding body JSON.
    /// A draft revision with accepted delivery or a saved Sent copy is no
    /// longer an unsent draft, but its durable head remains available.
    public func drafts(account: AccountID?, limit: Int) async throws -> [DraftSummary] {
        try await read { db in
            try Self.fetchDraftSummaries(db, account: account, limit: limit)
        }
    }

    /// Lists bounded draft projections for an explicit account scope. The
    /// account predicate is part of SQL, before ordering and LIMIT.
    public func drafts(accounts: Set<AccountID>?, limit: Int) async throws -> [DraftSummary] {
        try await read { db in
            try Self.fetchDraftSummaries(db, accounts: accounts, limit: limit)
        }
    }

    private static func fetchDraftSummaries(
        _ db: Database,
        accounts: Set<AccountID>?,
        limit: Int
    ) throws -> [DraftSummary] {
        guard limit > 0 else { return [] }
        var sql = """
            SELECT id, account_id, revision, subject, updated_at, conflict_of, attachment_count
            FROM drafts
            """
        var predicates: [String] = []
        var arguments = StatementArguments()
        if let accounts {
            guard !accounts.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: accounts.count).joined(separator: ", ")
            predicates.append("account_id IN (\(placeholders))")
            for account in accounts.sorted(by: { $0.rawValue < $1.rawValue }) {
                arguments += [account.rawValue]
            }
        }
        predicates.append(
            """
            NOT EXISTS (
                SELECT 1
                FROM outbox
                WHERE outbox.draft_id = drafts.id
                  AND outbox.draft_revision = drafts.revision
                  AND outbox.state IN (?, ?)
            )
            """
        )
        arguments += [OutboxState.sentCopyPending.rawValue, OutboxState.sent.rawValue]
        sql += " WHERE " + predicates.joined(separator: " AND ")
        sql += " ORDER BY updated_at DESC, id DESC LIMIT ?"
        arguments += [min(limit, 1_000)]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.draftSummary(from:))
    }

    /// Observes bounded draft and outbox projections for an explicit account
    /// scope. Filtering remains in each SQL projection before LIMIT.
    public func observeOutgoing(
        accounts: Set<AccountID>?,
        limit: Int
    ) -> AsyncStream<OutgoingState> {
        observe { db in
            OutgoingState(
                drafts: try Self.fetchDraftSummaries(db, accounts: accounts, limit: limit),
                outbox: try Self.fetchOutboxSummaries(db, accounts: accounts, limit: limit)
            )
        }
    }

    /// Observes bounded, body-free draft and outbox projections after commit.
    /// The first state is delivered immediately; later states use the store's
    /// standard coalesced ValueObservation scheduling.
    public func observeOutgoing(account: AccountID?, limit: Int) -> AsyncStream<OutgoingState> {
        observe { db in
            OutgoingState(
                drafts: try Self.fetchDraftSummaries(db, account: account, limit: limit),
                outbox: try Self.fetchOutboxSummaries(db, account: account, limit: limit)
            )
        }
    }

    /// Reports whether account removal would hide any unresolved outgoing
    /// work. Accepted submissions remain unresolved until their Sent copy is
    /// saved; cancellation and completed delivery are not counted.
    public func hasUnsentOutgoing(account: AccountID) async throws -> Bool {
        try await read { db in
            let result: Int? = try Int.fetchOne(
                db,
                sql: """
                    SELECT EXISTS (
                        SELECT 1
                        FROM drafts
                        WHERE account_id = ?
                          AND NOT EXISTS (
                              SELECT 1
                              FROM outbox
                              WHERE outbox.draft_id = drafts.id
                                AND outbox.draft_revision = drafts.revision
                                AND outbox.state IN (?, ?)
                          )
                    )
                    OR EXISTS (
                        SELECT 1
                        FROM outbox
                        WHERE account_id = ?
                          AND state NOT IN (?, ?)
                    )
                    """,
                arguments: [
                    account.rawValue,
                    OutboxState.sentCopyPending.rawValue,
                    OutboxState.sent.rawValue,
                    account.rawValue,
                    OutboxState.sent.rawValue,
                    OutboxState.cancelled.rawValue
                ]
            )
            return (result ?? 0) != 0
        }
    }

    /// Deletes only the selected draft revision; frozen outbox rows remain.
    public func deleteDraft(id: UUID, expectedRevision: Int64) async throws {
        try await durableWrite { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT revision FROM drafts WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ) else {
                throw OutgoingMailError.draftNotFound
            }
            let revision: Int64 = row["revision"]
            guard revision == expectedRevision else { throw OutgoingMailError.revisionConflict }
            let attachmentIDs = try String.fetchAll(
                db,
                sql: """
                    SELECT attachment_id
                    FROM attachment_references
                    WHERE source_kind = 'draft' AND source_id = ?
                    """,
                arguments: [id.uuidString.lowercased()]
            )
            try db.execute(
                sql: "DELETE FROM drafts WHERE id = ? AND revision = ?",
                arguments: [id.uuidString.lowercased(), expectedRevision]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.revisionConflict }
            try Self.markAttachmentReferencesRemoved(db, ids: attachmentIDs, at: Date())
        }
        try await collectOutgoingStorage(at: Date())
    }

    // MARK: - Attachments and submission files

    /// Imports one immutable attachment into the private spool. The caller
    /// supplies a stable idempotency UUID; a same-account retry returns the
    /// original metadata without touching the source or destination.
    public func importDraftAttachment(
        id: UUID,
        accountID: AccountID,
        sourceURL: URL,
        filename: String,
        mimeType: String
    ) async throws -> DraftAttachment {
        let rawID = id.uuidString.lowercased()
        if let existing: DraftAttachment = try await read({ db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_id, filename, mime_type, byte_count, reclaiming_at
                    FROM draft_attachments
                    WHERE id = ?
                    """,
                arguments: [rawID]
            ) else {
                return nil
            }
            let owner: String = row["account_id"]
            guard owner == accountID.rawValue else {
                throw OutgoingMailError.invalidContent("An attachment identifier belongs to another account.")
            }
            let reclaimingAt: Double? = row["reclaiming_at"]
            guard reclaimingAt == nil else {
                throw OutgoingMailError.invalidContent("Attachment cleanup is in progress.")
            }
            return DraftAttachment(
                id: id,
                filename: row["filename"],
                mimeType: row["mime_type"],
                byteCount: row["byte_count"]
            )
        }) {
            return existing
        }

        try Self.validateAttachmentInput(filename: filename, mimeType: mimeType)
        guard sourceURL.isFileURL else {
            throw OutgoingMailError.invalidContent("Attachment source must be a local file URL.")
        }
        let sourceDescriptor = try Self.openNoFollow(
            sourceURL,
            flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        let sourceSize: Int64
        do {
            sourceSize = try Self.regularFileSize(sourceDescriptor, path: sourceURL)
            _ = outgoingClose(sourceDescriptor)
        } catch {
            _ = outgoingClose(sourceDescriptor)
            throw error
        }
        guard sourceSize <= outgoingAttachmentMaximumBytes else {
            throw OutgoingMailError.invalidContent("Attachment exceeds the 256 MiB size limit.")
        }

        let admissionDate = Date()
        outgoingImportRegistry.begin(rawID)
        defer { outgoingImportRegistry.end(rawID) }
        try await collectOutgoingStorage(at: admissionDate)

        let admissionResult: (existing: DraftAttachment?, reserved: Bool) = try await durableWrite { db in
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT account_id, filename, mime_type, byte_count, reclaiming_at
                    FROM draft_attachments
                    WHERE id = ?
                    """,
                arguments: [rawID]
            ) {
                let owner: String = row["account_id"]
                guard owner == accountID.rawValue else {
                    throw OutgoingMailError.invalidContent("An attachment identifier belongs to another account.")
                }
                let reclaimingAt: Double? = row["reclaiming_at"]
                guard reclaimingAt == nil else {
                    throw OutgoingMailError.invalidContent("Attachment cleanup is in progress.")
                }
                return (
                    DraftAttachment(
                        id: id,
                        filename: row["filename"],
                        mimeType: row["mime_type"],
                        byteCount: row["byte_count"]
                    ),
                    false
                )
            }
            if let reservation = try Row.fetchOne(
                db,
                sql: "SELECT account_id FROM attachment_import_reservations WHERE id = ?",
                arguments: [rawID]
            ) {
                let owner: String = reservation["account_id"]
                if owner == accountID.rawValue {
                    throw OutgoingMailError.invalidContent("An attachment import with this identifier is already in progress.")
                }
                throw OutgoingMailError.invalidContent("An attachment identifier belongs to another account.")
            }
            guard try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM accounts WHERE id = ?",
                arguments: [accountID.rawValue]
            ) != nil else {
                throw MailStoreError.accountNotFound
            }
            try Self.enforceStagingAdmission(db, accountID: accountID, byteCount: sourceSize)
            try db.execute(
                sql: """
                    INSERT INTO attachment_import_reservations
                    (id, account_id, byte_count, started_at, owner_pid)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    rawID, accountID.rawValue, sourceSize,
                    admissionDate.timeIntervalSince1970, Self.processIdentifier()
                ]
            )
            return (nil, true)
        }
        if let existingAfterAdmission = admissionResult.existing {
            return existingAfterAdmission
        }
        guard admissionResult.reserved else {
            throw OutgoingMailError.invalidContent("Attachment import admission failed.")
        }

        let destination = Self.attachmentPath(id, root: outgoingDirectory)
        var destinationCreated = false
        do {
            let byteCount = try Self.copyImportedFile(from: sourceURL, to: destination)
            destinationCreated = true
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            let registeredAt = Date()
            do {
                return try await durableWrite { db in
                    guard try Int.fetchOne(
                        db,
                        sql: """
                            SELECT 1
                            FROM attachment_import_reservations
                            WHERE id = ? AND account_id = ?
                            """,
                        arguments: [rawID, accountID.rawValue]
                    ) != nil else {
                        throw OutgoingMailError.invalidContent("Attachment import reservation is no longer active.")
                    }
                    guard byteCount <= outgoingAttachmentMaximumBytes else {
                        throw OutgoingMailError.invalidContent("Attachment exceeds the 256 MiB size limit.")
                    }
                    let totals = try Self.stagingTotals(db, accountID: accountID.rawValue)
                    let globalTotals = try Self.stagingTotals(db, accountID: nil)
                    guard totals.bytes <= outgoingAccountStagingMaximumBytes,
                          totals.files <= outgoingAccountStagingMaximumFiles,
                          globalTotals.bytes <= outgoingGlobalStagingMaximumBytes,
                          globalTotals.files <= outgoingGlobalStagingMaximumFiles else {
                        throw OutgoingMailError.invalidContent("The attachment staging limit has been reached.")
                    }
                    try db.execute(
                        sql: """
                            INSERT INTO draft_attachments
                            (id, account_id, filename, mime_type, byte_count,
                             created_at, unreferenced_at, reclaiming_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                            """,
                        arguments: [
                            rawID, accountID.rawValue, filename, mimeType, byteCount,
                            registeredAt.timeIntervalSince1970, registeredAt.timeIntervalSince1970
                        ]
                    )
                    try db.execute(
                        sql: "DELETE FROM attachment_import_reservations WHERE id = ?",
                        arguments: [rawID]
                    )
                    return DraftAttachment(
                        id: id, filename: filename, mimeType: mimeType, byteCount: byteCount
                    )
                }
            } catch {
                try? await durableWrite { db in
                    try db.execute(
                        sql: "DELETE FROM attachment_import_reservations WHERE id = ?",
                        arguments: [rawID]
                    )
                }
                throw error
            }
        } catch {
            try? await durableWrite { db in
                try db.execute(
                    sql: "DELETE FROM attachment_import_reservations WHERE id = ?",
                    arguments: [rawID]
                )
            }
            if destinationCreated {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
    }

    /// Resolves a registered attachment UUID only within its owning account.
    public func draftAttachmentURL(id: UUID, accountID: AccountID) async throws -> URL {
        let url = Self.attachmentPath(id, root: outgoingDirectory)
        let expectedByteCount: Int64 = try await read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT account_id, byte_count, reclaiming_at FROM draft_attachments WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ) else {
                throw OutgoingMailError.attachmentNotFound
            }
            let owner: String = row["account_id"]
            let reclaimingAt: Double? = row["reclaiming_at"]
            guard owner == accountID.rawValue, reclaimingAt == nil else {
                throw OutgoingMailError.attachmentNotFound
            }
            return row["byte_count"]
        }
        let descriptor: Int32
        do {
            descriptor = try Self.openNoFollow(url, flags: O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        } catch {
            throw OutgoingMailError.attachmentNotFound
        }
        defer { _ = outgoingClose(descriptor) }
        do {
            guard try Self.regularFileSize(descriptor, path: url) == expectedByteCount else {
                throw OutgoingMailError.attachmentNotFound
            }
        } catch is OutgoingMailError {
            throw OutgoingMailError.attachmentNotFound
        } catch {
            throw OutgoingMailError.attachmentNotFound
        }
        return url
    }

    /// Returns the deterministic private MIME-file location for a submission.
    public func submissionFileURL(id: UUID) -> URL {
        Self.submissionPath(id, root: outgoingDirectory)
    }

    // MARK: - Outbox

    /// Freezes a draft revision into one idempotent queued submission.
    public func enqueueSubmission(
        id: UUID,
        draftID: UUID,
        expectedRevision: Int64,
        at: Date
    ) async throws -> OutboxRecord {
        let result = try await durableWrite { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM drafts WHERE id = ?", arguments: [draftID.uuidString.lowercased()]) else {
                throw OutgoingMailError.draftNotFound
            }
            let draft = try Self.draft(from: row)
            guard draft.revision == expectedRevision else { throw OutgoingMailError.revisionConflict }
            try Self.validateAttachments(db, accountID: draft.accountID, attachments: draft.content.attachments)
            guard Self.isSendReady(draft.content) else {
                throw OutgoingMailError.invalidContent("Complete the sender and at least one recipient before sending.")
            }

            let submissionID = id.uuidString.lowercased()

            if let existingRow = try Row.fetchOne(db, sql: "SELECT * FROM outbox WHERE id = ?", arguments: [submissionID]) {
                let existing = try Self.outbox(from: existingRow)
                guard existing.draftID == draftID, existing.draftRevision == expectedRevision else {
                    throw OutgoingMailError.invalidContent("A submission identifier cannot target another draft revision.")
                }
                return existing
            }
            if let existingRevisionRow = try Row.fetchOne(
                db,
                sql: "SELECT * FROM outbox WHERE draft_id = ? AND draft_revision = ?",
                arguments: [draftID.uuidString.lowercased(), expectedRevision]
            ) {
                return try Self.outbox(from: existingRevisionRow)
            }

            let messageID = "<\(submissionID)@mailternal.local>"
            let contentJSON = try StoreJSON.encode(draft.content)
            try db.execute(
                sql: """
                    INSERT INTO outbox (
                        id, account_id, draft_id, draft_revision, subject, content_json,
                        message_id, message_date, state, attempt_id, attempt_count,
                        next_attempt_at, envelope_json, byte_count, accepted_at,
                        failure_json, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 0, NULL, NULL, NULL, NULL, NULL, ?)
                    """,
                arguments: [
                    submissionID, draft.accountID.rawValue, draftID.uuidString.lowercased(), expectedRevision,
                    draft.content.subject, contentJSON, messageID, at.timeIntervalSince1970,
                    OutboxState.queued.rawValue, at.timeIntervalSince1970
                ]
            )
            try Self.replaceAttachmentReferences(
                db, accountID: draft.accountID, sourceKind: "outbox", sourceID: id,
                sourceRevision: expectedRevision, attachments: draft.content.attachments, at: at
            )
            return OutboxRecord(
                id: id,
                accountID: draft.accountID,
                draftID: draftID,
                draftRevision: expectedRevision,
                content: draft.content,
                messageID: messageID,
                messageDate: at
            )
        }
        try await collectOutgoingStorage(at: Date())
        return result
    }
    /// Lists bounded outbox projections for an explicit account scope. The
    /// account predicate is applied in SQL before ordering and LIMIT.
    public func outbox(accounts: Set<AccountID>?, limit: Int) async throws -> [OutboxSummary] {
        try await read { db in
            try Self.fetchOutboxSummaries(db, accounts: accounts, limit: limit)
        }
    }

    private static func fetchOutboxSummaries(
        _ db: Database,
        accounts: Set<AccountID>?,
        limit: Int
    ) throws -> [OutboxSummary] {
        guard limit > 0 else { return [] }
        var sql = """
            SELECT id, account_id, draft_id, draft_revision, subject, state,
                   attempt_count, next_attempt_at, accepted_at, failure_json
            FROM outbox
            """
        var arguments = StatementArguments()
        if let accounts {
            guard !accounts.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: accounts.count).joined(separator: ", ")
            sql += " WHERE account_id IN (\(placeholders))"
            for account in accounts.sorted(by: { $0.rawValue < $1.rawValue }) {
                arguments += [account.rawValue]
            }
        }
        sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
        arguments += [min(limit, 1_000)]
        return try Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.outboxSummary(from:))
    }

    /// Loads one full frozen submission by durable identifier.
    public func outbox(id: UUID) async throws -> OutboxRecord? {
        try await read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM outbox WHERE id = ?", arguments: [id.uuidString.lowercased()]) else {
                return nil
            }
            return try Self.outbox(from: row)
        }
    }

    /// Lists bounded lightweight outbox projections without decoding bodies.
    public func outbox(account: AccountID?, limit: Int) async throws -> [OutboxSummary] {
        try await read { db in
            try Self.fetchOutboxSummaries(db, account: account, limit: limit)
        }
    }

    /// Returns the earliest durable due time for queued work or a pending
    /// Sent-copy operation. A nil due date is represented by the Unix epoch,
    /// which means the caller should run immediately.
    public func nextOutgoingAttempt(account: AccountID) async throws -> Date? {
        try await read { db in
            guard let enabled: Int = try Int.fetchOne(
                db,
                sql: "SELECT is_enabled FROM accounts WHERE id = ?",
                arguments: [account.rawValue]
            ), enabled != 0 else {
                return nil
            }
            let due: Double? = try Double.fetchOne(
                db,
                sql: """
                    SELECT MIN(COALESCE(next_attempt_at, 0))
                    FROM outbox
                    WHERE account_id = ?
                      AND state IN (?, ?)
                    """,
                arguments: [
                    account.rawValue,
                    OutboxState.queued.rawValue,
                    OutboxState.sentCopyPending.rawValue
                ]
            )
            return due.map { Date(timeIntervalSince1970: $0) }
        }
    }

    /// Claims the next eligible queued submission with a fresh attempt token.
    public func claimNextSubmission(account: AccountID, at: Date) async throws -> OutboxRecord? {
        try await durableWrite { db in
            guard let enabled: Int = try Int.fetchOne(
                db,
                sql: "SELECT is_enabled FROM accounts WHERE id = ?",
                arguments: [account.rawValue]
            ), enabled != 0 else { return nil }
            guard let candidate = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM outbox
                    WHERE account_id = ? AND state = ?
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                    ORDER BY created_at ASC, id ASC
                    LIMIT 1
                    """,
                arguments: [account.rawValue, OutboxState.queued.rawValue, at.timeIntervalSince1970]
            ) else { return nil }
            let id: UUID = try Self.uuid(from: candidate["id"])
            let attemptID = UUID()
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attempt_id = ?, attempt_count = attempt_count + 1,
                        next_attempt_at = NULL, failure_json = NULL
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    OutboxState.preparing.rawValue, attemptID.uuidString.lowercased(),
                    id.uuidString.lowercased(), OutboxState.queued.rawValue
                ]
            )
            guard db.changesCount == 1 else { return nil }
            return try Self.outbox(from: Self.requireOutbox(db, id: id))
        }
    }

    /// Records a synced MIME file and advances the current attempt to sending.
    public func markSubmissionPrepared(
        id: UUID,
        attemptID: UUID,
        envelope: SMTPEnvelope,
        byteCount: Int64
    ) async throws {
        guard byteCount >= 0 else { throw OutgoingMailError.invalidContent("Submission size cannot be negative.") }
        let envelopeJSON = try StoreJSON.encode(envelope)
        try Self.synchronizeSubmissionFile(id: id, root: outgoingDirectory, expectedByteCount: byteCount)
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            try Self.requireAttempt(row, attemptID)
            guard (row["state"] as String) == OutboxState.preparing.rawValue else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: "UPDATE outbox SET state = ?, envelope_json = ?, byte_count = ?, failure_json = NULL WHERE id = ? AND attempt_id = ? AND state = ?",
                arguments: [
                    OutboxState.sending.rawValue, envelopeJSON, byteCount,
                    id.uuidString.lowercased(), attemptID.uuidString.lowercased(), OutboxState.preparing.rawValue
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
        }
    }

    /// Marks the instant before the final DATA terminator is committed.
    /// The owning account must still exist and be enabled at the marker.
    public func markSubmissionCommitStarted(id: UUID, attemptID: UUID) async throws {
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            try Self.requireAttempt(row, attemptID)
            guard (row["state"] as String) == OutboxState.sending.rawValue else {
                throw OutgoingMailError.invalidTransition
            }
            let accountID: String = row["account_id"]
            guard let enabled: Int = try Int.fetchOne(
                db,
                sql: "SELECT is_enabled FROM accounts WHERE id = ?",
                arguments: [accountID]
            ), enabled != 0 else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?
                    WHERE id = ? AND attempt_id = ? AND state = ?
                      AND EXISTS (
                          SELECT 1
                          FROM accounts
                          WHERE accounts.id = outbox.account_id
                            AND accounts.is_enabled != 0
                      )
                    """,
                arguments: [
                    OutboxState.awaitingAcceptance.rawValue, id.uuidString.lowercased(),
                    attemptID.uuidString.lowercased(), OutboxState.sending.rawValue
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
        }
    }

    /// Records positive DATA acceptance and schedules Sent-copy persistence.
    public func markSubmissionAccepted(id: UUID, attemptID: UUID, receipt: SMTPSubmissionReceipt) async throws {
        guard (200..<300).contains(receipt.replyCode) else {
            throw OutgoingMailError.invalidContent("SMTP acceptance requires a successful 2xx reply.")
        }
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            try Self.requireAttempt(row, attemptID)
            guard (row["state"] as String) == OutboxState.awaitingAcceptance.rawValue else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: "UPDATE outbox SET state = ?, accepted_at = ?, next_attempt_at = NULL, failure_json = NULL WHERE id = ? AND attempt_id = ? AND state = ?",
                arguments: [
                    OutboxState.sentCopyPending.rawValue, receipt.acceptedAt.timeIntervalSince1970,
                    id.uuidString.lowercased(), attemptID.uuidString.lowercased(), OutboxState.awaitingAcceptance.rawValue
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
        }
    }

    /// Records a submission result, distinguishing confirmed failure from uncertainty.
    public func recordSubmissionFailure(
        id: UUID,
        attemptID: UUID,
        failure: SMTPSubmissionError,
        retryAt: Date?
    ) async throws {
        let failureJSON = try StoreJSON.encode(failure)
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            try Self.requireAttempt(row, attemptID)
            guard let currentState = OutboxState(rawValue: row["state"] as String),
                  [.preparing, .sending, .awaitingAcceptance].contains(currentState) else {
                throw OutgoingMailError.invalidTransition
            }

            let nextState: OutboxState
            if currentState == .awaitingAcceptance {
                let confirmedReply = failure.replyCode.map { (400...599).contains($0) } == true
                if failure.kind == .deliveryUnknown {
                    nextState = .deliveryUnknown
                } else if confirmedReply, failure.isRetryable, retryAt != nil {
                    nextState = .queued
                } else if confirmedReply {
                    nextState = .failed
                } else {
                    nextState = .deliveryUnknown
                }
            } else if failure.kind == .deliveryUnknown {
                nextState = .deliveryUnknown
            } else if failure.isRetryable, retryAt != nil {
                nextState = .queued
            } else {
                nextState = .failed
            }
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attempt_id = NULL, next_attempt_at = ?, failure_json = ?
                    WHERE id = ? AND attempt_id = ?
                    """,
                arguments: [
                    nextState.rawValue,
                    nextState == .queued ? retryAt?.timeIntervalSince1970 : nil,
                    failureJSON, id.uuidString.lowercased(), attemptID.uuidString.lowercased()
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
        }
    }

    /// Returns the next Sent-copy-only operation eligible at `at`.
    public func nextSentCopy(account: AccountID, at: Date) async throws -> OutboxRecord? {
        try await read { db in
            guard let enabled: Int = try Int.fetchOne(
                db,
                sql: "SELECT is_enabled FROM accounts WHERE id = ?",
                arguments: [account.rawValue]
            ), enabled != 0 else {
                return nil
            }
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM outbox
                    WHERE account_id = ? AND state = ?
                      AND (next_attempt_at IS NULL OR next_attempt_at <= ?)
                    ORDER BY created_at ASC, id ASC
                    LIMIT 1
                    """,
                arguments: [account.rawValue, OutboxState.sentCopyPending.rawValue, at.timeIntervalSince1970]
            ) else {
                return nil
            }
            return try Self.outbox(from: row)
        }
    }

    /// Records a Sent-copy failure without changing SMTP delivery state.
    public func recordSentCopyFailure(
        id: UUID,
        attemptID: UUID,
        failure: SMTPSubmissionError,
        retryAt: Date?
    ) async throws {
        let failureJSON = try StoreJSON.encode(failure)
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            try Self.requireAttempt(row, attemptID)
            guard (row["state"] as String) == OutboxState.sentCopyPending.rawValue else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: "UPDATE outbox SET failure_json = ?, next_attempt_at = ? WHERE id = ? AND attempt_id = ? AND state = ?",
                arguments: [
                    failureJSON, retryAt?.timeIntervalSince1970, id.uuidString.lowercased(),
                    attemptID.uuidString.lowercased(), OutboxState.sentCopyPending.rawValue
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
        }
    }

    /// Completes only the IMAP Sent-copy phase.
    public func markSentCopySaved(id: UUID, attemptID: UUID) async throws {
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            try Self.requireAttempt(row, attemptID)
            guard (row["state"] as String) == OutboxState.sentCopyPending.rawValue else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: "UPDATE outbox SET state = ?, attempt_id = NULL, next_attempt_at = NULL, failure_json = NULL WHERE id = ? AND attempt_id = ? AND state = ?",
                arguments: [
                    OutboxState.sent.rawValue, id.uuidString.lowercased(), attemptID.uuidString.lowercased(),
                    OutboxState.sentCopyPending.rawValue
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
        }
    }

    /// Explicitly requeues a failed or acknowledged-unknown submission, or
    /// schedules only the Sent-copy phase when it is pending.
    public func retrySubmission(id: UUID, acknowledgeDuplicateRisk: Bool, at: Date) async throws -> OutboxRecord {
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            guard let state = OutboxState(rawValue: row["state"] as String) else {
                throw OutgoingMailError.invalidTransition
            }
            if state == .sentCopyPending {
                try db.execute(
                    sql: """
                        UPDATE outbox
                        SET next_attempt_at = ?, failure_json = NULL
                        WHERE id = ? AND state = ? AND attempt_id IS NOT NULL
                        """,
                    arguments: [
                        at.timeIntervalSince1970, id.uuidString.lowercased(),
                        OutboxState.sentCopyPending.rawValue
                    ]
                )
                guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
                return try Self.outbox(from: Self.requireOutbox(db, id: id))
            }
            if state == .deliveryUnknown && !acknowledgeDuplicateRisk {
                throw OutgoingMailError.duplicateRiskRequiresAcknowledgement
            }
            guard state == .failed || state == .deliveryUnknown else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attempt_id = NULL, next_attempt_at = ?,
                        envelope_json = NULL, byte_count = NULL, accepted_at = NULL,
                        failure_json = NULL
                    WHERE id = ? AND state = ?
                    """,
                arguments: [
                    OutboxState.queued.rawValue, at.timeIntervalSince1970,
                    id.uuidString.lowercased(), state.rawValue
                ]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
            return try Self.outbox(from: Self.requireOutbox(db, id: id))
        }
    }

    /// Cancels a submission only while SMTP commit has not begun.
    public func cancelSubmission(id: UUID) async throws -> OutboxRecord {
        try await durableWrite { db in
            let row = try Self.requireOutbox(db, id: id)
            guard let state = OutboxState(rawValue: row["state"] as String),
                  [.queued, .preparing, .sending, .failed].contains(state) else {
                throw OutgoingMailError.invalidTransition
            }
            try db.execute(
                sql: "UPDATE outbox SET state = ?, attempt_id = NULL, next_attempt_at = NULL WHERE id = ? AND state = ?",
                arguments: [OutboxState.cancelled.rawValue, id.uuidString.lowercased(), state.rawValue]
            )
            guard db.changesCount == 1 else { throw OutgoingMailError.invalidTransition }
            return try Self.outbox(from: Self.requireOutbox(db, id: id))
        }
    }

    /// Repairs states left by a process crash. A transaction that reached the
    /// DATA commit point is deliberately never returned to the send queue.
    public func recoverOutgoing(at: Date) async throws {
        let unknown = SMTPSubmissionError(
            kind: .deliveryUnknown,
            message: "The previous SMTP delivery outcome is unknown."
        )
        let unknownJSON = try StoreJSON.encode(unknown)
        try await durableWrite { db in
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attempt_id = NULL, next_attempt_at = NULL,
                        envelope_json = NULL, byte_count = NULL, failure_json = NULL
                    WHERE state IN (?, ?)
                    """,
                arguments: [
                    OutboxState.queued.rawValue,
                    OutboxState.preparing.rawValue,
                    OutboxState.sending.rawValue
                ]
            )
            try db.execute(
                sql: """
                    UPDATE outbox
                    SET state = ?, attempt_id = NULL, next_attempt_at = NULL,
                        failure_json = ?
                    WHERE state = ?
                    """,
                arguments: [
                    OutboxState.deliveryUnknown.rawValue, unknownJSON,
                    OutboxState.awaitingAcceptance.rawValue
                ]
            )
        }
        try await collectOutgoingStorage(at: at)
    }
}
