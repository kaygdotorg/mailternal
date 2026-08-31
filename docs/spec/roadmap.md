# Mailternal — Roadmap (frozen 2026-08-31)

| Version | Contents |
|---|---|
| **0.0.1** | macOS only. 1 IMAP account, text-only full-history newest-first sync, flat folder/message list, viewer, `\Seen`-only writes, offline FTS search, IDLE + local notifications, MAS build. |
| **0.0.2** | Threading (References/In-Reply-To graph), triage actions (archive/delete/flag/move), compose + SMTP send. |
| **0.0.3** | iOS/iPadOS app, `mailternald`, APNs gateway, NSE content-free wake pipeline. |
| **0.0.4** | CLI (automation surface: search/export/daemon admin), multi-account, unified inbox. |
| Later | JMAP + Fastmail zero-knowledge push, Gmail OAuth + CASA, Thunderbird autoconfig, rules/snooze/send-later, monetization switch-on (lifetime purchase). |

Scope changes to this ladder require explicit sign-off; nothing shrinks silently.

0.0.1 acceptance note: full history is the target mode; the documented disk-pressure
fallbacks (halted backfill, 30-day windowed mode) are **conforming** degraded states
with mandatory "search covers mail since <date>" disclosure, and resume automatically
when headroom recovers.
