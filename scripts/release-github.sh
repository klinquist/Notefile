#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
  python3 - "Notefile.xcodeproj/project.pbxproj" <<'PY'
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

if [[ "$NOTARIZE_DMG" == "1" && -z "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
  echo "release-github.sh expects NOTARYTOOL_KEYCHAIN_PROFILE in the environment for notarized releases." >&2
  exit 1
fi

"$ROOT_DIR/scripts/build-macos-dmg.sh" "$VERSION"
DMG_PATH="$ROOT_DIR/dist/Notefile-${VERSION}-macOS.dmg"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Expected DMG not found at $DMG_PATH" >&2
  exit 1
fi

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag -a "$TAG" -m "Notefile $VERSION"
fi

git push origin "$TAG"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG_PATH" --clobber
else
  gh release create "$TAG" "$DMG_PATH" \
    --title "Notefile $VERSION" \
    --notes "macOS DMG release for Notefile $VERSION."
fi

echo "Published GitHub release $TAG"
