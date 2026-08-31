import Foundation
import Testing
@testable import MailternalStore

@Test func sha256KnownVectors() {
    #expect(ContentHash.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    #expect(ContentHash.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(
        ContentHash.sha256Hex(Data("The quick brown fox jumps over the lazy dog".utf8))
            == "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
    )
}

@Test func attachmentLRURespectsCapAndPins() async throws {
    try await withStore(cacheCap: 1000) { store, _ in
        func blob(_ byte: UInt8, count: Int) -> Data {
            Data(repeating: byte, count: count)
        }

        let a = try await store.putAttachment(data: blob(1, count: 400))
        let b = try await store.putAttachment(data: blob(2, count: 400))
        #expect(try await store.attachmentCacheSize() == 800)
        #expect(FileManager.default.fileExists(atPath: a.url.path))
        #expect(FileManager.default.fileExists(atPath: b.url.path))

        // Third 400-byte file exceeds 1000; oldest (a) is evicted.
        let c = try await store.putAttachment(data: blob(3, count: 400))
        #expect(try await store.attachmentCacheSize() == 800)
        #expect(!FileManager.default.fileExists(atPath: a.url.path))
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        #expect(FileManager.default.fileExists(atPath: c.url.path))
        #expect(try await store.lookupAttachment(contentHash: a.contentHash) == nil)

        // Pin the current oldest (b) and insert another; b must survive, c goes.
        let pin = store.pinAttachment(contentHash: b.contentHash)
        let d = try await store.putAttachment(data: blob(4, count: 400))
        #expect(FileManager.default.fileExists(atPath: b.url.path))
        #expect(!FileManager.default.fileExists(atPath: c.url.path))
        #expect(FileManager.default.fileExists(atPath: d.url.path))
        #expect(try await store.attachmentCacheSize() == 800)

        store.unpinAttachment(pin)
        try await store.evictAttachmentCache()
        // Still at 800, under cap; nothing more to evict.
        #expect(try await store.attachmentCacheSize() == 800)

        // Same content is content-addressed (no extra bytes).
        let again = try await store.putAttachment(data: blob(2, count: 400))
        #expect(again.contentHash == b.contentHash)
        #expect(try await store.attachmentCacheSize() == 800)
    }
}
