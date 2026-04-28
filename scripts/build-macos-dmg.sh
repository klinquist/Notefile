#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_RELEASE_ENV="$ROOT_DIR/scripts/release.local.env"

if [[ -f "$LOCAL_RELEASE_ENV" ]]; then
  source "$LOCAL_RELEASE_ENV"
fi

PROJECT_PATH="$ROOT_DIR/Notesync.xcodeproj"
SCHEME="Notesync"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.derived-release-macos}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist/macos}"
ARCHIVE_PATH="$BUILD_ROOT/Notesync.xcarchive"
EXPORT_DIR="$BUILD_ROOT/export"
DMG_STAGING_DIR="$BUILD_ROOT/dmg-staging"
EXPORT_OPTIONS_PLIST="$BUILD_ROOT/export-options.plist"

SIGN_FOR_DISTRIBUTION="${SIGN_FOR_DISTRIBUTION:-0}"
NOTARIZE_DMG="${NOTARIZE_DMG:-0}"
ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-0}"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
DEVELOPER_ID_APPLICATION_IDENTITY="${DEVELOPER_ID_APPLICATION_IDENTITY:-Developer ID Application}"

xcodebuild_auth_args=()
if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
  if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    echo "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together." >&2
    exit 1
  fi

  xcodebuild_auth_args=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  SIGN_FOR_DISTRIBUTION="1"
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

PROJECT_TEAM_ID="$(
  python3 - "$ROOT_DIR/Notesync.xcodeproj/project.pbxproj" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"DEVELOPMENT_TEAM = ([^;]+);", text)
print(match.group(1).strip() if match else "")
PY
)"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  DEVELOPMENT_TEAM="$PROJECT_TEAM_ID"
fi

VERSION="${1:-$MARKETING_VERSION}"
APP_NAME="Notesync"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/${APP_NAME}-${VERSION}-macOS.dmg"

rm -rf "$BUILD_ROOT"
mkdir -p "$EXPORT_DIR" "$DMG_STAGING_DIR" "$ROOT_DIR/dist"

verify_developer_id_signing() {
  local test_binary="$BUILD_ROOT/developer-id-codesign-check"
  local test_log="$BUILD_ROOT/developer-id-codesign-check.log"

  cp /bin/echo "$test_binary"

  if ! codesign --force --sign "$DEVELOPER_ID_APPLICATION_IDENTITY" --timestamp=none "$test_binary" >"$test_log" 2>&1; then
    cat "$test_log" >&2
    echo "Developer ID signing preflight failed for identity '$DEVELOPER_ID_APPLICATION_IDENTITY'." >&2
    echo "If the error is errSecInternalComponent, update the key partition list with:" >&2
    echo "security set-key-partition-list -S apple-tool:,apple: -s -t private -k \"<mac-login-password>\" /Users/kris/Library/Keychains/login.keychain-db" >&2
    echo "You can also set DEVELOPER_ID_APPLICATION_IDENTITY to a specific certificate hash or full identity name." >&2
    exit 1
  fi

  rm -f "$test_binary" "$test_log"
}

if [[ "$SIGN_FOR_DISTRIBUTION" == "1" ]]; then
  verify_developer_id_signing
fi

archive_args=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -archivePath "$ARCHIVE_PATH"
  archive
)

if [[ "$SIGN_FOR_DISTRIBUTION" == "1" ]]; then
  if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    echo "Signing requested but no DEVELOPMENT_TEAM is configured." >&2
    exit 1
  fi

  archive_args+=(
    CODE_SIGN_STYLE=Automatic
    CODE_SIGNING_ALLOWED=YES
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
  )

  if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
    archive_args=(-allowProvisioningUpdates "${xcodebuild_auth_args[@]}" "${archive_args[@]}")
  fi

  echo "Building signed macOS archive for version $VERSION"
else
  archive_args+=(CODE_SIGNING_ALLOWED=NO)
  echo "Building unsigned macOS archive for version $VERSION"
fi

xcodebuild "${archive_args[@]}"

APP_SOURCE="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

if [[ ! -d "$APP_SOURCE" ]]; then
  echo "Built app not found at $APP_SOURCE" >&2
  exit 1
fi

if [[ "$SIGN_FOR_DISTRIBUTION" == "1" ]]; then
  cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>signingCertificate</key>
  <string>${DEVELOPER_ID_APPLICATION_IDENTITY}</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>${DEVELOPMENT_TEAM}</string>
</dict>
</plist>
EOF

  export_args=(
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
  )

  if [[ "$ALLOW_PROVISIONING_UPDATES" == "1" ]]; then
    export_args=(-allowProvisioningUpdates "${xcodebuild_auth_args[@]}" "${export_args[@]}")
  fi

  xcodebuild "${export_args[@]}"
else
  cp -R "$APP_SOURCE" "$APP_PATH"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found at $APP_PATH" >&2
  exit 1
fi

if [[ "$SIGN_FOR_DISTRIBUTION" == "1" ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"

  if [[ "$NOTARIZE_DMG" != "1" ]]; then
    spctl -a -t exec -vv "$APP_PATH"
  fi
fi

rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  "$ROOT_DIR/scripts/notarize-macos-dmg.sh" "$DMG_PATH"
fi

echo "Built app: $APP_PATH"
echo "Built DMG: $DMG_PATH"

if [[ "$SIGN_FOR_DISTRIBUTION" == "1" ]]; then
  echo "macOS app signing: enabled"
fi

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  echo "DMG notarization: completed"
fi
