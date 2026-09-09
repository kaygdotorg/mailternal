# Mailternal — Automation Architecture Spec

Why this exists: an app that needs a human at the keyboard is not automatable by
agents. Every fact the app knows and every action a user can take must be reachable
by a program, live, without a UI. The CLI (`cli.md`) is the first client of this
architecture; the iOS app and `mailternald` are the next.

## One state document, one command log
The app's user-visible state is a single serializable **state document** owned by
`AppModel` and mutated only through a Codable **`Command`** enum. SwiftUI views
dispatch commands; the CLI sends the same commands over IPC; both read the same
runtime state.

- State document (`AppState`, Codable, versioned `schema: "mailternal.state.v1"`):
  accounts and account state, folders, selected account/folder/messages, folder
  counts, current list page, reader tabs/active tab/reading position, visible search
  query/results, settings, presented dialogs/available actions, sync/outbox/error
  state, and the effective list configuration. Mail remains store-owned; transient
  GUI state has explicit ownership in AppModel rather than hidden view-local state.
  Credentials are never serialized, and message/draft content is obtained through
  structured queries rather than duplicated in every GUI-state event.
- The current `Command` enum covers account and folder lifecycle, list/read/triage,
  search, settings, explicit GUI/tab/window controls, pairing UI, remote
  configuration/revocation, SMTP configuration, versioned drafts, attachment
  staging, sending and outbox recovery. Stable identities address targets; pixel
  coordinates and accessibility-tree scraping are not the automation interface.
  A new command requires both CLI dispatch and application handling through
  exhaustive switches; no implemented in-app workflow may remain GUI-only.
- The CLI's ordinary mail queries/commands and its explicit `ui` control namespace
  are separate observable contracts, backed by the same runtime. Ordinary mail
  operations must not implicitly navigate/focus the GUI or alter its tabs/visible
  composer. Store mutations naturally update displayed mail data. Explicit UI
  commands may change the requested GUI state.
- Selection-dependent commands carry an observed `SelectionContext` revision.
  A stale revision is rejected rather than silently retargeted. Commands carrying
  explicit stable message IDs or links do not fail merely because GUI selection
  changed.
- Agents can query current state and subscribe to an initial versioned snapshot
  followed by ordered changes. `ui state`/`ui observe` request GUI state; ordinary
  `state`/`observe` do not. A subscription gap or reconnect requires a fresh
  snapshot, so stale context is detectable. No computer-use loop is required for
  state discovery or control.
- The wire response is `mailternal.response.v1`. A successful one-shot command
  uses a stable `mailternal.cli.result.v1` envelope:
  `{"schema":"mailternal.cli.result.v1","version":1,"ok":true,"result":…}`.
  When the decoded payload is a `CommandResult`, the envelope also includes its
  command name and optional `stateRevision`; scalar and no-payload results use
  `result` as a JSON scalar or `null`. State snapshots/events retain their
  `mailternal.state.v1` or `mailternal.event.v1` shape, and errors retain the
  typed response envelope.
- The persisted command log contains only origin, action name, target identities,
  timestamps, status, and redacted outcome metadata. It retains pending/running
  records and the latest 1,000 terminal records; secrets and command payloads are
  never replayed from this log. Mail operations recover through their store-owned
  persisted queues. A runtime reloads command metadata after acquiring the
  exclusive lease, so takeover cannot overwrite the previous owner's final
  records.
- Command completion is distinct from SMTP acceptance. If an effect has already
  been accepted but its audit or queue completion cannot be persisted, native
  clients retain a needs-review outcome rather than presenting an ordinary
  retryable failure. The composer consults the original submission in Outbox;
  Watch commands remain needs-review and are not replayed automatically.

## List configuration and workspace persistence

The effective `listConfiguration` in `AppState` combines global defaults with an
optional current-folder override. A folder scope is keyed by the stable
`AccountLinkID` and complete server folder path, not a local `FolderID`, so the
setting can follow an account across devices. The configuration contains the
cards/columns presentation, side-by-side or list-above-reader pane layout, complete
column order, visibility, widths, and sort descriptor.

The `ui list-target`, layout, presentation, column, sort, and reset commands are
GUI commands and enter the same FIFO as every other mutation. Their direct
workspace writes are awaited before command success is reported. Values are
persisted by the workspace synchronization controller (global defaults or
per-folder overrides); resetting a folder removes its override and restores global
inheritance. Column order must contain every known column exactly once and widths
must be finite and positive.

Account-scoped paired clients cannot mutate global/workspace controls. A paired
non-GUI state snapshot reports the default list configuration; a paired client
with GUI permission may observe only the explicitly account-owned GUI state.

## Performance gates and evidence

