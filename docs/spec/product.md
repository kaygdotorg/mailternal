# Mailternal — Product Spec

## What
A first-class Apple-native mail client for macOS and iOS/iPadOS, plus a CLI and a
self-hostable push daemon (`mailternald`). No other platforms, ever.

Top priorities, in order: **performance, aesthetics, polish**. Mailternal follows the
design language captured in `docs/spec/design.md` (derived from Hermternal); when in
doubt about how anything should look or feel, `design.md` is the sole authority.

## Audience
Shippable product for arbitrary users — not a personal tool. Architecture must not
foreclose multi-tenancy of the hosted push service.

## License & monetization
- **License**: AGPLv3. Genuinely open source. Forks may self-host `mailternald` with
  their own Apple developer key; this is accepted, not fought.
- **Monetization** (post-0.1, not implemented before): paid app; a **lifetime purchase**
  unlocks everything, including self-hosting. Everything free while the product is
  unproven.
- **Distribution**: apps are Mac App Store / App Store only (sandboxed,
  `com.apple.security.network.client`); no direct app downloads. The sandboxed app
  reaches a same-Mac `mailternald` over localhost TCP but never installs or launches
  it. `mailternald` and the CLI are exempt from MAS-only: signed release artifacts +
  container image, or build-from-source (see push.md).

## Platform minimums
iOS/iPadOS 26, macOS 26. **SwiftUI-first, with the explicit AppKit seams mandated in
design.md** (window shell, settings split view, virtualized message list). Where the
two documents appear to conflict, design.md governs UI architecture.

## Account scope
- v0.0.1: exactly **one IMAP account**.
- Providers: generic IMAP, iCloud and Fastmail via app-specific passwords
  (setup presets with guidance).
- **Gmail** (M4, required on macOS, iOS and CLI): **App Password** is the default,
  guided path (2-Step Verification required; deep link to Google's page, paste
  field); **bring-your-own OAuth client** (user's own Google Cloud client id, PKCE,
  loopback redirect) is the advanced path. No Mailternal-owned client id and no CASA
  assessment until revenue justifies the annual fee. Never a web-session/scraping
  path (blocked by Google since 2021; it killed Mailplane). Exchange: never.
- Account setup: manual host/port/TLS entry + provider presets (a plist, not a
  discovery subsystem). Full Thunderbird-autoconfig/RFC 6186 later.
- **SMTP is collected only with the composer milestone (M5)**; presets may carry
  dormant non-secret SMTP defaults until then.
- **Transport**: implicit TLS or mandatory STARTTLS with hostname + system-trust
  validation; no insecure fallback, no plaintext auth outside TLS; capabilities
  re-fetched after STARTTLS and after auth. The Linux core enforces the same rules
  independently of App Transport Security. Certificate/auth failures get explicit,
  cancelable error UX.
- **Secrets live in the Keychain**, never in SQLite.

## App surface (macOS first; iOS in M6)
Screens: folder sidebar → flat chronological message list per folder (configurable
swipe actions, Settings → Actions → Gestures) → reader as three floating islands
(subject / expandable headers / body) → account setup. No threading in 0.0.1.

- **Mutations**: seen, unseen, flagged/unflagged, archive, trash — all through
  persisted optimistic queues (sync.md). **No sending until M5.**
- **Full-text search** over the entire synced history, offline, instant (FTS5).
  Windowed/degraded sync states disclose "search covers mail since <date>".
- HTML mail in `WKWebView`: **remote images blocked by default** (notice shown only
  when the message references remote content), inline `cid:` parts always shown,
  Email Reading mode Original/Dark with an opaque canvas, plain-text fallback.
- Live updates via in-app IMAP IDLE + macOS local notifications (no daemon needed on
  macOS). Notifications fire only for post-activation mail — never from backfill
  (baseline rule in sync.md).
- Initial sync UX: app is live immediately; newest mail readable within seconds;
  per-folder backfill progress in the sidebar; backfill continues in background.

## Non-goals for 0.0.1
Threading, multi-account, unified inbox, rules/snooze/send-later, JMAP, monetization,
a Mailternal-owned Gmail OAuth client. The CLI, iOS and the daemon are **in** 0.0.1
(roadmap.md); the CLI and automation architecture are specified in `cli.md`,
`automation.md`, `pairing.md`, `docs.md`.

## Engineering ground rules
- Swift everywhere: one core package `MailternalCore` shared by apps, CLI, daemon.
- Core must build and test on Linux (CI) and macOS. Daemon networking is SwiftNIO —
  never `URLSession` on Linux. Static musl Linux binaries for daemon/CLI with a
  **pinned toolchain**.
- SQLite + FTS5 via GRDB in every surface.
- Debug harness: a private, unshipped `mailternal-debug` executable may exist from day
  one to exercise the sync engine headlessly. It is not a stable surface.
