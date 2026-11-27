#!/bin/sh
set -eu

case "${CI_XCODE_CLOUD:-${CI:-}}" in
    TRUE|true|1) ;;
    *) exit 0 ;;
esac

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ] || exit 0

WORKFLOW_NORMALIZED=$(printf '%s' "${CI_WORKFLOW:-}" | tr '[:upper:]' '[:lower:]')
RELEASE_ROUTE=${TUNER_RELEASE_ROUTE:-production}
case "$RELEASE_ROUTE" in
    production) EXPECTED_WORKFLOW="Internal Testflight" ;;
    proof)
        EXPECTED_WORKFLOW=${TUNER_PROOF_WORKFLOW_NAME:-}
        if [ -z "$EXPECTED_WORKFLOW" ]; then
            echo "release-note gate: proof workflow name is not configured" >&2
            exit 1
        fi
        ;;
    *)
        echo "release-note gate: release route is invalid" >&2
        exit 1
        ;;
esac
EXPECTED_WORKFLOW_NORMALIZED=$(printf '%s' "$EXPECTED_WORKFLOW" | tr '[:upper:]' '[:lower:]')
[ "$WORKFLOW_NORMALIZED" = "$EXPECTED_WORKFLOW_NORMALIZED" ] || {
    echo "release-note gate: upload-capable archives are restricted to their configured release workflow" >&2
    exit 1
}

SIGNED_APP_PATH=${CI_APP_STORE_SIGNED_APP_PATH:-}
[ -n "$SIGNED_APP_PATH" ] || {
    echo "release-note gate: Internal Testflight archive has no signed-app export" >&2
    exit 1
}

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
    --require-archive-evidence \
    --output "$PROJECT_DIR/TestFlight/WhatToTest.en-US.txt"
