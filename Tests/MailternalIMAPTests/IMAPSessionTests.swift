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

@Test func preauthGreetingSkipsAuthentication() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        let connecting = Task { try await imap.session.connect() }
        try await imap.writeServer("* PREAUTH IMAP4rev1 already authenticated")

        var (tag, _) = try await imap.expectCommand(containing: "CAPABILITY")
        try await imap.capability(tag, ScriptedIMAP.postTLSCaps)
        (tag, _) = try await imap.expectCommand(containing: "CAPABILITY")
        try await imap.capability(tag, ScriptedIMAP.postTLSCaps)
        try await connecting.value

        let commands = imap.recordedClientLines.value.joined(separator: "\n").uppercased()
        #expect(!commands.contains("LOGIN"))
        #expect(!commands.contains("AUTHENTICATE"))
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
        try await imap.writeServer(#"* LIST (\All) "/" "[Gmail]/All Mail""#)
        try await imap.writeServer(#"* LIST (\Flagged) "/" "[Gmail]/Starred""#)
        try await imap.writeServer(#"* LIST (\Important) "/" "[Gmail]/Important""#)
        try await imap.ok(tag, "LIST completed")
        let discovery = try await listing.value
        let roles = Dictionary(uniqueKeysWithValues: discovery.folders.map { ($0.name, $0.role) })
        #expect(roles["INBOX"] == .inbox)
        #expect(roles["Sent"] == .sent)
        #expect(roles["Trash"] == .trash)
        #expect(roles["Junk"] == .junk)
        #expect(roles["All Mail"] == .archive)
        #expect(roles["Starred"] == FolderRole.none)
        #expect(roles["Important"] == FolderRole.none)
        let allMail = try #require(discovery.folders.first { $0.path == "[Gmail]/All Mail" })
        #expect(allMail.name == "All Mail")
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

@Test func overBudgetFetchPoisonsOnlyItsSession() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let fetching = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(
                    uids: IMAPUIDSet(uid: 1),
                    peek: [.text],
                    maximumResponseBytes: 0
                )
            )
        }
        _ = try await imap.expectCommand(containing: "UID FETCH")
        do {
            try await imap.writeServer("* 1 FETCH (UID 1 BODY[TEXT] {1}\r\nx)")
        } catch {
            // The transport closes as soon as it sees the over-budget literal.
        }
        do {
            _ = try await fetching.value
            Issue.record("over-budget FETCH should fail")
        } catch let error as IMAPError {
            #expect(error == .responseTooLarge(limit: 0))
        } catch {
            Issue.record("over-budget FETCH returned \(error)")
        }

        do {
            _ = try await imap.session.listFolders()
            Issue.record("a poisoned session must reject later commands")
        } catch let error as IMAPError {
            #expect(error == .transport("Session is closed"))
        } catch {
            Issue.record("closed session returned \(error)")
        }
    }

    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let fetching = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(uids: IMAPUIDSet(uid: 2), flags: true)
            )
        }
        let (tag, _) = try await imap.expectCommand(containing: "UID FETCH")
        try await imap.writeServer("* 2 FETCH (UID 2 FLAGS (\\Seen))")
        try await imap.ok(tag)
        let messages = try await fetching.value
        #expect(messages.count == 1)
        #expect(messages.first?.uid == 2)
    }
}

@Test func unsolicitedFetchesPublishHintsWithoutEnteringFetchResults() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        var events = imap.session.events.makeAsyncIterator()
        try await imap.writeServer("* 7 FETCH (UID 7 BODY[TEXT] {1}\r\nx)")
        let beforeHint = await events.next()
        #expect(beforeHint == .fetchHint)

        let firstFetch = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(uids: IMAPUIDSet(uid: 1), flags: true)
            )
        }
        let (firstTag, _) = try await imap.expectCommand(containing: "UID FETCH")
        try await imap.writeServer("* 1 FETCH (UID 1 FLAGS (\\Seen))")
        try await imap.ok(firstTag)
        let firstResult = try await firstFetch.value
        #expect(firstResult.count == 1)
        #expect(firstResult.first?.uid == 1)

        try await imap.writeServer("* 8 FETCH (UID 8 BODY[TEXT] {1}\r\ny)")
        let afterHint = await events.next()
        #expect(afterHint == .fetchHint)

        let secondFetch = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(uids: IMAPUIDSet(uid: 2), flags: true)
            )
        }
        let (secondTag, _) = try await imap.expectCommand(containing: "UID FETCH")
        try await imap.writeServer("* 2 FETCH (UID 2 FLAGS (\\Seen))")
        try await imap.ok(secondTag)
        let secondResult = try await secondFetch.value
        #expect(secondResult.count == 1)
        #expect(secondResult.first?.uid == 2)
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

@Test func renameMailboxEncodesAndSurfacesTaggedResponse() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let renaming = Task {
            try await imap.session.renameMailbox(from: "Projects/Old", to: "Projects/New")
        }
        let (tag, line) = try await imap.expectCommand(containing: "RENAME")
        #expect(line.contains(#"RENAME "Projects/Old" "Projects/New""#))
        try await imap.ok(tag)
        try await renaming.value
    }
}

@Test func renameMailboxSurfacesTaggedNO() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let renaming = Task {
            try await imap.session.renameMailbox(from: "Old", to: "New")
        }
        let (tag, _) = try await imap.expectCommand(containing: "RENAME")
        try await imap.no(tag, "[ALREADYEXISTS] New exists")
        do {
            try await renaming.value
            Issue.record("renameMailbox should surface tagged NO")
        } catch let error as IMAPError {
            #expect(error.isTaggedNO)
        }
    }
}

