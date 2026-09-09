import Foundation
import Testing
import MailternalAutomation
import MailternalInterfaces

struct CommandContractTests {
    @Test func searchRetainsItsExplicitLimitAcrossTheWire() throws {
        let command = Command.search("subject:invoice", 17)
        #expect(try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command)) == command)
    }

    @Test func readerCommandsRetainTargetsAndParametersAcrossTheWire() throws {
        let reference = MessageReference.local(MessageID(rawValue: 84))
        let tab = UUID()
        let commands: [Command] = [
            .openMessage(reference, permanent: true), .openWindow(reference),
            .activateTab(tab), .closeTab(tab), .closeOthers(tab),
            .closeToRight(tab), .keepTab(tab), .moveTab(tab, 7),
            .fetchAttachment(reference, "2.1")
        ]
        for command in commands {
            #expect(try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(command)) == command)
        }
    }

    @Test func takeoverReloadPreservesThePreviousOwnersFinalRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("commands.json")
        let previousOwner = CommandJournal(fileURL: path)
        let nextOwner = CommandJournal(fileURL: path)
        let first = try await previousOwner.append(origin: .localCLI, action: "mail.refresh")
        try await previousOwner.complete(first.id)
        try await nextOwner.reload()
        let second = try await nextOwner.append(origin: .app, action: "ui.sidebar.toggle")
        let disk = try await CommandJournal(fileURL: path).snapshot()
        #expect(disk.map(\.id) == [first.id, second.id])
        #expect(disk.first?.status == .completed)
    }
}
