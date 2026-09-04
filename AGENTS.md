# Mailternal — agent ground rules

- Read `docs/spec/*.md` and `DECISIONS.md` before changing behavior; `design.md` is
  the sole authority on how anything looks or feels.
- **Documentation lives next to the code it describes.** A behavior change without the
  matching doc-comment, guide (`docs/user`, `docs/developer`), or `--help` text change
  is incomplete. Never edit generated output (API reference, CLI reference, JSON
  Schema) — change the source it is generated from.
- Performance thresholds in `perf/baselines.json` are gates; loosening one requires a
  `DECISIONS.md` entry.
- Every user mutation goes through a persisted queue and the `Command` log; never
  call the store from a view.
- Builds and tests run on the remote Mac (`Scripts/build-mbp.sh`); the Linux host has
  no Swift toolchain. Use `rtk` and `code-review-graph` for reading and navigation.
- Never touch the `kayg` user's session or `/Users/Shared/Mailternal` without being
  asked; QA instances use their own containers.
- **UI QA on mbp runs through CuaDriver** (`/Applications/CuaDriver.app/Contents/MacOS/cua-driver`,
  daemon in the `agents` VNC session with Accessibility + Screen Recording granted):
  `list-tools`, `describe <tool>`, `call <tool> '<json>'` — clicks, drags, hotkeys, menus, AX
  trees, screenshots (`get_desktop_state {"screenshot_out_file": …}`). Do not use `screencapture`
  from an SSH context for WebKit content and never ask for `automationmodetool`/TCC changes.
- Use the deployed bundle or your own chunk build; own QA container per agent
  (`cp -R ~/mailternal-qa-ReaderIslands ~/mailternal-qa-<agent>`); announce server mutations on
  hub; restore what you move.
- **Launch timing**: `MAILTERNAL_QA=1 Mailternal -qa-account … -qa-gui` prints `launch phase=<name> t=<ms since exec>` for app-init, did-finish-launching, shell-show-begin/end, window-front, first-frame, folders-snapshot, first-rows, settled-frame, plus store-open subphases (`store-pool-open-*`, `store-pragmas-*`, `store-migrator-*`, `store-index-build-*`, `store-checkpoint-skipped`, `store-first-queries-*`). `first-frame` is the first Core Animation transaction completion after `orderFront`; `settled-frame` is the first Core Animation commit after both folders and rows are ready. The older `first-page ready` line is a 2 s poller and is not a launch metric. `vm-qa.sh launch-release` runs the Release app selected by `APP` (default `~/mailternal/Mailternal-release.app`).
- **QA IMAP server** is the Dovecot on mbp itself: `-qa-account 127.0.0.1 1143 startTLS`
  (user `qa@mailternal.test`, `MAILTERNAL_QA_PASSWORD=qa-password`). `10.69.69.155:1025` is
  dead; a container seeded for a different `qa-<host>-<port>` account id is wiped by the QA
  seed, so copy fixtures only with a matching endpoint.
- **XCUITest under `agents` works**: automation mode is enabled on mbp
  (`sudo automationmodetool enable-automationmode-without-authentication`, re-run by kayg
  after a reboot). Prefer `xcodebuild … test -only-testing:MailternalUITests/…` in your own
  build dir over synthetic CuaDriver clicks for gesture/keyboard verification.
