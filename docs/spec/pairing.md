# Mailternal — Pairing & Credential Handoff Spec

One mechanism moves accounts, credentials, settings and remote-access grants between
any two surfaces: macOS ↔ macOS, macOS ↔ iOS, iOS ↔ iOS, any Apple app ↔ CLI.

## Delivery status

The macOS and iOS development targets include authenticated LAN pairing and
offline encrypted-file transfer. Device installation, provisioning, and live
account connection/reading remain release gates; a successful compile is not
device-workflow verification.

On both native apps, open **Settings → Sync → Pair Device**. The first
user-facing flow is **Show code** on the Mac and **Scan code** on the iPhone,
followed by an explicit choice of accounts and confirmation before importing
configuration or credentials. The channel remains direction-free as specified
below. Pair Device remains available when iCloud workspace sync is off.

Each new QR invitation appears with one brief pixel-grid reveal; the final code
is stationary and unmodified, with its white quiet zone preserved. Reduce Motion
shows the complete code immediately. See `design.md` for the motion contract.

Pairing transfers account setup and credentials; it is not ongoing mailbox
synchronization. Mail remains synchronized through IMAP, credentials remain in
Keychain, and ongoing workspace/customization synchronization uses the separate
iCloud workspace contract in `product.md`.

## Pairing bundle
Versioned, encrypted JSON (`schema: "mailternal.pairing.v1"`): account config,
credentials (app password or OAuth refresh token), user settings, optionally the
remote-listener grant (host, certificate fingerprint, bearer token). Native
transport and offline-file ingress enforce a 256 KiB encoded bundle limit.

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
- Offline native apps: **Export encrypted file** / **Import encrypted file** use
  an authenticated AES-GCM envelope and a separately conveyed, generated
  256-bit passphrase. Human-chosen passwords are not accepted by the HKDF-based
  file format. Import authenticates and validates before showing account and
  settings choices, then awaits the same durable import path as LAN pairing.
  A local import does not send a network acknowledgement.
- The CLI `account export` / `account import` fallback and whole-bundle QR
  representation remain separate CLI delivery work.
- Linux CLI: import lands in the 0600 secrets file (`cli.md`).

## Security invariants
- Bundles are encrypted end-to-end with the session/PAKE key; relays (if any) see
  ciphertext only.
- Session keys are single-use and expire in minutes; QR display auto-expires.
- The remote-listener grant is per client and revocable from the Mac.

Account identity adoption is recoverable: SQLite records the old/new canonical
identity in the same transaction that relinks the account. Startup and import
completion replay pending workspace and reader-link remaps before acknowledging
success. Replays preserve already-migrated settings; unreadable ancillary reader
snapshots are quarantined rather than blocking account startup indefinitely.
