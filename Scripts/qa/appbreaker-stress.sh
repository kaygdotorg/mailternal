#!/usr/bin/env bash
# AppBreaker live headless stress against crippled Dovecot 127.0.0.1:2143.
# Run on agents@mbp after Scripts/build-mbp.sh AppBreaker app.
set -euo pipefail

ROOT="${APPBREAKER_ROOT:-$HOME/mailternal-build/AppBreaker}"
APP="${APP:-$ROOT/App/build/Build/Products/Debug/Mailternal.app/Contents/MacOS/Mailternal}"
DATA="${APPBREAKER_DATA:-$HOME/mailternal-build/AppBreaker-qa}"
LOGDIR="${APPBREAKER_LOGS:-$HOME/mailternal-build/AppBreaker-logs}"
HOST="${QA_HOST:-127.0.0.1}"
PORT="${QA_PORT:-2143}"
SECURITY="${QA_SECURITY:-startTLS}"
KILL_AFTER="${KILL_AFTER_COUNT:-400}"
IDLE_SECS="${IDLE_SECS:-20}"

mkdir -p "$DATA" "$LOGDIR"
export MAILTERNAL_QA=1
export MAILTERNAL_QA_CERT="${MAILTERNAL_QA_CERT:-$HOME/mailternal-qa/certs/dovecot.crt}"
export MAILTERNAL_QA_USER="${MAILTERNAL_QA_USER:-qa@mailternal.test}"
export MAILTERNAL_QA_PASSWORD="${MAILTERNAL_QA_PASSWORD:-qa-password}"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '%s %s\n' "$(ts)" "$*" | tee -a "$LOGDIR/orchestrator.log" >&2; }

if [ ! -x "$APP" ]; then
  echo "missing app binary: $APP" >&2
  exit 1
fi