**Performance is a gate, not a claim of completion** (`perf/baselines.json`, CI
job): warm launch to all-folders ≤ 0.5 s, search p95 ≤ 5 ms, first list page
≤ 50 ms, idle footprint ≤ 30 MB, and command dispatch overhead ≤ 1 ms.
Snapshots are built on demand, never on every keystroke. The refactor touches
`AppModel` and views only — never the store/sync hot paths (keyset paging, FTS
rowid order, GRDB writer off-main). Loosening a threshold requires a
`DECISIONS.md` entry.

The only measured overnight performance improvement proven on the final migration
artifact is a legacy-schema upgrade: store-open 88,597.3 ms → 47,245.2 ms
settled (46.7% lower; one controlled legacy clone/observation). This is not
steady-state or cache-cold launch. Prior warm medians overlap concurrent build
activity and older artifacts, and are not a final API/native baseline. No reliable
continuous scroll/hitch measurement exists; final large-mailbox scrolling benefit
has not yet been established.

## Message identity
A message is addressed everywhere by its **deep link**:
`mailternal://open/v1/account/<AccountLinkID>/folder/<kind>/<locator>/message/<uidvalidity>/<uid>`.
`AccountLinkID` is a random UUID minted at account creation and synced with the
account's non-secret metadata, so one account has one id on every device; the folder
locator is the server's stable mailbox object id when advertised, else the path;
IMAP's UIDVALIDITY/UID is the message identity. Non-secret, cross-device, printed as
`link` on every CLI row; the Int64 store id is accepted as a local shortcut only.
Mapped moves use the server-returned destination UIDVALIDITY/UID; they never infer
the destination UID from the source. Cached content follows that exact identity.
When an existing destination row wins a collision, local-ID aliases preserve held
references and cascade away with the destination cache entry. Aliases do not make
an old server deep link valid in a different mailbox or UIDVALIDITY generation.

## IPC
- **Transport**: a Unix domain socket inside the app container (`mailternal.sock`),
  newline-delimited JSON: request/response plus subscription streams (state changes,
  new mail). Auth: socket mode 0600 plus a per-launch token file next to it. The same
  wire protocol is what `mailternald` speaks later; XPC is not used (macOS-only, and
  it cannot serve the daemon).
- **Remote access** (user-enabled, default off): the app can expose the same
  protocol on a TCP listener bound to a validated interface. The accepted default
  remains the Tailscale/NetBird address; `0.0.0.0`/`::` is allowed only when the
  caller explicitly opts into wildcard binding. The current CLI requires an
  explicit host in `remote enable HOST PORT`; it does not discover a Tailscale/
  NetBird address, and its simple enable path does not expose the wildcard opt-in
  and rejects wildcard hosts. These are implementation limitations, not changes
  to the accepted requirement.
- TLS uses an app-generated self-signed certificate, a per-client bearer token,
  and a pinned SHA-256 fingerprint of the certificate DER. Pairing creates a
  short-lived one-time offer and returns the host, port, client id, bearer, and
  fingerprint for the paired endpoint. The Apple listener requires Network and
  Security support plus successful local identity creation/reconstruction; when
  unavailable it fails as `tlsUnavailable`. Apple clients use Network/Security;
  Linux clients use SwiftNIO/NIOSSL with the same paired leaf pin checked before
  bearer authentication. Linux connection candidates own separate handshake
  state and are closed on cancellation. Request and handshake waits are bounded;
  an established observer may remain silent indefinitely until cancelled or
  disconnected. A saved configuration is not proof that the listener is
  reachable. The protected identity record in the app container contains the
  certificate DER, private-key data, and fingerprint. Security APIs
  generate/reconstruct a transient `SecIdentity`; no Keychain persistence is
  promised.
- One-time offer codes use the base64url alphabet. Claims ignore copied
  whitespace, but preserve hyphens and underscores as meaningful code characters.
- `remote enable|disable` and `pair --revoke UUID` are typed
  `Command.configureRemote(AutomationRemoteConfiguration)` and
  `Command.revokeAutomationClient(UUID)` operations. They are local-only,
  serialized through the runtime FIFO, and persist/reload the listener (with
  configuration rollback if reload fails). A paired bearer cannot configure or
  revoke another client. Tailscale is transport, not auth: a hostile tailnet node
  must still fail.
- Each request selects exactly one mutually exclusive operation category:
  a `command`, a `control`, or a state operation (`wantsState: true`). The
  `wantsGUIState` and `observesState` fields are state modifiers and may be
  combined with a state operation; `afterRevision` is valid only for observation.
  A command/control combined with state flags, or command combined with control,
  is rejected as a usage error before any handler or observer effect.
