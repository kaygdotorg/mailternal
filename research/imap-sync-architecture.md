## 1. Start UI from local cache before any network

- **Local DB is the source of truth; the network is a sync channel, not a data source** — UI observes reactive streams from the local store and never blocks on a socket. — https://tiwariashuism.medium.com/offline-first-android-architecture-the-complete-engineering-guide-be78c102c59d
- **RFC 4549 (the canonical disconnected-IMAP client spec)** frames the client as a local replica + a "driver" that issues the minimal IMAP command set to reconcile it; treat network connections as *expensive*, never leave them idle during local I/O. — https://www.rfc-editor.org/rfc/rfc4549.html
- **All disconnected-client operations must key on UID, not sequence numbers**, so client and server provably refer to the same messages across reconnects (RFC 4549 §3). — https://datatracker.ietf.org/doc/html/rfc4549
- **RFC 4549 explicitly rejects a single universal sync strategy** — "there is no single synchronization strategy appropriate for all cases"; descriptor-only (envelope/flags, no bodies) is a legitimate terminal state for archival folders. — https://www.rfc-editor.org/rfc/rfc4549.html
- **Never wipe local cache on a paginated refetch; merge**, and make each sync batch a complete transaction or a full rollback — no half-updated DB. — https://medium.com/@enesselcuk/local-first-offline-first-architecture-on-android-synchronization-and-reactive-state-management-314129d136dd
- **Product-level contrast**: Spark keeps mail server-side and caches only ~1 month of messages/attachments for offline; Canary stores locally and runs AI on-device — two opposite answers to "how much cache." — https://sparkmailapp.com/help/general/email-storage-and-backups · https://setapp.com/app-reviews/canary-mail-vs-spark-mail
- **Mimestream** syncs directly to the Gmail API (no intermediary service), stores everything on-device, and skips IMAP entirely to preserve Gmail's label/thread data model. — https://mimestream.com/trust/security-and-privacy · https://tidbits.com/2023/05/24/why-i-use-mimestream-for-gmail/

## 2. INBOX-first / selected-folder-first prioritization

- **Nylas sync-engine keeps an explicit ordered folder list "in order of sync priority," with INBOX required and first** for generic IMAP. — https://github.com/nylas/sync-engine/blob/master/inbox/crispin.py
- **Folder SELECT is expensive**, so Nylas's Crispin client operates on the currently-selected folder and deliberately leaves it selected after a call rather than re-selecting. — https://github.com/nylas/sync-engine/blob/master/inbox/crispin.py
- **Headers first, bodies selectively**; use `BODY.PEEK[]` (not `RFC822`) to avoid auto-\Seen, and back off exponentially on `[OVERQUOTA]`. — https://www.unipile.com/imap-api-python/
- **RFC 5819 LIST-STATUS** returns per-mailbox STATUS inline with LIST — one round trip for the whole folder tree instead of LIST + N× STATUS. This is the single biggest win for "show the folder list with unread counts instantly." — https://www.rfc-editor.org/rfc/rfc5819.html
- **RFC 8438 `STATUS=SIZE`** extends STATUS with mailbox size, useful for ordering backfill by cost. — https://www.rfc-editor.org/rfc/rfc8438.txt

## 3. Concurrent IMAP connections per account

