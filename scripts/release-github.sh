#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCAL_RELEASE_ENV="$ROOT_DIR/scripts/release.local.env"

if [[ -f "$LOCAL_RELEASE_ENV" ]]; then
  source "$LOCAL_RELEASE_ENV"
fi

cd "$ROOT_DIR"

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required for publishing releases." >&2
  exit 1
fi

if [[ -n "$(git status --short)" ]]; then
  echo "Working tree is not clean. Commit or stash changes before publishing a release." >&2
  exit 1
fi

MARKETING_VERSION="$(
  python3 - "Notesync.xcodeproj/project.pbxproj" <<'PY'
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

VERSION="${1:-$MARKETING_VERSION}"
TAG="v$VERSION"

export SIGN_FOR_DISTRIBUTION="${SIGN_FOR_DISTRIBUTION:-1}"
export NOTARIZE_DMG="${NOTARIZE_DMG:-1}"
export ALLOW_PROVISIONING_UPDATES="${ALLOW_PROVISIONING_UPDATES:-1}"
export NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  if [[ -n "${ASC_KEY_PATH:-}" || -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" ]]; then
    if [[ -z "${ASC_KEY_PATH:-}" || -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
      echo "ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID must be set together for notarized releases." >&2
      exit 1
    fi
  elif [[ -z "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
    echo "Notarized releases require ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID." >&2
    echo "Alternatively set NOTARYTOOL_KEYCHAIN_PROFILE to use a stored notarytool profile." >&2
    exit 1
  fi
fi

"$ROOT_DIR/scripts/build-macos-dmg.sh" "$VERSION"
DMG_PATH="$ROOT_DIR/dist/Notesync-${VERSION}-macOS.dmg"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Expected DMG not found at $DMG_PATH" >&2
  exit 1
fi

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "Notesync $VERSION"
fi

git push origin "$TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" --clobber
else
  gh release create "$TAG" "$DMG_PATH" \
    --title "Notesync $VERSION" \
    --notes "macOS DMG release for Notesync $VERSION."
fi

echo "Published GitHub release $TAG"
