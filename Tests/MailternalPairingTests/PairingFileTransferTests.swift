#if os(macOS) && canImport(CryptoKit)
import Foundation
import CryptoKit
import MailternalInterfaces
import MailternalPairing
import MailternalWorkspace
import Testing

@Suite(.serialized)
struct PairingFileTransferTests {
    @Test
    func generatedPassphraseRoundTripsEncryptedBundle() throws {
        let expected = fixtureBundle()
        let passphrase = try PairingFileTransfer.makePassphrase()
        #expect(passphrase.utf8.count == PairingFileTransfer.generatedPassphraseLength)

        let encrypted = try PairingFileTransfer.encrypt(expected, passphrase: passphrase)
        #expect(encrypted.count <= PairingFileTransfer.maximumFileBytes)
        #expect(encrypted.count > 16)
        let actual = try PairingFileTransfer.decrypt(encrypted, passphrase: passphrase)
        #expect(bundleMatches(actual, expected))
    }

    @Test
    func tamperingAndWrongPassphraseNeverDecrypt() throws {
        let expected = fixtureBundle()
        let passphrase = try PairingFileTransfer.makePassphrase()
        var encrypted = try PairingFileTransfer.encrypt(expected, passphrase: passphrase)
        encrypted[encrypted.index(encrypted.startIndex, offsetBy: 45)] ^= 0x01

        #expect(throws: PairingFileTransferError.authenticationFailed) {
            try PairingFileTransfer.decrypt(encrypted, passphrase: passphrase)
        }
        #expect(throws: PairingFileTransferError.authenticationFailed) {
            try PairingFileTransfer.decrypt(
                try PairingFileTransfer.encrypt(expected, passphrase: passphrase),
                passphrase: try PairingFileTransfer.makePassphrase()
            )
        }
    }
}

private func fixtureBundle() -> PairingBundle {
    let account = AccountConfig(
        id: AccountID(rawValue: "offline-pairing-account"),
        accountLinkID: AccountLinkID(
            rawValue: UUID(uuidString: "10111213-1415-4617-9819-1a1b1c1d1e1f")!
        ),
        displayName: "Offline fixture account",
        emailAddress: "offline@mailternal.test",
        username: "offline",
        imap: IMAPEndpoint(host: "imap.fixture.test", port: 993, security: .implicitTLS),
        isEnabled: true
    )
    return PairingBundle(
        accounts: [PairingAccount(config: account, credential: "offline-fixture-credential")],
        settings: [
            "appearance.theme": .string("dark"),
            "messageList.showUnread": .bool(true)
        ]
    )
}

private func bundleMatches(_ actual: PairingBundle, _ expected: PairingBundle) -> Bool {
    guard actual.schema == expected.schema,
          actual.accounts.count == expected.accounts.count,
          actual.settings == expected.settings else {
        return false
    }
    return zip(actual.accounts, expected.accounts).allSatisfy { actualAccount, expectedAccount in
        actualAccount.config == expectedAccount.config
            && actualAccount.credential == expectedAccount.credential
    }
}
#endif
