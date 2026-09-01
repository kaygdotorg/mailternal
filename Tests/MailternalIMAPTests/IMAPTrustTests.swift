import Foundation
import Testing
@testable import MailternalIMAP

/// Extra trust roots are process-wide; these two cases must not overlap.
@Suite(.serialized)
struct IMAPTrustIPLiteralTests {
    @Test func ipLiteralWithoutQATrustRootsIsRefused() throws {
        IMAPSession.resetAdditionalTrustRoots()
        defer { IMAPSession.resetAdditionalTrustRoots() }

        let expected = IMAPError.tls("Connect using a hostname, not an IP address.")
        #expect(throws: expected) {
            _ = try IMAPTLS.makeClientHandler(hostname: "127.0.0.1")
        }
        #expect(throws: expected) {
            _ = try IMAPTLS.makeClientHandler(hostname: "8.8.8.8")
        }
        #expect(throws: expected) {
            _ = try IMAPTLS.makeClientHandler(hostname: "::1")
        }
        #expect(throws: expected) {
            _ = try IMAPTLS.makeClientHandler(hostname: "[::1]")
        }

        // DNS hostnames still build a verifying handler (no network).
        _ = try IMAPTLS.makeClientHandler(hostname: "imap.example.com")
        #expect(IMAPTrust.sniHostname(for: "imap.example.com") == "imap.example.com")
        #expect(IMAPTrust.sniHostname(for: "127.0.0.1") == nil)
    }

    @Test func ipLiteralAllowedWhenQATrustRootsInstalled() throws {
        IMAPSession.resetAdditionalTrustRoots()
        defer { IMAPSession.resetAdditionalTrustRoots() }

        IMAPSession.installAdditionalTrustRoots(pem: [Data(qaLeafPEM.utf8)])
        #expect(IMAPTrust.additionalTrustRootsInstalled)

        // QA 127.0.0.1 path: extras present, handler builds, SNI still omitted.
        _ = try IMAPTLS.makeClientHandler(hostname: "127.0.0.1")
        #expect(IMAPTrust.sniHostname(for: "127.0.0.1") == nil)
        _ = try IMAPTLS.makeClientHandler(hostname: "::1")
    }
}

/// Any parseable leaf is enough: handler creation does not handshake.
private let qaLeafPEM = """
-----BEGIN CERTIFICATE-----
MIIDFTCCAf2gAwIBAgIUJSSM6zTe2C83s+79PHmuNWSlA60wDQYJKoZIhvcNAQEL
BQAwGjEYMBYGA1UEAwwPbWFpbHRlcm5hbC50ZXN0MB4XDTI2MDkwMTA3MTY0MFoX
DTI2MDkwMjA3MTY0MFowGjEYMBYGA1UEAwwPbWFpbHRlcm5hbC50ZXN0MIIBIjAN
BgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqtisWOVEhh/fkwr8CLuRX43I/Dlk
cSEPLnTLgwBaCCqdQwGKOfxp15U9OlrQLRT8XPlaIBvLOQ5Ri3IQRCA22LJ15+xr
Lod/N2/8dGxbJVFm73o7i919A5UPhz6zQkiyTLzcACOyaUxGZ5DfCcL0/i5dtn1Z
13CTRvesyM90olEMSnxzWXD2EoRzKWsICIuCngJUqDBudPMhOl44DMTcXoBPbSUb
KEfeXgTY3zLxQ/b+PxQUnzO7LoH01Jr6r0NLXm972gOByOu9BhHHu4zv42HNCibg
jpnLRKD4x+CwgC5Xc8vTQ0b9Kxwp+Z65n7JlGs2pdwrqUVLYj2tu8YyJ4QIDAQAB
o1MwUTAdBgNVHQ4EFgQU6uYwMVDLYfI1CgxSZG+rnu4Ii/0wHwYDVR0jBBgwFoAU
6uYwMVDLYfI1CgxSZG+rnu4Ii/0wDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0B
AQsFAAOCAQEAOt8DGjO6DFxEksG7XCBdB91kQh4JFZuPhNwgSyMnwhULdfIDKn2F
AdexplN+JslH9nfkFxyHHK9rpHk4vodjgl/Rl67xTYSKSATbHF34n8CqIrHp9vGF
SbUXM86BOIfbBlMRsq7KzUwiD8CsaKiy6ZJM7x/D4aK+itouao9fYKpalZrED1uq
I2j+r/qAm5F1a+Z+KZYShPESJs3w2z9KWhfmPLFMKrjKSNZfdioK6ao18A1MSMsj
KNxTxWNmC+znFxoWhrAisNjc631xL45nnaeuLdL32YWBlul6wWqQWCxTH849lsMC
zK+5QiM3SuHOOMiblKel6JXsR6iq6kPh1g==
-----END CERTIFICATE-----
"""
