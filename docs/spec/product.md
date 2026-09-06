# Mailternal — Product Spec

## What
A first-class Apple-native mail client for macOS and iOS/iPadOS, an iPhone-companion
watchOS app, plus a CLI and a self-hostable push daemon (`mailternald`).
No other platforms, ever.

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
- v0.0.1 preserves the current macOS multi-account functionality as the parity baseline.
- Accounts can be disabled; disabling stops the engine and hides folders while retaining settings and the saved password.
- Providers: generic IMAP, iCloud and Fastmail via app-specific passwords, plus
  Gmail via Google App Password (2-Step Verification required; setup guidance
  links to Google's App Password page).
- **Gmail** (shipped in 0.0.1 for 2-Step Verification accounts): use the full
  Gmail address with an App Password for IMAP/SMTP. OAuth stays deferred; there is
  no Mailternal-owned OAuth client or web-session/scraping path. Exchange: never.
- Account setup: manual host/port/TLS entry + provider presets (a plist, not a
  discovery subsystem). Full Thunderbird-autoconfig/RFC 6186 later.
- **SMTP configuration arrives with the composer milestone (M5)**, which is
  required before 0.0.1 can ship; presets may carry dormant non-secret defaults
  until implementation.
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

- **Mutations**: seen, unseen, flagged/unflagged, archive, trash, folder moves,
  and folder renames all go through persisted optimistic queues (sync.md).
- **Folder rename**: edits are coalesced by folder and sent as a real IMAP
  `RENAME`; the sidebar reflects the server discovery result, preserving stable
  OBJECTID identity when available.
- **Full-text search** over the entire synced history, offline, instant (FTS5).
  Windowed/degraded sync states disclose "search covers mail since <date>".
- HTML mail in `WKWebView`: **remote images blocked by default** (notice shown only
  when the message references remote content), inline `cid:` parts always shown,
  Email Reading mode Original/Dark with an opaque canvas, plain-text fallback.
  A single click on an `http(s)` or `mailto:` link MUST open it through the
  system default handler; it MUST NOT navigate the reader. A link context menu
  MUST provide only **Open Link** and **Copy Link**, while retaining text-selection
  actions such as **Copy**, **Look Up**, and **Services** when text is selected.
- **Rapid reader navigation**: Up/Down selection MUST remain immediate. Reuse
  prepared local details and coalesce duplicate in-flight detail reads; warm a
  bounded adjacent-message window without marking prefetched mail read or
  requesting raw messages, attachments, or remote images. Superseded work MUST
  NOT replace the current selection's content. Do not debounce selection, delay
  the loading indicator, or display an old message under a new message's header
  to conceal load latency.
- **Header enrichment**: ordinary reading uses the stored envelope immediately.
  Fetch full raw headers only on explicit expanded/raw-header demand, not merely
  to populate a Delivered date during list navigation. Preserve already-loaded
  enrichment; a Delivered date is shown only when its real source is available.
- Live updates via in-app IMAP IDLE + macOS local notifications (no daemon needed on
  macOS). Notifications fire only for post-activation mail — never from backfill
  (baseline rule in sync.md).
- Initial sync UX: app is live immediately; newest mail readable within seconds;
  per-folder backfill progress in the sidebar; backfill continues in background.

## Reader tabs

The main window's rightmost pane is the reader. It MUST expose one tab strip for
messages open in that reader; detached message windows MUST remain tab-less.
- Each open tab retains its rendered reader surface—`WKWebView` for HTML or
  `NSTextView` for plain text—and native scroll position in one bounded reader
  pool. The pool keeps at most eight most-recently-used tab surfaces; opening a
  new tab evicts the least-recently-used surface, and closing a tab releases its
  surface immediately. Switching among retained tabs swaps the installed view
  without reloading HTML or rebuilding attributed plain text. Reading-mode and
  appearance changes use the existing injected-style path for every retained
  HTML surface and invalidate only the affected native-text layout caches.

### Open and promote

- A single click on a message-list row MUST call `open(message, permanent:
  false)`. The resulting transient tab MUST become active and move its `TabID`
  to the front of MRU. The transient tab MUST be reused by the next single
  click: its `message` changes in place rather than creating another tab. If
  no transient tab exists, the new transient MUST be inserted immediately
  right of the `activeID` that was active before the `open` call (or become
  the only tab).
- A double click MUST call `open(message, permanent: true)`. A newly created
  permanent tab MUST become active and MUST be inserted immediately right of
  the `activeID` that was active before the `open` call. `open(message,
  permanent:)` MUST activate the resulting tab and move its `TabID` to the
  front of MRU. If a tab already contains `message`,
  `permanent: false` MUST only activate that tab, including when it is already
  the active permanent tab. With `permanent: true`, an existing permanent tab
  MUST be activated; otherwise the matching transient tab MUST be promoted in
  place. `open` MUST NOT create a duplicate or change an unrelated transient
  tab. Promoting a transient MUST keep its `TabID`, position, reader scroll, and
  message, and only clear `isTransient`.
- Choosing **Open in New Tab** from a message-list context menu MUST open every
  selected message as a permanent tab in visible list order. A click on a row
  already in the selection MUST preserve the full selection; a click outside it
  MUST target only that row. Existing tabs MUST be reused (and matching
  transients promoted in place), without duplicate message tabs. The final
  message in visible order becomes the single active tab while the list
  selection remains intact. The batch transition MUST persist once and retain
  the bounded, lazy reader-surface policy rather than rendering every opened tab
  eagerly.
- ⌘-click MUST retain the message list's multi-selection behavior and MUST NOT
  open or promote a reader tab. While the message list has multiple selected
  rows, the reader MUST continue showing the active tab, and the active tab,
  transient tab, MRU, and reader scroll MUST NOT change. Archive, Trash, and
  More in the reader strip MUST target only the active tab's message; list-
  scoped actions MAY continue to target the full list selection. A later
  ordinary single click that collapses selection to one row MUST apply the
  transient-open rule.
- Pressing Enter on a search result and opening a deep link MUST call
  `open(message, permanent: false)`, exactly following the single-click rule.

### State and invariants

The reader-tab state MUST use the following model names and fields:

- `ReaderTab { id: TabID, message: MessageID, isTransient }` is one tab.
  `id` is the stable identity of the tab; `message` is the stable identity of
  the message shown by it. The persisted representation of `message` MUST be
  its stable deep link (`mailternal://open/v1/...`), not a copied message body.
- `ReaderTabs` owns the ordered `tabs`, `activeID`, MRU stack, and
  `perTabScroll`. `activeID` is nil when no tabs exist and otherwise MUST name
  an existing tab. The reader-tab operations are `open(_:permanent:)`,
  `activate`, `close`, `closeOthers`, `closeToRight`, `keep`, `move`,
  `activateNext`, `activatePrevious`, and `messageRemoved`.
  `scrollOffset` reads or writes the saved reader position for the addressed
  tab; it MUST be the tab's `perTabScroll`, not a global reader position.
- Changing the selected folder MUST clear the message-list selection without
  clearing, reloading, or hiding the active reader tab. The tab remains visible
  even when its message is outside the selected folder.
- `order` is the position of each `ReaderTab` in `ReaderTabs.tabs`. The MRU
  stack is ordered most-recently-used first. Activating a tab MUST move it to
  the front without duplicates; closing a tab MUST remove it.
- `ReaderTabsSnapshot` is the Codable persistence shape. It MUST contain
  stable message deep links, `id`, `isTransient`, `order`, MRU order,
  `activeID`, and per-tab reader scroll, and MUST NOT contain message bodies,
  rendered HTML, or other reader content.

Persisted entries whose deep links no longer resolve, or whose messages are
removed before detail loads, MUST be closed silently. They MUST NOT remain as
phantom tabs or leave the reader in an endless loading state; when no entry
resolves, `activeID` MUST be nil and the reader MUST show its empty state.

After every operation and restore, `ReaderTabs` MUST contain at most one
transient tab, MUST NOT contain duplicate `MessageID` values, and MUST satisfy
`activeID == nil` if and only if `tabs.isEmpty`; otherwise `activeID` MUST name
exactly one existing tab. Closing a tab MUST also remove its MRU and
`perTabScroll` entries. A `permanent: true` open for a new message MUST insert
right of the `activeID` that was active before the `open` call. Dragging MUST
change `order` without changing `id` or `message`.

### Navigation and persistence

- Activating a tab MUST synchronize the account, folder, and message-list
  selection to that message. The list MUST preserve and restore scroll
  position per folder, and the reader MUST preserve and restore
  `perTabScroll` per tab.
- Activating a tab whose account is disabled MUST NOT re-enable the account or
  close the tab. The tab MUST become active and show locally cached reader
  content; account, folder, and message-list selection MUST remain empty until
  the account is enabled, after which activation MUST perform the normal
  synchronization.
- A tab MUST follow its `MessageID` when the message moves to another folder
  or account; moving a message MUST NOT close or duplicate the tab. When a
  move changes a message's canonical deep link, `ReaderTabs` MUST replace that
  tab's persisted link with the destination canonical deep link before the
  next snapshot is committed, without changing its `id`, order, `isTransient`,
  active/MRU state, or reader scroll.
- If a message is deleted or expunged, its tab MUST close and the app MUST show
  the toast `Message was deleted`.
- All tabs, including the transient tab, MUST persist across launches. The
  persisted reader-tab record MUST contain stable message deep links, tab
  order, `activeID`, `isTransient`, MRU order, and per-tab reader scroll. It
  MUST NOT contain message bodies, rendered HTML, or other reader content.
- Restore MUST sort entries by persisted `order`, drop unresolved entries
  without changing the relative order of survivors, and rebuild MRU by
  removing missing and repeated `TabID`s while preserving survivor order. A
  duplicate `MessageID` MUST retain its permanent entry over a transient entry,
  otherwise the first entry in persisted order; a second transient MUST be
  dropped by the same rule. Any retained tab absent from persisted MRU MUST
  be appended in tab order. If `activeID` is dropped, the first surviving MRU
  tab MUST become active; if no tabs remain, the reader is empty.

### Close, switch, and menu actions

- Closing the active tab MUST activate the next valid tab in MRU order. A
  middle click MUST close that tab. If the main window has no tabs when ⌘W is
  invoked, it MUST close the main window. Otherwise ⌘W MUST close the active
  tab and, if that close leaves no tabs, the same invocation MUST then close
  the main window.
- ⌃Tab and ⌘⇧] MUST call `activateNext`; ⌃⇧Tab and ⌘⇧[ MUST call
  `activatePrevious`. Each successful switch MUST update MRU. With fewer than
  two tabs, these commands MUST leave tab and MRU state unchanged.
- After a close activates another tab, keyboard focus MUST move to the
  equivalent focus target in that tab's reader, falling back to its reader
  root. If no tab remains and the window stays open, keyboard focus MUST move
  to the message list. A pointer-initiated close of an inactive tab MUST
  preserve the current keyboard focus.
- Closing an inactive tab, including the transient tab, MUST leave `activeID`
  and the relative MRU order of surviving tabs unchanged. Closing the active
  transient MUST use the normal MRU fallback. If no tab survives, `activeID`
  MUST become nil and the reader MUST enter its empty state. The next
  transient open MUST create a new tab immediately right of the `activeID`
  that is active before that open call, or as the only tab.
- A tab context menu MUST provide **Close**, **Close Others**, **Close to the
  Right**, **Keep** (only for the transient tab), **Open in New Window**, and
  **Copy Link**. Close Others MUST retain only the chosen tab; Close to the
### Reader tab strip and preview

- The reader tab strip MUST be a single native unified-titlebar/toolbar row
  over the rightmost reader column and MUST be visible whenever
  `tabs.tabs` is non-empty, including when exactly one tab exists. It MUST be
  hidden when the reader is empty and while global search is presented.
- The reader tab strip MUST keep Archive, Trash, and More in a fixed trailing
  cluster. More MUST contain Flag, Raw Source, Email Reading mode, and every
  other tab-strip action not named Archive or Trash. The sidebar toggle MUST
  remain in the window titlebar. The strip MUST have no own background, the
  reader-tabs toolbar item MUST have no label or tooltip, and toolbar
  customization MUST be disabled.
- Each tab MUST use its intrinsic width, computed as leading slot plus subject
  text width plus title paddings, clamped to 72–220 pt. Tabs MUST have an 8 pt
  leading strip inset and 8 pt spacing. When they overflow, they MUST scroll
  horizontally beneath a fixed 28 pt trailing fade up to the actions cluster.
- Hovering an inactive tab MUST immediately show a local preview in a
  non-activating child panel beneath that tab; hovering the active tab MUST
  never show a redundant preview. The panel MUST be exactly 220 pt wide by
  160 pt high and contain a scrollable preview body. If sender and received
  time are already available locally, the card MUST include them in a compact
  metadata line; otherwise it MUST omit them and MUST NOT fetch them. It MUST
  overlay the reader without reflowing it, changing selection or scroll,
  marking the message read, or fetching remote content. The panel MUST remain
  hoverable while the pointer is over either the inactive tab or card and
  dismiss after a 150 ms grace period after leaving both.

## Cross-device workspace and customization

These are accepted product requirements, not a claim of implemented sync.

- Apple-device workspace metadata uses iCloud; mailbox content/state still uses
  the mail synchronization subsystem and credentials remain in Keychain.
- Publish workspace changes immediately when connectivity permits, without
  interrupting interactive reading on another device. Adopt automatic handoff
  when the user resumes an inactive device.
- Offer sync participation during onboarding and a per-device master switch plus
  category switches under Settings → Sync. Turning a category off preserves its
  current local settings and the cloud copy while stopping its incoming/outgoing sync.
- When re-enabling a category, compare local and cloud settings. If they differ,
  ask "Use this device's settings" or "Use synced settings" before replacing either
  side. If they match, enable immediately without prompting.
- Retain the current macOS layout and add the requested Thunderbird-style dense
  configurable message columns and list-above-reader arrangement.
- Customization has global defaults plus per-folder overrides. All customization
  settings, including column visibility, order, widths, sorting, and overrides,
  participate in iCloud sync, controlled under Settings → Sync.
- Merge independent customization changes; for the same setting, the latest
  explicit edit wins. Treat column order as one value. Receiving a remote value
  must not manufacture another edit. This rare path does not need elaborate merging.
- watchOS assists the iPhone rather than implementing independent generic IMAP
  or introducing a content-fetching server gateway. Its initial scope is
  notifications, recent-mail browsing, cached-message reading, quick read/unread,
  flag, archive/trash triage, and Continue on iPhone.
- Without a reachable phone, cached messages remain readable and triage actions
  are persisted until reconnection. Show pending status and last synchronization;
  do not imply that cached mail is fresh or queued actions are already applied.
- When composer/SMTP lands in the other clients, the Watch also gains sending
  through the iPhone: short new messages, replies/reply-all, and forwarding using
  native text input/dictation and an explicit Send action. Hand off attachment
  management and longer editing to the iPhone.

## Sending release acceptance

0.0.1 cannot ship until IMAP and the complete sending workflow work on both Mac
and iPhone: compose, reply/reply-all, forward, attachments, saved drafts, a
persisted outbox with visible failure/retry, and a saved Sent copy. Failures must
never silently discard a message. Composer and SMTP remain a shared app/CLI
milestone (`cli.md`); implementing iOS first does not defer sending beyond 0.0.1.
Companion Watch sending arrives with that SMTP milestone through the iPhone.
Preserve both versions of concurrently edited drafts rather than silently losing
either. A submission whose server acceptance is uncertain must show "Delivery
status unknown" and require explicit retry; automatically retry only definitely
unsent transient failures.

## CLI mail and GUI-control parity

The CLI is a full standalone IMAP/SMTP client and a complete explicit driver for
the GUI. Ordinary queries and mail commands must not change GUI navigation,
focus, tabs, or visible composer state; resulting mailbox-data changes naturally
appear in views. Explicit UI commands control every in-app action. Structured
current-state queries and live updates expose GUI context without computer use.
Both modes share the app's mail runtime and command contracts (`cli.md`,
`automation.md`); neither mode is a reduced subset.

## Non-goals for 0.0.1
Threading, unified inbox, rules/snooze/send-later, JMAP, monetization,
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
