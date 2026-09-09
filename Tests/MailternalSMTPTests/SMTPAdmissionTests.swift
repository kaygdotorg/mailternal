import MailternalInterfaces
import Testing
@testable import MailternalSMTP

@Test func rejectsIPLiteralBeforeOpeningAnSMTPConnection() async {
    let client = SMTPClient(timeout: .milliseconds(100))
    let configuration = SMTPConfiguration(
        host: "127.0.0.1",
        port: 465,
        security: .implicitTLS,
        username: "user"
    )
    do {
        try await client.validate(configuration: configuration, password: "secret")
        Issue.record("an IP literal must not bypass hostname verification")
    } catch let error as SMTPSubmissionError {
        switch error.kind {
        case .configuration:
            break
        default:
            Issue.record("expected configuration rejection, got \(error.kind.rawValue)")
        }
    } catch {
        Issue.record("expected SMTPSubmissionError")
    }
}

@Test func rejectsNULCredentialsBeforeAUTH() async {
    let client = SMTPClient(timeout: .milliseconds(100))
    let configuration = SMTPConfiguration(
        host: "smtp.example.test",
        port: 465,
        security: .implicitTLS,
        username: "user"
    )
    do {
        try await client.validate(configuration: configuration, password: "bad\0secret")
        Issue.record("NUL credentials must be rejected before AUTH")
    } catch let error as SMTPSubmissionError {
        switch error.kind {
        case .configuration:
            break
        default:
            Issue.record("expected configuration rejection, got \(error.kind.rawValue)")
        }
    } catch {
        Issue.record("expected SMTPSubmissionError")
    }
}
