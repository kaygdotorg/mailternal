# Mailternal — Roadmap (re-cut 2026-09-02)

**0.0.1 is the whole surface below.** Stability is the release criterion, not the
calendar. Milestones are ordered by dependency, not versioned.

| Milestone | Contents | Status |
|---|---|---|
| **M1 macOS app** | 1 IMAP account, text-only full-history newest-first sync, folder hierarchy, message list with swipe actions (configurable), reader islands, seen/unseen/flag/archive/trash queues, offline FTS search, IDLE + local notifications, deep links, MAS build. | landed, hardening |
| **M2 automation architecture** | State document + `Command` log, container socket, undo journal, settings surface, perf CI gates (`automation.md`). | next |
| **M3 CLI** | Bundled `mailternal` with read/triage parity, `--host` (SSH + paired TLS listener), Linux static build with vendored SQLite, `schema`, docs pipeline live (`cli.md`, `docs.md`). | |
| **M4 Gmail** | App Password path (default, guided) + bring-your-own OAuth client (advanced, PKCE, loopback); Gmail folder semantics (All Mail = archive, labels). Required on macOS, iOS and CLI. No CASA. | |
| **M5 composer + SMTP** | Composer state document (CLI-editable from day one), SMTP submission, `send`/`reply` in app and CLI together. | deferred until M1–M4 + iOS ship |
| **M6 iOS/iPadOS** | Same SwiftUI code, `NavigationSplitView`; `mailternald` + APNs gateway on a Proxmox VM; NSE content-free wake pipeline (`push.md`); pairing + iCloud Keychain handoff (`pairing.md`). | |
| Later | JMAP + Fastmail zero-knowledge push, our own verified Gmail OAuth client (when revenue justifies the annual assessment), Thunderbird autoconfig, threading, rules/snooze/send-later, monetization switch-on (lifetime purchase). | |

Scope changes to this ladder require explicit sign-off; nothing shrinks silently.

0.0.1 acceptance note: full history is the target mode. The only documented
disk-pressure fallback is a halted backward backfill with mandatory "synced
through <date>" / "search covers mail since <date>" disclosure; it resumes
automatically when actual headroom recovers above the hysteresis threshold.
The reserve is `min(20 GiB, max(5 GiB, 2% of the volume))`, using important-usage
capacity when available. There is no setup-time 30-day cutoff, and no message
may be discarded while advancing the durable UID cursor.
