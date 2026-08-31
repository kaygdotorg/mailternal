# Mailternal — Push Architecture Spec (ships 0.0.3)

macOS needs none of this: a running Mac app holds its own IDLE connection and posts
local notifications. This subsystem exists because iOS cannot keep an IMAP connection
alive in the background.

## Components
1. **`mailternald`** — self-hostable daemon (Swift/SwiftNIO; static musl Linux binary
   + macOS binary). Watches mailboxes, decides "wake this device," relays through the
   gateway. Optional: the apps are fully functional without it (iOS falls back to
   Background App Refresh, best-effort).
2. **APNs gateway** — a tiny minimal-state relay run by us; the only holder of the Apple
   developer key. Accepts authorized wake requests from any mailternald (ours or
   self-hosted) and forwards to APNs. Sees device tokens and timing; never mail
   content, never credentials.
3. **Notification Service Extension (NSE)** — on device; receives the wake, fetches
   the delta from IMAP directly, rewrites the notification content locally.

## APNs payload (what actually invokes an NSE)
A silent `content-available` push does **not** run an NSE. The wake is therefore a
**visible generic alert** — `{"aps":{"alert":{"title":"New mail"},"mutable-content":1}}`
plus an encrypted opaque hint field — and the NSE replaces the text after its IMAP
fetch. On NSE timeout (~30 s budget) the system delivers the original generic alert
automatically: the fallback is built in, and APNs still carries zero mail content.

## Security posture (pragmatic, honest)
- For IMAP/iCloud, mailternald **must hold account credentials** to IDLE. Policy: it
  issues no `FETCH` for message content, ever; it learns only mailbox-changed events.
- Claim, exactly: *"Pushes contain no mail content, and the daemon does not fetch or
  store messages. Because it holds IMAP credentials, a compromised daemon could
  access the account — self-host it if that matters to you."* The words "cannot read
  your mail" are reserved for the JMAP relay below, where they are true.
- **Fastmail/JMAP (later)**: RFC 8620 `PushSubscription` + RFC 8291 encryption —
  Fastmail pushes an encrypted state blob straight to mailternald, which relays it
  blindly. Zero credentials held; genuinely zero-knowledge.
- Gmail (later, post-CASA): Pub/Sub watch with a metadata-scoped OAuth token.

## Credential storage in the daemon
- macOS daemon: Keychain.
- Linux daemon: envelope encryption — a **provisioned master key** (protected file /
  fd / container secret / supported secret manager; never beside the database),
  per-account AEAD data keys, key rotation supported. The daemon **refuses to serve
  while locked or when the master key is unavailable**: no account data key is
  decrypted and no IMAP connection is attempted until the master key has been
  supplied successfully.
- Logs and crash reports never contain credentials or IMAP literals.

## Registration & authorization (device ⇄ daemon ⇄ gateway)
- The device obtains a random **gateway capability token** scoped to
  `(APNs token, account, device public key)` from the gateway, then delegates it to
  its chosen daemon. The APNs token itself is never authorization.
- Every wake request carries the capability; gateway enforces replay protection and
  per-device rate limits. Self-hosted daemons authenticate like any other client.
- Lifecycle: capability rotation on schedule; device removal revokes; APNs `410`
  (token gone) marks the registration dead — the daemon learns via a permanent
  error on its next wake attempt and drops the account watch; device key
  replacement re-registers.
- The gateway is **minimal-state, not stateless**: it persists capability records,
  a replay-nonce window, per-device rate counters, and the device-token registry —
  and nothing else (no mail data, no credentials, no mailbox state). Revocation and
  replay checks are authoritative against this store; rate-limit updates are atomic.
- Payloads beyond the bare wake (e.g. future JMAP blobs) are encrypted to the device
  public key; the gateway cannot distinguish wake types.

## NSE access to secrets and state (0.0.3 app design constraint)
- Credentials in a **Keychain access group** shared app⇄NSE.
- GRDB store + attachment cache in an **App Group container**.
- NSE uses the same single-writer transactional sync path with a cross-process busy
  timeout; strict work/memory budget (NSE memory cap is low); on interruption it
  persists a handoff cursor so the main app finishes the delta without duplicate
  notifications.

## Failure modes
- NSE fetch timeout → system shows the generic "New mail" alert (automatic).
- Credential revocation (password change) → daemon marks account failed, sends a
  flagged wake; app surfaces re-auth.
- Gateway down → daemon queues briefly, drops after TTL; iOS BAR remains the floor.

## Distribution
The Mac App Store constraint applies to the **apps only**. `mailternald` and the CLI
ship as signed release artifacts (static Linux binaries + notarized macOS binaries,
checksummed) and a container image; self-hosters may also build from source (AGPL).
The MAS app never installs or launches a privileged daemon.
