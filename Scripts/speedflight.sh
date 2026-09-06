#!/usr/bin/env bash
# Cut a cloud-signed iOS IPA from a real, pushed Git commit and upload it to
# Speedflight. XcodeGen runs in a temporary Git worktree so the current source
# checkout and its generated project are never changed.
#
#   Scripts/speedflight.sh "<title>" "<notes>" [screenshot.png ...]
#
# Configure .env.speedflight once; see --help. The file contains the upload
# secret and must stay private. The App Store Connect private key is read by
# xcodebuild only and is never sent to Speedflight.
set -euo pipefail
# Do not let an invoking shell's xtrace expose configuration values.
set +x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel 2>/dev/null || true)"

usage() {
  cat <<'HELP'
Usage:
  Scripts/speedflight.sh "<title>" "<notes>" [screenshot.png ...]
  Scripts/speedflight.sh --help

Cut and share Mailternal's iOS build from a Mac. The title is one line;
notes may contain newlines. Screenshots are optional PNG, JPG/JPEG, or WebP
files, in display order (at most 12 and under 10 MiB each).

This script always builds the pushed HEAD in a temporary, real Git worktree
under ~/Developer/Worktrees, regenerates Mobile/MailternalMobile.xcodeproj
with XcodeGen there, and writes private artifacts to build/share/ in the
current worktree. It never commits, pushes, manually creates/revokes signing
assets, or installs on a device.

Required one-time setup at the repository root:
  1. Create an App Store Connect API key with Admin or App Manager role for
     team VP77RTCF3K. Save the downloaded private key (never upload it) as
     ~/private_keys/AuthKey_<ASC_KEY_ID>.p8, or set ASC_PRIVATE_KEY_PATH.
  2. Create .env.speedflight and chmod 600 it. Keep this file gitignored:
       ASC_KEY_ID=...
       ASC_ISSUER_ID=...
       SPEEDFLIGHT_SECRET=...
       SPEEDFLIGHT_DEEP_LINK=mailternal://
       SPEEDFLIGHT_AUTHOR=...
     SPEEDFLIGHT_SECRET must be 32-128 [A-Za-z0-9_-] characters.
     Optional: SPEEDFLIGHT_ICON=path/to/icon-1024.png (relative to repo root)
  3. Commit and push the source and this script. The working tree must be
     clean and HEAD must be an ancestor of its configured upstream branch.

Build facts are fixed to the XcodeGen project Mobile/project.yml:
  project: Mobile/MailternalMobile.xcodeproj
  scheme: MailternalIOS
  bundle: org.kayg.mailternal.ios
  team: VP77RTCF3K
  export: Release / release-testing / automatic / thinning=<none>
  upload: https://speedflight.dev
Requirements on the Mac: macOS, Xcode command-line tools (xcodebuild),
XcodeGen (xcodegen), jq, curl, file, git, and the App Store Connect key file.
Xcode's provisioning update flag may create or download the signing assets
needed for this archive; this script does not revoke, export, or manually
manage certificates, profiles, keychain items, or privacy permissions.
The final line is the server-returned page URL:
  Build page: https://speedflight.dev/a/<page-id>

The page link permits installation on devices registered to the signing Apple
account. Do not paste the upload secret or page link into public locations.
HELP
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 2 ]]; then
  usage >&2
  exit 2
fi

TITLE="$1"
NOTES="$2"
shift 2
# Keep optional screenshots in "$@"; empty arrays fail under macOS Bash 3 nounset.

fail() {
  printf 'speedflight: %s\n' "$*" >&2
  exit 1
}

if [[ -z "$TITLE" ]]; then
  fail 'title must not be empty'
fi
if [[ -z "$NOTES" ]]; then
  fail 'notes must not be empty'
fi
case "$TITLE" in
  *[![:print:]]*) fail 'title must contain printable characters and be one line' ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail 'must run on the Mac build host (macOS); this Linux checkout cannot run xcodebuild'
fi