launch() {
  local name="$1"; shift
  local out="$LOGDIR/$name.stderr"
  : > "$out"
  log "launch $name -> $out -- $*"
  # Direct binary so $! is Mailternal. caffeinate -w holds idle sleep until exit.
  nohup "$APP" \
    -qa-account "$HOST" "$PORT" "$SECURITY" \
    -qa-container "$DATA" \
    -ApplePersistenceIgnoreState YES \
    "$@" \
    >>"$out" 2>&1 &
  local pid=$!
  echo "$pid" > "$LOGDIR/$name.pid"
  log "pid=$pid"
  caffeinate -i -w "$pid" >/dev/null 2>&1 &
  # sidecar RSS/CPU sampler
  nohup bash -c "
    pid=$pid
    samp='$LOGDIR/$name.ps'
    peak='$LOGDIR/$name.peak'
    echo ts,etime,pcpu,rss_kb > \"\$samp\"
    peak_rss=0
    while kill -0 \$pid 2>/dev/null; do
      line=\$(ps -p \$pid -o etime=,pcpu=,rss= 2>/dev/null || true)
      if [ -n \"\$line\" ]; then
        rss=\$(echo \"\$line\" | awk '{print \$NF}')
        echo \"\$(date -u +%Y-%m-%dT%H:%M:%SZ),\$line\" >> \"\$samp\"
        if [ \"\${rss:-0}\" -gt \"\$peak_rss\" ] 2>/dev/null; then
          peak_rss=\$rss
          echo \$peak_rss > \"\$peak\"
        fi
      fi
      sleep 2
    done
  " >/dev/null 2>&1 &
  echo $! > "$LOGDIR/$name.sampler.pid"
  echo "$pid"
}

wait_log() {
  local file="$1"
  local pattern="$2"
  local timeout="$3"
  local start
  start=$(date +%s)
  while true; do
    if grep -E -q "$pattern" "$file" 2>/dev/null; then
      grep -E "$pattern" "$file" | tail -1 >&2
      return 0
    fi
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      log "timeout waiting for /$pattern/ in $file"
      return 1
    fi
    sleep 1
  done
}

inbox_count() {
  local file="$1"
  grep -E "inbox count=" "$file" 2>/dev/null | tail -1 | sed -n 's/.*inbox count=\([0-9][0-9]*\).*/\1/p'
}

db() { echo "$DATA/store.sqlite"; }

sqlite_report() {
  local sqlite
  sqlite="$(command -v sqlite3 || true)"
  if [ -z "$sqlite" ]; then
    log "sqlite3 not on PATH"
    return 0
  fi
  local dbfile
  dbfile="$(db)"
  if [ ! -f "$dbfile" ]; then
    log "no db at $dbfile"
    return 0
  fi
  {
    echo "=== sizes ==="
    ls -l "$dbfile" "$dbfile-wal" "$dbfile-shm" 2>/dev/null || true
    echo "=== integrity ==="
    "$sqlite" "$dbfile" "PRAGMA integrity_check;"
    echo "=== fts integrity ==="
    "$sqlite" "$dbfile" "INSERT INTO messages_fts(messages_fts) VALUES('integrity-check');" 2>&1 || true
    echo "=== counts ==="
    "$sqlite" "$dbfile" "SELECT path, (SELECT COUNT(*) FROM messages m JOIN generations g ON g.id=m.generation_id WHERE g.folder_id=f.id AND g.state='live') FROM folders f WHERE retired=0;"
    echo "=== page EXPLAIN first ==="
    "$sqlite" "$dbfile" "
      EXPLAIN QUERY PLAN
      SELECT m.id, m.from_display, m.subject, m.preview, m.internal_date, m.uid,
             m.is_read, m.has_attachments
      FROM messages m
      WHERE m.generation_id = (
        SELECT live_generation_id FROM folders WHERE path = 'INBOX' AND retired = 0 LIMIT 1
      )
      ORDER BY m.internal_date DESC, m.uid DESC LIMIT 81;
    "
    echo "=== page EXPLAIN keyset ==="
    "$sqlite" "$dbfile" "
      EXPLAIN QUERY PLAN
      SELECT m.id, m.from_display, m.subject, m.preview, m.internal_date, m.uid,
             m.is_read, m.has_attachments
      FROM messages m
      WHERE m.generation_id = (
        SELECT live_generation_id FROM folders WHERE path = 'INBOX' AND retired = 0 LIMIT 1
      )
      AND (m.internal_date < 2000000000 OR (m.internal_date = 2000000000 AND m.uid < 999999))
      ORDER BY m.internal_date DESC, m.uid DESC LIMIT 81;
    "
    echo "=== search EXPLAIN thread ==="
    "$sqlite" "$dbfile" "
      EXPLAIN QUERY PLAN
      SELECT m.id
      FROM messages_fts
      JOIN messages m ON m.id = messages_fts.rowid
      JOIN generations g ON g.id = m.generation_id AND g.state = 'live'
      JOIN folders f ON f.id = g.folder_id AND f.retired = 0
      WHERE messages_fts MATCH 'thread'
      ORDER BY rank
      LIMIT 25;
    "
    echo "=== search timer ==="
    "$sqlite" "$dbfile" <<'SQL'
.timer on
SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'thread';
SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'message';
SELECT COUNT(*) FROM messages_fts WHERE messages_fts MATCH 'zxqwvnotatoken';
SQL
  } | tee "$LOGDIR/sqlite-report.txt" >&2
}

stop_pid() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

phase_kill_resume() {
  rm -rf "$DATA"
  mkdir -p "$DATA"
  local pid
  pid="$(launch run1)"
  local err="$LOGDIR/run1.stderr"
  if ! wait_log "$err" "headless launch pid=" 60; then
    log "app did not log headless start"
    tail -50 "$err" || true
    return 1
  fi
  log "waiting for inbox count >= $KILL_AFTER"
  local start
  start=$(date +%s)
  while true; do
    local n
    n="$(inbox_count "$err" || true)"
    if [ -n "${n:-}" ] && [ "$n" -ge "$KILL_AFTER" ]; then
      log "inbox reached $n — kill -9 $pid"
      break
    fi
    if [ $(( $(date +%s) - start )) -ge 600 ]; then
      log "giving up wait-for-kill-threshold; last count=${n:-none}"
      if [ -z "${n:-}" ] || [ "$n" -lt 20 ]; then
        tail -80 "$err" || true
        return 1
      fi
      break
    fi
    sleep 2
  done
  kill -9 "$pid" || true
  sleep 1
  log "post-kill integrity"
  sqlite_report || true
  local pid2
  pid2="$(launch run2 -qa-bench-search)"
  local err2="$LOGDIR/run2.stderr"
  wait_log "$err2" "headless launch pid=" 60 || true
  wait_log "$err2" "resuming backfill from cursor" 300 || true
  if grep -q "resuming backfill from cursor" "$err2"; then
    log "RESUME_OK $(grep "resuming backfill from cursor" "$err2" | head -1)"
  else
    log "RESUME_MISSING in first 90s — will keep watching"
  fi
  echo "$pid2"
}

phase_wait_complete() {
  local pid="$1"
  local err="$LOGDIR/run2.stderr"
  log "waiting for all folders complete (pid=$pid)"
  # 100k basic IMAP on 2143 can take hours.
  if wait_log "$err" "all folders complete" 21600; then
    log "FULL_SYNC_DONE"
  else
    log "FULL_SYNC_TIMEOUT"
    tail -30 "$err" || true
  fi
  log "idle sample ${IDLE_SECS}s"
  local cpu_file="$LOGDIR/idle-cpu.txt"
  : > "$cpu_file"
  for _ in $(seq 1 "$IDLE_SECS"); do
    ps -p "$pid" -o pcpu=,rss= >> "$cpu_file" 2>/dev/null || break
    sleep 1
  done
  log "idle cpu samples:"; cat "$cpu_file" | tee -a "$LOGDIR/orchestrator.log"
  if command -v leaks >/dev/null 2>&1; then
    log "leaks $pid"
    leaks "$pid" 2>&1 | tee "$LOGDIR/leaks.txt" | tail -40
  else
    log "leaks tool missing"
  fi
  sqlite_report || true
  stop_pid "$pid"
}

phase_cold_start() {
  local pid
  pid="$(launch cold -qa-bench-search)"
  local err="$LOGDIR/cold.stderr"
  wait_log "$err" "first-page ready" 120 || true
  grep -E "first-page ready|search term=|headless launch" "$err" | head -40 | tee -a "$LOGDIR/orchestrator.log"
  sleep 8
  stop_pid "$pid"
}

phase_lru() {
  local pid
  pid="$(launch lru -qa-cache-cap 8192 -qa-fetch-cid)"
  local err="$LOGDIR/lru.stderr"
  wait_log "$err" "attachment cache after cid fetch|fetchPart cid failed|BUG attachment" 180 || true
  grep -E "fetchPart|attachment cache|BUG" "$err" | tee -a "$LOGDIR/orchestrator.log"
  sleep 2
  stop_pid "$pid"
}

main() {
  log "begin AppBreaker stress app=$APP data=$DATA"
  local pid2
  pid2="$(phase_kill_resume)"
  phase_wait_complete "$pid2"
  phase_cold_start
  phase_lru
  log "done"
}

main "$@"