- **RFC 2683 §3.1.1 gives no numeric cap** but is emphatic: "you must avoid making multiple connections to the same *mailbox* in your own client (for load balancing or other such reasons)" and "NO SERVER IS GUARANTEED TO SUPPORT THIS" — handle both a failing second SELECT and the server killing your first connection. — https://www.rfc-editor.org/rfc/rfc2683.txt
- **Gmail: 15 simultaneous IMAP connections per account**, shared across every client and device signed in. — https://workspaceforensics.com/gmail-deliverability/gmail-sync-connection/imap-too-many-simultaneous-connections-15/ · Google's own page confirms the failure mode without the number: https://support.google.com/mail/answer/7126229
- **Gmail also enforces ~2,500 MB/day IMAP download bandwidth**, so connection count isn't the only budget during backfill. — https://www.unipile.com/imap-api-python/ · https://knowledge.workspace.google.com/admin/gmail/gmail-bandwidth-limits
- **Dovecot: `mail_max_userip_connections` defaults to 10**, per-user *per source IP*, counted separately for IMAP and POP3, and enforced on backends only (not proxies). This is the de-facto floor for self-hosted/indie hosts. — https://doc.dovecot.org/main/core/admin/limits.html · https://doc.dovecot.org/2.3/settings/core/
- **Fastmail documents a login-rate limit (500 successful logins / 10 min / user across all services)** rather than a published concurrent-connection cap — design for login-rate pressure, not just socket count. — https://www.fastmail.help/hc/en-us/articles/1500000277382-Account-limits
- **Fastmail's own engineering position**: IDLE only watches one folder, so multi-folder push forces one connection per folder, which "may run into problems… as some servers limit the number of simultaneous connections for a user" — their argued fix is JMAP push, not more sockets. — https://www.fastmail.com/blog/what-we-talk-about-when-we-talk-about-push/
- **iCloud is commonly reported at ~5 concurrent connections per account** — treat as the tightest mainstream target. ⚠️ Only SEO-blog sourcing found; not in Apple docs. — https://mailboxtaxi.com/troubleshooting/fix-too-many-imap-connections
- **MailCore2 (the engine behind Canary, Airmail, and many macOS/iOS clients) defaults to `DEFAULT_MAX_CONNECTIONS 3`** per `IMAPAsyncSession`, with `allowsFolderConcurrentAccessEnabled = true` by default and a warning that "some older IMAP servers don't like this." — https://github.com/MailCore/mailcore2/blob/master/src/async/imap/MCIMAPAsyncSession.cpp · https://github.com/MailCore/mailcore2/blob/master/src/objc/imap/MCOIMAPSession.h
- **Thunderbird ships "Maximum number of server connections to cache" = 5** per account (Server Settings → Advanced); the standard fix for connection errors is lowering it to 1–3. — https://my.wirenine.com/knowledgebase/4170/How-to-change-the-maximum-number-of-IMAP-connections-in-Mozilla-Thunderbird.html · https://bugzilla.mozilla.org/show_bug.cgi?id=561055
- **Practical synthesis**: 3–5 pooled connections per account is the shipped consensus (MailCore2 3, Thunderbird 5), which stays under iCloud's ~5 and well under Dovecot's 10 and Gmail's 15 — leaving headroom for the user's phone on the same account.

## 4. Lazy per-folder sync on selection vs. background full sync

- **Thunderbird's model**: headers for *all* messages in *all* IMAP folders (to build the local index), bodies **on demand only** unless a folder is explicitly marked for offline use. — https://support.mozilla.org/en-US/kb/imap-synchronization
- **Offline-for-this-folder is an explicit per-folder opt-in** in Thunderbird (Account Settings → Synchronization & Storage), i.e. the "background full sync" is user-scoped rather than automatic. — https://support.mozilla.org/en-US/questions/1288270
- **RFC 4549 endorses tiered depth per mailbox** — for archival mailboxes, fetching just enough descriptor info to identify messages *is* the whole sync step; full-body download is deferred to user selection. — https://www.rfc-editor.org/rfc/rfc4549.html
- **Gmail server-side folder cap**: users can set "Limit IMAP folders to contain no more than N messages" (10,000 default option) — a lazy client should honor/expect truncated folders. — https://support.google.com/mail/answer/7126229

## 5. QRESYNC / CONDSTORE incremental sync