if [[ -z "$REPO_ROOT" || ! -e "$REPO_ROOT/.git" ]]; then
  fail 'source must be a real Git checkout; rsync/build copies without .git are not accepted'
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}
for command_name in git xcodebuild xcodegen jq curl file; do
  require_command "$command_name"
done

ENV_FILE="$REPO_ROOT/.env.speedflight"
ENV_RELATIVE='.env.speedflight'
[[ ! -L "$ENV_FILE" && -f "$ENV_FILE" ]] ||
  fail "$ENV_RELATIVE must be a regular, non-symlink file"
if git -C "$REPO_ROOT" ls-files --error-unmatch -- "$ENV_RELATIVE" >/dev/null 2>&1; then
  fail "$ENV_RELATIVE is tracked; remove it from Git and rotate its SPEEDFLIGHT_SECRET"
fi
if ! git -C "$REPO_ROOT" check-ignore -q -- "$ENV_RELATIVE"; then
  fail "$ENV_RELATIVE is not ignored; add it to .gitignore before continuing"
fi

ENV_MODE="$(stat -f '%Lp' "$ENV_FILE" 2>/dev/null || true)"
if [[ ! "$ENV_MODE" =~ ^[0-7]{3,4}$ ]]; then
  ENV_MODE="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || true)"
fi
[[ "$ENV_MODE" == '600' || "$ENV_MODE" == '0600' ]] ||
  fail "$ENV_RELATIVE must have mode 0600 (run: chmod 600 $ENV_RELATIVE)"

# Parse the small, documented KEY=VALUE file instead of sourcing it. This keeps
# configuration data from being executable shell code and prevents inherited
# exported settings from reaching child processes.
unset ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_PATH SPEEDFLIGHT_SECRET \
  SPEEDFLIGHT_DEEP_LINK SPEEDFLIGHT_AUTHOR SPEEDFLIGHT_ICON
while IFS= read -r env_line || [[ -n "$env_line" ]]; do
  case "$env_line" in
    '') continue ;;
    \#*) continue ;;
  esac
  [[ "$env_line" == *=* ]] || fail "invalid line in $ENV_RELATIVE (expected KEY=VALUE)"
  env_name="${env_line%%=*}"
  env_value="${env_line#*=}"
  [[ "$env_name" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
    fail "invalid setting name in $ENV_RELATIVE"
  case "$env_name" in
    ASC_KEY_ID|ASC_ISSUER_ID|ASC_PRIVATE_KEY_PATH|SPEEDFLIGHT_SECRET|SPEEDFLIGHT_DEEP_LINK|SPEEDFLIGHT_AUTHOR|SPEEDFLIGHT_ICON) ;;
    *) fail "unsupported setting in $ENV_RELATIVE: $env_name" ;;
  esac
  case "$env_value" in
    \"*\") env_value="${env_value:1:${#env_value}-2}" ;;
    \'*\') env_value="${env_value:1:${#env_value}-2}" ;;
    \"*|\'*) fail "unterminated quoted value in $ENV_RELATIVE" ;;
  esac
  printf -v "$env_name" '%s' "$env_value"
done < "$ENV_FILE"
: "${ASC_KEY_ID:?set ASC_KEY_ID in .env.speedflight}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID in .env.speedflight}"
: "${SPEEDFLIGHT_SECRET:?set SPEEDFLIGHT_SECRET in .env.speedflight}"
: "${SPEEDFLIGHT_DEEP_LINK:?set SPEEDFLIGHT_DEEP_LINK=mailternal:// in .env.speedflight}"
: "${SPEEDFLIGHT_AUTHOR:?set SPEEDFLIGHT_AUTHOR in .env.speedflight}"

[[ "$ASC_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || fail 'ASC_KEY_ID contains unsupported characters'
case "$SPEEDFLIGHT_AUTHOR" in
  *[![:print:]]*) fail 'SPEEDFLIGHT_AUTHOR must contain printable characters and be one line' ;;
esac

ASC_PRIVATE_KEY_PATH="${ASC_PRIVATE_KEY_PATH:-$HOME/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
case "$ASC_PRIVATE_KEY_PATH" in
  *[![:print:]]*) fail 'ASC_PRIVATE_KEY_PATH must contain printable characters' ;;
esac
[[ ! -L "$ASC_PRIVATE_KEY_PATH" && -f "$ASC_PRIVATE_KEY_PATH" ]] ||
  fail 'missing App Store Connect private key file (it must be a regular, non-symlink file)'
KEY_MODE="$(stat -f '%Lp' "$ASC_PRIVATE_KEY_PATH" 2>/dev/null || true)"
if [[ ! "$KEY_MODE" =~ ^[0-7]{3,4}$ ]]; then
  KEY_MODE="$(stat -c '%a' "$ASC_PRIVATE_KEY_PATH" 2>/dev/null || true)"
fi
[[ "$KEY_MODE" == '600' || "$KEY_MODE" == '0600' ]] ||
  fail 'the App Store Connect private key must have mode 0600 (run chmod 600 on it)'

PROJECT_RELATIVE='Mobile/MailternalMobile.xcodeproj'
SCHEME='MailternalIOS'
BUNDLE_ID='org.kayg.mailternal.ios'
TEAM_ID='VP77RTCF3K'
BASE='https://speedflight.dev'
OUT="$REPO_ROOT/build/share"

file_size() {
  local path="$1" size
  size="$(stat -f '%z' "$path" 2>/dev/null || true)"
  if [[ ! "$size" =~ ^[0-9]+$ ]]; then
    size="$(stat -c '%s' "$path" 2>/dev/null || true)"
  fi
  printf '%s' "$size"
}

screenshot_type() {
  case "$1" in
    *.png|*.PNG) printf 'image/png' ;;
    *.jpg|*.JPG|*.jpeg|*.JPEG) printf 'image/jpeg' ;;
    *.webp|*.WEBP) printf 'image/webp' ;;
    *) return 1 ;;
  esac
}

