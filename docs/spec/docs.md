# Mailternal — Documentation Pipeline Spec

Source of truth is the repository, only. `mailternal.com/docs` is built from `main`
on every tag by CI in this repo; there is no second docs repository to drift.

## Two rules
1. **Reference is generated, never hand-edited**: API reference from Swift doc
   comments (DocC, `--symbol-graph-minimum-access-level public`), CLI reference from
   swift-argument-parser (`generate-docc-reference`), JSON Schema dumped from the
   Codable types (`mailternal schema` → `docs/reference/schemas/*.json`, diff-checked
   in CI so a type change without a schema change fails the build).
2. **Guides are hand-written Markdown in `docs/`**, split Diátaxis-style:
   - `/docs/user` — tutorials and how-tos: setup, Gmail app password, pairing, CLI
     cookbook for agents.
   - `/docs/developer` — architecture (`docs/spec`), API/CLI/schema reference,
     contributing, `DECISIONS.md`.
   Code samples live in `Snippets/` (SE-0356) so they compile or the build fails.

## Tooling
Kiln (Swift-native static site generator that ingests DocC archives; no Node/Python
toolchain). Fallback if Kiln proves too young: Starlight at `/` with the DocC archive
mounted at `/api`.

## Privacy guard
Only `public` symbols enter the reference. `Tests/`, `Scripts/`, QA fixtures and
`research/` never do. A CI denylist grep (hostnames, key material, internal paths,
user names) blocks the deploy.

## Policy (mirrored in AGENTS.md)
Documentation lives next to the code it describes. A behavior change without the
matching doc-comment, guide, or help-text change is incomplete. Never edit generated
output.