- **RFC 7162 is the spec**: CONDSTORE gives per-message MODSEQ + conditional STORE (conflict detection between concurrent writers); QRESYNC adds `SELECT … (QRESYNC (uidvalidity modseq …))` returning changed flags **and** `VANISHED` expunges in a *single round trip* on reconnect. — https://www.rfc-editor.org/rfc/rfc7162.html
- **Superseded RFC 5162** is the earlier QRESYNC spec; cite 7162 (2014), and note `draft-ietf-qresync-rfc5162bis` is the lineage. — https://www.rfc-editor.org/rfc/rfc5162.html · https://datatracker.ietf.org/doc/html/draft-ietf-qresync-rfc5162bis-10
- **Server support reality**: Dovecot, Cyrus, Zimbra, and iCloud support both CONDSTORE and QRESYNC; **Gmail supports CONDSTORE only, not QRESYNC** — so you need a non-QRESYNC fallback path (UID FETCH ranges + UID SEARCH for expunges) regardless. — https://bugzilla.mozilla.org/show_bug.cgi?id=1747311
- **Thunderbird still has neither, as of this bug's latest activity** — bug 1747311 is NEW/unimplemented after 4 years, the assignee has "no immediate plans," and it blocks Thunderbird's IMAP-performance meta-bugs. Don't cite Thunderbird as a QRESYNC reference implementation. — https://bugzilla.mozilla.org/show_bug.cgi?id=1747311
- **Also gate on UIDVALIDITY**: a change means the local folder replica is invalid and must be rebuilt — this is the one case where wiping cache is correct. — https://www.rfc-editor.org/rfc/rfc4549.html

## 6. Batching SQLite writes during backfill

- **WAL + `synchronous = NORMAL` is the standard pairing** — WAL is "the single biggest performance improvement for most workloads," and NORMAL lets commits return before the fsync lands, which Android's official guidance calls a win "at no material cost." — https://developer.android.com/topic/performance/sqlite-performance-best-practices
- **Wrapping N inserts in one transaction turns N fsyncs into 1** — commonly 100×–1000× on bulk paths. This is the dominant factor during backfill, ahead of prepared-statement reuse. — https://developer.android.com/topic/performance/sqlite-performance-best-practices · https://phiresky.github.io/blog/2020/sqlite-performance-tuning/
- **Chunk, don't use one giant transaction** — commit every ~1k–10k rows so a crash or cancel mid-backfill loses one chunk, not the whole run, and the WAL doesn't balloon. — https://sqlpey.com/c/boosting-sqlite-insert-speed/
- **Secondary pragmas that matter for backfill**: raise `cache_size`, `temp_store = MEMORY`, and defer/rebuild secondary indexes (incl. FTS) rather than maintaining them per-row. — https://powersync.com/blog/sqlite-optimizations-for-ultra-high-performance · https://phiresky.github.io/blog/2020/sqlite-performance-tuning/
- **WAL's real payoff for a mail client is reader concurrency** — the UI keeps reading the cache at full speed while the backfill writer commits, which is what makes point (1) hold up under a cold sync. — https://phiresky.github.io/blog/2020/sqlite-performance-tuning/

---

**Sourcing caveats worth knowing before you design against these numbers:** the Gmail-15 and iCloud-5 figures are from third-party/SEO knowledge-base pages, not vendor documentation — Google's official page describes the error but never publishes the number, and Apple publishes nothing. Fastmail publishes a login-rate limit but no concurrency cap. The only *authoritative* per-user connection number I found is Dovecot's documented default of 10. The MailCore2 (3) and Thunderbird (5) client-side defaults are solid ground and imply everyone is already designing to a low single-digit budget.

**Notable gap:** Apple Mail's and Spark's internal sync architectures are effectively undocumented — every result was a review site or a support forum, so I'd treat any claim about them as unverified. Mimestream is documented but is Gmail-API-only, so it doesn't inform IMAP connection strategy at all.

