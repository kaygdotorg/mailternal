# Mailternal QA IMAP

Containerized Dovecot with one Maildir, two listeners. Tests on `agents@mbp` connect to localhost. The mailbox is already seeded; re-running `chaos.sh seed` is a no-op until counts drop.

## Connect (from mbp)

| Path | Host | Port | TLS | What it advertises after LOGIN |
|---|---|---|---|---|
| QRESYNC + CONDSTORE | `127.0.0.1` | **1143** | STARTTLS | `QRESYNC`, `CONDSTORE`, `ENABLE`, `UIDPLUS`, `MULTIAPPEND`, … |
| Same mailbox, implicit TLS | `127.0.0.1` | **1993** | IMAPS | same as 1143 |
| Basic IMAP | `127.0.0.1` | **2143** | optional STARTTLS; plaintext allowed | `IMAP4rev1 LITERAL+ IDLE` only |

The CONDSTORE-only sync path uses **1143** and does not `ENABLE QRESYNC`. The basic path uses **2143**.

```
user:     qa@mailternal.test
password: qa-password
```

Self-signed cert (generated at first `up`, SAN includes `localhost` + `127.0.0.1`):

```
~/mailternal-qa/certs/dovecot.crt
~/mailternal-qa/certs/dovecot.key
```

Pin that cert or disable verification. `openssl s_client -connect 127.0.0.1:1993` then `QUIT`.

Seeded folders (skip-if-counts-match):

| Folder | Target |
|---|---|
| INBOX | 100000 |
| Archive | 20000 |
| Sent | 500 |
| Junk | 300 |
| Drafts | 100 |
| Horrors | every `Tests/MailternalMIMETests/Corpus/*.eml` (or 30 generated malformed messages if that dir is missing) |
| Trash | empty (SPECIAL-USE `\Trash`) |

## Bring-up

Docker runs on **mbp** (OrbStack). From the Linux repo:

```
Scripts/qa/chaos.sh up
Scripts/qa/chaos.sh seed
Scripts/qa/chaos.sh status
```

`up` rsyncs this directory to `agents@mbp:~/mailternal-qa` (does not touch `Sources/` / `App/`) and starts `mailternal-qa-full` + `mailternal-qa-crippled` against named volume `mailternal-qa-maildata`.

On mbp directly:

```
cd ~/mailternal-qa
./chaos.sh up
python3 seed.py          # IMAP APPEND/MULTIAPPEND to 127.0.0.1:1143
./chaos.sh status
```

Completion: `SELECT INBOX` reports `* 100000 EXISTS` (or more after `deliver`).

## Dedicated-VM tab-switch latency

Run this check on the dedicated macOS QA VM, not on the Linux build host. The VM
must have a deployed QA build and fixture, `zsh`, and `osascript` with System
Events automation/accessibility permission. `Scripts/deploy-vm.sh` copies both
`vm-qa.sh` and this helper to the VM as `~/vm-qa.sh` and
`~/tab-switch-latency-vm.sh`. Start exactly one Mailternal QA process: the
harness targets the process name `Mailternal`, so another Mailternal process
makes the keystrokes nondeterministic. Before measuring, leave at least two tabs
already loaded in that process; the check switches between existing tabs and
does not create or load them.

Launch the app and load the tabs (the helper reads the launch log), then run:

```
~/vm-qa.sh launch NightlyQA
# In the VM, wait for two or more tabs to finish loading.
~/tab-switch-latency-vm.sh NightlyQA 10 100
```

The arguments are `[run-name] [switch-count] [budget-ms]`; all default to
`FinalQA`, `10`, and `100`. The run log is
`$HOME/mailternal-qa-<run-name>/launch.log`. A pass reports exactly the
requested number of samples, `navigations=0` (no `html-requested` or
`did-finish` events), and a maximum latency no greater than the budget. The
default gate remains **100 ms**. Missing logs, invalid arguments, too few
samples, navigation, malformed event pairs, or a maximum over budget exit
nonzero.

The final `NightlyQA` run on 2026-09-05 was:

```text
samples=10 max=95.9ms navigations=0 malformed=0 budget=100.0ms
```

## Chaos

Run on mbp or via the Linux wrapper (`chaos.sh` re-execs over ssh when local Docker is down):

```
./chaos.sh uidvalidity [mailbox]     # stop, edit dovecot-uidvalidity + uidlist V=, start
./chaos.sh expunge N [mailbox]       # random N STORE \Deleted + EXPUNGE
./chaos.sh deliver M [mailbox]       # APPEND M new messages
./chaos.sh restart                   # docker compose restart; drops live connections
./chaos.sh toggle                    # print endpoints
./chaos.sh toggle both|only-full|only-crippled|full|crippled
```

Default mailbox is INBOX. `down` removes containers and keeps the maildir volume.

## seed.py

Stdlib Python 3.9+. Default `--host 127.0.0.1 --port 1143 --tls starttls`.

```
python3 seed.py --status
python3 seed.py --verify
python3 seed.py --extra INBOX 50
python3 seed.py --tls imaps --port 1993 --verify
python3 seed.py --tls plain --port 2143 --status
```

Idempotent: `STATUS (MESSAGES)` per folder; APPEND only the shortfall. Resume by running it again. Progress is printed per MULTIAPPEND batch.

Horrors: files from `Tests/MailternalMIMETests/Corpus/` if found, else `Scripts/qa/corpus/` next to the script, else 30 built-in malformed messages (broken boundaries, bad QP/base64, mislabeled charsets, 8-bit headers, deep nesting, missing dates).
