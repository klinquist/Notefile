#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_RELEASE_ENV="$ROOT_DIR/scripts/release.local.env"

if [[ -f "$LOCAL_RELEASE_ENV" ]]; then
  source "$LOCAL_RELEASE_ENV"
fi

PROJECT_PATH="$ROOT_DIR/Notesync.xcodeproj"
APP_NAME="Notesync"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
DEVELOPER_ID_APPLICATION_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"
SIGN_DMG="${SIGN_DMG:-1}"
SCRIPT_NAME="$(basename "$0")"

usage() {
  echo "Usage: ASC_KEY_PATH=/path/AuthKey_XXXXXXXXXX.p8 ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=uuid ./scripts/$SCRIPT_NAME [path-to-dmg]" >&2
  echo "   or: NOTARYTOOL_KEYCHAIN_PROFILE=notesync ./scripts/$SCRIPT_NAME [path-to-dmg]" >&2
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Could not find project at $PROJECT_PATH" >&2
  exit 1
fi

MARKETING_VERSION="$(
  python3 - "$ROOT_DIR/Notesync.xcodeproj/project.pbxproj" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"MARKETING_VERSION = ([^;]+);", text)
if not match:
    raise SystemExit("Could not find MARKETING_VERSION")
print(match.group(1).strip())
PY
)"

DMG_PATH="${1:-$ROOT_DIR/dist/${APP_NAME}-${MARKETING_VERSION}-macOS.dmg}"

notarytool_auth_args=()
if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
  if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    echo "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together." >&2
    exit 1
  fi

  notarytool_auth_args=(
    --key "$ASC_KEY_PATH"
    --key-id "$ASC_KEY_ID"
    --issuer "$ASC_ISSUER_ID"
  )
elif [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
  notarytool_auth_args=(
    --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE"
  )
else
  echo "Notarization credentials are required." >&2
  usage
  exit 1
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found at $DMG_PATH" >&2
  exit 1
fi

if [[ "$SIGN_DMG" == "1" ]]; then
  echo "Signing $(basename "$DMG_PATH")"
  codesign --force --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" --timestamp "$DMG_PATH"
fi

codesign --verify --verbose=2 "$DMG_PATH"

echo "Submitting $(basename "$DMG_PATH") for notarization"
xcrun notarytool submit "$DMG_PATH" \
  "${notarytool_auth_args[@]}" \
  --wait

echo "Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Checking Gatekeeper assessment"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo "Notarized DMG: $DMG_PATH"
