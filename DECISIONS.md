# Mailternal — Decision Log

Contested calls and their *why*, so future-us doesn't relitigate. Format: decision →
rationale → revisit-when.

1. **Swift everywhere, no Rust core.** Static musl Linux binaries verified viable
   (Swift Static Linux SDK); daemon workload is IO-bound (SwiftNIO), neutralizing
   Rust's 2–10x CPU-microbenchmark edge; UniFFI bindings would tax every build
   forever. Revisit: only if MIME-parse profiling demands — then vendor one parser,
   not a rewrite. (Sources: research/swift-static-binaries-2026.md)
2. **AGPLv3, unenforced self-hosting.** Real OSS; gateway-based payment enforcement
   rejected. A fork shipping its own Apple key is a competitor doing real work, not
   freeloading. Accepted knowingly.
3. **Lifetime purchase, post-0.1.** No monetization code before there's a product.
4. **Original read-only first-build scope is superseded by decision 33.** The initial
   performance-focused cut deferred compose and allowed only `\Seen` writes.
   It is not the 0.0.1 release contract.
5. **Text-only full-history sync; attachments on demand.** Full text history is what
   makes offline search the flagship feature; attachments dominate mailbox size and
   are rarely re-read. Separate caches: SQLite for text, content-hash files (LRU,
   2 GB default) for attachments. Insufficient space up front → 30-day window.
6. **No subject-based thread merging.** False merges destroy trust faster than false
   splits. Strict References/In-Reply-To graph; JWZ subject pass may bolt on later
   behind the thread-builder interface.
7. **Mac App Store only.** Sandboxed app reaches localhost mailternald fine; dropping
   the direct/Sparkle channel deletes a second behavior profile and test matrix.
8. **Push posture: "zero-content", not "E2EE".** IMAP watching requires the daemon to
   hold credentials; we say so plainly. True zero-knowledge arrives with JMAP
   PushSubscription relay and is marketed only there.
9. **Consumer Gmail OAuth deferred.** A Mailternal-owned restricted-scope OAuth client
   requires Google verification + annual CASA assessment; App Password IMAP remains
   the shipped 0.0.1 path for accounts with 2-Step Verification.
10. **iOS 26 / macOS 26 minimums.** Newest SwiftUI; no legacy weight at launch.
11. **FTS5 `unicode61 remove_diacritics 2`.** Right for whitespace-delimited scripts;
    porter is English-biased, trigram triples the index. *Known limitation*: unicode61
    does no CJK word segmentation, so CJK search is materially weaker in 0.0.1 —
    documented, with an ICU-backed segmentation strategy planned post-0.0.1.
12. **Own MIME parser, corpus-driven.** No mature cross-platform Swift MIME parser
    exists; C options (gmime/libetpan) drag GLib or unmaintained code across the
    Linux static build. We write ours against a conformance corpus + fuzzing + strict
    limits (sync.md "MIME"), with quarantine so a poison message never stalls a
    folder. Revisit if the corpus defeats us.
13. **Wake pushes are visible generic alerts, not silent pushes.** APNs only invokes
    an NSE for `mutable-content:1` alert payloads; silent `content-available` wakes
    go to the app and are throttled. Generic "New mail" alert + NSE rewrite gives an
    automatic timeout fallback and keeps APNs content-free.
14. **CLI is a remote control for the whole app, not a second client.** All UI state
    is one Codable state document mutated only by a `Command` enum; the CLI sends the
    same commands over a container socket. Structural parity (exhaustive switch)
    beats "automation bolted on" — every later screen would need its own hooks.
    Performance thresholds are CI gates (`automation.md`). Revisit: never.
15. **Unix socket + newline JSON, not XPC.** One protocol serves the app, `mailternald`
    and a future iOS client; XPC is macOS-only and cannot serve the daemon.