- `AutomationControl.remoteStatus` is a local-only transport control. Its typed
  result reports `enabled` (the persisted configuration intent), `running` (the
  listener's actual running state), `host`, and `port`; a saved configuration
  alone never implies that the listener is running.
- Admission runs only after Unix token or paired bearer authentication. The
  unauthenticated pairing claim retains its stricter shape checks and
  authorization failure semantics.
- TLS connection admission allows eight pre-authentication connections overall,
  at most two per peer. The first frame has a five-second deadline. Authenticated
  requests and observers share 32 slots, at most four per paired client. Bursts
  above the pre-authentication limit can fail before a typed protocol response.
- SSH (`mailternal --host user@mac`, which runs the Mac-side CLI over `ssh` and
  pipes JSON) remains the zero-config alternative. Credentials never leave the
  Mac in either mode.

### Bounded content transfers
Large JSON results and attachment bytes use the authenticated
`mailternal.transfer.v1` transfer contract instead of embedding an unbounded
payload or exposing a local filesystem path. The initial command response
contains an opaque transfer descriptor (`transferID`, kind, total byte count,
and optional filename/content type). Clients read it with sequential
`transferRead` requests, supplying the exact next offset and a length no larger
than 256 KiB; a descriptor is complete only after the final chunk reaches its
declared size. Clients may send `transferCancel` to discard an incomplete
transfer. Transfers are capped at 256 MiB and expire after 60 seconds without a
successful read. Expiry runs even when no further request arrives.

Transfer handles are bound to the authenticated client and the account grant
snapshot used to create them. Every subsequent chunk request rechecks bearer
authentication, client identity, read permission, and current account grants;
revocation or grant narrowing therefore fails closed. Ranges cannot be replayed,
skipped, reordered, or read by another client. Temporary spool files are
private, removed on completion, cancellation, expiry, failed admission, and
read errors, and are never returned as paths.
Attachment transfers retain an open descriptor for the immutable cache inode;
evicting or replacing the cache path does not replace the bytes being read.

`fetch-attachment` requires `--output PATH`. The CLI writes a private mode-0600
sibling file and atomically publishes it only after completion, without
overwriting an existing destination. Handled failures remove the temporary
sibling; the destination never contains a partial transfer. The CLI drains the
same bounded transfer contract over the Unix socket, Apple TLS, Linux TLS, and
SSH transports. `--stream` explicitly sends attachment bytes to stdout, still
bounded by the transfer limit. A failure after byte output begins is reported
on stderr, never appended as JSON to the binary stream.

Large JSON results use a private spool and bounded output chunks rather than
re-encoding the complete result into a protocol frame. The CLI validates each
chunk's sequence, offset, length, and final marker before accepting its bytes.
Large results remain raw JSON even on a TTY; chunks are never independently
passed through the small-result terminal formatter.

## Engine ownership

Exactly **one engine-owning runtime process per container** at any time, enforced
by a descriptor lock; the lock file's existence is not the authority. The process
may own multiple per-account engines. The accepted precedence remains running app
> headless daemon (`mailternal engine start`) > per-invocation CLI runtime, and a
live socket is always reused rather than opening a competing runtime. The runtime
reloads command metadata only after acquiring the lease, so takeover cannot
overwrite the previous owner's final records.
Pairing transactions use a separate descriptor lock: creating or claiming offers,
revoking clients, and validating bearer tokens never reacquire the owner's
lifetime lease.

Current CLI behavior is narrower than that end-state: on macOS, an ordinary
non-GUI invocation with no owner starts the bundled app as a headless engine
(`--mailternal-engine`) and shuts it down after the request/stream. GUI-required
commands refuse a headless owner. The Linux CLI does not start a local engine;
without a reachable runtime, it returns unavailable (exit 3). Direct cached-store
reads and standalone IMAP/SMTP execution remain accepted architecture work, not
current CLI behavior. Routing through the app does not imply GUI control.

## Undo journal
An `op_journal` table in the store records each user mutation with its inverse
(move back, flag toggle); last 50 ops, no TTL. ⌘Z in the app and `mailternal undo`
consume the same journal, whichever surface performed the op. Ops that are
irreversible on the server (a completed EXPUNGE) are refused with a clear error rather
than pretended.
Pending moves can be cancelled without server work. In-flight moves retain the undo
request until their exact destination identity is known; completed moves enqueue an
inverse move. A partial server rejection removes only the rejected entries from the
undoable batch, leaving acknowledged siblings reversible.

## Settings

`settings list|get|set <key> [value]` use the typed settings keys exposed by the
current runtime (for example `appearance.email-reading` and
`actions.swipe.trailing`). With the app running, the change is a `Command` and the
UI updates live. The accepted CFPreferences fallback for an absent runtime is not
implemented by the current CLI: settings commands use the socket or the macOS
headless runtime, and never edit a plist directly. Unknown keys and invalid typed
values are rejected.

For `actions.swipe.leading` and `actions.swipe.trailing`, `settings set` accepts
the existing full-array JSON contract (for example, `["archive","trash"]`) and
also a per-slot edit payload:
`{"index":1,"action":"archive"}` inserts or moves that action at slot 1,
while `{"index":1,"action":null}` removes the action at that slot. Slot indices
are zero-based and must be within the edge's picker limit; action names must be
the existing `SwipeActionKind` values. Per-slot edits are applied to the current
array when their queued command executes, so rapid edits to different slots do
not overwrite one another with stale snapshots.
