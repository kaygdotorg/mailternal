# Mailternal — Sync & Storage Spec

## Protocol abstraction
All protocol code sits behind a protocol-agnostic sync interface shaped like JMAP's
model: mailboxes / messages with **change-token** semantics. IMAP is the only
implementation in 0.0.1; JMAP slots in later without touching the store or UI.

### Change detection — three paths, per-folder
1. **QRESYNC**: `ENABLE QRESYNC`, QRESYNC `SELECT` parameters, `VANISHED` for
   expunges, `CHANGEDSINCE` for flag deltas.
2. **CONDSTORE-only**: `FETCH ... (FLAGS) (CHANGEDSINCE n)` for flag deltas, plus
   periodic UID reconciliation passes to discover expunges (CONDSTORE cannot report
   them).
3. **Basic IMAP**: bounded `UID FETCH <range> (FLAGS)` sweeps for flag deltas plus
   UID reconciliation for expunges (iCloud lands here).

Capability selection is **per folder and downgradeable**: an advertised extension that
answers `BAD`/`NO`/`NOMODSEQ` or returns malformed data demotes that folder to the
next path down, persistently, with a log entry.

### UIDVALIDITY replacement (generation-scoped, atomic)
Each synced folder carries a **mailbox generation** keyed by UIDVALIDITY. On change:
open a new generation; reject all responses, queued mutations, and async fetches tagged
with prior generations; backfill the new generation while the old snapshot stays
readable (marked stale in UI); atomically switch the folder pointer; delete old
message + FTS rows in bounded cleanup batches. Never blank the UI on a big folder.

## Mailbox discovery
- Enumerate via `LIST` (all folders, not `LSUB`); skip `\Noselect`/`\NonExistent`
  containers; honor `SPECIAL-USE` attributes for role mapping (Archive/Trash/Junk/
  Sent), with name-heuristic fallback.
- Mailbox identity: use `OBJECTID`/`MAILBOXID` (RFC 8474) when the server advertises
  it — renames then preserve identity and never resync. Without OBJECTID, a rename is
  reconciled conservatively as delete + new mailbox (fresh generation, full backfill);
  no heuristic identity matching.
- Detect `X-GM-EXT-1` / known Gmail hosts to apply Gmail's IMAP folder semantics.

### Gmail via IMAP
- Gmail uses `imap.gmail.com:993` with implicit TLS. Authenticate with the full
  address and a Google App Password; App Passwords require 2-Step Verification.
- Gmail's `[Gmail]/All Mail` advertises `\All`, which maps to Mailternal's `archive`
  role. `\Junk`, `\Trash`, `\Sent`, and `\Drafts` map to junk, trash, sent, and
  drafts. `\Flagged` (Starred) and `\Important` remain ordinary folders with no
  role. Labels are ordinary folders, but a labelled message is the same message
  (the same `X-GM-MSGID`) as its copy in All Mail.
- The sidebar strips the `[Gmail]/` display prefix while retaining each exact path
  for `SELECT`, `MOVE`, and identity. Archive removes the INBOX label by moving to
  `[Gmail]/All Mail` (using `UID MOVE` when advertised, or the normal COPY/DELETE
  fallback).
- Gmail advertises `CONDSTORE` but not `QRESYNC`; the sync engine uses the
  CONDSTORE MODSEQ delta path. Gmail may enforce a per-user IMAP folder message cap.

## Sync policy
- **Text-only full-history sync**: envelopes + bodies (text/plain and text/html parts)
  for every message. Attachments are never bulk-synced; on-demand only.
- **Every prefetch uses PEEK**: all metadata, preview, body, and part fetches are
  `BODY.PEEK[...]`/`BINARY.PEEK[...]`. A plain `BODY[...]` is a bug — it implicitly
  sets `\Seen` and would mark the whole mailbox read during initial sync. The only
  `\Seen` transition is the explicit queued store below.

### Write queues
0.0.1 supports seven user mutations: **seen**, **unseen**, **flagged**,
**archive**, **trash**, **move-to-folder**, and **folder rename**. Flag
operations share one persisted queue keyed by `(account, mailbox, UIDVALIDITY,
UID, flag)`; later operations for the same flag replace earlier ones. Move
operations share the historical `archive_queue` table and carry either a
destination role or the destination folder identity. Facade batches are
enqueued in one local transaction and drained as one UID set when their source
and destination match.

