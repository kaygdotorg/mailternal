#!/usr/bin/env bash
# Mailternal QA Dovecot helpers. Run from this directory, or from the Linux
# build host (re-execs on agents@mbp where Docker actually runs).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
QA_SSH="${QA_SSH:-agents@mbp}"
QA_REMOTE_DIR="${QA_REMOTE_DIR:-mailternal-qa}"
COMPOSE_PROJECT="mailternal-qa"
USER_IMAP="qa@mailternal.test"
PASS_IMAP="qa-password"

usage() {
  cat <<'EOF'
Usage: chaos.sh <command> [args]

Lifecycle
  up                 Deploy to the Docker host, build, start both instances
  down               Stop and remove containers (keeps the maildir volume)
  seed               Run seed.py against 127.0.0.1:1143 on the Docker host
  status             EXISTS counts + CAPABILITY on both instances

Chaos
  uidvalidity [mailbox]
                     Stop Dovecot, bump UIDVALIDITY for mailbox (default INBOX), start
  expunge N [mailbox]
                     Mark N random messages in mailbox \Deleted and EXPUNGE
  deliver M [mailbox]
                     APPEND a burst of M new messages (default INBOX)
  restart            Restart both IMAP processes (drops live connections)
  toggle             Show both endpoints
  toggle both        Start full + crippled (default)
  toggle only-full   Stop crippled, leave QRESYNC/CONDSTORE ports up
  toggle only-crippled
                     Stop full, leave basic-IMAP :2143 up
  toggle full|crippled
                     Restart that instance

Mailbox names: INBOX, Archive, Sent, Junk, Drafts, Horrors, Trash.
EOF
}

need_remote() {
  if [ "${QA_REMOTE:-}" = 1 ]; then
    return 1
  fi
  if [ "${QA_FORCE_REMOTE:-}" = 1 ]; then
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

remote_exec() {
  # Re-invoke this script on mbp after syncing Scripts/qa + MIME corpus.
  local corpus=""
  if [ -d "$ROOT/../../Tests/MailternalMIMETests/Corpus" ]; then
    corpus="$ROOT/../../Tests/MailternalMIMETests/Corpus"
  fi
  ssh -o BatchMode=yes "$QA_SSH" "mkdir -p ~/$QA_REMOTE_DIR/certs ~/$QA_REMOTE_DIR/corpus"
  rsync -a --delete \
    --exclude certs --exclude corpus --exclude '.*.swp' \
    "$ROOT/" "$QA_SSH:~/$QA_REMOTE_DIR/"
  if [ -n "$corpus" ]; then
    rsync -a "$corpus/" "$QA_SSH:~/$QA_REMOTE_DIR/corpus/"
  fi
  local quoted=""
  local a
  for a in "$@"; do
    quoted="$quoted $(printf '%q' "$a")"
  done
  exec ssh -o BatchMode=yes "$QA_SSH" "export QA_REMOTE=1; cd ~/$QA_REMOTE_DIR && ./chaos.sh$quoted"
}

compose() {
  docker compose -f "$ROOT/docker-compose.yml" --project-name "$COMPOSE_PROJECT" "$@"
}

maildir_of() {
  local mailbox="${1:-INBOX}"
  case "$mailbox" in
    INBOX|inbox) echo /var/mail/qa/Maildir ;;
    *) echo "/var/mail/qa/Maildir/.${mailbox}" ;;
  esac
}

wait_banner() {
  local port="$1"
  local i
  for i in $(seq 1 60); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  echo "timeout waiting for 127.0.0.1:$port" >&2
  return 1
}

ensure_certs() {
  mkdir -p "$ROOT/certs"
  if [ ! -s "$ROOT/certs/dovecot.crt" ] || [ ! -s "$ROOT/certs/dovecot.key" ]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$ROOT/certs/dovecot.key" \
      -out "$ROOT/certs/dovecot.crt" \
      -subj "/CN=mailternal.test" \
      -addext "subjectAltName=DNS:mailternal.test,DNS:imap.mailternal.test,DNS:localhost,DNS:mbp.local,IP:127.0.0.1,IP:::1"
    chmod 600 "$ROOT/certs/dovecot.key"
    chmod 644 "$ROOT/certs/dovecot.crt"
    echo "generated $ROOT/certs/dovecot.crt"
  fi
}

