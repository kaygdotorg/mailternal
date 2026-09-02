# Mailternal — Automation Architecture Spec

Why this exists: an app that needs a human at the keyboard is not automatable by
agents. Every fact the app knows and every action a user can take must be reachable
by a program, live, without a UI. The CLI (`cli.md`) is the first client of this
architecture; the iOS app and `mailternald` are the next.

## One state document, one command log
The app's user-visible state is a single serializable **state document** owned by
`AppModel` and mutated only through a Codable **`Command`** enum. SwiftUI views
dispatch commands; the CLI sends the same commands over IPC; both read the same
snapshot.

- State document (`AppState`, Codable, versioned `schema: "mailternal.state.v1"`):
  accounts, selected account/folder/message, folder list with counts, the current
  list page, open composer drafts (when the composer exists — its document shape is
  designed *before* its UI), search text, sync status, settings that affect the UI.
  Everything in it is derivable from the store plus UI selection; it is never the
  source of truth for mail.
- `Command` (Codable, `CaseIterable` names): `select(folder|message|account)`,
  `page(next|previous)`, `search(text)`, `mark(link, read|unread)`,
  `flag(link, on|off)`, `archive(link)`, `trash(link)`, `undo`, `refresh`,
  `settings.set(key, value)`, `composer.*` (later). A new `Command` case without a
  CLI verb and a state-document effect is a compile error (exhaustive `switch` in the
  CLI's command table and in `AppModel.apply`).
- **Performance is a gate, not a hope** (`perf/baselines.json`, CI job): warm launch
  to all-folders ≤ 0.5 s, search p95 ≤ 5 ms, first list page ≤ 50 ms, idle footprint
  ≤ 30 MB, command dispatch overhead ≤ 1 ms. Snapshots are built on demand, never on
  every keystroke. The refactor touches `AppModel` and views only — never the
  store/sync hot paths (keyset paging, FTS rowid order, GRDB writer off-main).
  Loosening a threshold requires a DECISIONS.md entry.

## Message identity
A message is addressed everywhere by its **deep link**:
`mailternal://open/v1/account/<AccountLinkID>/folder/<kind>/<locator>/message/<uidvalidity>/<uid>`.
`AccountLinkID` is a random UUID minted at account creation and synced with the
account's non-secret metadata, so one account has one id on every device; the folder
locator is the server's stable mailbox object id when advertised, else the path;
IMAP's UIDVALIDITY/UID is the message identity. Non-secret, cross-device, printed as
`link` on every CLI row; the Int64 store id is accepted as a local shortcut only.

## IPC
- **Transport**: a Unix domain socket inside the app container (`mailternal.sock`),
  newline-delimited JSON: request/response plus subscription streams (state changes,
  new mail). Auth: socket mode 0600 plus a per-launch token file next to it. The same
  wire protocol is what `mailternald` speaks later; XPC is not used (macOS-only, and
  it cannot serve the daemon).
- **Remote access** (user-enabled, default off): the app can expose the same protocol
  on a TCP listener bound to a chosen interface — the Tailscale/NetBird address by
  default, never `0.0.0.0` unless explicitly chosen. TLS with an app-generated
  self-signed certificate plus a per-client bearer token; the client learns host,
  certificate fingerprint and token only through **pairing** (`pairing.md`), never by
  typing. Tailscale is transport, not auth: a hostile tailnet node must still fail.
  SSH (`mailternal --host user@mac`, which runs the Mac-side CLI over `ssh` and pipes
  JSON) remains the zero-config alternative. Credentials never leave the Mac in either
  mode.

## Engine ownership
Exactly **one sync engine per container** at any time, enforced by a lock file in the
container. Precedence: running app > headless daemon (`mailternal engine start`) >
per-invocation CLI engine. A CLI invocation that finds a live socket always uses it
instead of opening the store; otherwise reads open the store directly (no engine) and
mutations start an engine, drain the queues, and exit.

## Undo journal
An `op_journal` table in the store records each user mutation with its inverse
(move back, flag toggle); last 50 ops, no TTL. ⌘Z in the app and `mailternal undo`
consume the same journal, whichever surface performed the op. Ops that are
irreversible on the server (a completed EXPUNGE) are refused with a clear error rather
than pretended.

## Settings
`settings list|get|set <key> [value]` use the same keys as UserDefaults
(`appearance.email-reading`, `actions.swipe.trailing`, …). With the app running the
change is a `Command` so the UI updates live; without it, values are written through
CFPreferences for the app's bundle id (cfprefsd-safe), never by touching the plist.
