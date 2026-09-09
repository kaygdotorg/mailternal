# Mailternal — CLI Spec

`mailternal` is the bundled command-line client and remote control for the app.
The accepted end-state is feature parity for every mail operation the app
supports (see `automation.md`). The source maps every implemented `CommandName`
through the CLI and generated schema, including SMTP configuration, versioned
drafts, attachments, sending, and outbox recovery.

## Process model (hybrid)

1. App running → the CLI reuses its mail runtime over the container socket
   (`automation.md`). Ordinary queries and mail commands do not navigate or focus
   the GUI, change tabs, or alter a visible composer. Mail-data changes naturally
   propagate to views. Explicit `ui` commands drive GUI state.
2. App not running → on macOS, an ordinary non-GUI invocation may start the
   bundled app as a headless engine (`--mailternal-engine`) for the request,
   then stop it. `draft send`, `outbox retry`, and `pair --show` are lifecycle
   exceptions: delivery requests leave a newly started owner running so the
   persisted outbox can drain, even if the command acknowledgement is lost.
   `engine stop` explicitly stops that owner. Pairing reuses
   a reachable owner or starts a headless owner and leaves a newly started
   owner running, so the short-lived offer remains claimable after the CLI
   exits. GUI-required commands refuse a headless owner; `--no-start` makes an
   unavailable runtime an immediate exit-3 result. If pairing is disabled or
   its listener cannot start, `pair --show` returns an exit-3 unavailable
   result rather than an offer. The accepted standalone IMAP/SMTP runtime
   remains the target architecture, but the current CLI does not open the store
   directly or provide a standalone IMAP/SMTP implementation.
   The Linux executable does not start a local engine; without a reachable
   remote or runtime it returns unavailable (exit 3).
3. Remote agents → `--host` and `MAILTERNAL_HOST` select the transport. A
   `USER@HOST` value runs the Mac-side CLI over SSH; an `https://HOST[:PORT]`
   value uses the paired TLS listener. SSH accepts `--ssh-port`. HTTPS uses a
   stored paired endpoint by host, or requires `--port` together with
   `--bearer` and `--fingerprint` (the corresponding bearer/fingerprint
   environment variables are also accepted). The HTTPS URL cannot contain
   userinfo, a path, a query, or a fragment. Both transports return the same
   CLI output contract; the Mac retains account credentials. `https://` selects
   Mailternal's newline-delimited protocol over TLS, not a general HTTP API.
   Apple clients use Network/Security; Linux clients use SwiftNIO/NIOSSL. Both
   verify the paired leaf-certificate fingerprint before sending bearer data.
   Creating the Apple listener still requires Network/Security and a local
   identity; persisted endpoint configuration alone is not a reachability check.

## Install

The bundled executable is
`Mailternal.app/Contents/MacOS/mailternal`. Settings → **Command Line** derives
the source path from the current app bundle's
`Contents/MacOS/mailternal`, displays the generated shell command, offers a copy
button, and checks whether `/usr/local/bin/mailternal` resolves to that exact
executable. The sandbox does not install into `/usr/local/bin`; run the command
in Terminal, or choose another writable directory on `PATH`. The default command
is a symlink (`ln -sf -- …/Contents/MacOS/mailternal /usr/local/bin/mailternal`)
so the selected installed app version remains the one being invoked.

`mailternal setup` emits the same installation command. Its piped form is the
structured `mailternal.setup.v1` object (including `command`, `target`, and
`executable`); an interactive terminal prints only the command for convenient
copying. Homebrew is not a current installation path.

## Command shape

The CLI help and command grammar are maintained beside the parser and Codable
command types; this guide intentionally does not duplicate that hand-maintained
grammar. Use `mailternal --help` for the current CLI grammar and
`mailternal schema` for command payload/result schemas.
The stable families are ordinary mail queries and triage (`list`, `read`, `raw`,
`search`, `mark`, `flag`, `archive`, `trash`, `move`, `undo`, `refresh`), account,
folder, draft, outbox, settings, engine, pairing, and the explicit `ui` namespace. Remote
administration is exposed by `remote status|disable|enable HOST PORT` and
`pair --revoke UUID`; those operations are typed runtime commands, not direct
pairing-file edits.