cmd_up() {
  ensure_certs
  compose up --build -d
  wait_banner 1143
  wait_banner 1993
  wait_banner 2143
  echo "full      STARTTLS  127.0.0.1:1143"
  echo "full      IMAPS     127.0.0.1:1993"
  echo "crippled  IMAP      127.0.0.1:2143"
  echo "cert      $ROOT/certs/dovecot.crt"
}

cmd_down() {
  compose down
}

cmd_seed() {
  wait_banner 1143
  PYTHONUNBUFFERED=1 python3 "$ROOT/seed.py" --host 127.0.0.1 --port 1143 --tls starttls "$@"
}

python_imap() {
  python3 - "$@" <<'PY'
import os, re, sys, socket, ssl, random, time
from pathlib import Path

# Reuse seed.py helpers when present.
sys.path.insert(0, os.environ.get("QA_ROOT", "."))
from seed import connect, wait_ready, quote_mailbox, ImapError, USER, PASSWORD  # noqa: E402
host = os.environ.get("QA_IMAP_HOST", "127.0.0.1")
port = int(os.environ.get("QA_IMAP_PORT", "1143"))
tls = os.environ.get("QA_IMAP_TLS", "starttls")
user = os.environ.get("QA_IMAP_USER", USER)
password = os.environ.get("QA_IMAP_PASS", PASSWORD)
argv = sys.argv[1:]
op = argv[0]

wait_ready(host, port, tls, timeout=30)
c = connect(host, port, tls)
c.login(user, password)

def status(mailbox):
    return c.status_messages(mailbox)
def compact_uids(uids):
    ordered = sorted(set(uids))
    if not ordered:
        return ""
    ranges = []
    lo = prev = ordered[0]
    for uid in ordered[1:]:
        if uid == prev + 1:
            prev = uid
            continue
        ranges.append(str(lo) if lo == prev else "%d:%d" % (lo, prev))
        lo = prev = uid
    ranges.append(str(lo) if lo == prev else "%d:%d" % (lo, prev))
    return ",".join(ranges)


if op == "status":
    print("CAPABILITY", " ".join(c.caps))
    for m in ("INBOX", "Archive", "Sent", "Junk", "Drafts", "Horrors", "Trash"):
        try:
            n = status(m)
            print("MESSAGES", m, n)
        except Exception as e:
            print("MESSAGES", m, "ERR", e)
    exists = c.select("INBOX")
    print("SELECT INBOX EXISTS", exists)
elif op == "expunge":
    n = int(argv[1])
    mailbox = argv[2] if len(argv) > 2 else "INBOX"
    exists = c.select(mailbox)
    if exists <= 0 or n <= 0:
        print("expunge: nothing to do (EXISTS %d, N %d)" % (exists, n))
        sys.exit(0)
    n = min(n, exists)
    seqs = sorted(random.sample(range(1, exists + 1), n))
    selected_uids = []
    # Resolve sequence numbers before marking them. The UID list is the
    # durable identity the sync test can compare with local rows.
    for i in range(0, len(seqs), 50):
        chunk = seqs[i:i+50]
        set_ = ",".join(str(x) for x in chunk)
        _, fetched = c.cmd("FETCH %s (UID)" % set_)
        for line in fetched:
            match = re.search(r"^\*\s+\d+\s+FETCH\s+\(.*?\bUID\s+(\d+)\b", line, re.IGNORECASE)
            if match:
                selected_uids.append(int(match.group(1)))
        c.cmd("STORE %s +FLAGS.SILENT (\\Deleted)" % set_)
    tagged, untagged = c.cmd("EXPUNGE")
    vanished = sum(1 for line in untagged if line.upper().endswith(" EXPUNGE"))
    print("expunged ~%d (STORE %d seqs, EXPUNGE lines %d) mailbox=%s was EXISTS %d" % (
        n, n, vanished, mailbox, exists))
    print("EXPUNGED mailbox=%s count=%d uids=%s" % (
        mailbox, len(selected_uids), compact_uids(selected_uids)))
    print("now EXISTS", c.status_messages(mailbox))
elif op == "caps":
    print("CAPABILITY", " ".join(c.caps))
else:
    raise SystemExit("unknown python op " + op)
c.logout()
PY
}

