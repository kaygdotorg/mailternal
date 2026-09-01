import Testing
@testable import MailternalSanitizer

@Test("compile success installs the fence")
func fenceStateCompiledList() {
    #expect(HTMLIsolationFence.state(compiledList: true) == .installed)
}

@Test("compile nil/failure is fail-closed, never installed")
func fenceStateMissingListIsFailed() {
    #expect(HTMLIsolationFence.state(compiledList: false) == .failed)
    #expect(HTMLIsolationFence.state(compiledList: false) != .installed)
}

@Test("decision table: wait / load / refuse")
func fenceDecisionTable() {
    #expect(HTMLIsolationFence.decision(for: .compiling) == .waitForFence)
    #expect(HTMLIsolationFence.decision(for: .installed) == .loadHTML)
    #expect(HTMLIsolationFence.decision(for: .failed) == .refuseHTML)
}

@Test("failed compile never yields loadHTML")
func failedFenceNeverLoadsHTML() {
    let fence = HTMLIsolationFence.state(compiledList: false)
    #expect(HTMLIsolationFence.decision(for: fence) == .refuseHTML)
    #expect(HTMLIsolationFence.decision(for: fence) != .loadHTML)
}

@Test("pending compile never yields loadHTML")
func compilingFenceNeverLoadsHTML() {
    #expect(HTMLIsolationFence.decision(for: .compiling) != .loadHTML)
}
