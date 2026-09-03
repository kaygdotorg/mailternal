#!/bin/sh
# Deploys a built chunk to /Users/Shared/Mailternal and relaunches it in the
# kayg GUI session on the Mac. Usage: Scripts/relaunch-kayg.sh <chunk>
set -eu
CHUNK="${1:?chunk}"
SRC="/Users/agents/mailternal-build/$CHUNK/App/build/Build/Products/Debug/Mailternal.app"
ssh agents@mbp "test -x '$SRC/Contents/MacOS/Mailternal'" || { echo "no built app at $SRC; not deploying" >&2; exit 1; }
DST="/Users/Shared/Mailternal/Mailternal.app"
ssh agents@mbp "pgrep -fl 'MacOS/Mailternal' | grep -v Shared | awk '{print \$1}' | xargs -r kill 2>/dev/null; rm -rf $DST.new && ditto '$SRC' $DST.new && rm -rf $DST && mv $DST.new $DST"
ssh kayg@mbp "pkill -x Mailternal 2>/dev/null; sleep 1; open -a $DST; sleep 2; pgrep -x Mailternal >/dev/null && echo 'relaunched in kayg session'"
