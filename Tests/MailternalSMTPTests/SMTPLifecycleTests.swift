import Testing
@testable import MailternalSMTP

@Test func failedReplyInboxWakesAnAwaitingCommand() async {
    let inbox = SMTPReplyInbox()
    let waiter = Task {
        do {
            _ = try await inbox.next()
            return false
        } catch let error as SMTPWireError {
            if case .connectionClosed = error { return true }
            return false
        } catch {
            return false
        }
    }
    await Task.yield()
    inbox.fail(SMTPWireError.connectionClosed)
    #expect(await waiter.value)
}

@Test func cancellationWakesAnAwaitingReplyWithoutLeakingTheContinuation() async {
    let inbox = SMTPReplyInbox()
    let waiter = Task {
        do {
            _ = try await inbox.next()
            return false
        } catch let error as SMTPWireError {
            if case .cancelled = error { return true }
            return false
        } catch {
            return false
        }
    }
    await Task.yield()
    waiter.cancel()
    #expect(await waiter.value)
}
