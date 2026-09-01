# Mailternal — Roadmap (frozen 2026-08-31)

| Version | Contents |
|---|---|
| **0.0.1** | macOS only. 1 IMAP account, text-only full-history newest-first sync, collapsible nested folder hierarchy, flat/non-threaded message list, viewer, `\Seen`-only writes, offline FTS search, IDLE + local notifications, MAS build. |
| **0.0.2** | Threading (References/In-Reply-To graph), triage actions (archive/delete/flag/move), compose + SMTP send. |
| **0.0.3** | iOS/iPadOS app, `mailternald`, APNs gateway, NSE content-free wake pipeline. |
| **0.0.4** | CLI (automation surface: search/export/daemon admin), multi-account, unified inbox. |
| Later | JMAP + Fastmail zero-knowledge push, Gmail OAuth + CASA, Thunderbird autoconfig, rules/snooze/send-later, monetization switch-on (lifetime purchase). |

Scope changes to this ladder require explicit sign-off; nothing shrinks silently.

0.0.1 acceptance note: full history is the target mode. The only documented
disk-pressure fallback is a halted backward backfill with mandatory "synced
through <date>" / "search covers mail since <date>" disclosure; it resumes
automatically when actual headroom recovers above the hysteresis threshold.
The reserve is `min(20 GiB, max(5 GiB, 2% of the volume))`, using important-usage
capacity when available. There is no setup-time 30-day cutoff, and no message
may be discarded while advancing the durable UID cursor.
