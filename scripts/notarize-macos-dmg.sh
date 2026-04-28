#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Notesync.xcodeproj"
APP_NAME="Notesync"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-notesync}"
DEVELOPER_ID_APPLICATION_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"
SIGN_DMG="${SIGN_DMG:-1}"
SCRIPT_NAME="$(basename "$0")"

usage() {
  echo "Usage: NOTARYTOOL_KEYCHAIN_PROFILE=notesync ./scripts/$SCRIPT_NAME [path-to-dmg]" >&2
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

if [[ -z "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
  echo "NOTARYTOOL_KEYCHAIN_PROFILE is required." >&2
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

if ! xcrun notarytool history --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "Could not use notarytool keychain profile '$NOTARYTOOL_KEYCHAIN_PROFILE'." >&2
  echo "Store credentials with:" >&2
  echo "xcrun notarytool store-credentials $NOTARYTOOL_KEYCHAIN_PROFILE --apple-id <apple-id> --team-id <team-id> --validate" >&2
  exit 1
fi

echo "Submitting $(basename "$DMG_PATH") for notarization"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait

echo "Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Checking Gatekeeper assessment"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo "Notarized DMG: $DMG_PATH"
