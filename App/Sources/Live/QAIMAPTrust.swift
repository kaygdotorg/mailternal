import Foundation
import MailternalIMAP

/// Loads the seeded Dovecot self-signed cert when `MAILTERNAL_QA=1`.
enum QAIMAPTrust {
    static func installIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["MAILTERNAL_QA"] == "1" || QALaunch.parse() != nil else { return }
        do {
            try install()
        } catch {
            QALaunch.log("QA cert install failed: \(error)")
        }
    }

    /// Throws if the QA cert cannot be loaded. Used by the smoke test.
    static func install() throws {
        let environment = ProcessInfo.processInfo.environment
        #if os(macOS)
        let path = environment["MAILTERNAL_QA_CERT"]
            ?? NSHomeDirectory() + "/mailternal-qa/certs/dovecot.crt"
        #else
        // An iOS app cannot read the macOS QA fixture under the user's home
        // directory. Device/simulator QA must provide an explicit fixture URL.
        guard let path = environment["MAILTERNAL_QA_CERT"], !path.isEmpty else {
            throw LiveMailError("MAILTERNAL_QA_CERT is required for iOS QA.")
        }
        #endif
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw LiveMailError("QA certificate at \(path) is empty.")
        }
        IMAPSession.installAdditionalTrustRoots(pem: [data])
        QALaunch.log("installed QA trust root path=\(path) bytes=\(data.count)")
    }
}
