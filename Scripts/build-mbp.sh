#!/usr/bin/env bash
# Rsync the repo under agents@mbp:~/Developer/Worktrees/mailternal-build and build there.
#   Scripts/build-mbp.sh [dirname] [package|app|test [filter]]
# dirname defaults to "main" (integration); chunk agents MUST pass their chunk name.
# App builds must pass the shared-Keychain/provisioning gate. An ad-hoc
# memory-only QA build is never an installable substitute for a signed app.
set -euo pipefail
DIR="${1:-main}"
MODE="${2:-package}"
REMOTE="agents@mbp"
DEST="~/Developer/Worktrees/mailternal-build/$DIR"
ssh "$REMOTE" "mkdir -p $DEST"
rsync -a --delete --exclude .git --exclude .build --exclude 'App/build' \
  --exclude .code-review-graph --exclude 'App/Mailternal.xcodeproj' \
  --exclude 'Mobile/build' --exclude 'Mobile/MailternalMobile.xcodeproj' \
  "$(git rev-parse --show-toplevel)/" "$REMOTE:$DEST/"
case "$MODE" in
  package)
    ssh "$REMOTE" "cd $DEST && swift build 2>&1" ;;
  test)
    FILTER="${3:-}"
    # Treat the test filter as one remote argument, including regex operators.
    FILTER_ARG=""
    if [[ -n "$FILTER" ]]; then printf -v FILTER_ARG ' --filter %q' "$FILTER"; fi
    ssh "$REMOTE" "cd $DEST && swift test${FILTER_ARG} 2>&1" ;;
  app)
    # The local shell's pipefail does not propagate through SSH.
    ssh "$REMOTE" "set -o pipefail && cd $DEST/App && /opt/homebrew/bin/xcodegen generate && \
      xcodebuild -project Mailternal.xcodeproj -scheme Mailternal -configuration Debug \
      -derivedDataPath build build 2>&1 | tail -30 && \
      python3 ../Scripts/verify-app-signing.py build/Build/Products/Debug/Mailternal.app" ;;
  *) echo "unknown mode $MODE" >&2; exit 2 ;;
esac
