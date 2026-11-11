#!/bin/sh
set -eu

case "${CI_XCODE_CLOUD:-${CI:-}}" in
    TRUE|true|1) ;;
    *) exit 0 ;;
esac

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ] || exit 0

# Non-TestFlight archives have no App Store signed app path and don't set
# TestFlight's What to Test field.
APP_STORE_SIGNED_APP_PATH=${CI_APP_STORE_SIGNED_APP_PATH:-}
[ -n "$APP_STORE_SIGNED_APP_PATH" ] || exit 0

# CI_ARCHIVE_PATH identifies the Xcode Cloud archive itself. The signed-app
# export path is used only to distinguish TestFlight distribution from other
# archive actions; its directory layout is not an .xcarchive layout.
ARCHIVE_PATH=${CI_ARCHIVE_PATH:-}
[ -n "$ARCHIVE_PATH" ] || {
    echo "release-note gate: Xcode Cloud archive path is missing" >&2
    exit 1
}
[ -d "$ARCHIVE_PATH" ] || {
    echo "release-note gate: Xcode Cloud archive path is not a directory" >&2
    exit 1
}

case "${CI_BUILD_NUMBER:-}" in
    ''|*[!0-9]*)
        echo "release-note gate: Xcode Cloud archive has no numeric CI_BUILD_NUMBER" >&2
        exit 1
        ;;
esac

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
python3 "$SCRIPT_DIR/release_notes.py" render \
    --build-number "$CI_BUILD_NUMBER" \
    --archive-path "$ARCHIVE_PATH" \
    --output "$PROJECT_DIR/TestFlight/WhatToTest.en-US.txt"
