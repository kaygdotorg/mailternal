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