#### Flags (`\Seen` and `\Flagged`)
- Local read, unread, flag, and unflag actions enqueue a persisted op with
  `(account, mailbox, UIDVALIDITY, UID, flag, set)` and optimistically update
  the message row.
- Ops are sent as `UID STORE <uid-set> +FLAGS.SILENT (\Seen|\Flagged)` when
  `set` is true, or `UID STORE <uid-set> -FLAGS.SILENT (\Seen|\Flagged)` when
  false.
- Pending local `seen=true` wins over inbound unseen, `seen=false` wins over
  inbound seen, and pending `flagged` set/clear wins over inbound state until
  the corresponding STORE is acknowledged.
- Only tagged `OK` dequeues an op. Transport errors, `BYE`, and connection loss
  retain it for retry. Tagged `NO`/`BAD` drops it, clears the optimistic
  override, and records a sync error.
- Ops whose UIDVALIDITY no longer matches the live generation are discarded.

#### Moves (`archive`, `trash`, and move-to-folder)
- Local archive, trash, or move-to-folder enqueues a persisted, coalesced op
  `(account, mailbox, UIDVALIDITY, UID, destination[, destination_folder_id])`
  and optimistically deletes the message row from the source folder in the same
  local write transaction. The next delta reconciles server truth after a
  crash or failed send.
- A folder destination is resolved by its stable folder identity to its current
  server path at drain time; a retired or missing destination is discarded and
  an error-log row records the failure. Role destinations retain their
  role-based resolution.
- When the session advertises `MOVE`, send `UID MOVE <uid-set> <destination-mailbox>`.
  Otherwise send `UID COPY <uid-set> <destination-mailbox>`, then `UID STORE
  <uid-set> +FLAGS.SILENT (\Deleted)`, then `UID EXPUNGE <uid-set>` so only the
  moved UIDs are expunged. Matching queued moves are batched into one server
  operation.
- Only a tagged `OK` for the complete server operation dequeues the ops.
  Transport errors, `BYE`, and connection loss retain them for retry; tagged
  `NO`/`BAD` drops them and records a move error.
- Ops whose UIDVALIDITY no longer matches the live generation are dropped
  without a server write. Replacement activation and every UIDVALIDITY mismatch
  cleanup apply this stale-op rule.

#### Folder rename
- A rename is inserted into `folder_rename_queue` before any network command.
  The table is keyed by `folder_id`; a later edit coalesces into the same row
  and replaces `target_name`, `target_path`, and `enqueued_at`. The queue is
  durable across process restart.
- `target_path` replaces only the terminal component of the folder's current
  path, retaining its hierarchy prefix and exact LIST separator. On tagged `OK`,
  the store updates that folder and any descendants sharing the old separator
  prefix, and dequeues the operation in one local transaction before discovery.
  A rejected rename never changes the local path.
- The sync engine drains renames serially on the command channel with IMAP
  `RENAME`. Tagged `OK` applies the local tree update and immediately refreshes
  mailbox discovery. Transport errors, `BYE`, and connection loss retain the row
  for retry. Tagged `NO`/`BAD`, account/folder mismatches, and retired folders
  remove the row and record a user-visible store error.
- Discovery preserves a `FolderID` and its generation after a successful queued
  rename, including on path-only servers, because the local path is applied
  before LIST reconciliation. An unsolicited external rename on a path-only
  server remains conservative delete + new mailbox behavior.

### Backfill algorithm (bounded, resumable)
- Per folder: walk **descending fixed-size UID windows** from `UIDNEXT-1` (never
  `UID SEARCH ALL` — no materializing the whole UID set). Sparse UID ranges are
  normal; empty windows advance the cursor.
- Each window: PEEK-fetch envelopes + BODYSTRUCTURE + text parts, parse, insert
  messages + FTS rows in **one bounded batch transaction** (budgeted by row count and
  decoded bytes), commit atomically, then persist the per-folder cursor
  `(generation, phase, low-water UID)`. Cursor only advances after commit; every
  phase is idempotent; resume from the last committed cursor after crash, cancel,
  reconnect, or kill.