16. **Remote access = SSH or a paired TLS listener bound to the overlay interface.**
    Tailscale/NetBird are transport, not auth: per-client bearer token + pinned
    self-signed cert learned only via pairing. Credentials never leave the Mac.
17. **Reversibility over gates.** Mutating CLI commands need no `--yes`; an
    `op_journal` shared with ⌘Z makes them undoable. `--yes` trains agents to pass it
    reflexively; undo actually protects.
18. **Message identity is the deep link everywhere** (AccountLinkID + folder locator +
    UIDVALIDITY/UID): non-secret, stable, cross-device; CLI rows print it as `link`.
19. **Gmail via App Password shipped in 0.0.1 for 2SV accounts; OAuth stays deferred.**
    Google App Passwords remain officially supported for consumer IMAP/SMTP with 2SV,
    avoiding the verification and annual CASA assessment required by a Mailternal-owned
    restricted-scope OAuth client. Web-session scraping is blocked by Google and against
    its ToS (it killed Mailplane) — never. Revisit OAuth when revenue justifies the fee.
20. **Pairing is a direction-free handshake.** QR/8-word code carries a session key +
    rendezvous; the encrypted bundle then flows either way (push or pull), covering
    every device pair. iCloud Keychain sync when both devices share an iCloud
    account; CLI reads the same Keychain item via a shared access group.
21. **Static Linux CLI vendors SQLite.** GRDB expects system `libsqlite3`, which the
    Static Linux SDK lacks; bundle the amalgamation as a C target (macOS uses system
    SQLite). Bigger binary accepted; measure, maybe publish both variants.
22. **Docs are generated reference + hand-written Diátaxis guides, built from the
    repo by Kiln on tag** (`docs.md`). Public symbols only; denylist grep before
    deploy. Doc changes ride with the code change (AGENTS.md policy).
23. **Everything above is 0.0.1** (macOS, CLI, Gmail, iOS + daemon); composer/SMTP is
    the last milestone. Stability, not calendar, decides the release.
24. **UI performance is tested with XCUITest + signposts on the mbp runner** under the
    `agents` user (dedicated automation Mac arrives October). Wall-clock asserts do
    not belong in the unit suite (load flakes under parallel builds).
25. **Bound IMAP parser and line buffering to 1 MiB via a temporary NIOIMAP fork.** The upstream
    `IMAPClientHandler` hardcodes NIO's single-step decoder buffer to the much smaller
    `IMAPDefaults.lineLengthLimit`, and does not expose that setting. Mailternal therefore
    uses `kaygdotorg/swift-nio-imap`, branch `mailternal/line-buffer`, revision
    `0c03790b44b95ae1d57de17a6518a3f77bf10088`, and applies one 1 MiB limit to the
    decoder buffer, response-parser buffer, and response literals. This bounds memory while
    allowing legitimate large FETCH responses; an oversized response remains a
    non-transport parse error for per-UID isolation. The upstream PR
    https://github.com/apple/swift-nio-imap/pull/849 proposes the small
    `IMAPClientHandler` initializer parameter so this fork can be retired once the API is
    accepted and released. Revisit: replace the fork with the upstream release.
26. **Reader tabs occupy the native main-window titlebar toolbar; the transient persists.**
    A measured toolbar item over the rightmost reader column keeps the reader
    content at its original top inset while a browser-like strip supplies
    familiar compression, scrolling, and keyboard mechanics. The strip is
    clear, has an 8 pt leading inset, intrinsic 72–220 pt tab widths
    (`leading slot + subject width + inter-item spacing + title paddings`), 8 pt
    gaps, and a 28 pt transparent trailing fade that reaches the fixed native
    message-actions cluster with no extra gap. The reader-tabs toolbar item has
    no label or tooltip and toolbar customization is disabled. The strip is
    absent when the reader has no tabs or global search is presented.
    Hovering immediately presents a non-activating 220×160 child panel with a
    scrollable card and no entrance animation; a 150 ms grace period keeps it
    open while the pointer moves between tab and card. Persisting the transient
    preserves the user's open reading context and its scroll position across
    launches rather than silently discarding a real tab. Persisted links that
    no longer resolve, or details removed before load, close silently and never
    leave a phantom tab or endless reader spinner. Tabs deliberately show no
    unread or flag marks: those states belong to message-list triage, while tab
    titles stay quiet and scannable. Tabs are main-window-only so detached
    message windows remain focused, simple, and tab-less instead of creating a
    second tab state to synchronize. Revisit: only if a future multi-window
    reader model can preserve one unambiguous tab owner.
