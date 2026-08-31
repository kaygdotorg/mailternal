#!/usr/bin/env bash
# Rsync the repo to agents@mbp and build there.
#   Scripts/build-mbp.sh [dirname] [package|app|test [filter]]
# dirname defaults to "main" (integration); chunk agents MUST pass their chunk name.
set -euo pipefail
DIR="${1:-main}"
MODE="${2:-package}"
REMOTE="agents@mbp"
DEST="~/mailternal-build/$DIR"
ssh "$REMOTE" "mkdir -p $DEST"
rsync -a --delete --exclude .git --exclude .build --exclude 'App/Mailternal.xcodeproj' \
  "$(git rev-parse --show-toplevel)/" "$REMOTE:$DEST/"
case "$MODE" in
  package)
    ssh "$REMOTE" "cd $DEST && swift build 2>&1" ;;
  test)
    FILTER="${3:-}"
    ssh "$REMOTE" "cd $DEST && swift test ${FILTER:+--filter $FILTER} 2>&1" ;;
  app)
    ssh "$REMOTE" "cd $DEST/App && /opt/homebrew/bin/xcodegen generate && \
      xcodebuild -project Mailternal.xcodeproj -scheme Mailternal -configuration Debug \
      -derivedDataPath build build 2>&1 | tail -30" ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
