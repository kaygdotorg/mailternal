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
  accounts, windows and focused surface, selected account/folder/messages, folder
  counts, current list page, reader tabs/active tab/reading position, visible search
  query/results, composer drafts, settings, presented dialogs/available actions,
  sync/outbox/error state. Mail remains store-owned; transient GUI state has explicit
  ownership in AppModel rather than hidden view-local state. Credentials are never
  serialized; message/draft content has structured queries rather than duplication
  in every GUI-state event.
- `Command` (Codable, `CaseIterable` names) covers every current in-app action:
  account lifecycle, folder selection/rename/retention, list paging and
  multi-selection, visible search, read/unread, flag, archive/trash/arbitrary moves,
  undo, refresh, settings, reader tabs/windows and reading position, dialogs, and
  the composer lifecycle with SMTP. Stable identities address targets; pixel
  coordinates and accessibility-tree scraping are not the automation interface.
  A new command requires both CLI dispatch and application handling through
  exhaustive switches; no in-app workflow may remain GUI-only.
- The CLI's ordinary mail queries/commands and its explicit `ui` control namespace
  are separate observable contracts, backed by the same runtime. Ordinary mail
  operations must not implicitly navigate/focus the GUI or alter its tabs/visible
  composer. Store mutations naturally update displayed mail data. Explicit UI
  commands may change the requested GUI state.
- Agents can query current GUI state and subscribe to an initial versioned snapshot
  followed by ordered changes. A subscription gap or reconnect requires a fresh
  snapshot, so stale context is detectable. No computer-use loop is required for
  state discovery or control.
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
Exactly **one engine-owning runtime process per container** at any time, enforced
by a lock file; that process may own multiple per-account engines. Precedence:
running app > headless daemon (`mailternal engine start`) > per-invocation CLI
runtime. A CLI invocation that finds a live socket uses it instead of opening a
competing runtime. Otherwise cached reads may open the store directly; operations
requiring the network, including raw-source fetch and SMTP, use the same headless
runtime and persisted queues. Routing through the app does not imply GUI control.

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
