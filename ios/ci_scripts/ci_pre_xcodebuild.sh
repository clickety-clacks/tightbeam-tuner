#!/bin/sh
set -eu

case "${CI_XCODE_CLOUD:-${CI:-}}" in
    TRUE|true|1) ;;
    *) exit 0 ;;
esac

# Only numbered archives can become TestFlight builds. Ordinary build, test, and
# analyze actions continue without requiring a release note.
[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0

case "${CI_BUILD_NUMBER:-}" in
    ''|*[!0-9]*)
        echo "release-note gate: Xcode Cloud archive has no numeric CI_BUILD_NUMBER" >&2
        exit 1
        ;;
esac

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
python3 "$SCRIPT_DIR/release_notes.py" validate --build-number "$CI_BUILD_NUMBER"