On macOS, the embedded CLI resolves the app's declared executable from the
bundle metadata, rather than treating the CLI itself as the app. A persistent
headless owner detaches all three standard streams, so piped CLI calls reach
EOF even while the owner continues running. Startup failures remain typed
`unavailable` results; background app output is not forwarded through the CLI.
`engine stop` shuts down and exits a headless owner without terminating a GUI owner.
Concurrent startup callers converge on the same owner. A headless process that
loses the runtime lease exits without opening or migrating the store, starting
account engines, or opening a window. Store construction is lazy; the elected
owner starts its detached database open only after acquiring the lease.
`Scripts/qa/cli-runtime-ownership.py` exercises startup and shutdown against a
fresh, private, account-free container on macOS.

`remote status` queries the owning runtime rather than reading configuration
files in the CLI. Its result reports `enabled` (persisted intent), `running`
(the listener is actually present), and the configured `host` and `port`. With
no reachable owner it returns exit 3 (`unavailable`) and does not start one;
configuration alone is never reported as a running listener.

`draft new|reply|forward|save|delete|get|list|attach|attachment|send` operates on
durable drafts without presenting or navigating a GUI composer. `draft send`
requires the observed revision and returns the durable submission, not a promise
of server delivery. `outbox get|list|retry|cancel` exposes authoritative delivery
state. Retrying `deliveryUnknown` requires `--acknowledge-duplicate-risk`;
Sent-copy recovery never submits the message to SMTP again.

`account smtp configure ACCOUNT --file JSON` accepts non-secret SMTP settings.
Supply a replacement password through the existing protected password input
path, or choose `--use-imap-password` to reuse the IMAP credential.
`--keep-password` requires the current SMTP credential reference in the JSON.
Replacement secrets are validated before a fresh Keychain reference is committed;
neither passwords nor credential values appear in account state or command logs.
`account smtp disable ACCOUNT` removes outgoing configuration without deleting
saved drafts.

`draft attach DRAFT --file PATH` uploads in bounded chunks and saves a new draft
revision. Standard input requires `--file - --filename NAME`. Imported attachments
have a caller-known UUID recorded in the command's target identities; saved draft
and outbox references protect their bytes. Uncommitted imports have a bounded,
expiring staging lifetime described in `sync.md`.

For `fetch-attachment`, the required form is
`fetch-attachment <id-or-link> <part> --output PATH`. The destination must not
already exist: the CLI writes a private mode-0600 sibling file, then atomically
publishes the complete destination without overwriting another file. Handled
failures remove the temporary sibling; partial bytes are never published at the
destination. `--stream` is an explicit alternative for machine callers that need
attachment bytes on stdout; it cannot be combined with `--output`. Errors after
streaming begins go to stderr so that stdout remains an attachment byte stream.


## Explicit GUI control and context

`ui` is the explicit GUI-control namespace; ordinary `list`, `read`, `search`,
and triage commands must not implicitly drive a window. A CLI search is not the
GUI's visible search query. Explicit settings mutations change their named
settings, but list-layout/workspace controls remain GUI commands.

`state`/`observe` return ordinary account and mail-runtime state without GUI
context. `ui state` exposes the local GUI's windows, focused surface, active
account/folder, list selection and paging, reader tabs/active tab/reading
position, visible search and results, reading settings, presented dialogs and
available actions, and relevant sync/outbox/error state. Draft and outbox summaries
are observable runtime state; native editor focus and unsaved keystrokes are not
serialized. Read a saved draft through `draft get`. Credentials are never
serialized into state, and mail content is returned by structured queries rather
than repeated in state events.

For a paired remote client, account links and independent `read`, `mutate`,
`send`, and GUI-control grants are enforced separately. `ui state` and
`ui observe` require GUI permission; returned folders, rows, selections, tabs,
and account states are filtered to the granted accounts. Detached windows are
included only when their explicit account ownership is granted; global dialogs,
settings, and unowned windows are not exposed. A non-GUI paired snapshot uses
the default list configuration and does not expose GUI rows or controls.