cmd_status() {
  echo "=== full :1143 (STARTTLS) ==="
  QA_IMAP_PORT=1143 QA_IMAP_TLS=starttls QA_ROOT="$ROOT" python_imap status
  echo "=== crippled :2143 (plain) ==="
  QA_IMAP_PORT=2143 QA_IMAP_TLS=plain QA_ROOT="$ROOT" python_imap status || true
}

cmd_uidvalidity() {
  local mailbox="${1:-INBOX}"
  echo "bumping UIDVALIDITY for $mailbox (volume must be idle; brief dual stop)"
  compose stop dovecot-full dovecot-crippled
  docker run --rm --entrypoint /bump-uidvalidity.sh \
    -v mailternal-qa-maildata:/var/mail \
    mailternal-qa-dovecot:local \
    "$mailbox"
  compose start dovecot-full dovecot-crippled
  wait_banner 1143
  wait_banner 2143
  echo "UIDVALIDITY bump complete for $mailbox"
  QA_ROOT="$ROOT" python3 - "$mailbox" <<'PY'
import os, sys
sys.path.insert(0, os.environ["QA_ROOT"])
from seed import connect, wait_ready, quote_mailbox, USER, PASSWORD
mb = sys.argv[1]
wait_ready("127.0.0.1", 1143, "starttls", 30)
c = connect("127.0.0.1", 1143, "starttls")
c.login(USER, PASSWORD)
tagged, untagged = c.cmd("STATUS %s (UIDVALIDITY MESSAGES)" % quote_mailbox(mb))
print("after bump:", tagged)
for line in untagged:
    print(line)
c.logout()
PY
}

cmd_expunge() {
  local n="${1:?N required}"
  local mailbox="${2:-INBOX}"
  QA_IMAP_PORT=1143 QA_IMAP_TLS=starttls QA_ROOT="$ROOT" python_imap expunge "$n" "$mailbox"
}

cmd_deliver() {
  local m="${1:?M required}"
  local mailbox="${2:-INBOX}"
  PYTHONUNBUFFERED=1 python3 "$ROOT/seed.py" --host 127.0.0.1 --port 1143 --tls starttls \
    --extra "$mailbox" "$m"
}

cmd_restart() {
  echo "restarting full IMAP (drops live connections on 1143/1993; leaves 2143)"
  compose restart dovecot-full
  wait_banner 1143
  echo "restarted full instance"
}

cmd_toggle() {
  local mode="${1:-}"
  case "$mode" in
    ""|show)
      echo "full     127.0.0.1:1143 STARTTLS  (QRESYNC + CONDSTORE)"
      echo "full     127.0.0.1:1993 IMAPS     (same mailbox, implicit TLS)"
      echo "crippled 127.0.0.1:2143 IMAP      (IMAP4rev1 LITERAL+ IDLE)"
      compose ps
      ;;
    both)
      compose up -d
      wait_banner 1143
      wait_banner 2143
      echo "both instances up"
      ;;
    only-full)
      compose up -d dovecot-full
      compose stop dovecot-crippled || true
      wait_banner 1143
      echo "only full (1143/1993) listening"
      ;;
    only-crippled)
      compose up -d dovecot-crippled
      compose stop dovecot-full || true
      wait_banner 2143
      echo "only crippled (2143) listening"
      ;;
    full)
      compose restart dovecot-full
      wait_banner 1143
      echo "full restarted"
      ;;
    crippled)
      compose restart dovecot-crippled
      wait_banner 2143
      echo "crippled restarted"
      ;;
    *)
      echo "unknown toggle '$mode'" >&2
      usage >&2
      exit 2
      ;;
  esac
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ $# -eq 0 ]; then
  usage
  exit 0
fi

if need_remote; then
  remote_exec "$@"
fi

cmd="$1"
shift || true
case "$cmd" in
  up) cmd_up "$@" ;;
  down) cmd_down "$@" ;;
  seed) cmd_seed "$@" ;;
  status) cmd_status "$@" ;;
  uidvalidity) cmd_uidvalidity "$@" ;;
  expunge) cmd_expunge "$@" ;;
  deliver) cmd_deliver "$@" ;;
  restart) cmd_restart "$@" ;;
  toggle) cmd_toggle "$@" ;;
  help) usage ;;
  *)
    echo "unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
