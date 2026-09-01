import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore

/// Pure policy helpers (spec: docs/spec/sync.md). Kept free of I/O so unit tests
/// can pin window math, the UIDNEXT−1 baseline edge, downgrade, disk, and notify.
enum SyncPolicy: Sendable {
    static let defaultWindowSize: UInt32 = 1_000
    static let setupSampleSize = 1_000
    static let windowedDays = 30
    /// FTS + WAL + SQLite overhead on accumulated text-part bytes.
    static let storeOverheadNumerator: Int64 = 8
    static let storeOverheadDenominator: Int64 = 5
    static let minReserveBytes: Int64 = 5 * 1024 * 1024 * 1024
    static let hysteresisBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let rawSourceCap = 4 * 1024 * 1024
    static let idleRenewal: Duration = .seconds(25 * 60)
    static let hintDebounce: Duration = .milliseconds(250)
    static let specialUseDelta: Duration = .seconds(120)
    static let otherFolderDelta: Duration = .seconds(300)

    // MARK: Baseline (UIDNEXT − 1)

    /// Persist before backfill. `UIDNEXT == 1` (empty) or missing → baseline `0`
    /// so every future UID is greater-than and notifiable.
    static func baseline(uidNext: UInt32?) -> IMAPUID {
        let next = uidNext ?? 1
        if next <= 1 { return IMAPUID(rawValue: 0) }
        return IMAPUID(rawValue: next &- 1)
    }

    static func isNotifiable(uid: IMAPUID, baseline: IMAPUID?) -> Bool {
        guard let baseline else { return false }
        return uid.rawValue > baseline.rawValue
    }

    // MARK: Backfill windows

    /// Next descending inclusive UID window. `lowWater` is the lowest UID already
    /// committed; the following window ends at `lowWater − 1`. Empty mailboxes
    /// (`UIDNEXT ≤ 1`) yield `nil`.
    static func nextWindow(
        uidNext: UInt32,
        windowSize: UInt32,
        lowWater: UInt32?
    ) -> ClosedRange<UInt32>? {
        let size = max(1, windowSize)
        let high: UInt32
        if let lowWater {
            if lowWater <= 1 { return nil }
            high = lowWater &- 1
        } else {
            if uidNext <= 1 { return nil }
            high = uidNext &- 1
        }
        if high == 0 { return nil }
        let low: UInt32 = high >= size ? high &- size &+ 1 : 1
        return low...high
    }

    static func backfillProgress(uidNext: UInt32, lowWater: UInt32?) -> Double? {
        guard uidNext > 1 else { return 1 }
        let top = uidNext &- 1
        let remaining = (lowWater ?? (top &+ 1))
        let done = top >= remaining ? top &- remaining &+ 1 : 0
        return min(1, max(0, Double(done) / Double(top)))
    }

    // MARK: Paths

    static func advertisedPath(_ advertised: IMAPDeltaPath) -> DeltaPath {
        switch advertised {
        case .qresync: return .qresync
        case .condstore: return .condstore
        case .basic: return .basic
        }
    }

    /// Fresh generations take the advertised path. Existing rows keep a persistent
    /// downgrade.
    static func initialPath(stored: DeltaPath, advertised: DeltaPath, isFresh: Bool) -> DeltaPath {
        isFresh ? advertised : stored
    }

    enum DowngradeReason: String, Sendable {
        case taggedNO
        case taggedBAD
        case noModSeq
        case malformed
    }

    /// Persistent one-step demotion. `NOMODSEQ` skips CONDSTORE (it cannot work).
    static func downgrade(
        from current: DeltaPath,
        reason: DowngradeReason,
        advertisedHasCondstore: Bool
    ) -> DeltaPath {
        if reason == .noModSeq { return .basic }
        switch current {
        case .qresync:
            return advertisedHasCondstore ? .condstore : .basic
        case .condstore, .basic:
            return .basic
        }
    }

    static func folderRank(_ role: FolderRole) -> Int {
        switch role {
        case .inbox: return 0
        case .sent, .drafts, .archive, .junk, .trash: return 1
        case .none: return 2
        }
    }

    static func isSpecialUse(_ role: FolderRole) -> Bool {
        switch role {
        case .inbox, .none: return false
        case .sent, .drafts, .archive, .junk, .trash: return true
        }
    }