27. **Process-wide backfill resource budgets are bounded and shared.** All account
    engines acquire connection permits from one `BackfillConnectionBudget`, capped at
    four backfill connections total; the primary sync channel counts while the
    dedicated IDLE channel does not. Each backfill window fetches metadata without
    literals, then groups compatible MIME sections within contiguous newest-first
    cohorts. Requests retain the 1 MiB header and 4 MiB text-part limits; both each
    FETCH response and retained cohort bodies are capped at 32 MiB. Literal
    declarations are checked before receive/assembly, and the lossless response
    stream pauses socket reads at its high watermark. Oversized responses bisect
    the window on fresh connections before cursor advancement. Store writes
    commit bounded batches of at most 64 rows or 1 MiB decoded content. Default
    sessions share four NIO event loops and TLS contexts keyed to the complete
    trust-root snapshot; injected event loops remain caller-owned.
    A historical pre-batching five-minute single-account headless sample on
    the 1,636,773,888-byte fixture measured 119,728 KB peak RSS and 55.733% average
    CPU; the dual-account resource bound is analytical from the shared four-permit
    pool and bounded window/write budgets. Revisit: only if profiling shows a lower
    cap preserves acceptable throughput.
28. **Retain a bounded WebKit surface per reader tab.** Each open tab keeps its
    rendered `MessageWebView` and native scroll position so switching tabs is an
    AppKit child-view swap rather than another `loadHTMLString`. The pool is
    capped at eight most-recently-used surfaces; opening beyond the cap evicts
    the least-recently-used surface, and every tab-close path drops its surface
    and cached height immediately. Reading-mode changes inject style into all
    retained documents. The outer reader scroll hierarchy also remains mounted;
    restoration waits for the matching tab/message representation rather than
    replacing the scroll view and relying on multi-second delayed retries.
    Revisit: only if memory profiling on real newsletter workloads shows eight
    surfaces is too high or too low.
29. **Gate loaded reader-tab commits at 100 ms while keeping main-thread work at
    16 ms.** The initial 20 ms candidate was uncalibrated and below repeatable
    end-to-end AppKit/SwiftUI commit time even when retained surfaces performed
    zero HTML navigations. A historical dedicated-VM run measured ten
    selection-to-reader-commit switches, 95.9 ms maximum, with zero navigations.
    That callback measurement excludes pointer gesture arbitration and is not
    proof of input-to-display latency. The 100 ms ceiling still governs the full
    input-to-reader-commit path; single-click tab activation must not wait on a
    higher-priority double-click recognizer. QA distinguishes command dispatch,
    matching surface readiness, and restored scroll state. Neither a readiness
    callback nor a Core Animation transaction completion claims physical display
    presentation. The separate 16 ms main-thread work budget remains unchanged.
    Revisit: lower the ceiling after complete input-path measurements justify it;
    never raise either threshold without a new measured decision.