for screenshot in "$@"; do
  case "$screenshot" in *[![:print:]]*) fail 'screenshot path contains control characters' ;; esac
  [[ ! -L "$screenshot" && -f "$screenshot" ]] ||
    fail 'each screenshot must be a regular, non-symlink file'
  screenshot_type_value="$(screenshot_type "$screenshot")" ||
    fail 'unsupported screenshot type (use PNG, JPG/JPEG, or WebP)'
  screenshot_mime="$(file -b --mime-type "$screenshot" 2>/dev/null || true)"
  [[ "$screenshot_mime" == "$screenshot_type_value" ]] ||
    fail 'screenshot filename extension does not match its file MIME type'
  screenshot_size="$(file_size "$screenshot")"
  [[ "$screenshot_size" =~ ^[0-9]+$ ]] || fail 'could not determine screenshot size'
  (( screenshot_size < 10485760 )) || fail 'screenshot exceeds 10 MiB'
done

ICON_PATH="${SPEEDFLIGHT_ICON:-}"
if [[ -n "$ICON_PATH" ]]; then
  case "$ICON_PATH" in *[![:print:]]*) fail 'SPEEDFLIGHT_ICON path contains control characters' ;; esac
  [[ "$ICON_PATH" = /* ]] || ICON_PATH="$REPO_ROOT/$ICON_PATH"
  [[ ! -L "$ICON_PATH" && -f "$ICON_PATH" ]] ||
    fail 'SPEEDFLIGHT_ICON must be a regular, non-symlink file'
  case "$ICON_PATH" in *.png|*.PNG) ;; *) fail 'SPEEDFLIGHT_ICON must be a PNG file' ;; esac
  icon_mime="$(file -b --mime-type "$ICON_PATH" 2>/dev/null || true)"
  [[ "$icon_mime" == 'image/png' ]] || fail 'SPEEDFLIGHT_ICON must contain PNG data'
  icon_size="$(file_size "$ICON_PATH")"
  [[ "$icon_size" =~ ^[0-9]+$ ]] || fail 'could not determine SPEEDFLIGHT_ICON size'
  (( icon_size < 2097152 )) || fail 'SPEEDFLIGHT_ICON exceeds 2 MiB'
fi
cd "$REPO_ROOT"
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || fail 'HEAD is detached; run from a named branch with an upstream'
COMMIT="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  fail 'working tree is dirty; commit changes before sharing a build'
fi
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
[[ -n "$UPSTREAM" ]] || fail "branch '$BRANCH' has no upstream; push it before sharing a build"
if ! git merge-base --is-ancestor "$COMMIT" "$UPSTREAM" 2>/dev/null; then
  fail "HEAD is not pushed to '$UPSTREAM'; push the current commit before sharing a build"
fi

# Include a repository link only when the configured origin is a credential-free
# HTTPS URL or a normal SSH URL. It is optional in the Speedflight API.
REPO_URL=''
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
case "$ORIGIN_URL" in
  git@*:* )
    ORIGIN_HOST_PATH="${ORIGIN_URL#git@}"
    ORIGIN_HOST="${ORIGIN_HOST_PATH%%:*}"
    ORIGIN_PATH="${ORIGIN_HOST_PATH#*:}"
    ORIGIN_PATH="${ORIGIN_PATH%.git}"
    REPO_URL="https://$ORIGIN_HOST/$ORIGIN_PATH"
    ;;
  https://*)
    if [[ "$ORIGIN_URL" != *'@'* ]]; then
      REPO_URL="${ORIGIN_URL%.git}"
    fi
    ;;
esac
# Keep the secret in a short-lived curl config file, never in curl's argv. Any
# curl diagnostics are discarded because a URL error could echo the secret.
api_request() {
  local method="$1"
  local api_path="$2"
  local response_path="$3"
  local payload_path="${4:-}"
  local content_type="${5:-}"
  local curl_config curl_error

  curl_config="$(mktemp "$PRIVATE_TMP/curl-config.XXXXXX")"
  curl_error="$PRIVATE_TMP/curl-error"
  {
    printf 'url = "%s%s"\n' "$BASE" "$api_path"
    printf 'request = "%s"\n' "$method"
    printf '%s\n' 'fail' 'silent' 'show-error' 'http1.1'
    if [[ "$method" == 'POST' ]]; then
      # Build creation has no idempotency key; never replay a POST after an
      # ambiguous network failure.
      printf '%s\n' 'retry = 0'
    else
      printf '%s\n' 'retry = 3' 'retry-all-errors' 'retry-delay = 3'
    fi
    if [[ -n "$content_type" ]]; then
      printf 'header = "Content-Type: %s"\n' "$content_type"
    fi
  } > "$curl_config"

  if [[ -n "$payload_path" ]]; then
    if ! curl -q --config "$curl_config" --data-binary "@$payload_path" \
      > "$response_path" 2> "$curl_error"; then
      rm -f "$curl_config" "$curl_error"
      return 1
    fi
  elif ! curl -q --config "$curl_config" > "$response_path" 2> "$curl_error"; then
    rm -f "$curl_config" "$curl_error"
    return 1
  fi
  rm -f "$curl_config" "$curl_error"
}

if ! PRIVATE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/speedflight-private.XXXXXX")"; then
  fail 'cannot create a private temporary directory'
fi
chmod 700 "$PRIVATE_TMP"
WORKTREE_ROOT="$HOME/Developer/Worktrees"
if [[ ! -d "$WORKTREE_ROOT" ]] && ! mkdir -p "$WORKTREE_ROOT"; then
  fail "cannot create required Git worktree directory: $WORKTREE_ROOT"
fi
if ! WORKTREE_PARENT="$(mktemp -d "$WORKTREE_ROOT/speedflight.XXXXXX")"; then
  fail "cannot create a temporary Git worktree under $WORKTREE_ROOT"
fi
chmod 700 "$WORKTREE_PARENT"
BUILD_CHECKOUT="$WORKTREE_PARENT/source"
WORKTREE_ADDED=0
BUILD_ID=''
REMOTE_BUILD_ACTIVE=0
PAGE_URL=''

cleanup() {
  exit_status=$?
  if [[ "$REMOTE_BUILD_ACTIVE" == 1 && -n "$BUILD_ID" ]]; then
    DELETE_RESPONSE="$PRIVATE_TMP/delete-response"
    DELETE_PATH="/api/apps/${SPEEDFLIGHT_SECRET}/${BUNDLE_ID}/builds/${BUILD_ID}"
    api_request DELETE "$DELETE_PATH" "$DELETE_RESPONSE" '' '' >/dev/null 2>&1 || true
  fi
  if [[ "$WORKTREE_ADDED" == 1 ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$BUILD_CHECKOUT" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKTREE_PARENT" "$PRIVATE_TMP"
  exit "$exit_status"
}
trap cleanup EXIT

# This is deliberately a Git worktree, not an rsync copy: generated Xcode
# output is based on the exact clean commit whose branch/commit are published.
git -C "$REPO_ROOT" worktree add --detach "$BUILD_CHECKOUT" "$COMMIT" >/dev/null ||
  fail 'could not create the temporary real Git worktree for this commit'
WORKTREE_ADDED=1

XCODEGEN_BIN="$(command -v xcodegen)"
(
  cd "$BUILD_CHECKOUT/Mobile"
  "$XCODEGEN_BIN" generate --quiet
) || fail 'XcodeGen could not regenerate the iOS project in the temporary checkout'
[[ -d "$BUILD_CHECKOUT/$PROJECT_RELATIVE" ]] ||
  fail "XcodeGen did not create $PROJECT_RELATIVE"

rm -rf "$OUT"
mkdir -p "$OUT"
chmod 700 "$OUT"

xcodebuild -project "$BUILD_CHECKOUT/$PROJECT_RELATIVE" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$OUT/DerivedData" \
  -archivePath "$OUT/App.xcarchive" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  -quiet archive || fail 'xcodebuild archive failed; verify the ASC key role/team and signing configuration'

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>release-testing</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>VP77RTCF3K</string>
  <key>thinning</key>
  <string>&lt;none&gt;</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$OUT/App.xcarchive" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" \
  -allowProvisioningUpdates \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -authenticationKeyPath "$ASC_PRIVATE_KEY_PATH" \
  -quiet || fail 'xcodebuild export failed; verify release-testing signing for team VP77RTCF3K'

IPA_CANDIDATES=("$OUT/export/"*.ipa)
if [[ ${#IPA_CANDIDATES[@]} -ne 1 || ! -f "${IPA_CANDIDATES[0]}" ]]; then
  fail 'export did not produce exactly one IPA'
fi
IPA_PATH="$OUT/signed.ipa"
mv "${IPA_CANDIDATES[0]}" "$IPA_PATH"

META_FILE="$PRIVATE_TMP/metadata.json"
jq -n \
  --arg title "$TITLE" \
  --arg notes "$NOTES" \
  --arg deepLink "$SPEEDFLIGHT_DEEP_LINK" \
  --arg branch "$BRANCH" \
  --arg commit "$COMMIT" \
  --arg author "$SPEEDFLIGHT_AUTHOR" \
  --arg repoUrl "$REPO_URL" \
  '{title:$title, notes:$notes, deepLink:$deepLink, branch:$branch, commit:$commit, author:$author}
   + (if $repoUrl == "" then {} else {repoUrl:$repoUrl} end)' > "$META_FILE"

# Keep the secret in a short-lived curl config file, never in curl's argv. Any
# curl diagnostics are discarded because a URL error could echo the secret.

CREATE_RESPONSE="$PRIVATE_TMP/create-response.json"
CREATE_PATH="/api/apps/${SPEEDFLIGHT_SECRET}/${BUNDLE_ID}/builds"
api_request POST "$CREATE_PATH" "$CREATE_RESPONSE" "$META_FILE" 'application/json' ||
  fail 'Speedflight build registration failed; check network access and the upload secret'

# Capture a safe id before validating the rest of the response so an invalid
# page response can still be deleted by cleanup without exposing the secret.
BUILD_ID="$(jq -r '.buildId // empty' "$CREATE_RESPONSE" 2>/dev/null || true)"
if [[ "$BUILD_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
  REMOTE_BUILD_ACTIVE=1
else
  BUILD_ID=''
fi
if ! jq -e 'type == "object" and (.buildId|type == "string") and (.pageId|type == "string") and (.pageUrl|type == "string")' \
  "$CREATE_RESPONSE" >/dev/null; then
  fail 'Speedflight returned an invalid registration response (missing buildId/pageId/pageUrl)'
fi
PAGE_ID="$(jq -r '.pageId' "$CREATE_RESPONSE")"
PAGE_URL="$(jq -r '.pageUrl' "$CREATE_RESPONSE")"
[[ -n "$BUILD_ID" ]] || fail 'Speedflight returned an empty build id'
[[ "$PAGE_ID" =~ ^[0-9a-f]{32}$ ]] || fail 'Speedflight returned an unsafe page id'
[[ "$PAGE_URL" =~ ^https://speedflight\.dev/a/[0-9a-f]{32}$ ]] ||
  fail 'Speedflight returned an unexpected page URL; refusing to print or share it'
[[ "$PAGE_URL" == "https://speedflight.dev/a/$PAGE_ID" ]] ||
  fail 'Speedflight page URL does not match its returned page id'

UPLOAD_RESPONSE="$PRIVATE_TMP/upload-response.json"
IPA_PATH_API="/api/apps/${SPEEDFLIGHT_SECRET}/${BUNDLE_ID}/builds/${BUILD_ID}/app.ipa"
api_request PUT "$IPA_PATH_API" "$UPLOAD_RESPONSE" "$IPA_PATH" 'application/octet-stream' ||
  fail 'Speedflight IPA upload failed; the server did not accept the exported archive'
if ! jq -e --arg page "$PAGE_URL" 'type == "object" and .ok == true and .pageUrl == $page' \
  "$UPLOAD_RESPONSE" >/dev/null; then
  fail 'Speedflight returned an invalid IPA upload response'
fi

screenshot_number=0
for screenshot in "$@"; do
  screenshot_number=$((screenshot_number + 1))
  screenshot_type_value="$(screenshot_type "$screenshot")"
  screenshot_base="$(basename "$screenshot")"
  screenshot_safe="$(printf '%s' "$screenshot_base" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
  [[ -n "$screenshot_safe" ]] || screenshot_safe='screenshot'
  screenshot_name="$(printf '%02d-%s' "$screenshot_number" "$screenshot_safe")"
  screenshot_response="$PRIVATE_TMP/screenshot-$screenshot_number.json"
  screenshot_path="/api/apps/${SPEEDFLIGHT_SECRET}/${BUNDLE_ID}/builds/${BUILD_ID}/screenshots/${screenshot_name}"
  api_request PUT "$screenshot_path" "$screenshot_response" "$screenshot" "$screenshot_type_value" ||
    fail "Speedflight screenshot upload failed: $screenshot"
done

if [[ -n "$ICON_PATH" ]]; then
  ICON_RESPONSE="$PRIVATE_TMP/icon-response.json"
  ICON_PATH_API="/api/apps/${SPEEDFLIGHT_SECRET}/${BUNDLE_ID}/icon"
  api_request PUT "$ICON_PATH_API" "$ICON_RESPONSE" "$ICON_PATH" 'image/png' ||
    fail 'Speedflight icon upload failed'
fi

if printf '\nBuild page: %s\n' "$PAGE_URL"; then
  REMOTE_BUILD_ACTIVE=0
else
  fail 'could not print the Speedflight page URL'
fi
