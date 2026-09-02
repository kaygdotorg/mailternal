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
9. **Consumer Gmail deferred.** Restricted-scope OAuth requires Google verification +
   annual CASA assessment; not worth it pre-traction. Explicitly unsupported in docs.
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
19. **Gmail via App Password (default) + bring-your-own OAuth client (advanced); no
    CASA.** Google requires an annual lab assessment ($540–1,800/yr) for any app
    shipping its own restricted-scope client id; Thunderbird/K-9/Mimestream pay it,
    FairEmail/mutt/aerc don't. Unverified projects cap at 100 lifetime users. App
    passwords remain officially supported for consumer IMAP/SMTP with 2SV (research/
    google-gmail-oauth-verification-2026.md). Web-session scraping is blocked by
    Google and against ToS (it killed Mailplane) — never. Revisit when revenue
    justifies the fee.
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
