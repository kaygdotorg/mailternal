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
4. **0.0.1 is read-only, no compose, no threading.** Deliberate scope cut for a
   performant, working first build. `\Seen` sync is the one write — a truly read-only
   client would corrupt unread state on the user's other clients.
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
    literals, then requests one UID/section at a time with a 1 MiB header limit, a
    4 MiB text-part limit, and a 32 MiB aggregate PEEK-body budget. Store writes
    commit bounded batches of at most 64 rows or 1 MiB decoded content, avoiding
    caller-sized FTS/write arrays. A five-minute single-account headless sample on
    the 1,636,773,888-byte fixture measured 119,728 KB peak RSS and 55.733% average
    CPU; the dual-account resource bound is analytical from the shared four-permit
    pool and bounded window/write budgets. Revisit: only if profiling shows a lower
    cap preserves acceptable throughput.
