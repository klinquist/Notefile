#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_RELEASE_ENV="$ROOT_DIR/scripts/release.local.env"

if [[ -f "$LOCAL_RELEASE_ENV" ]]; then
  source "$LOCAL_RELEASE_ENV"
fi

PROJECT_PATH="$ROOT_DIR/Notesync.xcodeproj"
SCHEME="${SCHEME:-Notesync}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${TEAM_ID:-YYE9CDH9RT}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/dist/app-store}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.derived-app-store}"
UPLOAD_SYMBOLS="${UPLOAD_SYMBOLS:-0}"
ALLOW_XCODE_ACCOUNT_AUTH="${ALLOW_XCODE_ACCOUNT_AUTH:-0}"

IOS_ARCHIVE_PATH="$BUILD_ROOT/Notesync-iOS.xcarchive"
MACOS_ARCHIVE_PATH="$BUILD_ROOT/Notesync-macOS.xcarchive"
IOS_EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions-iOS.plist"
MACOS_EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions-macOS.plist"
IOS_EXPORT_PATH="$BUILD_ROOT/upload-ios"
MACOS_EXPORT_PATH="$BUILD_ROOT/upload-macos"

auth_args=()
if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
  if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    echo "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together." >&2
    exit 1
  fi

  if [[ ! -f "$ASC_KEY_PATH" ]]; then
    echo "ASC_KEY_PATH does not point to a file: $ASC_KEY_PATH" >&2
    exit 1
  fi

  auth_args=(
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
elif [[ "$ALLOW_XCODE_ACCOUNT_AUTH" != "1" ]]; then
  echo "App Store uploads require ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID." >&2
  echo "Set them in scripts/release.local.env to avoid using Xcode account login state." >&2
  echo "Set ALLOW_XCODE_ACCOUNT_AUTH=1 only if you intentionally want xcodebuild to use Xcode Accounts." >&2
  exit 1
fi

ensure_no_export_compliance_needed() {
  local plist_path="$1"

  if /usr/libexec/PlistBuddy -c "Print :ITSAppUsesNonExemptEncryption" "$plist_path" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :ITSAppUsesNonExemptEncryption false" "$plist_path"
  else
    /usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "$plist_path"
  fi
}

write_export_options() {
  local output_path="$1"
  local upload_symbols_value="<false/>"

  if [[ "$UPLOAD_SYMBOLS" == "1" || "$UPLOAD_SYMBOLS" == "true" ]]; then
    upload_symbols_value="<true/>"
  fi

  cat > "$output_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>upload</string>
  <key>method</key>
  <string>app-store-connect</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>uploadSymbols</key>
  ${upload_symbols_value}
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>iCloudContainerEnvironment</key>
  <string>Production</string>
  <key>teamID</key>
  <string>${TEAM_ID}</string>
</dict>
</plist>
EOF
}

archive_platform() {
  local platform="$1"
  local archive_path="$2"

  echo "Archiving $platform"
  xcodebuild \
    -allowProvisioningUpdates \
    "${auth_args[@]}" \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=$platform" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -archivePath "$archive_path" \
    archive \
    CODE_SIGN_STYLE=Automatic \
    CODE_SIGNING_ALLOWED=YES \
    DEVELOPMENT_TEAM="$TEAM_ID"
}

upload_archive() {
  local archive_path="$1"
  local export_path="$2"
  local export_options="$3"

  echo "Uploading $(basename "$archive_path") to App Store Connect"
  xcodebuild \
    -allowProvisioningUpdates \
    "${auth_args[@]}" \
    -exportArchive \
    -archivePath "$archive_path" \
    -exportPath "$export_path" \
    -exportOptionsPlist "$export_options"
}

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Could not find project at $PROJECT_PATH" >&2
  exit 1
fi

ensure_no_export_compliance_needed "$ROOT_DIR/Notesync/Resources/Info.plist"
ensure_no_export_compliance_needed "$ROOT_DIR/Notesync/Resources/InfoMac.plist"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$IOS_EXPORT_PATH" "$MACOS_EXPORT_PATH"

write_export_options "$IOS_EXPORT_OPTIONS"
write_export_options "$MACOS_EXPORT_OPTIONS"

archive_platform "iOS" "$IOS_ARCHIVE_PATH"
upload_archive "$IOS_ARCHIVE_PATH" "$IOS_EXPORT_PATH" "$IOS_EXPORT_OPTIONS"

archive_platform "macOS" "$MACOS_ARCHIVE_PATH"
upload_archive "$MACOS_ARCHIVE_PATH" "$MACOS_EXPORT_PATH" "$MACOS_EXPORT_OPTIONS"

echo "Uploaded iOS and macOS builds to App Store Connect."