@Test func copyUIDPreservesParallelRangeOrder() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let copying = Task {
            try await imap.session.copy(uids: IMAPUIDSet(ranges: [7...9, 20...20]), to: "Archive")
        }
        let (tag, _) = try await imap.expectCommand(containing: "UID COPY")
        try await imap.writeServer("\(tag) OK [COPYUID 900 7:9,20 101,301:303] copied")
        let mapping = try #require(await copying.value)
        #expect(mapping.destinationUIDValidity == 900)
        #expect(mapping.destinationUID(for: IMAPUID(rawValue: 7)) == IMAPUID(rawValue: 101))
        #expect(mapping.destinationUID(for: IMAPUID(rawValue: 8)) == IMAPUID(rawValue: 301))
        #expect(mapping.destinationUID(for: IMAPUID(rawValue: 9)) == IMAPUID(rawValue: 302))
        #expect(mapping.destinationUID(for: IMAPUID(rawValue: 20)) == IMAPUID(rawValue: 303))
        #expect(mapping.destinationUID(for: IMAPUID(rawValue: 10)) == nil)
    }
}

@Test func moveRetainsUntaggedCOPYUIDBeforeExpunge() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let moving = Task { try await imap.session.move(uids: IMAPUIDSet(uid: 7), to: "Archive") }
        let (tag, _) = try await imap.expectCommand(containing: "UID MOVE")
        try await imap.writeServer("* OK [COPYUID 901 7 401] moving")
        try await imap.writeServer("* 1 EXPUNGE")
        try await imap.ok(tag)
        let mapping = try #require(await moving.value)
        #expect(mapping.destinationUIDValidity == 901)
        #expect(mapping.destinationUID(for: IMAPUID(rawValue: 7)) == IMAPUID(rawValue: 401))
    }
}

@Test(arguments: ["", "[COPYUID 902 7:8 501] "])
func successfulMoveWithoutUsableMappingIsNotRetryable(_ code: String) async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let moving = Task { try await imap.session.move(uids: IMAPUIDSet(uid: 7), to: "Archive") }
        let (tag, _) = try await imap.expectCommand(containing: "UID MOVE")
        try await imap.writeServer("\(tag) OK \(code)moved")
        #expect(try await moving.value == nil)
    }
}

@Test func copyUIDMappingDoesNotExpandLargeRangesOrAcceptAmbiguity() throws {
    let complete = try #require(IMAPCopyUIDMapping(
        destinationUIDValidity: 903,
        sourceUIDs: [1...UInt32.max],
        destinationUIDs: [1...UInt32.max]
    ))
    let last = IMAPUID(rawValue: UInt32.max)
    #expect(complete.destinationUID(for: last) == last)
    let ambiguous = try #require(IMAPCopyUIDMapping(
        destinationUIDValidity: 903,
        sourceUIDs: [7...7, 7...7],
        destinationUIDs: [501...502]
    ))
    #expect(ambiguous.destinationUID(for: IMAPUID(rawValue: 7)) == nil)
}

@Test func closeDuringIdleDropsSocketWithoutLogout() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let idling = Task { try await imap.session.beginIdle() }
        _ = try await imap.expectCommand(containing: "IDLE")
        try await imap.writeServer("+ idling")
        _ = try await idling.value

        await imap.session.close()

        let joined = imap.recordedClientLines.value.joined(separator: "\n").uppercased()
        #expect(!joined.contains("LOGOUT"))
        do {
            _ = try await imap.session.listFolders()
            Issue.record("commands after close should fail")
        } catch let error as IMAPError {
            #expect(!error.isTLS)
        }
    }
}

@Test func closeUnblocksInFlightFetchWithoutLeakingWaiter() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let fetching = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(uids: IMAPUIDSet(uid: 1), envelope: true)
            )
        }
        _ = try await imap.expectCommand(containing: "UID FETCH")
        await imap.session.close()
        do {
            _ = try await fetching.value
            Issue.record("in-flight fetch should fail when the session closes")
        } catch is CancellationError {
            // close() may cancel the send waiter
        } catch let error as IMAPError {
            #expect(!error.isTLS)
        }
    }
}

@Test func closeDuringIdleStartUnblocksContinuation() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let idling = Task { try await imap.session.beginIdle() }
        _ = try await imap.expectCommand(containing: "IDLE")
        // No "+" — close must resume idleStartWaiter rather than leak it.
        await imap.session.close()
        do {
            _ = try await idling.value
            Issue.record("beginIdle should fail when the session closes")
        } catch is CancellationError {
            // close() may cancel the idle-start waiter
        } catch let error as IMAPError {
            #expect(!error.isTLS)
        }
    }
}

@Test func parseErrorPoisonsSessionSoLaterCommandsFailFast() async throws {
    try await ScriptedIMAP.run(security: .implicitTLS) { imap in
        try await imap.connectImplicit()
        let fetching = Task {
            try await imap.session.fetch(
                IMAPFetchRequest(uids: IMAPUIDSet(uid: 1), envelope: true)
            )
        }
        _ = try await imap.expectCommand(containing: "UID FETCH")
        do {
            try await imap.writeServer("this is not IMAP")
        } catch {
            // NIOIMAP throws at writeInbound; ResponseCollector.errorCaught still runs.
        }
        do {
            _ = try await fetching.value
            Issue.record("fetch should fail when the decoder dies")
        } catch is CancellationError {
            // waiter may be cancelled as the reader ends
        } catch let error as IMAPError {
            #expect(!error.isTLS)
        }
        do {
            _ = try await imap.session.listFolders()
            Issue.record("commands after parser death should fail fast")
        } catch is CancellationError {
        } catch let error as IMAPError {
            #expect(!error.isTLS)
        }
    }
}
