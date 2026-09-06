# Mailternal — Roadmap (re-cut 2026-09-02)

**0.0.1 is the whole surface below.** Stability is the release criterion, not the
calendar. Milestones are ordered by dependency, not versioned.

| Milestone | Contents | Status |
|---|---|---|
| **M1 macOS app** | Current multi-account macOS functionality is the parity baseline: text-only full-history newest-first sync, folder hierarchy, message list with configurable swipe actions, reader islands, persisted triage queues, offline FTS search, IDLE + local notifications, deep links, MAS build. Add configurable message-table columns and list-above-reader layout without removing the existing layout. | landed baseline, hardening and layout expansion |
| **M2 automation architecture** | State document + `Command` log, container socket, undo journal, settings surface, perf CI gates (`automation.md`). | next |
| **M3 CLI** | Bundled `mailternal` with read/triage parity, `--host` (SSH + paired TLS listener), Linux static build with vendored SQLite, `schema`, docs pipeline live (`cli.md`, `docs.md`). | |
| **M4 Gmail** | App Password path (default, guided) + bring-your-own OAuth client (advanced, PKCE, loopback); Gmail folder semantics (All Mail = archive, labels). Required on macOS, iOS and CLI. No CASA. | |
| **M5 composer + SMTP** | Shared CLI-editable composer state and app/CLI submission. Mac and iPhone require compose, reply/reply-all, forward, attachments, saved drafts, a persisted outbox with visible failure/retry, and a saved Sent copy. | required for 0.0.1; may follow iOS implementation, not its release |
| **M6 iOS/iPadOS** | Native iOS surface over shared mail behavior; `mailternald` + APNs gateway on a Proxmox VM; NSE content-free wake pipeline (`push.md`); pairing + iCloud Keychain handoff (`pairing.md`). iCloud workspace metadata and all customizations, including per-folder overrides, sync without interrupting active reading; onboarding and Settings → Sync control participation. | Native development builds include macOS/iOS account pairing. Phone installation, live mail connection/reading, and reciprocal real-device pairing remain verification gates; see `pairing.md`. |
| Later | JMAP + Fastmail zero-knowledge push, our own verified Gmail OAuth client (when revenue justifies the annual assessment), Thunderbird autoconfig, threading, rules/snooze/send-later, monetization switch-on (lifetime purchase). | |

Scope changes to this ladder require explicit sign-off; nothing shrinks silently.

The Watch begins with reading, quick triage, and handoff as an iPhone companion,
not an independent IMAP client. Sending through the iPhone joins when the other
clients' composer/SMTP milestone lands: short new messages, reply/reply-all, and
forwarding with explicit Send; attachment management and longer editing hand off
to iPhone. Cached reading and persisted queued triage remain available when the
phone is unreachable, with pending and last-sync status.
The Mac/iPhone IMAP and full sending requirements are release gates, not optional
post-0.0.1 milestones. See `product.md` and decisions 31–33.

0.0.1 acceptance note: full history is the target mode. The only documented
disk-pressure fallback is a halted backward backfill with mandatory "synced
through <date>" / "search covers mail since <date>" disclosure; it resumes
automatically when actual headroom recovers above the hysteresis threshold.
The reserve is `min(20 GiB, max(5 GiB, 2% of the volume))`, using important-usage
capacity when available. There is no setup-time 30-day cutoff, and no message
may be discarded while advancing the durable UID cursor.
