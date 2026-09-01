import Foundation
import MailternalIMAP

/// Loads the seeded Dovecot self-signed cert when `MAILTERNAL_QA=1`.
enum QAIMAPTrust {
    static func installIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["MAILTERNAL_QA"] == "1" || QALaunch.parse() != nil else { return }
        try? install()
    }

    /// Throws if the QA cert cannot be loaded. Used by the smoke test.
    static func install() throws {
        let path = ProcessInfo.processInfo.environment["MAILTERNAL_QA_CERT"]
            ?? NSHomeDirectory() + "/mailternal-qa/certs/dovecot.crt"
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw LiveMailError("QA certificate at \(path) is empty.")
        }
        IMAPSession.installAdditionalTrustRoots(pem: [data])
    }
}
