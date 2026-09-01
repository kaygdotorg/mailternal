import Foundation
import MailternalInterfaces
import Testing
@testable import MailternalIMAP

@Test func startTLSMissingCapabilityRefusesDowngrade() async throws {
    try await ScriptedIMAP.run(security: .startTLS) { imap in
        let connecting = Task { try await imap.session.connect() }
        try await imap.writeServer("* OK IMAP4rev1 ready")
        let (tag, _) = try await imap.expectCommand(containing: "CAPABILITY")
        try await imap.capability(tag, "IMAP4rev1 AUTH=PLAIN SASL-IR")
        do {
            try await connecting.value
            Issue.record("connect should fail without STARTTLS")
        } catch let error as IMAPError {
            #expect(error.isTLS)
        }
        let joined = imap.recordedClientLines.value.joined(separator: "\n").uppercased()
        #expect(!joined.contains("LOGIN"))
        #expect(!joined.contains("AUTHENTICATE"))
    }
}

@Test func startTLSTaggedNORefusesDowngrade() async throws {
    try await ScriptedIMAP.run(security: .startTLS) { imap in
        let connecting = Task { try await imap.session.connect() }
        try await imap.writeServer("* OK IMAP4rev1 ready")
        var (tag, _) = try await imap.expectCommand(containing: "CAPABILITY")
        try await imap.capability(tag, "IMAP4rev1 STARTTLS AUTH=PLAIN")
        (tag, _) = try await imap.expectCommand(containing: "STARTTLS")
        try await imap.no(tag, "TLS not available")
        do {
            try await connecting.value
            Issue.record("connect should fail when STARTTLS is NO")
        } catch let error as IMAPError {
            #expect(error.isTLS)
        }
        let joined = imap.recordedClientLines.value.joined(separator: "\n").uppercased()
        #expect(!joined.contains("LOGIN"))
        #expect(!joined.contains("AUTHENTICATE"))
    }
}

