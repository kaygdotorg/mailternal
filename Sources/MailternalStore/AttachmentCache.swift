import Foundation
import GRDB

/// In-process pin counts. Pins are not durable — a crash must not permanently
/// exempt files from LRU eviction.
final class PinTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func pin(_ hash: String) {
        lock.lock()
        defer { lock.unlock() }
        counts[hash, default: 0] += 1
    }

    func unpin(_ hash: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = counts[hash] else { return }
        if current <= 1 {
            counts.removeValue(forKey: hash)
        } else {
            counts[hash] = current - 1
        }
    }

    func pinnedHashes() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(counts.keys)
    }
}

extension MailStore {
    /// Stores bytes under `sha256(data)`. Atomic temp+rename; LRU eviction honors
    /// `attachmentCacheCapBytes` and in-use pins (spec: sync.md Attachment cache).
    @discardableResult
    public func putAttachment(data: Data) async throws -> (contentHash: String, url: URL) {
        let hash = ContentHash.sha256Hex(data)
        let dest = attachmentURL(for: hash)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dest.path) {
            try atomicWrite(data, to: dest)
        }
        let size = Int64(data.count)
        let cap = attachmentCacheCapBytes
        let pinned = pins.pinnedHashes()
        let evicted = try await write { db in
            let stamp = try MailStore.nextAccessStamp(db)
            try db.execute(
                sql: """
                    INSERT INTO attachment_cache (content_hash, byte_size, last_access)
                    VALUES (?, ?, ?)
                    ON CONFLICT(content_hash) DO UPDATE SET
                        byte_size = excluded.byte_size,
                        last_access = excluded.last_access
                    """,
                arguments: [hash, size, stamp]
            )
            return try MailStore.evictUnlocked(db, cap: cap, pinned: pinned, keep: hash)
        }
        for dead in evicted {
            try? fm.removeItem(at: attachmentURL(for: dead))
        }
        return (hash, dest)
    }

    public func attachmentURL(for contentHash: String) -> URL {
        cachesDirectory.appendingPathComponent(contentHash, isDirectory: false)
    }

    public func lookupAttachment(contentHash: String) async throws -> URL? {
        let url = attachmentURL(for: contentHash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try await write { db in
            let stamp = try MailStore.nextAccessStamp(db)
            try db.execute(
                sql: "UPDATE attachment_cache SET last_access = ? WHERE content_hash = ?",
                arguments: [stamp, contentHash]
            )
        }
        return url
    }

    /// Pins `contentHash` so LRU eviction will not delete it until matching `unpin`.
    public func pinAttachment(contentHash: String) -> AttachmentPin {
        pins.pin(contentHash)
        return AttachmentPin(contentHash: contentHash)
    }

    public func unpinAttachment(_ pin: AttachmentPin) {
        pins.unpin(pin.contentHash)
    }

    public func attachmentCacheSize() async throws -> Int64 {
        try await read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_size), 0) FROM attachment_cache") ?? 0
        }
    }

    public func evictAttachmentCache() async throws {
        let cap = attachmentCacheCapBytes
        let pinned = pins.pinnedHashes()
        let evicted = try await write { db in
            try MailStore.evictUnlocked(db, cap: cap, pinned: pinned, keep: nil)
        }
        for dead in evicted {
            try? FileManager.default.removeItem(at: attachmentURL(for: dead))
        }
    }

    private func atomicWrite(_ data: Data, to dest: URL) throws {
        let tmpDir = cachesDirectory.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tmp = tmpDir.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try data.write(to: tmp, options: [.atomic])
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            if !FileManager.default.fileExists(atPath: dest.path) {
                throw error
            }
        }
    }

    static func nextAccessStamp(_ db: Database) throws -> Double {
        let now = Date().timeIntervalSince1970
        let maxExisting = try Double.fetchOne(db, sql: "SELECT MAX(last_access) FROM attachment_cache") ?? 0
        return max(now, maxExisting + 0.000_001)
    }

    /// Evicts oldest unpinned rows until `SUM(byte_size) <= cap`. Never evicts `keep`.
    static func evictUnlocked(
        _ db: Database,
        cap: Int64,
        pinned: Set<String>,
        keep: String?
    ) throws -> [String] {
        var total = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_size), 0) FROM attachment_cache") ?? 0
        if total <= cap { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT content_hash, byte_size FROM attachment_cache ORDER BY last_access ASC"
        )
        var evicted: [String] = []
        for row in rows {
            if total <= cap { break }
            let hash: String = row["content_hash"]
            if pinned.contains(hash) { continue }
            if hash == keep { continue }
            let size: Int64 = row["byte_size"]
            try db.execute(sql: "DELETE FROM attachment_cache WHERE content_hash = ?", arguments: [hash])
            evicted.append(hash)
            total -= size
        }
        return evicted
    }
}
