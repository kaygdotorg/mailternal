# Launch timing notes

Mailternal's QA launch markers are intended for measuring the first interactive
window rather than background sync. Run the app with `MAILTERNAL_QA=1` and
`-qa-gui`:

```text
MAILTERNAL_QA=1 Mailternal -qa-account 127.0.0.1 1143 startTLS \
  -qa-container ~/mailternal-qa-run -qa-gui
```

The `t=` value is milliseconds from the process start reported by `sysctl`, not
from the first Swift object. The required top-level phases are:

- `app-init`
- `did-finish-launching`
- `window-front`
- `first-frame`
- `store-open`
- `folders-snapshot`
- `first-rows n=<count>`
- `settled-frame`

`first-frame` is the completion of the Core Animation transaction that contains
the first `orderFront`. `settled-frame` is the first Core Animation commit after
both a non-empty folder snapshot and the first non-empty message page have been
published. The old `first-page ready` line is a progress poller and must not be
used as a launch phase.

For attribution, QA also prints shell boundaries (`shell-show-begin` and
`shell-show-end`) and store-open subphases. Store subphases cover pool creation,
connection pragmas, the GRDB migrator, the unread-index build when applicable,
each v14 configurable-sort index build, and the explicit `checkpoint-skipped`
marker. `store-first-queries-*` covers the first account restoration reads,
including `store-qa-seed-*` and `store-fetch-accounts-*` when QA mode replaces
the account fixture. The package emits matching `StoreOpen` `os_signpost` events
for Instruments and Console correlation. Migration markers identify migration
body and index-build intervals. For deferred migrations, their `*-end` markers
precede GRDB's migration-record write, full foreign-key check, and transaction
commit; immediate migrations v10–v15 enforce foreign keys inline, so their
`*-end` markers precede only the record write and transaction commit.

Schema migrations v10–v15 use GRDB's supported `.immediate` foreign-key mode:
they add indexes/columns or create empty tables and do not recreate existing
tables. This keeps foreign-key enforcement enabled without a full deferred
`PRAGMA foreign_key_check` scan per migration. The v7 table-rebuild migration
remains on deferred checks.

## VM runs

Build on `agents@mbp`, deploy the Debug bundle and QA helpers, and use a private
fixture:

```text
Scripts/build-mbp.sh LaunchVM app
Scripts/deploy-vm.sh LaunchVM
ssh lume@mailternal-macos-vm.vpn.kayg.org
sudo purge
zsh ~/vm-qa.sh launch lv-debug
zsh ~/vm-qa.sh phases lv-debug
```

`Scripts/deploy-vm.sh` copies `vm-qa.sh` and the dedicated tab-switch helper to
`~/vm-qa.sh` and `~/tab-switch-latency-vm.sh`. For a diagnostic tab-switch run,
leave two or more genuinely loaded tabs after launch, then run:

```text
zsh ~/tab-switch-latency-vm.sh NightlyQA 10 100
```

Any prior tab-switch sample is diagnostic only, not final scrolling evidence.
The existing 103-tab/66.4 ms sample predates the current API and fixture, so it
is not current acceptance evidence. The current API fixture has created 103
pinned existing-read tabs, but final tab restoration and performance
measurements remain pending. No reliable continuous scroll/hitch measurement
exists: Cua or endpoint round-trip duration is transport time, not
presented-frame smoothness, and wheel displacement/handler timing alone is not
an end-to-end scrolling measurement.

`vm-qa.sh launch` removes and re-copies the store before every run, including
`launch-release`, so it cannot substantiate warm-reopen performance. For a true
warm run, manually restart the same Release executable against the unchanged
store, and record the fixture identity and executable hash. Keep five runs per
controlled cell, report medians, and retain the raw phase logs with the artifact.

For Release, rsync the Release `.app` to `~/mailternal/Mailternal-release.app`
and run `zsh ~/vm-qa.sh launch-release lv-release`; `APP=/path/to/app` can
override that path. The helper stages the fixture in a run-named directory
inside the `org.kayg.mailternal` sandbox container, passes that exact
Application Support path to `-qa-container`, and installs the QA certificate
inside the same container. A cold run includes `sudo purge` before the copy and
launch. Do not call a helper's recopy a warm relaunch.

The only measured overnight performance improvement proven on the final migration
artifact is a legacy-schema upgrade: store-open 88,597.3 ms → 47,245.2 ms
settled (46.7% lower; one controlled legacy clone/observation). This is a
one-time migration result, not steady-state or cache-cold launch. Prior warm
medians overlap concurrent build activity and older artifacts and are not a final
API/native baseline.

The fixture must already contain the current GRDB migration identifiers when the
goal is launch latency. If `v10_unread_index` or `v14_list_sort_indexes` is
absent, GRDB correctly builds the corresponding required indexes over the
populated `messages` table at open. These are one-time schema migrations, not
steady-state launch work; report each migration separately rather than
attributing it to SQLite pool creation.