- A message that fails to parse/fetch is **quarantined** (stored with error state,
  envelope-only) and never blocks its folder.

- Priority queue: INBOX first, then the currently visible folder, then
  SPECIAL-USE folders, then custom folders; within a folder, newest first.
  `FolderBackfillScheduler` owns this ordering and wakes workers when a folder
  is enabled. Cancellation points between batches keep the writer responsive.
- **Local-retention flags:** `keepLocally = true` folders are backfilled and
  included in delta passes. A `false` folder is still discovered and refreshed
  with STATUS/SELECT counts (so its sidebar count remains current), but never
  receives message FETCHes or a backfill/delta message walk. Turning it on
  queues its backfill immediately; turning it off cancels its in-flight worker
  and leaves existing rows intact.
- **Bounded parallel backfill:** each account has up to
  `SyncPolicy.maxBackfillConnections` (3) connections in a worker pool. The
  dedicated INBOX IDLE connection is opened immediately and is separate from
  that pool. Each worker owns one mailbox connection and walks independent
  windows; the GRDB writer remains serialized while per-folder transactions
  interleave.
- If a server rejects a pool connection at its per-account cap (for example
  Dovecot ~10, iCloud ~5, or Gmail ~15), the scheduler falls back to the
  number of connections accepted and remembers that cap for the session. A
  cap never disables discovery or the already-open workers.

**IMAP protocol bounds:** IMAP line buffering and individual literals are capped
at 1 MiB. A larger server response is surfaced as a non-transport parse error
and handled by per-UID quarantine/bisection, so one malformed message cannot
stall a folder.

### Disk policy (no up-front full scan)
- Start syncing the newest INBOX window immediately — never block startup on a
  mailbox-wide size scan or an age-based cutoff.
- Capacity checks prefer macOS important-usage capacity, then ordinary available
  capacity. If neither is available, treat capacity as unknown/ample rather than
  zero.
- Reserve headroom is real-space based: `reserve = min(20 GiB, max(5 GiB, 2%
  of the volume))`.
- Halt the backward walk per folder only when actual free space falls below
  `reserve`, after at least the newest window has committed; surface "synced
  through <date>". **Resume threshold:** free space >
  `reserve + 2 GiB` (hysteresis); resume automatically.
- Every fetched message in every committed window is retained. There is no
  setup-time 30-day/windowed filter that can discard messages while advancing
  the durable UID cursor. Windowed mode is only the disclosed, resumable state
  while actual disk pressure has halted older history; it upgrades to full
  backfill when headroom recovers.
- IDLE is re-issued before the RFC 2177 29-minute ceiling (default renewal 25 min;
  many servers drop sooner — renew on any timeout evidence).
- `EXISTS`/`EXPUNGE`/`FETCH` during IDLE are **hints only**: leave IDLE, run the
  folder's selected delta path (QRESYNC/CONDSTORE/basic), commit, *then* post
  notifications and re-enter IDLE. Same delta-first rule after every reconnect
  (jittered exponential backoff).
- Non-INBOX folders: periodic delta pass on the sync connection (default 5 min,
  SPECIAL-USE folders more often than cold folders).

## Storage
- **One SQLite database** (GRDB, WAL): accounts (non-secret settings only — secrets
  live in Keychain), folders, generations, messages (envelope, flags, body text, raw
  sanitized HTML, normalized `Message-ID`/`References`/`In-Reply-To`), sync state
  (per-folder path selection, HIGHESTMODSEQ, cursors), seen/flag/move write queues,
  parse-error records.
- All writes through a single writer queue; bounded batch transactions; observation
  notifications debounced/coalesced after commit.
- **List access is paginated**: keyset pagination on stable
  `(internalDate DESC, uid DESC)` ordering; lightweight list projections (no
  bodies/HTML); GRDB observation limited to visible pages plus aggregate counts.
  Never observe a whole-folder query.
