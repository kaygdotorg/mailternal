# Mailternal — agent ground rules

## General Rules

- Always use rtk and code-review-graph to read/edit the codebase as that is very token efficient.
- You are the orchaestrator meaning you delegate and administer. 
  - You are the control plane. 
  - Your job is to understand the user's intent by asking questions or using the /grill-me skill if necessary.
  - Once you are confident that you understand the user's intent, make a detailed plan and delegate it to a task subagent. If the plan is too complex or you need additional verification before it's good to implement, use the reviewer subagent to refine the plan until you're ready to hand it off.
  - Task subagents are dumb. They don't have the context of your conversation with the user. 
  - Task subagents need to be told exactly what they need to do and why. 
  - Once task subagents are done, you need to verify the changes they claim to have implemented by yourself. Trusting a task subagent is a fool's errand.
- There is a harness web search skill located at ~/.claude/skills/harness-web-search. Use it to supplement information you already know. Use it to also fetch updated information in general from the internet when needed. 
- If there is an overnight set of tasks left by the user, keep working on them without showing prompts/interviews for decisions. Those decisions need to be either deferred till the morning or asked before the user has left.

## Code Rules

- **Commits go to `dev`.** Verify the current branch before every commit.
  `main` is reserved for stable releases; promote verified changes there only
  with explicit user approval, never as part of routine development.
- **Commit identity is `K Gopal Krishna <mail@kayg.org>`.** Verify both
  `git var GIT_AUTHOR_IDENT` and `git var GIT_COMMITTER_IDENT` before committing.
  On clone setup, configure `git config --local user.useConfigOnly true` and
  `git config --local core.hooksPath .githooks`; the versioned identity hook
  rejects incorrect authors and committers, including environment overrides.
  Keep this hook enabled.
- **Keep secrets out of Git.** Before every commit, inspect all staged paths and
  the complete staged diff for credentials, tokens, private/signing keys, private
  configuration, and real account data. Run an available secret scanner with
  redacted output; `.gitignore` alone is not proof that a commit is safe.
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
- On `mbp`, actual repository roots live under `/Users/agents/Developer`; worktrees
  and isolated build copies live under `/Users/agents/Developer/Worktrees`.
  The QA VM is owned and launched by `kayg`, not `agents`.
- Test builds for `kayg@mbp` go under `/Users/kayg/Applications`.
  Keep them separate from `/Users/Shared/Mailternal`; installing a test build
  does not authorize replacing the production app or changing real account data.
- Never touch the `kayg` user's session or `/Users/Shared/Mailternal` without being
  asked; QA instances use their own containers.
- **UI QA on mbp runs through CuaDriver** (`/Applications/CuaDriver.app/Contents/MacOS/cua-driver`,
  daemon in the `agents` VNC session with Accessibility + Screen Recording granted):
  `list-tools`, `describe <tool>`, `call <tool> '<json>'` — clicks, drags, hotkeys, menus, AX
  trees, screenshots (`get_desktop_state {"screenshot_out_file": …}`). Do not use `screencapture`
  from an SSH context for WebKit content and never ask for `automationmodetool`/TCC changes.
- Use the deployed bundle or your own chunk build; own QA container per agent
  (`cp -R ~/Developer/Worktrees/mailternal-qa-ReaderIslands ~/Developer/Worktrees/mailternal-qa-<agent>` on `agents@mbp`); announce server mutations on
  hub; restore what you move.
- **Launch timing**: `MAILTERNAL_QA=1 Mailternal -qa-account … -qa-gui` prints `launch phase=<name> t=<ms since exec>` for app-init, did-finish-launching, shell-show-begin/end, window-front, first-frame, folders-snapshot, first-rows, settled-frame, plus store-open subphases (`store-pool-open-*`, `store-pragmas-*`, `store-migrator-*`, `store-index-build-*`, `store-checkpoint-skipped`, `store-first-queries-*`). `first-frame` is the first Core Animation transaction completion after `orderFront`; `settled-frame` is the first Core Animation commit after both folders and rows are ready. The older `first-page ready` line is a 2 s poller and is not a launch metric. `vm-qa.sh launch-release` runs the Release app selected by `APP` (default `~/mailternal/Mailternal-release.app`).
- **QA IMAP server** is the Dovecot on mbp itself: `-qa-account 127.0.0.1 1143 startTLS`
  (user `qa@mailternal.test`, `MAILTERNAL_QA_PASSWORD=qa-password`). `10.69.69.155:1025` is
  dead; a container seeded for a different `qa-<host>-<port>` account id is wiped by the QA
  seed, so copy fixtures only with a matching endpoint.
  
## Verification rules

- lume@mailternal-macos-vm is available over netbird ssh for verification tasks. It has unrestricted cua driver access for easy interactions. The username/password on that vm is lume/lume.
- agents@mbp is only for building/infrastructure tasks.
- kayg@mbp is only for placing test builds under ~kayg/Applications to test. You will only ever keep one build there and periodically replace that build and notify the user if something needs their testing.
