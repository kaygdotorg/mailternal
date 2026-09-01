import Foundation
import MailternalIMAP
import MailternalInterfaces
import MailternalStore
import Testing
@testable import MailternalSync

@Test func backfillWindowsDescendFromUidNextMinusOne() {
    #expect(SyncPolicy.nextWindow(uidNext: 1, windowSize: 10, lowWater: nil) == nil)
    #expect(SyncPolicy.nextWindow(uidNext: 0, windowSize: 10, lowWater: nil) == nil)
    #expect(SyncPolicy.nextWindow(uidNext: 5, windowSize: 10, lowWater: nil) == 1...4)
    #expect(SyncPolicy.nextWindow(uidNext: 100, windowSize: 10, lowWater: nil) == 90...99)
    #expect(SyncPolicy.nextWindow(uidNext: 100, windowSize: 10, lowWater: 90) == 80...89)
    #expect(SyncPolicy.nextWindow(uidNext: 100, windowSize: 10, lowWater: 1) == nil)
    #expect(SyncPolicy.nextWindow(uidNext: 8, windowSize: 10, lowWater: 5) == 1...4)
}

@Test func baselineIsUidNextMinusOneIncludingEmptyMailboxEdge() {
    #expect(SyncPolicy.baseline(uidNext: nil).rawValue == 0)
    #expect(SyncPolicy.baseline(uidNext: 0).rawValue == 0)
    #expect(SyncPolicy.baseline(uidNext: 1).rawValue == 0)
    #expect(SyncPolicy.baseline(uidNext: 2).rawValue == 1)
    #expect(SyncPolicy.baseline(uidNext: 100_001).rawValue == 100_000)
    #expect(SyncPolicy.isNotifiable(uid: IMAPUID(rawValue: 1), baseline: IMAPUID(rawValue: 0)))
    #expect(!SyncPolicy.isNotifiable(uid: IMAPUID(rawValue: 100_000), baseline: IMAPUID(rawValue: 100_000)))
    #expect(SyncPolicy.isNotifiable(uid: IMAPUID(rawValue: 100_001), baseline: IMAPUID(rawValue: 100_000)))
}

@Test func downgradeMatrixStepsAndNomodseqSkipsCondstore() {
    #expect(
        SyncPolicy.downgrade(from: .qresync, reason: .taggedNO, advertisedHasCondstore: true) == .condstore
    )
    #expect(
        SyncPolicy.downgrade(from: .qresync, reason: .taggedBAD, advertisedHasCondstore: false) == .basic
    )
    #expect(
        SyncPolicy.downgrade(from: .qresync, reason: .malformed, advertisedHasCondstore: true) == .condstore
    )
    #expect(
        SyncPolicy.downgrade(from: .qresync, reason: .noModSeq, advertisedHasCondstore: true) == .basic
    )
    #expect(
        SyncPolicy.downgrade(from: .condstore, reason: .taggedNO, advertisedHasCondstore: true) == .basic
    )
    #expect(
        SyncPolicy.downgrade(from: .basic, reason: .taggedBAD, advertisedHasCondstore: true) == .basic
    )
    #expect(SyncPolicy.initialPath(stored: .basic, advertised: .qresync, isFresh: true) == .qresync)
    #expect(SyncPolicy.initialPath(stored: .basic, advertised: .qresync, isFresh: false) == .basic)
}

@Test func notificationDedupeIsGenerationAndUID() {
    let folder = FolderID(rawValue: 1)
    let gen = MailboxGeneration(folder: folder, uidValidity: 9)
    var seen: Set<NotificationKey> = []
    let key = NotificationKey(generation: gen, uid: IMAPUID(rawValue: 4))
    #expect(seen.insert(key).inserted)
    #expect(!seen.insert(key).inserted)
    let otherGen = NotificationKey(
        generation: MailboxGeneration(folder: folder, uidValidity: 10),
        uid: IMAPUID(rawValue: 4)
    )
    #expect(seen.insert(otherGen).inserted)
}

@Test func knownUIDSetIsBoundedByUidNextMinusOne() {
    #expect(SyncPolicy.knownUIDSet(uidNext: 1).ranges == [1...1])
    #expect(SyncPolicy.knownUIDSet(uidNext: 100_001).ranges == [1...100_000])
}

@Test func diskPolicyReserveWindowedHaltAndResume() {
    #expect(SyncPolicy.reserveBytes(volumeBytes: 10 * 1024 * 1024 * 1024) == 5 * 1024 * 1024 * 1024)
    #expect(SyncPolicy.reserveBytes(volumeBytes: 100 * 1024 * 1024 * 1024) == 10 * 1024 * 1024 * 1024)
    #expect(SyncPolicy.projectedStoreBytes(textPartBytes: 1000) == 1600)
    #expect(SyncPolicy.extrapolatedTextBytes(sampleTextBytes: 1000, sampleCount: 10, messageCount: 100) == 10_000)
    let reserve: Int64 = 100
    #expect(SyncPolicy.shouldEnterWindowed(freeBytes: 150, projectedBytes: 60, reserveBytes: reserve))
    #expect(!SyncPolicy.shouldEnterWindowed(freeBytes: 500, projectedBytes: 10, reserveBytes: reserve))
    #expect(SyncPolicy.shouldHalt(freeBytes: 90, reserveBytes: reserve))
    #expect(!SyncPolicy.shouldResume(freeBytes: 101, reserveBytes: reserve))
    #expect(SyncPolicy.shouldResume(freeBytes: reserve + SyncPolicy.hysteresisBytes + 1, reserveBytes: reserve))
}

@Test func inboxRanksAheadOfSpecialUseAndRemainder() {
    let inbox = FolderRecord(
        id: FolderID(rawValue: 1), path: "INBOX", name: "INBOX", role: .inbox,
        generation: MailboxGeneration(folder: FolderID(rawValue: 1), uidValidity: 1),
        baseline: nil, deltaPath: .basic, highestModseq: nil, lastUidNext: 1,
        lastDeltaAt: .distantPast, isReplacement: false
    )
    let archive = FolderRecord(
        id: FolderID(rawValue: 2), path: "Archive", name: "Archive", role: .archive,
        generation: MailboxGeneration(folder: FolderID(rawValue: 2), uidValidity: 1),
        baseline: nil, deltaPath: .basic, highestModseq: nil, lastUidNext: 1,
        lastDeltaAt: .distantPast, isReplacement: false
    )
    let other = FolderRecord(
        id: FolderID(rawValue: 3), path: "Projects", name: "Projects", role: .none,
        generation: MailboxGeneration(folder: FolderID(rawValue: 3), uidValidity: 1),
        baseline: nil, deltaPath: .basic, highestModseq: nil, lastUidNext: 1,
        lastDeltaAt: .distantPast, isReplacement: false
    )
    let ordered = SyncPolicy.sortFolders([other, archive, inbox])
    #expect(ordered.map(\.role) == [.inbox, .archive, .none])
}
