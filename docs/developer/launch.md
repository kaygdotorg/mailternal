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
and the explicit `checkpoint-skipped` marker. `store-first-queries-*` covers the
first account restoration reads. The package emits matching `StoreOpen`
`os_signpost` events for Instruments and Console correlation.

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
`~/vm-qa.sh` and `~/tab-switch-latency-vm.sh`. For the tab-switch gate, leave
two or more tabs loaded after launch, then run:

```text
zsh ~/tab-switch-latency-vm.sh NightlyQA 10 100
```

The final `NightlyQA` run on 2026-09-05 reported
`samples=10 max=95.9ms navigations=0 malformed=0 budget=100.0ms`.

`vm-qa.sh launch` removes and copies `~/mailternal-qa-base` before every run.
For Release, rsync the Release `.app` to `~/mailternal/Mailternal-release.app`
and run `zsh ~/vm-qa.sh launch-release lv-release`; `APP=/path/to/app` can
override that path. The helper stages the fixture in a run-named directory
inside the `org.kayg.mailternal` sandbox container, passes that exact
Application Support path to `-qa-container`, and installs the QA certificate
inside the same container. A cold run includes `sudo purge` before the copy and
launch; a warm run relaunches immediately against the same container. Keep five
runs per cell, report medians, and retain the raw phase logs with the artifact.

The fixture must already contain the current GRDB migration identifiers when
the goal is launch latency. If `v10_unread_index` is absent, GRDB correctly
builds `messages_unread_idx` over the populated `messages` table at open. That
is a one-time schema migration, not steady-state launch work; report it
separately rather than attributing it to SQLite pool creation.
