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
