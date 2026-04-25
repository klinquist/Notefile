#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
    archive_args=(-allowProvisioningUpdates "${archive_args[@]}")
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
    export_args=(-allowProvisioningUpdates "${export_args[@]}")
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
  spctl -a -t exec -vv "$APP_PATH"
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
  if [[ -z "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
    echo "Notarization requested but NOTARYTOOL_KEYCHAIN_PROFILE is not set." >&2
    exit 1
  fi

  echo "Submitting DMG for notarization"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
    --wait

  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "Built app: $APP_PATH"
echo "Built DMG: $DMG_PATH"

if [[ "$SIGN_FOR_DISTRIBUTION" == "1" ]]; then
  echo "macOS app signing: enabled"
fi

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  echo "DMG notarization: completed"
fi
