#!/bin/sh
set -eu

case "${CI_XCODE_CLOUD:-${CI:-}}" in
    TRUE|true|1) ;;
    *) exit 0 ;;
esac

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ] || exit 0

# Non-TestFlight archives have no App Store signed export and don't set
# TestFlight's What to Test field.
SIGNED_APP_PATH=${CI_APP_STORE_SIGNED_APP_PATH:-}
[ -n "$SIGNED_APP_PATH" ] || exit 0

# The signed export is a directory containing the IPA that TestFlight receives.
[ -d "$SIGNED_APP_PATH" ] || {
    echo "release-note gate: Xcode Cloud signed-app export path is not a directory" >&2
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
    --signed-app-path "$SIGNED_APP_PATH" \
    --output "$PROJECT_DIR/TestFlight/WhatToTest.en-US.txt"
