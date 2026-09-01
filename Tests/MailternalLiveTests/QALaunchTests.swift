#if os(macOS)
import Foundation
import MailternalInterfaces
import Testing
@testable import MailternalLive

@Test func qaLaunchParsesHostPortSecurityAndFlags() {
    let parsed = QALaunch.parse(
        arguments: [
            "Mailternal",
            "-qa-account", "127.0.0.1", "2143", "startTLS",
            "-qa-container", "/tmp/mailternal-qa-data",
            "-qa-cache-cap", "4096",
            "-qa-bench-search",
            "-qa-fetch-cid",
        ],
        environment: [
            "MAILTERNAL_QA_USER": "qa@mailternal.test",
            "MAILTERNAL_QA_PASSWORD": "secret",
        ]
    )
    #expect(parsed != nil)
    #expect(parsed?.host == "127.0.0.1")
    #expect(parsed?.port == 2143)
    #expect(parsed?.security == .startTLS)
    #expect(parsed?.cacheCap == 4096)
    #expect(parsed?.benchSearch == true)
    #expect(parsed?.fetchCID == true)
    #expect(parsed?.username == "qa@mailternal.test")
    #expect(parsed?.password == "secret")
    #expect(parsed?.accountID.rawValue == "qa-127.0.0.1-2143")
    #expect(parsed?.containerRoot.path == "/tmp/mailternal-qa-data")
}

@Test func qaLaunchIgnoresIncompleteAccountArgs() {
    #expect(
        QALaunch.parse(arguments: ["Mailternal", "-qa-account", "127.0.0.1"], environment: [:]) == nil
    )
    #expect(QALaunch.parse(arguments: ["Mailternal", "-mock"], environment: [:]) == nil)
}

@Test func qaLaunchAcceptsImplicitTLSAlias() {
    let parsed = QALaunch.parse(
        arguments: ["Mailternal", "-qa-account", "127.0.0.1", "1993", "implicitTLS"],
        environment: [:]
    )
    #expect(parsed?.security == .implicitTLS)
    #expect(parsed?.port == 1993)
    #expect(parsed?.password == "qa-password")
}

@Test func qaLaunchFootprintIsReadable() {
    #expect(QALaunch.footprintBytes() > 0)
}
#endif
