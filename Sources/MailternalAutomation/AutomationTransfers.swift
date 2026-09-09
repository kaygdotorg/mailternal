import Foundation
import MailternalInterfaces
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runtime-owned transfer handles. File I/O runs outside the UI actor; attachments
/// retain their immutable cache inode rather than copying the entire file. Encoded
/// command results use exclusive 0600 spools. Every read rechecks the authenticated
/// owner and current account grant. Idle handles release their resources even when
/// the client disappears without sending another request.
public actor AutomationTransferRegistry {
    private final class Source: @unchecked Sendable {
        let handle: FileHandle
        let temporaryURL: URL?

        init(descriptor: Int32, temporaryURL: URL? = nil) {
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            self.temporaryURL = temporaryURL
        }

        deinit {
            try? handle.close()
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        }
    }

    private struct Entry {
        let descriptor: AutomationTransferDescriptor
        let ownerOrigin: CommandOrigin
        let ownerClientID: UUID?
        let accountLinkIDs: Set<AccountLinkID>
        let source: Source
        let isUpload: Bool
        var nextOffset: UInt64 = 0
        var nextSequence: UInt64 = 0
        var finalized = false
        var expiresAt: ContinuousClock.Instant
    }

    private let idleTimeout: Duration
    private let temporaryDirectory: URL
    private var entries: [UUID: Entry] = [:]
    private var expirationTask: Task<Void, Never>?
    private var closed = false

    public init() {
        idleTimeout = .seconds(60)
        temporaryDirectory = FileManager.default.temporaryDirectory
    }

    init(idleTimeout: Duration, temporaryDirectory: URL) {
        self.idleTimeout = idleTimeout
        self.temporaryDirectory = temporaryDirectory
    }

    deinit { expirationTask?.cancel() }

    public func create(
        data: Data,
        kind: AutomationTransferKind,
        context: AutomationClientContext,
        filename: String? = nil,
        contentType: String? = nil
    ) throws -> AutomationTransferDescriptor {
        try admit(size: UInt64(data.count), context: context)
        let transferID = UUID()
        let url = temporaryDirectory.appendingPathComponent("mailternal-transfer-\(transferID.uuidString)")
        let fd = url.path.withCString { open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else {
            throw AutomationCommandError.unsupported("transfer could not be prepared")
        }
        let source = Source(descriptor: fd, temporaryURL: url)
        do {
            try source.handle.write(contentsOf: data)
            try source.handle.seek(toOffset: 0)
        } catch {
            throw AutomationCommandError.unsupported("transfer could not be prepared")
        }
        return register(
            source: source,
            descriptor: AutomationTransferDescriptor(
                transferID: transferID, kind: kind, size: UInt64(data.count),
                filename: filename, contentType: contentType
            ),
            context: context,
            isUpload: false
        )
    }

    /// The caller supplies an immutable file, such as a completed cache entry.
    /// An open descriptor survives cache eviction without retaining or duplicating
    /// the attachment bytes in memory. Symlinks and non-regular files are rejected.
    public func create(
        fileURL: URL,
        kind: AutomationTransferKind,
        context: AutomationClientContext,
        filename: String? = nil,
        contentType: String? = nil
    ) throws -> AutomationTransferDescriptor {
        try admit(size: 0, context: context)
        let fd = fileURL.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard fd >= 0 else {
            throw AutomationCommandError.unsupported("transfer source is unavailable")
        }
        let source = Source(descriptor: fd)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw AutomationCommandError.unsupported("transfer source is unavailable")
        }
        guard UInt64(info.st_size) <= AutomationTransferPolicy.maximumBytes else {
            throw AutomationCommandError.unsupported("transfer exceeds the permitted size")
        }
        return register(
            source: source,
            descriptor: AutomationTransferDescriptor(
                kind: kind, size: UInt64(info.st_size),
                filename: filename ?? fileURL.lastPathComponent, contentType: contentType
            ),
            context: context
        )
    }

    /// Starts a bounded client-to-runtime upload. The file is created with
    /// exclusive 0600 permissions and is usable only after every sequential
    /// write reaches the declared final offset.
    public func createUpload(
        size: UInt64,
        filename: String,
        contentType: String,
        context: AutomationClientContext
    ) throws -> AutomationTransferDescriptor {
        guard !filename.isEmpty, !contentType.isEmpty else {
            throw AutomationCommandError.invalidPayload("transfer metadata")
        }
        try admit(size: size, context: context, requiringMutation: true)
        let transferID = UUID()
        let url = temporaryDirectory.appendingPathComponent("mailternal-upload-\(transferID.uuidString)")
        let fd = url.path.withCString {
            open($0, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else {
            throw AutomationCommandError.unsupported("transfer could not be prepared")
        }
        let source = Source(descriptor: fd, temporaryURL: url)
        return register(
            source: source,
            descriptor: AutomationTransferDescriptor(
                transferID: transferID,
                kind: .attachment,
                size: size,
                filename: filename,
                contentType: contentType
            ),
            context: context,
            isUpload: true
        )
    }

    public func write(
        transferID: UUID,
        sequence: UInt64,
        offset: UInt64,
        totalBytes: UInt64,
        data: Data,
        final: Bool,
        context: AutomationClientContext
    ) throws {
        purgeExpired()
        guard var entry = entries[transferID], entry.isUpload, !entry.finalized else {
            throw AutomationCommandError.unsupported("upload is unavailable")
        }
        try authorizeOwner(entry, context: context)
        guard context.grant.canMutate,
              entry.accountLinkIDs.isSubset(of: context.grant.accountLinkIDs),
              totalBytes == entry.descriptor.size,
              sequence == entry.nextSequence,
              offset == entry.nextOffset,
              offset <= entry.descriptor.size,
              data.count <= AutomationTransferPolicy.chunkBytes,
              UInt64(data.count) <= entry.descriptor.size - offset,
              final == (offset + UInt64(data.count) == entry.descriptor.size)
        else {
            entries.removeValue(forKey: transferID)
            stopTimerIfEmpty()
            throw AutomationCommandError.permissionDenied(.mutate)
        }
        do {
            try entry.source.handle.write(contentsOf: data)
            entry.nextOffset += UInt64(data.count)
            entry.nextSequence += 1
            entry.expiresAt = ContinuousClock.now.advanced(by: idleTimeout)
            if final {
                try entry.source.handle.seek(toOffset: 0)
                entry.finalized = true
            }
            entries[transferID] = entry
        } catch {
            entries.removeValue(forKey: transferID)
            stopTimerIfEmpty()
            throw AutomationCommandError.unsupported("upload could not be written")
        }
    }

    /// Returns the private regular file only after a complete upload. The
    /// handle remains owned by the registry until `release` is called.
    public func finalizeUpload(
        transferID: UUID,
        context: AutomationClientContext
    ) throws -> URL {
        purgeExpired()
        guard let entry = entries[transferID],
              entry.isUpload, entry.finalized,
              let url = entry.source.temporaryURL
        else {
            throw AutomationCommandError.unsupported("upload is incomplete")
        }
        try authorizeOwner(entry, context: context)
        guard context.grant.canMutate,
              entry.accountLinkIDs.isSubset(of: context.grant.accountLinkIDs)
        else {
            throw AutomationCommandError.permissionDenied(.mutate)
        }
        return url
    }

    public func release(transferID: UUID, context: AutomationClientContext) throws {
        purgeExpired()
        guard let entry = entries[transferID] else { return }
        try authorizeOwner(entry, context: context)
        entries.removeValue(forKey: transferID)
        stopTimerIfEmpty()
    }

    public func read(
        transferID: UUID,
        offset: UInt64,
        length: Int,
        context: AutomationClientContext
    ) throws -> AutomationTransferChunk {
        purgeExpired()
        guard var entry = entries[transferID] else {
            throw AutomationCommandError.unsupported("transfer is unavailable")
        }
        try authorizeOwner(entry, context: context)
        guard context.grant.canRead,
              entry.accountLinkIDs.isSubset(of: context.grant.accountLinkIDs) else {
            throw AutomationCommandError.permissionDenied(.read)
        }
        do {
            guard !entry.isUpload, entry.finalized,
                  offset == entry.nextOffset,
                  length >= 0, length <= AutomationTransferPolicy.chunkBytes,
                  offset <= entry.descriptor.size,
                  UInt64(length) <= entry.descriptor.size - offset,
                  length > 0 || entry.descriptor.size == 0 else {
                throw AutomationCommandError.invalidPayload("transfer range")
            }
            var data = length == 0 ? Data() : (try entry.source.handle.read(upToCount: length) ?? Data())
            while data.count < length {
                guard let next = try entry.source.handle.read(upToCount: length - data.count), !next.isEmpty else {
                    throw AutomationCommandError.unsupported("transfer source is truncated")
                }
                data.append(next)
            }
            let final = offset + UInt64(length) == entry.descriptor.size
            let chunk = AutomationTransferChunk(
                transferID: transferID, sequence: entry.nextSequence, offset: offset,
                totalBytes: entry.descriptor.size, data: data, final: final
            )
            if final {
                entries.removeValue(forKey: transferID)
                stopTimerIfEmpty()
            } else {
                entry.nextOffset += UInt64(length)
                entry.nextSequence += 1
                entry.expiresAt = ContinuousClock.now.advanced(by: idleTimeout)
                entries[transferID] = entry
            }
            return chunk
        } catch {
            entries.removeValue(forKey: transferID)
            stopTimerIfEmpty()
            if let error = error as? AutomationCommandError { throw error }
            throw AutomationCommandError.unsupported("transfer source is unavailable")
        }
    }

    public func cancel(transferID: UUID, context: AutomationClientContext) throws {
        purgeExpired()
        guard let entry = entries[transferID] else { return }
        // An owner may release its resources even after its read grant is revoked.
        try authorizeOwner(entry, context: context)
        entries.removeValue(forKey: transferID)
        stopTimerIfEmpty()
    }

    public func shutdown() {
        closed = true
        entries.removeAll()
        stopTimerIfEmpty()
    }

    private func admit(
        size: UInt64, context: AutomationClientContext, requiringMutation: Bool = false
    ) throws {
        purgeExpired()
        guard !closed else { throw AutomationCommandError.appUnavailable }
        guard (requiringMutation ? context.grant.canMutate : context.grant.canRead),
              context.origin != .pairedRemote || context.clientID != nil else {
            throw AutomationCommandError.permissionDenied(requiringMutation ? .mutate : .read)
        }
        guard size <= AutomationTransferPolicy.maximumBytes else {
            throw AutomationCommandError.unsupported("transfer exceeds the permitted size")
        }
        let ownerCount = entries.values.reduce(0) { count, entry in
            count + (entry.ownerOrigin == context.origin && entry.ownerClientID == context.clientID ? 1 : 0)
        }
        let ownerLimit = context.origin == .pairedRemote ? 4 : 16
        guard entries.count < 32, ownerCount < ownerLimit else {
            throw AutomationCommandError.unsupported("too many active transfers")
        }
    }

    private func register(
        source: Source,
        descriptor: AutomationTransferDescriptor,
        context: AutomationClientContext,
        isUpload: Bool = false
    ) -> AutomationTransferDescriptor {
        entries[descriptor.transferID] = Entry(
            descriptor: descriptor, ownerOrigin: context.origin, ownerClientID: context.clientID,
            accountLinkIDs: context.origin == .pairedRemote ? context.grant.accountLinkIDs : [],
            source: source, isUpload: isUpload,
            finalized: !isUpload,
            expiresAt: ContinuousClock.now.advanced(by: idleTimeout)
        )
        scheduleExpiration()
        return descriptor
    }

    private func authorizeOwner(_ entry: Entry, context: AutomationClientContext) throws {
        guard entry.ownerOrigin == context.origin, entry.ownerClientID == context.clientID else {
            throw AutomationCommandError.permissionDenied(.read)
        }
    }

    private func purgeExpired() {
        let now = ContinuousClock.now
        for (id, entry) in entries where entry.expiresAt <= now {
            entries.removeValue(forKey: id)
        }
        stopTimerIfEmpty()
    }

    private func stopTimerIfEmpty() {
        guard entries.isEmpty else { return }
        expirationTask?.cancel()
        expirationTask = nil
    }

    private func scheduleExpiration() {
        guard expirationTask == nil,
              let deadline = entries.values.min(by: { $0.expiresAt < $1.expiresAt })?.expiresAt else { return }
        expirationTask = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            await self?.expireIdleHandles()
        }
    }

    private func expireIdleHandles() {
        guard !Task.isCancelled else { return }
        expirationTask = nil
        purgeExpired()
        scheduleExpiration()
    }
}