- **FTS5** external-content table over subject/from/to/body-text, tokenizer
  `unicode61 remove_diacritics 2`. Insert/update/delete kept consistent via triggers
  (delete executed while old content rows still exist); FTS rows written in the same
  batch transaction as messages; `rebuild` on schema migration; periodic
  `integrity-check` with rebuild-on-corruption recovery; segment `merge`/`optimize`
  scheduled off the interactive path.
  *Known limitation (documented)*: unicode61 does not segment CJK; CJK search is
  substring-poor in 0.0.1. A segmentation strategy (ICU-backed auxiliary tokens) is
  planned post-0.0.1.

## MIME (a real subsystem, treated as one)
- Own parser in `MailternalCore` (Swift, cross-platform), developed against a
  **conformance corpus**: malformed boundaries, `message/rfc822` nesting, RFC
  2047/2231 headers, broken quoted-printable/base64, `format=flowed`,
  unknown/mislabeled charsets (fall back ISO-8859-1, record), fuzzing in CI.
- **Limits (hard, enforced)**: single header line 64 KiB; total header block 1 MiB;
  decoded text part 8 MiB (truncate, mark truncated); MIME nesting depth 8;
  cancellation checkpoint at least every 256 KiB decoded.
- Parse failures never throw away the message: store envelope + error record
  (quarantine above). Viewer fallback for quarantined messages: **on-demand capped
  raw fetch** — `BODY.PEEK[]` up to 4 MiB, rendered as escaped plain text, never
  persisted beyond the viewer cache; fetch failure shows the error record.
- Benchmarked in CI; vendor a C parser only if profiling demands (DECISIONS #1).

## HTML isolation (security boundary, not a style pass)
Attacker-controlled HTML reaches `WKWebView` only under all of:
- JavaScript disabled; nonpersistent isolated `WKWebsiteDataStore`; no ambient file
  access.
- **Deny-by-default network layer**: a `WKContentRuleList` blocks *all* network
  loads categorically. `WKNavigationDelegate` is a second fence for navigations, not
  the subresource mechanism — it cannot see every subresource.
- Sanitizer removes every request-bearing construct: scripts, event handlers,
  iframes/objects/embeds, forms, `meta refresh`, `<link>` stylesheets, `@import`,
  CSS `url()`, `srcset`/`imagesrcset`, audio/video/track sources, SVG
  `href`/`use`/filters, and dangerous URL schemes. Only inline sanitized CSS and the
  app-controlled local scheme survive.
- **Remote-image reveal never opens the network to the page**: consenting rewrites
  `img` sources to the app-controlled scheme; the app's handler fetches exactly
  those URLs itself and serves bytes locally. The content-rule block stays active.
- `cid:` inline parts are **viewer-demanded**: placeholder first; opening a message
  fetches referenced inline parts (PEEK), stores them in the attachment cache, and
  rewrites references to the same local scheme handler. Same LRU rules.
- Test suite covers image/CSS/iframe/redirect/form/script/srcset/SVG exfiltration
  vectors before any HTML renders.

## Attachment cache
Plain files on disk keyed by content hash — not in SQLite. LRU eviction,
configurable cap, default 2 GB. Inline (cid) and explicit attachments share it.

## Notifications (macOS 0.0.1)
- Persist an INBOX **baseline** = `UIDNEXT − 1` at account activation, before
  backfill starts. Notify only for UIDs **>** baseline in the live generation,
  discovered by the delta path after live sync starts. A replacement UIDVALIDITY
  generation initializes a fresh baseline (`UIDNEXT − 1` at switchover).
- Never notify from backfill, reconciliation, or UIDVALIDITY replacement. Deduplicate
  by `(generation, UID)`.
- App frontmost with the folder visible → no banner (badge/list update only).
  Notification permission denied → sync proceeds normally, no prompts beyond the
  initial request.

## Threading (0.0.2 — nothing computed in 0.0.1)
0.0.1 stores normalized `Message-ID`, `References`, `In-Reply-To` **only** — no
thread id, no graph. 0.0.2 adds the builder (strict RFC 5322 References/In-Reply-To
graph, no subject merging) behind an interface, with a migration that computes thread
ids over existing rows. Rationale: stable graph computation under out-of-order
newest-first backfill is most of the threading feature; it stays out of the read-only
milestone.
