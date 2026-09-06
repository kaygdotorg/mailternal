#!/bin/zsh
set -euo pipefail
setopt pipefail

# Profile the native reader tab strip in the dedicated QA VM. Prepare exactly
# the requested tab count through the app first; measurement never opens mail.
name=${1:-NativeRepair20260905d}
target_tabs=${2:-20}
profile_seconds=${3:-90}
if (( $# > 3 )); then
  print -u2 "usage: $0 [qa-container-name] [tab-count] [profile-seconds]"
  exit 2
fi
if [[ "$target_tabs" != <-> ]] || (( target_tabs < 2 )); then
  print -u2 "tab count must be an integer >= 2: $target_tabs"
  exit 2
fi
if [[ "$profile_seconds" != <-> ]] || (( profile_seconds < 5 )); then
  print -u2 "profile duration must be an integer >= 5: $profile_seconds"
  exit 2
fi

driver=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
run="$HOME/mailternal-qa-$name"
app="$HOME/mailternal/Mailternal.app/Contents/MacOS/Mailternal"
artifact_dir="$run/tab-scroll-profile"
mkdir -p "$artifact_dir"

pid=$(pgrep -f "^$app .* -qa-container $run( |$)" | sed -n '1p' || true)
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

state() {
  "$driver" call get_window_state \
    "{\"pid\":$pid,\"window_id\":$window,\"include_screenshot\":false,\"max_depth\":2}"
}

tab_count() {
  state | jq -r '
    ([.elements[] | select(.role == "AXToolbar") | .element_index] | last) as $toolbar
    | [.elements[]
       | select(.parent_index == $toolbar and .role == "AXButton")
       | select((.frame.h // 0) >= 27 and (.frame.h // 0) <= 29)]
    | length
  '
}

count=$(tab_count)
if (( count != target_tabs )); then
  print -u2 "expected $target_tabs tabs, observed $count"
  exit 1
fi

# Record the exact target/window and executable identity next to the stacks.
initial_state=$("$driver" call get_window_state \
  "{\"pid\":$pid,\"window_id\":$window,\"include_screenshot\":true,\"screenshot_out_file\":\"$artifact_dir/initial.png\",\"max_depth\":2}")
print -r -- "$initial_state" | jq '{pid,window_id,window_bounds:([.elements[] | select(.role == "AXWindow")][0].frame)}' > "$artifact_dir/target.json"
shasum -a 256 "$app" > "$artifact_dir/executable.sha256"
print "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$artifact_dir/run.txt"
print "container=$run" >> "$artifact_dir/run.txt"
print "pid=$pid window=$window tabs=$count profile_seconds=$profile_seconds" >> "$artifact_dir/run.txt"
print "input=measured viewport pixel; proof=net first-tab position readback" >> "$artifact_dir/run.txt"
action_x=$(print -r -- "$initial_state" | jq '[.elements[] | select(.label == "Archive") | .frame.x] | min')
target_frame=$(print -r -- "$initial_state" | jq --argjson edge "$action_x" '
  [.elements[] | select(.role == "AXButton" and .frame.h == 28)
   | select((.frame.x + .frame.w / 2) > ($edge - 180)
            and (.frame.x + .frame.w / 2) < ($edge - 32))][0].frame')
[[ "$target_frame" != null ]] || { print -u2 "no visible tab target"; exit 1; }
scroll_x=$(print -r -- "$initial_state" | jq --argjson f "$target_frame" \
  '($f.x + $f.w / 2 - .window_bounds.x) * .screenshot_width / .window_bounds.width')
scroll_y=$(print -r -- "$initial_state" | jq --argjson f "$target_frame" \
  '($f.y + $f.h / 2 - .window_bounds.y) * .screenshot_height / .window_bounds.height')
before_x=$(print -r -- "$initial_state" | jq '[.elements[] | select(.role == "AXButton" and .frame.h == 28)][0].frame.x')


# Sample the real process while replaying horizontal wheel input over the tab
# viewport. The tab strip remains foreground-owned, while the sample recorder
# runs independently and cannot alter app scheduling.
"$driver" call bring_to_front "{\"pid\":$pid,\"window_id\":$window}" >/dev/null
: > "$artifact_dir/replay.log"
sample_file="$artifact_dir/sample.txt"
(
  sample "$pid" "$profile_seconds" 1 -file "$sample_file"
) &
sample_pid=$!
sleep 1
# Keep AX tree walks outside sampling: they can be much slower than input.
# The measured viewport point stays inside the strip as its content moves.
for direction in left right left right left; do
  print "replay direction=$direction epoch=$(date +%s)" >> "$artifact_dir/replay.log"
  "$driver" call scroll \
    "{\"pid\":$pid,\"window_id\":$window,\"x\":$scroll_x,\"y\":$scroll_y,\"direction\":\"$direction\",\"amount\":10,\"by\":\"line\",\"delivery_mode\":\"background\"}" \
    >> "$artifact_dir/replay.log"
  sleep 1
done
kill -0 "$sample_pid" || { print -u2 "sample ended before replay completed"; exit 1; }
wait "$sample_pid" || true
after_x=$(state | jq '[.elements[] | select(.role == "AXButton" and .frame.h == 28)][0].frame.x')
jq -n --argjson before "$before_x" --argjson after "$after_x" \
  '{before_first_x:$before,after_first_x:$after}' >> "$artifact_dir/replay.log"

# Keep a compact, quantitative summary in the artifact directory; the full
# sample remains available for stack inspection.
sample_lines=$(wc -l "$sample_file" | awk '{print $1}')
print "sample_lines=$sample_lines" >> "$artifact_dir/run.txt"
replay_events=5
print "replay_events=$replay_events" >> "$artifact_dir/run.txt"
print "tab_count=$(tab_count)" >> "$artifact_dir/run.txt"
[[ "$before_x" != "$after_x" ]] || { print -u2 "wheel replay did not move the strip"; exit 1; }
print -r -- "artifacts=$artifact_dir"
