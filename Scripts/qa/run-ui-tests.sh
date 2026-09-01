#!/usr/bin/env bash
# Run Mailternal XCUITests. Requires a macOS GUI console session
# (WindowServer). Over ssh without a console this will fail; use it
# from the morning GUI login on the build Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/App"
DERIVED="${DERIVED_DATA:-$APP/build}"
XCODEGEN="${XCODEGEN:-/opt/homebrew/bin/xcodegen}"

cd "$APP"
if [[ -x "$XCODEGEN" ]]; then
  "$XCODEGEN" generate
elif command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
else
  echo "xcodegen not found" >&2
  exit 2
fi

xcodebuild test \
  -project Mailternal.xcodeproj \
  -scheme Mailternal \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -only-testing:MailternalUITests \
  "$@"
