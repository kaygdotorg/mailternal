# 0.0.1 Implementation Plan — Chunks & Waves

Build host: `agents@mbp` (macOS 26.6, Xcode 26.6, Swift 6.3, xcodegen). This Linux
workspace holds the source of truth; agents rsync to `agents@mbp:~/mailternal-build/<chunk>/`
to compile/test **their own module only**. Integration builds are serialized by the
integration owner. Test launches: `ssh kayg@mbp open <app>` into the user's session.

## Module layout (SwiftPM package + xcodegen app project)
```
Package.swift                 — MailternalCore (lib), targets below
Sources/MailternalCore/
  Interfaces/                 — shared contracts (wave 0, frozen during wave 1)
  IMAP/                       — chunk B
  MIME/                       — chunk C
  Store/                      — chunk D
  Sanitizer/                  — chunk E (core half)
  Sync/                       — chunk F (wave 2)
App/                          — xcodegen project.yml, macOS app target (chunk A UI)
Scripts/build-mbp.sh          — rsync + xcodebuild driver
```

## Waves
- **Wave 0** (integration owner): scaffold — Package.swift, module dirs, frozen
  `Interfaces/` (envelope/bodystructure/store-writer/sync-event/`MailFacade` types),
  project.yml, entitlements, build script; verified compiling on mbp before fan-out.
- **Wave 1** (parallel; no cross-chunk edits; interfaces frozen):
  - **A. AppShell** — window shell + sidebar + NSTableView message list + viewer
    scaffold + account-setup UI + toasts + ⌘K search, per design.md, driven entirely
    by `MailFacade` with an in-memory mock.
  - **B. ImapEngine** — session layer: TLS/auth/capabilities, LIST discovery, PEEK
    fetch, UID STORE, IDLE, QRESYNC/CONDSTORE/basic delta primitives.
  - **C. MimeParser** — corpus-driven parser with spec limits.
  - **D. MailStore** — GRDB schema/migrations, FTS5 + triggers, keyset pagination,
    seen-op queue, generations/cursors, attachment cache LRU.
  - **E. HtmlIsolation** — sanitizer (core) + WKWebView config, content rules, local
    scheme handler (app side).
- **Wave 2** (parallel where possible):
  - **F. SyncEngine** — backfill/delta/topology/disk-policy/notification baseline,
    integrating B+C+D.
  - **G. AccountPlumbing** — Keychain, presets plist, wiring AppShell's `MailFacade`
    to the real engine.
- **Wave 3** (integration owner): serialized integration build on mbp, fix, smoke
  test against a real IMAP account, launch into `kayg@mbp` session for user testing.

## Rules for chunk agents
- Spec documents in docs/spec/ are the contract; DECISIONS.md is settled.
- Never edit `Interfaces/` or another chunk's directory; interface friction →
  message the integration owner over hub.
- Module-scoped `swift build`/`swift test` on mbp only, in your own build dir.
  No project-wide builds, no formatters.
- Tests: behavior of your module's contract (IMAP conversations against scripted
  stubs, MIME corpus, store invariants, sanitizer exfiltration vectors).