`ui observe` starts with a versioned snapshot and supplies ordered state changes.
Reconnection or a detected event gap requires resynchronization, never silently
stale context. Selection-dependent UI mutations carry an observed selection
revision and reject stale context; explicit canonical message links (or local
IDs for same-device clients) are not retargeted when GUI selection changes.
in-app workflows using stable identities and schema-discoverable commands,
without screenshots or coordinates. Explicit UI commands require a reachable
GUI app and do not silently become standalone mail operations when it is absent.

## Output contract

- A non-TTY one-shot command emits JSON. A TTY uses the CLI's human-readable
  rendering; streaming commands remain JSON Lines. No parseability flag is
  required.
- A successful one-shot command uses the
  `mailternal.cli.result.v1` envelope:
  `{"schema":"mailternal.cli.result.v1","version":1,"ok":true,"result":…}`.


  When the decoded payload is a `CommandResult`, the envelope also includes the
  command name and optional `stateRevision`; `result` contains the decoded JSON
  value or `null` for no payload. Scalar results are still represented by the
  tagged envelope.
- State snapshots and observation events retain their own
  `mailternal.state.v1`/`mailternal.event.v1` tags rather than being flattened
  into opaque bytes. Setup has the separate `mailternal.setup.v1` shape. Failures
  use the typed `mailternal.response.v1` envelope with a `failure` value.
When a query or export result exceeds the inline payload limit, `result` is a
`mailternal.transfer.v1` descriptor. The CLI transparently drains its ordered
chunks before rendering the normal result envelope; it never prints a temporary
spool path or accumulates an unbounded response. Transfer failures use the
ordinary typed failure envelope and leave no partial attachment destination.

- Exit codes are 0 success · 1 domain failure · 2 usage · 3 app/engine
  unavailable · 4 authentication or authorization.
`mailternal --help` is the maintained agent-facing CLI grammar and
`mailternal schema` is the generated reference for command payload/result
schemas. Both carry examples, exit codes, and identity rules; this guide
intentionally does not duplicate the exhaustive command list.

## Mutations

The current triage mutations are not read-only. Safety comes from the durable
command path and reversibility (`undo`), not from `--yes` gates. The separate
store undo journal retains the accepted 50-operation scope; the command metadata
journal retains pending/running entries and the latest 1,000 terminal records,
without credentials, bodies, drafts, or search text. Server-irreversible steps
(such as a completed EXPUNGE) must refuse undo rather than pretend success.

Remote administration is deliberately local-only: `remote enable|disable` and
`pair --revoke UUID` dispatch typed commands through the same FIFO and persist
their effects through the owning runtime. A paired bearer cannot reconfigure the
listener or revoke another client.

## Linux

The distribution target is a pinned-toolchain static musl CLI. The current Linux
executable is a protocol client: it can use SSH or a paired HTTPS listener, but
it does not start a local Mailternal engine. App-driving commands without a
reachable runtime return exit 3. The accepted standalone IMAP/SMTP and
credential-provider design remains future work; the current source does not
implement the documented `password_command` path or direct Linux store access.

### Credentials off-macOS

The accepted design is a 0600 secrets file under
`$XDG_CONFIG_HOME/mailternal/` or a `password_command`, with account import from
an encrypted pairing bundle. The current CLI does not implement that standalone
credential path; over SSH or paired remote access, credentials remain on the Mac
and are not imported.

## Generated reference and tests

The JSON Schema is generated from the Codable command types. The CLI command
grammar remains maintained beside the parser and types; neither is duplicated in
this guide.
Parity tests keep every implemented `Command` case reachable from a CLI verb.
`Scripts/qa/smtp-delivery.py` exercises the actual app, CLI, SMTP fixture and QA
IMAP server, including revision conflicts, binary transfer, failed/unknown
delivery, restart recovery, cancellation, and Sent-copy-only retry.
