#!/bin/zsh
set -eu
setopt pipefail

name=${1:-FinalQA}
switches=${2:-10}
budget_ms=${3:-100}

if (( $# > 3 )); then
  print -u2 "usage: $0 [run-name] [switch-count] [budget-ms]"
  exit 2
fi
if [[ "$switches" != <-> ]] || (( switches <= 0 )); then
  print -u2 "switch count must be a positive integer: $switches"
  exit 2
fi
if [[ "$budget_ms" != <-> ]] || (( budget_ms <= 0 )); then
  print -u2 "budget must be a positive integer in milliseconds: $budget_ms"
  exit 2
fi

log="$HOME/mailternal-qa-$name/launch.log"
if [[ ! -f "$log" ]]; then
  print -u2 "missing $log"
  exit 2
fi
driver=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
run="$HOME/mailternal-qa-$name"
pid=$(pgrep -f "Mailternal.*-qa-container $run" | sed -n '1p')
if [[ -z "$pid" ]]; then
  print -u2 "no Mailternal process for $run"
  exit 2
fi
window=$(
  "$driver" call list_windows '{}' |
    jq -r --argjson pid "$pid" '
      [.windows[]
        | select(.pid == $pid and .bounds.height > 100)
        | {id: .window_id, area: (.bounds.width * .bounds.height)}]
      | sort_by(.area)
      | last
      | .id // empty
    '
)
if [[ -z "$window" ]]; then
  print -u2 "no Mailternal window for pid $pid"
  exit 2
fi


start_line=$(wc -l < "$log")
for ((index = 0; index < switches; index++)); do
  "$driver" call hotkey \
    "{\"pid\":$pid,\"window_id\":$window,\"keys\":[\"ctrl\",\"tab\"],\"delivery_mode\":\"foreground\"}" \
    >/dev/null
  sleep 1.2
done

first_new_line=$((start_line + 1))
sed -n "${first_new_line},\$p" "$log" | awk \
  -v expected="$switches" \
  -v budget="$budget_ms" '
function timestamp(line, position, value) {
  position = match(line, /t=[0-9]+/)
  if (!position) return -1
  value = substr(line, RSTART + 2, RLENGTH - 2)
  return value + 0
}

{
  if ($0 ~ /selection-perf event=(html-requested|did-finish)([[:space:]]|$)/)
    navigations++

  if ($0 ~ /selection-perf event=select([[:space:]]|$)/) {
    if (pending) malformed++
    started = timestamp($0)
    if (started < 0) {
      malformed++
      pending = 0
    } else {
      pending = 1
    }
    next
  }

  if ($0 ~ /selection-perf event=reader-commit([[:space:]]|$)/) {
    if (!pending) {
      malformed++
      next
    }
    ended = timestamp($0)
    if (ended < started) {
      malformed++
      pending = 0
      next
    }
    if (ended < 0) {
      malformed++
      pending = 0
      next
    }
    latency = (ended - started) / 1000000
    samples++
    if (latency > maximum) maximum = latency
    printf "switch[%d]=%.1fms\n", samples, latency
    pending = 0
  }
}

END {
  if (pending) malformed++
  printf "samples=%d max=%.1fms navigations=%d malformed=%d budget=%.1fms\n", \
    samples, maximum, navigations, malformed, budget
  if (samples != expected || navigations != 0 || malformed != 0 || maximum > budget)
    exit 1
}
'
