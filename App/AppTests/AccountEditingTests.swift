import XCTest
import MailternalInterfaces

@MainActor
final class AccountEditingTests: XCTestCase {
    func testDisplayNameOnlyUpdateSkipsValidationAndPersistsConfig() async throws {
        let facade = MockMailFacade()
        let original = accountConfig(displayName: "Original")
        try await facade.addAccount(original, password: "password")
        facade.resetValidationCallCount()

        var edited = original
        edited.displayName = "Renamed"
        try await facade.updateAccount(edited, password: nil)

        XCTAssertEqual(facade.validationCallCount, 0)
        XCTAssertEqual(facade.accountConfig?.displayName, "Renamed")
    }

    func testHostUpdateValidatesExactlyOnce() async throws {
        let facade = MockMailFacade()
        let original = accountConfig()
        try await facade.addAccount(original, password: "password")
        facade.resetValidationCallCount()

        var edited = original
        edited.imap.host = "updated.mock.local"
        try await facade.updateAccount(edited, password: nil)

        XCTAssertEqual(facade.validationCallCount, 1)
        XCTAssertEqual(facade.accountConfig?.imap.host, "updated.mock.local")
    }

    func testAccountTitleFallsBackToEmailForEmptyDisplayName() async throws {
        let facade = MockMailFacade()
        let config = accountConfig(displayName: "")
        try await facade.addAccount(config, password: "password")

        XCTAssertEqual(AccountTitlePolicy.title(for: facade.accountConfig), config.emailAddress)
        XCTAssertEqual(facade.accountDisplayName, config.emailAddress)
    }

    private func accountConfig(displayName: String = "Account") -> AccountConfig {
        AccountConfig(
            id: AccountID(rawValue: "account-editing-test"),
            accountLinkID: .random(),
            displayName: displayName,
            emailAddress: "account@example.test",
            username: "account@example.test",
            imap: IMAPEndpoint(host: "mock.local", port: 993, security: .implicitTLS)
        )
    }
}
