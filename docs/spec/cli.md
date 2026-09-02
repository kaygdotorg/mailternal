# Mailternal — CLI Spec

`mailternal` is a remote control for the app and a standalone mail client, with
**feature parity** for every mail operation the app supports (structurally enforced:
see `automation.md`). It ships **inside the app bundle** and as a static Linux binary.

## Process model (hybrid)
1. App running → the CLI drives it over the container socket (`automation.md`),
   including UI state: selection, search, later the composer. "Change what's in the
   composer from a script" is the acceptance test of this design.
2. App not running (or Linux) → standalone: reads open the store directly; mutations
   run a per-invocation engine or talk to `mailternal engine start`.
3. Remote agents → `--host` / `MAILTERNAL_HOST`: `user@mac` runs the Mac-side CLI over
   SSH; `https://host:port` uses the paired TLS listener. Same JSON either way.

## Install
The binary lives at `Mailternal.app/Contents/MacOS/mailternal`. The sandbox cannot
write to `/usr/local/bin`, so Settings → **Command Line** shows the one-line install
command (`ln -sf "…/Mailternal.app/Contents/MacOS/mailternal" /usr/local/bin/mailternal`)
with a copy button and a live installed/not-installed check; `mailternal setup` prints
the same line. The symlink always resolves to the installed app's version — one
version to reason about. Homebrew comes later, pointing at the same signed binary.

## Command shape
Flat verbs for the hot path, noun-verb for admin:

```
mailternal list [--folder INBOX] [--limit N] [--after CURSOR]
mailternal read <link|id>              mailternal raw <link>
mailternal search "<query>" [--limit N] [--follow]
mailternal mark <link> read|unread     mailternal flag <link> [--off]
mailternal archive <link>              mailternal trash <link>
mailternal undo
mailternal observe                     # JSON Lines stream of state/new-mail events
mailternal refresh
mailternal account add|remove|list|export|import
mailternal settings list|get|set
mailternal engine start|stop|status
mailternal pair --show|--code <words>
mailternal schema                      # JSON Schema for every output type + command list
mailternal setup
```
`send`/`reply`/`composer.*` arrive with the composer + SMTP milestone, designed once
for app and CLI together.

## Output contract
- **JSON when stdout is not a TTY, pretty text when it is** (git/gh convention). Never
  make an agent pass a flag for parseable output; never make a human read JSON.
- Streaming commands (`observe`, `search --follow`) emit **JSON Lines**.
- Every object carries a schema tag (`"schema":"mailternal.message.v1"`); shape
  changes bump the tag so parsers detect them instead of misreading fields.
- Exit codes: 0 ok · 1 domain error (no such message) · 2 usage · 3 no app/engine
  reachable · 4 auth.
- `mailternal schema` and `--help` are written for agents: examples, exit codes,
  identity rules. The schema is generated from the Codable types and published to
  `mailternal.com/docs` (see `docs.md`); it is never hand-maintained.

## Mutations
Not read-only. Safety comes from **reversibility** (`undo`, `automation.md`), not
from `--yes` gates — gates train agents to pass `--yes` reflexively. Only
server-irreversible steps (EXPUNGE) refuse undo, explicitly.

## Linux
Static musl binary (Swift Static Linux SDK, pinned toolchain). Verified: swift-nio,
nio-ssl, nio-imap and swift-argument-parser build statically; **GRDB expects a system
`libsqlite3`, which the static SDK does not provide**, so the Linux build vendors the
SQLite amalgamation as a C target (macOS keeps system SQLite). Two artifacts may be
published (bundled / system SQLite) once sizes are measured; bundled is the default.
`URLSession` is irrelevant to the core (IMAP/SMTP are NIO sockets); OAuth token
refresh uses `AsyncHTTPClient`. App-driving commands on Linux exit 3 "no app".

### Credentials off-macOS
No Keychain on Linux: secrets live in a 0600 file under
`$XDG_CONFIG_HOME/mailternal/` or come from `password_command` (the mutt/aerc
convention). Accounts arrive via `account import` of a pairing bundle (`pairing.md`).
Over SSH/paired remote access nothing is imported — the Mac holds the credentials.

## Tests
CLI golden tests run against the existing scripted-IMAP harness; every command has a
JSON fixture and a TTY fixture. Parity test: every `Command` case has a CLI verb.
