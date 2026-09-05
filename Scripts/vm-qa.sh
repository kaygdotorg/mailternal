#!/bin/zsh
# Runs ON the QA VM (lume). Launch the deployed app against a fresh fixture copy
# and expose CuaDriver helpers.
#   vm-qa.sh launch <name>      -> fresh container ~/mailternal-qa-<name>, GUI, prints pid/window
#   vm-qa.sh shot <name> <file> -> screenshot of the app window into ~/mailternal-qa-<name>/<file>.png
#   vm-qa.sh click <name> x y count
#   vm-qa.sh key <name> <key>
#   vm-qa.sh kill <name>
D=/Applications/CuaDriver.app/Contents/MacOS/cua-driver
cmd=$1; name=$2
RUN=$HOME/mailternal-qa-$name
STORE=$RUN
if [ "$cmd" = launch-release ]; then
  APP=${APP:-$HOME/mailternal/Mailternal-release.app}
  # A sandboxed Release build can only open a QA store inside its app
  # container. Use a named sibling of the production root so every run stays
  # isolated without relying on CFFIXED_USER_HOME.
  STORE="$HOME/Library/Containers/org.kayg.mailternal/Data/Library/Application Support/Mailternal-QA-$name"
else
  APP=${APP:-$HOME/mailternal/Mailternal.app}
fi
QA_CERT_SOURCE=${MAILTERNAL_QA_CERT:-$HOME/mailternal-qa/certs/dovecot.crt}
QA_CERT="$HOME/Library/Containers/org.kayg.mailternal/Data/mailternal-qa/certs/dovecot.crt"
FIXTURE=${FIXTURE:-$HOME/mailternal-qa-base}
pidof_app() { pgrep -f "qa-container $STORE" | head -1 }
# main window = the largest window of the pid (Settings/hover panels are smaller)
winof() { $D call list_windows '{}' | jq -r ".windows[] | select(.pid==$1 and .bounds.height>100) | [(.bounds.width*.bounds.height), .window_id] | @tsv" | sort -rn | head -1 | cut -f2 }
case $cmd in
  launch|launch-release)
    pkill -f "qa-container $STORE" 2>/dev/null; sleep 0.5
    rm -rf "$RUN"; mkdir -p "$RUN"
    if [ "$cmd" = launch-release ]; then
      rm -rf "$STORE"; mkdir -p "$STORE" "${QA_CERT:h}"
      cp -R "$FIXTURE"/. "$STORE"/
      cp "$QA_CERT_SOURCE" "$QA_CERT"
      MAILTERNAL_QA=1 MAILTERNAL_QA_CERT="$QA_CERT" "$APP/Contents/MacOS/Mailternal" -qa-account 127.0.0.1 1143 startTLS -qa-container "$STORE" -qa-gui > "$RUN/launch.log" 2>&1 &
    else
      cp -R "$FIXTURE"/. "$STORE"/
      MAILTERNAL_QA=1 "$APP/Contents/MacOS/Mailternal" -qa-account 127.0.0.1 1143 startTLS -qa-container "$STORE" -qa-gui > "$RUN/launch.log" 2>&1 &
    fi
    for i in {1..60}; do sleep 0.25; P=$(pidof_app); [ -n "$P" ] && W=$(winof $P) && [ -n "$W" ] && break; done
    echo "P=$P W=$W"; sed -n '/launch phase/p' "$RUN/launch.log" ;;
  shot) P=$(pidof_app); W=$(winof $P); $D call get_window_state "{\"pid\":$P,\"window_id\":$W,\"screenshot_out_file\":\"$RUN/$3.png\",\"include_screenshot\":false,\"max_elements\":3}" >/dev/null && echo "$RUN/$3.png" ;;
  shotwin) P=$(pidof_app); $D call get_window_state "{\"pid\":$P,\"window_id\":$4,\"screenshot_out_file\":\"$RUN/$3.png\",\"include_screenshot\":false,\"max_elements\":3}" >/dev/null && echo "$RUN/$3.png" ;;
  winlist) P=$(pidof_app); $D call list_windows '{}' | jq -r ".windows[] | select(.pid==$P) | [.window_id, .bounds.x, .bounds.y, .bounds.width, .bounds.height] | @tsv" ;;
  click) P=$(pidof_app); W=$(winof $P); $D call click "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4,\"count\":${5:-1},\"delivery_mode\":\"foreground\"}" >/dev/null ;;
  key) P=$(pidof_app); W=$(winof $P); $D call hotkey "{\"pid\":$P,\"window_id\":$W,\"keys\":\"$3\"}" ;;
  kill) pkill -f "qa-container $STORE" 2>/dev/null || true ;;
  phases) sed -n '/launch phase/p' "$RUN/launch.log" ;;
  ax) P=$(pidof_app); W=$(winof $P); $D call get_window_state "{\"pid\":$P,\"window_id\":$W,\"include_screenshot\":false,\"max_elements\":${3:-400}}" ;;
  rclick) P=$(pidof_app); W=$(winof $P); $D call click "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4,\"button\":\"right\",\"delivery_mode\":\"foreground\"}" >/dev/null ;;
  hover) P=$(pidof_app); W=$(winof $P); $D call move_cursor "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4}" >/dev/null ;;
  scroll) P=$(pidof_app); W=$(winof $P); $D call scroll "{\"pid\":$P,\"window_id\":$W,\"x\":$3,\"y\":$4,\"direction\":\"$5\",\"amount\":${6:-6},\"delivery_mode\":\"foreground\"}" >/dev/null ;;
  desktop) screencapture -x "$RUN/$3.png"; echo "$RUN/$3.png" ;;
esac
