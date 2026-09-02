# Mailternal — Pairing & Credential Handoff Spec

One mechanism moves accounts, credentials, settings and remote-access grants between
any two surfaces: macOS ↔ macOS, macOS ↔ iOS, iOS ↔ iOS, any Apple app ↔ CLI.

## Pairing bundle
Versioned, encrypted JSON (`schema: "mailternal.pairing.v1"`): account config,
credentials (app password or OAuth refresh token), user settings, optionally the
remote-listener grant (host, certificate fingerprint, bearer token). Small enough
(< 3 KB) to travel offline.

## Handshake — direction-free
The QR code is a **pairing handshake**, not the payload: it carries a one-time
session key and a rendezvous (Bonjour service name on the LAN, or the remote listener
address). Once paired, either side may push or pull over the encrypted channel, so
every flow works:
- scan on iOS to *receive* everything from a Mac;
- scan on iOS to *send* everything to a freshly installed Mac;
- Mac scans Mac / iOS (camera present);
- CLI has no camera: it prints an ASCII QR (`pair --show`) for a phone to scan, or
  accepts a **short pairing code** (8 words) typed from the sender; the code derives
  the channel key via a PAKE so the code itself never travels.

Both apps get a Pairing screen with "Show code" and "Scan code". Same iCloud account
on both Apple devices → iCloud Keychain (`kSecAttrSynchronizable`) syncs the item and
no pairing is needed; the bundled CLI reads the same Keychain item through a shared
access group (signed with the app's Team ID).

## Fallbacks
- Offline: the whole bundle *in* the QR (fits) or `account export` → passphrase-
  encrypted file → `account import`.
- Linux CLI: import lands in the 0600 secrets file (`cli.md`).

## Security invariants
- Bundles are encrypted end-to-end with the session/PAKE key; relays (if any) see
  ciphertext only.
- Session keys are single-use and expire in minutes; QR display auto-expires.
- The remote-listener grant is per client and revocable from the Mac.