*(Aside: the claude.ai Gmail/Calendar/Drive connectors in this session are unauthorized and can't be authorized non-interactively — irrelevant to this research, but flagging it since it was reported.)*

## Sources

- [RFC 4549 — Synchronization Operations for Disconnected IMAP4 Clients](https://www.rfc-editor.org/rfc/rfc4549.html)
- [RFC 2683 — IMAP4 Implementation Recommendations](https://www.rfc-editor.org/rfc/rfc2683.txt)
- [RFC 7162 — CONDSTORE / QRESYNC](https://www.rfc-editor.org/rfc/rfc7162.html)
- [RFC 5162 — Quick Mailbox Resynchronization](https://www.rfc-editor.org/rfc/rfc5162.html)
- [RFC 5819 — STATUS in Extended LIST](https://www.rfc-editor.org/rfc/rfc5819.html)
- [RFC 8438 — IMAP STATUS=SIZE](https://www.rfc-editor.org/rfc/rfc8438.txt)
- [Dovecot — Limits](https://doc.dovecot.org/main/core/admin/limits.html) · [Dovecot Core Settings](https://doc.dovecot.org/2.3/settings/core/)
- [Fastmail — Account limits](https://www.fastmail.help/hc/en-us/articles/1500000277382-Account-limits) · [Fastmail — What we talk about when we talk about push](https://www.fastmail.com/blog/what-we-talk-about-when-we-talk-about-push/)
- [Google — Add Gmail to another email client](https://support.google.com/mail/answer/7126229) · [Gmail bandwidth limits](https://knowledge.workspace.google.com/admin/gmail/gmail-bandwidth-limits)
- [Workspace Forensics — IMAP "Too many simultaneous connections" (15)](https://workspaceforensics.com/gmail-deliverability/gmail-sync-connection/imap-too-many-simultaneous-connections-15/)
- [Mailbox Taxi — Fix "Too Many Simultaneous Connections"](https://mailboxtaxi.com/troubleshooting/fix-too-many-imap-connections)
- [MailCore2 — MCIMAPAsyncSession.cpp](https://github.com/MailCore/mailcore2/blob/master/src/async/imap/MCIMAPAsyncSession.cpp) · [MCOIMAPSession.h](https://github.com/MailCore/mailcore2/blob/master/src/objc/imap/MCOIMAPSession.h)
- [Thunderbird — IMAP Synchronization](https://support.mozilla.org/en-US/kb/imap-synchronization) · [Sync & Storage defaults](https://support.mozilla.org/en-US/questions/1288270) · [Max cached connections = 5](https://my.wirenine.com/knowledgebase/4170/How-to-change-the-maximum-number-of-IMAP-connections-in-Mozilla-Thunderbird.html) · [Bug 561055](https://bugzilla.mozilla.org/show_bug.cgi?id=561055) · [Bug 1747311 — QRESYNC/CONDSTORE](https://bugzilla.mozilla.org/show_bug.cgi?id=1747311)
- [Nylas sync-engine — crispin.py](https://github.com/nylas/sync-engine/blob/master/inbox/crispin.py) · [How We Use Python to Sync Billions of Emails](https://www.nylas.com/blog/billions-of-emails-synced-with-python/)
- [Mimestream — Security and Privacy](https://mimestream.com/trust/security-and-privacy) · [TidBITS — Why I Use Mimestream](https://tidbits.com/2023/05/24/why-i-use-mimestream-for-gmail/)
- [Spark — Email Storage and Backups](https://sparkmailapp.com/help/general/email-storage-and-backups) · [Setapp — Canary vs Spark](https://setapp.com/app-reviews/canary-mail-vs-spark-mail)
- [Unipile — IMAP API in Python (2026)](https://www.unipile.com/imap-api-python/)
- [Android — SQLite performance best practices](https://developer.android.com/topic/performance/sqlite-performance-best-practices) · [phiresky — SQLite performance tuning](https://phiresky.github.io/blog/2020/sqlite-performance-tuning/) · [PowerSync — SQLite optimizations](https://powersync.com/blog/sqlite-optimizations-for-ultra-high-performance) · [sqlpey — Boosting SQLite insert speed](https://sqlpey.com/c/boosting-sqlite-insert-speed/)
- [Offline-First Android Architecture](https://tiwariashuism.medium.com/offline-first-android-architecture-the-complete-engineering-guide-be78c102c59d) · [Local-First/Offline-First Architecture](https://medium.com/@enesselcuk/local-first-offline-first-architecture-on-android-synchronization-and-reactive-state-management-314129d136dd)
