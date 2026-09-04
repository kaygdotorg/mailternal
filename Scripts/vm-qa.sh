#!/bin/zsh
# Runs ON the QA VM (lume). Launch the deployed app against a fresh fixture copy
# and expose CuaDriver helpers.
#   vm-qa.sh launch <name>      -> fresh container ~/mailternal-qa-<name>, GUI, prints pid/window
#   vm-qa.sh shot <name> <file> -> screenshot of the app window into ~/mailternal-qa-<name>/<file>.png
#   vm-qa.sh click <name> x y count
#   vm-qa.sh key <name> <key>
#   vm-qa.sh kill <name>
D=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
cmd=$1; name=$2; C=~/mailternal-qa-$name
if [ "$cmd" = launch-release ]; then
  APP=${APP:-$HOME/mailternal/Mailternal-release.app}
else
  APP=${APP:-$HOME/mailternal/Mailternal.app}
fi
FIXTURE=${FIXTURE:-$HOME/mailternal-qa-base}
pidof_app() { pgrep -f "qa-container $C" | head -1 }
# main window = the largest window of the pid (Settings/hover panels are smaller)
winof() { $D call list_windows '{}' | jq -r ".windows[] | select(.pid==$1 and .bounds.height>100) | [(.bounds.width*.bounds.height), .window_id] | @tsv" | sort -rn | head -1 | cut -f2 }
case $cmd in
  launch|launch-release)
    pkill -f "qa-container $C" 2>/dev/null; sleep 0.5
    rm -rf "$C"; mkdir -p "$C"
    if [ "$cmd" = launch-release ]; then
      H="$HOME/mailternal-qa-${name}-home"
      rm -rf "$H"; mkdir -p "$H/Library/Application Support/Mailternal"
      cp -R "$FIXTURE"/. "$H/Library/Application Support/Mailternal/"
      CFFIXED_USER_HOME="$H" MAILTERNAL_QA=1 "$APP/Contents/MacOS/Mailternal" -qa-account 127.0.0.1 1143 startTLS -qa-container "$C" -qa-gui > "$C/launch.log" 2>&1 &
    else
      cp -R "$FIXTURE"/. "$C"/
      MAILTERNAL_QA=1 "$APP/Contents/MacOS/Mailternal" -qa-account 127.0.0.1 1143 startTLS -qa-container "$C" -qa-gui > "$C/launch.log" 2>&1 &
    fi
    for i in {1..60}; do sleep 0.25; P=$(pidof_app); [ -n "$P" ] && W=$(winof $P) && [ -n "$W" ] && break; done
    echo "P=$P W=$W"; grep 'launch phase' $C/launch.log ;;
  shot) P=$(pidof_app); W=$(winof $P); $D call get_window_state "{\"pid\":$P,\"window_id\":$W,\"screenshot_out_file\":\"$C/$3.png\",\"include_screenshot\":false,\"max_elements\":3}" >/dev/null && echo "$C/$3.png" ;;
  click) P=$(pidof_app); W=$(winof $P); $D call click "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4,\"count\":${5:-1},\"delivery_mode\":\"foreground\"}" >/dev/null ;;
  key) P=$(pidof_app); W=$(winof $P); $D call hotkey "{\"pid\":$P,\"window_id\":$W,\"keys\":\"$3\"}" ;;
  front) P=$(pidof_app); W=$(winof $P); $D call bring_to_front "{\"pid\":$P,\"window_id\":$W}" >/dev/null ;;
  kill) pkill -f "qa-container $C" ;;
  phases) grep 'launch phase' $C/launch.log ;;
  ax) P=$(pidof_app); W=$(winof $P); $D call get_window_state "{\"pid\":$P,\"window_id\":$W,\"include_screenshot\":false,\"max_elements\":${3:-400}}" ;;
  rclick) P=$(pidof_app); W=$(winof $P); $D call click "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4,\"button\":\"right\",\"delivery_mode\":\"foreground\"}" >/dev/null ;;
  hover) P=$(pidof_app); W=$(winof $P); $D call move_cursor "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4}" >/dev/null ;;
  scroll) P=$(pidof_app); W=$(winof $P); $D call scroll "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4,\"direction\":\"$5\",\"amount\":${6:-6},\"delivery_mode\":\"foreground\"}" >/dev/null ;;
  desktop) screencapture -x "$C/$3.png"; echo "$C/$3.png" ;;
esac
