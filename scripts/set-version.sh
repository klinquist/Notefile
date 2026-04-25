#!/bin/zsh

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <marketing-version> [build-number]" >&2
  exit 1
fi

MARKETING_VERSION="$1"
BUILD_NUMBER="${2:-}"
PROJECT_FILE="Notesync.xcodeproj/project.pbxproj"

if [[ ! -f "$PROJECT_FILE" ]]; then
  echo "Could not find $PROJECT_FILE" >&2
  exit 1
fi

python3 - "$PROJECT_FILE" "$MARKETING_VERSION" "$BUILD_NUMBER" <<'PY'
import pathlib
import re
import sys

project_file = pathlib.Path(sys.argv[1])
marketing_version = sys.argv[2]
build_number = sys.argv[3]

text = project_file.read_text()

text, marketing_count = re.subn(
    r"MARKETING_VERSION = [^;]+;",
    f"MARKETING_VERSION = {marketing_version};",
    text,
)

if marketing_count == 0:
    raise SystemExit("Did not find MARKETING_VERSION in project.pbxproj")

if build_number:
    text, build_count = re.subn(
        r"CURRENT_PROJECT_VERSION = [^;]+;",
        f"CURRENT_PROJECT_VERSION = {build_number};",
        text,
    )
    if build_count == 0:
        raise SystemExit("Did not find CURRENT_PROJECT_VERSION in project.pbxproj")

project_file.write_text(text)
PY

echo "Updated MARKETING_VERSION to $MARKETING_VERSION"
if [[ -n "$BUILD_NUMBER" ]]; then
  echo "Updated CURRENT_PROJECT_VERSION to $BUILD_NUMBER"
fi
