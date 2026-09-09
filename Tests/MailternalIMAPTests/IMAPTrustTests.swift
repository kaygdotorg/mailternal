import Foundation
import Testing
@testable import MailternalIMAP

/// Explicit trust roots are process-wide; admission checks must not overlap.
@Suite(.serialized)
struct IMAPTrustAdmissionTests {
    @Test func ipEndpointsFailClosedWithoutExplicitTrust() throws {
        IMAPSession.resetAdditionalTrustRoots()
        defer { IMAPSession.resetAdditionalTrustRoots() }
        for hostname in ["127.0.0.1", "[::1]"] {
            do {
                _ = try IMAPTLS.makeClientHandler(hostname: hostname)
                Issue.record("An IP endpoint was admitted without explicit QA trust.")
            } catch let failure as IMAPError {
                #expect(failure.isTLS)
            }
        }
    }

    @Test func malformedQARootsCannotAdmitLoopbackTransport() throws {
        defer { IMAPSession.resetAdditionalTrustRoots() }
        for pem in [Data(), Data("not-a-certificate".utf8)] {
            IMAPSession.installAdditionalTrustRoots(pem: [pem])
            do {
                _ = try IMAPTLS.makeClientContext(hostname: "127.0.0.1")
                Issue.record("Malformed explicit trust admitted a QA transport.")
            } catch let failure as IMAPError {
                #expect(failure.isTLS)
            }
        }
    }
}
