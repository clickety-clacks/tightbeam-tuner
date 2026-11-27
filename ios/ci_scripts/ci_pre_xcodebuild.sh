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
PROJECT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
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
if [ "$WORKFLOW_NORMALIZED" != "$EXPECTED_WORKFLOW_NORMALIZED" ]; then
    echo "release-note gate: upload-capable archives are restricted to their configured release workflow" >&2
    exit 1
fi
# Xcode Cloud environment values are available to this script, but the project
# target's checked-in setting takes precedence when Xcode resolves the archive.
# Materialize the selected, validated route identity before Xcode reads the project.
python3 "$SCRIPT_DIR/configure_bundle_identifier.py" \
    "$PROJECT_DIR/TightbeamTuner.xcodeproj/project.pbxproj"
python3 "$SCRIPT_DIR/compatibility_matrix.py"
python3 "$SCRIPT_DIR/release_notes.py" validate --build-number "$CI_BUILD_NUMBER"