    static func sortFolders(_ folders: [FolderRecord]) -> [FolderRecord] {
        folders.sorted { a, b in
            let ra = folderRank(a.role)
            let rb = folderRank(b.role)
            if ra != rb { return ra < rb }
            return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }
    }

    // MARK: Disk

    static func reserveBytes(volumeBytes: Int64) -> Int64 {
        max(minReserveBytes, volumeBytes / 10)
    }

    static func projectedStoreBytes(textPartBytes: Int64) -> Int64 {
        let safe = max(0, textPartBytes)
        return safe * storeOverheadNumerator / storeOverheadDenominator
    }

    static func extrapolatedTextBytes(sampleTextBytes: Int64, sampleCount: Int, messageCount: Int) -> Int64 {
        guard sampleCount > 0, messageCount > 0 else { return 0 }
        let avg = sampleTextBytes / Int64(sampleCount)
        return avg * Int64(messageCount)
    }

    static func shouldEnterWindowed(freeBytes: Int64, projectedBytes: Int64, reserveBytes: Int64) -> Bool {
        freeBytes - projectedBytes < reserveBytes
    }

    static func shouldHalt(freeBytes: Int64, reserveBytes: Int64) -> Bool {
        freeBytes < reserveBytes
    }

    static func shouldResume(freeBytes: Int64, reserveBytes: Int64) -> Bool {
        freeBytes > reserveBytes + hysteresisBytes
    }

    // MARK: Flags / errors

    static func messageFlags(_ flags: [String]) -> MessageFlags {
        var result = MessageFlags()
        var extra: [String] = []
        extra.reserveCapacity(flags.count)
        for raw in flags {
            switch normalizeFlag(raw) {
            case "seen": result.isRead = true
            case "flagged": result.isFlagged = true
            case "answered": result.isAnswered = true
            case "draft": result.isDraft = true
            case "deleted": result.isDeleted = true
            case "recent": break
            default:
                extra.append(raw)
            }
        }
        result.extra = extra
        return result
    }

    static func normalizeFlag(_ raw: String) -> String {
        raw.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            .lowercased()
    }

    static func isTaggedFailure(_ error: Error) -> Bool {
        guard let error = error as? IMAPError else { return false }
        return error.isTaggedNO || error.isTaggedBAD
    }

    static func taggedReason(_ error: Error) -> DowngradeReason? {
        guard let error = error as? IMAPError else { return nil }
        if error.isTaggedNO { return .taggedNO }
        if error.isTaggedBAD { return .taggedBAD }
        if case .parse = error { return .malformed }
        return nil
    }

    static func isConnectionCap(_ error: Error) -> Bool {
        guard let error = error as? IMAPError else { return false }
        switch error {
        case .taggedNO, .taggedBAD:
            return true
        case .transport(let message):
            return message.lowercased().contains("bye") || message.lowercased().contains("closed")
        default:
            return false
        }
    }

    static func isTransport(_ error: Error) -> Bool {
        guard let error = error as? IMAPError else { return false }
        switch error {
        case .transport, .tls, .parse: return true
        default: return false
        }
    }

    static func uidSet(_ range: ClosedRange<UInt32>) -> IMAPUIDSet {
        IMAPUIDSet(range)
    }

    /// Bounded UID set for flag sweeps. Never `1:4294967295` — Dovecot hangs
    /// on `UID FETCH 1:4294967295 (FLAGS) (CHANGEDSINCE …)`.
    static func knownUIDSet(uidNext: UInt32) -> IMAPUIDSet {
        let high = uidNext > 1 ? uidNext &- 1 : 1
        return IMAPUIDSet(1...high)
    }

    /// Basic-path expunge/flag reconcile window. Spec: bounded sweeps, never
    /// one `1...(UIDNEXT-1)` FETCH over a 100k mailbox.
    static let flagSweepWindowSize: UInt32 = 5000

    static func flagSweepWindows(
        uidNext: UInt32,
        windowSize: UInt32 = flagSweepWindowSize
    ) -> [ClosedRange<UInt32>] {
        guard uidNext > 1 else { return [] }
        let high = uidNext &- 1
        let size = max(1, windowSize)
        var windows: [ClosedRange<UInt32>] = []
        var lo: UInt32 = 1
        while true {
            let hi = min(high, lo &+ (size &- 1))
            windows.append(lo...hi)
            if hi == high { break }
            lo = hi &+ 1
        }
        return windows
    }

