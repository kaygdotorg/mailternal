#!/bin/zsh
set -euo pipefail
setopt pipefail

# Private VMPerfLab probe. Runs against one existing Release Mailternal window.
# Args: pid window x y seconds artifact-dir
pid=${1:?pid}
window=${2:?window}
x=${3:?x}
y=${4:?y}
seconds=${5:-20}
out=${6:?artifact directory}
driver=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
mkdir -p "$out"
: > "$out/cua-timing.tsv"
print "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$out/run.txt"
print "pid=$pid window=$window viewport_x=$x viewport_y=$y seconds=$seconds" >> "$out/run.txt"
bundle="$HOME/mailternal-vmperflab/Mailternal-release.app"
executable="$bundle/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$bundle/Contents/Info.plist")"
print "app_sha256=$(shasum -a 256 "$executable" | cut -d' ' -f1)" >> "$out/run.txt"

# Record the exact target state before replay; Cua latency is transport timing,
# not an app frame metric. Keep a separate sample of the app's main thread.
"$driver" call get_window_state "{\"pid\":$pid,\"window_id\":$window,\"include_screenshot\":true,\"screenshot_out_file\":\"$out/before.png\",\"max_depth\":2}" > "$out/before.json"
(
  sample "$pid" "$seconds" 1 -file "$out/sample.txt"
) &
sample_pid=$!
start=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
count=0
while (( $(perl -MTime::HiRes=time -e "printf '%d', time() < $start + $seconds - 1") )); do
  for direction in left right; do
    t0=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
    "$driver" call scroll "{\"pid\":$pid,\"window_id\":$window,\"x\":$x,\"y\":$y,\"direction\":\"$direction\",\"amount\":10,\"by\":\"line\",\"delivery_mode\":\"background\"}" >/dev/null
    rc=$?
    t1=$(perl -MTime::HiRes=time -e 'printf "%.6f",time')
    elapsed=$(perl -MTime::HiRes=time -e "printf '%.3f',($t1-$t0)*1000")
    print "$count	$direction	$elapsed	$rc" >> "$out/cua-timing.tsv"
    count=$((count + 1))
    sleep 0.12
  done
done
kill -0 "$sample_pid" 2>/dev/null || true
wait "$sample_pid" 2>/dev/null || true
"$driver" call get_window_state "{\"pid\":$pid,\"window_id\":$window,\"include_screenshot\":true,\"screenshot_out_file\":\"$out/after.png\",\"max_depth\":2}" > "$out/after.json"
print "events=$count" >> "$out/run.txt"
print "artifacts=$out"