@Test func listRoleMappingSkipsNoselect() async throws {
    try await ScriptedIMAP.run(security: .startTLS) { imap in
        try await imap.connectStartTLS()
        let listing = Task { try await imap.session.listFolders() }
        let (tag, _) = try await imap.expectCommand(containing: "LIST")
        try await imap.writeServer(#"* LIST (\Noselect \HasChildren) "/" "Parents""#)
        try await imap.writeServer(#"* LIST (\NonExistent) "/" "Ghost""#)
        try await imap.writeServer(#"* LIST (\Sent) "/" "Sent""#)
        try await imap.writeServer(#"* LIST (\Trash) "/" "Trash""#)
        try await imap.writeServer(#"* LIST (\Junk) "/" "Junk""#)
        try await imap.writeServer(#"* LIST (\Archive) "/" "Archive""#)
        try await imap.writeServer(#"* LIST (\Drafts) "/" "Drafts""#)
        try await imap.writeServer(#"* LIST () "/" "INBOX""#)
        try await imap.writeServer(#"* LIST () "/" "Projects""#)
        try await imap.writeServer(#"* LIST () "/" "Spam""#)
        try await imap.ok(tag, "LIST completed")
        let discovery = try await listing.value
        let roles = Dictionary(uniqueKeysWithValues: discovery.folders.map { ($0.name, $0.role) })
        #expect(roles["INBOX"] == .inbox)
        #expect(roles["Sent"] == .sent)
        #expect(roles["Trash"] == .trash)
        #expect(roles["Junk"] == .junk)
        #expect(roles["Archive"] == .archive)
        #expect(roles["Drafts"] == .drafts)
        #expect(roles["Spam"] == .junk)
        #expect(roles["Projects"] == FolderRole.none)
        #expect(discovery.folders.contains { $0.name == "Parents" } == false)
        #expect(discovery.folders.contains { $0.name == "Ghost" } == false)
        #expect(discovery.isGmail == false)
    }
}

@Test func gmailHostSetsDiscoveryFlag() async throws {
    try await ScriptedIMAP.run(host: "imap.gmail.com", security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let listing = Task { try await imap.session.listFolders() }
        let (tag, _) = try await imap.expectCommand(containing: "LIST")
        try await imap.writeServer(#"* LIST () "/" "INBOX""#)
        try await imap.ok(tag)
        let discovery = try await listing.value
        #expect(discovery.isGmail)
    }
}

@Test func peekOnlyFetchEncoding() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let fetching = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(
                    uids: IMAPUIDSet(uid: 42),
                    envelope: true,
                    bodyStructure: true,
                    flags: true,
                    internalDate: true,
                    peek: [.complete, .text, .binaryPart("1")]
                )
            )
        }
        let (tag, line) = try await imap.expectCommand(containing: "UID FETCH")
        #expect(line.uppercased().contains("BODY.PEEK"))
        #expect(line.uppercased().contains("BINARY.PEEK"))
        #expect(!line.contains("RFC822.TEXT"))
        #expect(!line.contains("BODY[TEXT]"))
        try await imap.ok(tag)
        _ = try await fetching.value
    }
}

@Test func qresyncSelectEncoding() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let selecting = Task {
            try await imap.session.select(
                "INBOX",
                qresync: IMAPQResyncSelect(
                    uidValidity: 9,
                    modificationSequence: 100,
                    knownUIDs: IMAPUIDSet(1...10)
                )
            )
        }
        var (tag, line) = try await imap.expectCommand()
        if line.uppercased().contains("ENABLE") {
            try await imap.writeServer("* ENABLED QRESYNC")
            try await imap.ok(tag)
            (tag, line) = try await imap.expectCommand(containing: "SELECT")
        }
        #expect(line.uppercased().contains("SELECT"))
        #expect(line.uppercased().contains("QRESYNC"))
        try await imap.writeServer("* 3 EXISTS")
        try await imap.writeServer("* OK [UIDVALIDITY 9]")
        try await imap.writeServer("* OK [HIGHESTMODSEQ 100]")
        try await imap.ok(tag, "[READ-WRITE] Select completed")
        let selected = try await selecting.value
        #expect(selected.exists == 3)
        #expect(selected.uidValidity == 9)
    }
}

@Test func changedSinceFetchEncoding() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let fetching = Task {
            try await imap.session.fetch(.flagsChangedSince(uids: IMAPUIDSet.all, modSeq: 77))
        }
        let (tag, line) = try await imap.expectCommand(containing: "UID FETCH")
        #expect(line.uppercased().contains("CHANGEDSINCE"))
        #expect(line.contains("77"))
        try await imap.ok(tag)
        _ = try await fetching.value
    }
}

@Test func idleEventStream() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let idling = Task { try await imap.session.beginIdle() }
        let (tag, _) = try await imap.expectCommand(containing: "IDLE")
        try await imap.writeServer("+ idling")
        let idle = try await idling.value
        var iterator = idle.events.makeAsyncIterator()
        try await imap.writeServer("* 12 EXISTS")
        let exists = await iterator.next()
        #expect(exists == .exists(12))
        try await imap.writeServer("* 4 EXPUNGE")
        let expunge = await iterator.next()
        #expect(expunge == .expunge(sequence: 4))
        try await imap.writeServer("* 2 FETCH (FLAGS (\\Seen))")
        let hint = await iterator.next()
        #expect(hint == .fetchHint)
        let ending = Task { try await imap.session.endIdle() }
        _ = try await imap.expectCommand(containing: "DONE")
        try await imap.ok(tag)
        try await ending.value
    }
}

@Test func taggedNOOnStoreSeen() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let storing = Task { try await imap.session.storeSeen(uids: IMAPUIDSet(uid: 5)) }
        let (tag, line) = try await imap.expectCommand(containing: "UID STORE")
        #expect(line.uppercased().contains("+FLAGS.SILENT"))
        #expect(line.uppercased().contains("SEEN"))
        try await imap.no(tag, "[CANNOT] not allowed")
        do {
            try await storing.value
            Issue.record("storeSeen should surface tagged NO")
        } catch let error as IMAPError {
            #expect(error.isTaggedNO)
        }
    }
}