    static func uidSet<S: Sequence>(uids: S) -> IMAPUIDSet where S.Element == UInt32 {
        let sorted = uids.filter { $0 >= 1 }.sorted()
        guard let first = sorted.first else { return IMAPUIDSet(ranges: []) }
        var ranges: [ClosedRange<UInt32>] = []
        var lo = first
        var hi = first
        for uid in sorted.dropFirst() {
            if uid == hi &+ 1 {
                hi = uid
            } else {
                ranges.append(lo...hi)
                lo = uid
                hi = uid
            }
        }
        ranges.append(lo...hi)
        return IMAPUIDSet(ranges: ranges)
    }

    static func contains(_ set: IMAPUIDSet, uid: UInt32) -> Bool {
        set.ranges.contains { $0.contains(uid) }
    }
}

struct NotificationKey: Hashable, Sendable {
    var generation: MailboxGeneration
    var uid: IMAPUID
}

struct FolderRecord: Sendable {
    var id: FolderID
    var path: String
    var name: String
    var role: FolderRole
    var generation: MailboxGeneration
    var baseline: IMAPUID?
    var deltaPath: DeltaPath
    var highestModseq: UInt64?
    var lastUidNext: UInt32
    var lastDeltaAt: Date
    var isReplacement: Bool
}

struct DiskSnapshot: Sendable {
    var freeBytes: Int64
    var volumeBytes: Int64
}

protocol DiskSpaceProviding: Sendable {
    func snapshot(for url: URL) -> DiskSnapshot
}

/// QA/testing: 200 GiB free on a 500 GiB volume, well above the spec reserve.
struct AmpleDiskSpace: DiskSpaceProviding {
    func snapshot(for url: URL) -> DiskSnapshot {
        DiskSnapshot(
            freeBytes: 200 * 1024 * 1024 * 1024,
            volumeBytes: 500 * 1024 * 1024 * 1024
        )
    }
}

struct FileDiskSpace: DiskSpaceProviding {
    func snapshot(for url: URL) -> DiskSnapshot {
        var keys: Set<URLResourceKey> = [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        #if os(macOS)
        keys.insert(.volumeAvailableCapacityForImportantUsageKey)
        #endif
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)
        var free = Int64(values?.volumeAvailableCapacity ?? 0)
        #if os(macOS)
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            free = Int64(important)
        }
        #endif
        let volume = Int64(values?.volumeTotalCapacity ?? 0)
        if volume <= 0 && free <= 0 {
            return DiskSnapshot(freeBytes: Int64.max / 8, volumeBytes: Int64.max / 8)
        }
        return DiskSnapshot(freeBytes: max(0, free), volumeBytes: max(1, volume))
    }
}

struct SyncSettings: Sendable {
    var backfillWindowSize: UInt32
    var idleRenewal: Duration
    var hintDebounce: Duration
    var specialUseDelta: Duration
    var otherFolderDelta: Duration
    var seenPoll: Duration
    var setupSampleSize: Int
    var windowedDays: Int
    var diskURL: URL
    var periodicTick: Duration
    var cleanupTick: Duration
    var reconnect: IMAPReconnectBackoff
    /// When false, skip `ENABLE QRESYNC` so a CONDSTORE-capable server stays
    /// on the CONDSTORE path (QA: 1143 without enable).
    var allowEnableQResync: Bool
    var flagSweepWindowSize: UInt32

    static let production = SyncSettings(
        backfillWindowSize: SyncPolicy.defaultWindowSize,
        idleRenewal: SyncPolicy.idleRenewal,
        hintDebounce: SyncPolicy.hintDebounce,
        specialUseDelta: SyncPolicy.specialUseDelta,
        otherFolderDelta: SyncPolicy.otherFolderDelta,
        seenPoll: .seconds(2),
        setupSampleSize: SyncPolicy.setupSampleSize,
        windowedDays: SyncPolicy.windowedDays,
        diskURL: FileManager.default.homeDirectoryForCurrentUser,
        periodicTick: .seconds(15),
        cleanupTick: .seconds(30),
        reconnect: IMAPReconnectBackoff(),
        allowEnableQResync: true,
        flagSweepWindowSize: SyncPolicy.flagSweepWindowSize
    )
}