30. **Warm a bounded, direction-aware local reader-detail window.** Cache up to
    24 navigation details and 8 MiB of body/HTML text, separately from retained
    tab details. Coalesce interactive loads by message identity and generation;
    stale results cannot replace the current selection. Warm eight neighbors
    ahead of keyboard travel and four behind through one local store batch of
    at most 12 IDs. Refresh cached neighbors' recency before replenishing the
    window so speculative insertion does not evict the next likely selection.
    Ordinary envelope display does not fetch raw source; only explicit source
    inspection does. Native text measurement does not mutate the view frame.
    A cached-fixture VM replay of 80 Down/Up inputs at 33 ms intervals reduced
    observed loading inputs from 73 to one and spinner exposure from about
    1.30 s to 46 ms before the subsequent eviction-priority fix. These are
    application/view lifecycle measurements, not physical display latency.
    A later mixed live/replay run is not a comparable timing sample. Keep
    genuine loading feedback: no debounce, delayed spinner, stale-body display,
    remote fetch, or attachment warm-up. Revisit: only if measured cache misses
    justify changing the bounded local window.
31. **watchOS is an iPhone companion, not an independent IMAP client.** Normal
    watchOS apps cannot use the direct TCP/TLS transport generic IMAP requires
    (Apple TN3135); audio streaming's exception does not apply to mail. Rather
    than introduce a content-fetching HTTPS gateway or provider-specific client,
    the Watch initially provides reading, quick triage, and handoff through the
    iPhone. When composer/SMTP lands in the other clients, the Watch also supports
    sending through its iPhone companion, not direct Watch SMTP. Cached reading
    remains available without a reachable phone; triage actions persist until
    reconnection, with pending status and last-sync visibility, not a freshness
    guarantee. Watch composition supports short new messages, reply/reply-all,
    and forwarding with native input/dictation and explicit Send; attachment
    management and longer editing hand off to iPhone. Revisit: only if supported
    Watch networking changes or independent operation is requested.
32. **Apple workspace metadata and all customizations sync through iCloud.**
    Synchronize immediately when connectivity permits without interrupting
    interactive reading; adopt handoff when resuming an inactive device. Offer
    participation during onboarding and controls under Settings → Sync. Column
    configuration has global defaults plus per-folder overrides; all customization
    settings, including widths and overrides, participate rather than silently
    remaining device-local. Workspace sync is distinct from mailbox synchronization
    and Keychain credential sharing. A per-device master switch plus category
    switches controls participation; disabling preserves local settings and the
    cloud copy. Merge independent settings and use the latest explicit edit for
    a same-setting conflict; receiving a remote value is not a new edit. Keep this
    rare conflict path simple rather than building elaborate merge machinery.
    Re-enabling a category with differing local/cloud settings asks which to keep:
    "Use this device's settings" or "Use synced settings." Matching values enable
    immediately. Revisit: only if a different ownership model is explicitly requested.
33. **0.0.1 requires complete IMAP and sending workflows on Mac and iPhone.**
    Current working macOS functionality is the parity baseline, not the obsolete
    one-account/read-only scope. Compose, reply/reply-all, forward, attachments,
    saved drafts, a persisted outbox with visible failure/retry, and a saved Sent
    copy are release requirements. App and CLI sending retain the shared command
    contract; companion Watch sending arrives with the same SMTP milestone.
    Preserve both versions of conflicting drafts. No SMTP failure may silently
    discard a message: ambiguous submission requires visible "Delivery status
    unknown" and an explicit retry choice, not an automatic duplicate-risk resend.
    Implementation order may put SMTP last, but cannot move it outside 0.0.1.
    Revisit: only with explicit release-scope approval.
34. **The CLI is a complete mail client and an explicit, state-aware GUI driver.**
    Standalone IMAP/SMTP does not require the GUI process. When connected to the
    app, queries and mail operations reuse its runtime without implicitly changing
    navigation, focus, tabs, or the visible composer. Ordinary data changes still
    propagate to views. Explicit UI commands expose every in-app action; structured
    current-state snapshots and live updates expose GUI context so agents need no
    screenshot/coordinate automation. All surfaces use the same mail runtime and
    command contracts, not competing client implementations. Revisit: never reduce
    either standalone mail parity or explicit GUI automation coverage.
