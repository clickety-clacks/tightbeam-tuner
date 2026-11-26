import copy
import json
import os
import plistlib
import sys
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_hook
import release_notes
import compatibility_matrix


def release(release_id: int, tag: str, published_at: str, asset_id: int) -> dict:
    return {
        "id": release_id,
        "tag_name": tag,
        "published_at": published_at,
        "draft": False,
        "prerelease": False,
        "assets": [{
            "id": asset_id,
            "name": f"tightbeam-{tag.split('+', 1)[0].removeprefix('v')}-darwin-aarch64-{asset_id:07x}.tgz",
            "state": "uploaded",
            "digest": f"sha256:{asset_id:064x}",
            "browser_download_url": f"https://github.com/clickety-clacks/tightbeam/releases/download/{tag}/runtime.tgz",
        }],
    }


def pinned_pair():
    latest = release(4304, "v0.1.16+4304", "2026-11-18T00:48:00Z", 9001)
    previous = release(4082, "v0.1.15+4082", "2026-11-13T18:00:00Z", 9002)
    prerelease = release(4283, "v0.1.16+4283", "2026-11-16T11:20:00Z", 9003)
    prerelease["prerelease"] = True
    return latest, [latest, prerelease, previous], release_hook.resolve_release_pair(
        latest, [latest, prerelease, previous], "darwin-aarch64"
    )


def candidate():
    return {
        "commit": "a" * 40,
        "tree": "b" * 40,
        "scheme": "TightbeamTuner",
        "configuration": "Release",
        "buildNumber": 84,
        "minimumOS": "26.0",
        "deviceFamilies": ["1", "2"],
    }


def baseline():
    return {
        "commit": "477868fbb15f5ce691e31569a7365f5e5c0d25b9",
        "tree": "e274e7ac34b246aa277b425a6b8881653ab521d7",
        "scheme": "TightbeamTuner",
        "configuration": "Release",
        "buildNumber": 83,
        "minimumOS": "26.0",
        "deviceFamilies": ["1", "2"],
    }


def compatibility_report(pair, target=None):
    target = target or candidate()
    baseline_value = baseline()
    producer = {
        "runId": "cloud-run-84",
        "attempt": 1,
        "sourceCommit": target["commit"],
        "sourceTree": target["tree"],
        "buildNumber": target["buildNumber"],
        "scheme": target["scheme"],
        "configuration": target["configuration"],
        "execution": "ios-simulator",
        "runtimeSource": "published-release-asset",
        "networkScope": "loopback-only",
    }
    runs = []
    for item in pair:
        checks = {
            "roster": {
                "status": "passed", "implementation": "production-client",
                "observed": {"sessionIdentity": "matched", "parentRelation": "matched"},
            },
            "initial_message_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "sequenceSummaryDecoded": True, "messagePageDecoded": True,
                    "clientStateMatched": True,
                },
            },
            "read_marker_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {"pageDecoded": True, "clientStateMatched": True},
            },
            "catch_up": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "gatewayRestarted": True,
                    "reconnected": True,
                    "snapshotReadCompleted": True,
                    "clientStateMatched": True,
                },
            },
            "live_subscription": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "eventClass": "session.spawned", "observedByClient": True,
                    "sessionIdentity": "matched", "parentRelation": "matched",
                },
            },
        }
        runs.append({
            "candidate": copy.deepcopy(target),
            "baseline": copy.deepcopy(baseline_value),
            "baselinePhaseSource": copy.deepcopy(baseline_value),
            "candidatePhaseSource": copy.deepcopy(target),
            "release": {
                "id": item.release_id, "tag": item.tag, "assetId": item.asset_id,
                "assetDigest": item.asset_digest,
            },
            "runId": producer["runId"], "attempt": producer["attempt"],
            "simulator": {"deviceType": "iPhone", "runtime": "iOS 27.0"},
            "baselineChecks": copy.deepcopy(checks),
            "checks": checks,
            "upgradeContinuity": {
                "status": "completed",
                "savedConnectionLoaded": True,
                "rosterIdentityPreserved": True,
            },
            "interfaceComparisons": {
                path: {"baselinePassed": True, "candidatePassed": True}
                for path in release_hook.REQUIRED_INTERFACE_PATHS
            },
        })
    return {
        "schemaVersion": 1,
        "candidate": copy.deepcopy(target),
        "baseline": baseline_value,
        "producer": producer,
        "runs": runs,
    }


def note(detail="None."):
    return release_notes.Note(
        build=84,
        items=(
            release_notes.NoteItem("Compatibility", "Chat is separate."),
            release_notes.NoteItem("Breaking changes", detail),
        ),
    )


class ReleaseResolutionTests(unittest.TestCase):
    def test_selects_latest_full_and_strict_predecessor_not_prerelease(self):
        latest, records, expected = pinned_pair()
        pair = release_hook.resolve_release_pair(latest, records, "darwin-aarch64")
        self.assertEqual([item.tag for item in pair], ["v0.1.16+4304", "v0.1.15+4082"])
        self.assertEqual(pair, expected)

    def test_missing_latest_or_predecessor_blocks(self):
        latest, records, _ = pinned_pair()
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "absent or ambiguous"):
            release_hook.resolve_release_pair(latest, records[1:], "darwin-aarch64")
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "fewer than two"):
            release_hook.resolve_release_pair(latest, [latest], "darwin-aarch64")

    def test_prerelease_latest_blocks(self):
        latest, _, _ = pinned_pair()
        latest["prerelease"] = True
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "not an eligible"):
            release_hook.resolve_release_pair(latest, [latest], "darwin-aarch64")

    def test_ambiguous_predecessor_and_asset_block(self):
        latest, records, _ = pinned_pair()
        tied = copy.deepcopy(records[-1])
        tied["id"] = 4083
        tied["tag_name"] = "v0.1.15+4083"
        tied["assets"][0]["id"] = 9004
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "ambiguous"):
            release_hook.resolve_release_pair(latest, records + [tied], "darwin-aarch64")
        bad_asset = copy.deepcopy(records)
        bad_asset[-1]["assets"][0]["digest"] = None
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "no SHA-256 digest"):
            release_hook.resolve_release_pair(latest, bad_asset, "darwin-aarch64")

    def test_asset_ambiguity_and_pair_reresolution_block(self):
        latest, records, pair = pinned_pair()
        duplicate = copy.deepcopy(latest["assets"][0])
        duplicate["id"] += 1
        latest["assets"].append(duplicate)
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "ambiguous"):
            release_hook.resolve_release_pair(latest, records, "darwin-aarch64")
        latest, records, pair = pinned_pair()
        changed = list(pair)
        changed[0] = release_hook.PublishedRelease(
            pair[0].release_id, pair[0].tag, pair[0].published_at,
            pair[0].asset_id + 1, pair[0].asset_name, pair[0].asset_digest, pair[0].download_url,
        )
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "changed while"):
            release_hook.same_release_pair(pair, tuple(changed))

    def test_release_asset_uses_published_filename_version_and_short_revision(self):
        latest, records, _ = pinned_pair()
        latest["assets"][0]["name"] = "tightbeam-v0.1.16+4304-darwin-aarch64.tgz"
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "ambiguous"):
            release_hook.resolve_release_pair(latest, records, "darwin-aarch64")


class CompatibilityReportTests(unittest.TestCase):
    def setUp(self):
        _, _, self.pair = pinned_pair()
        self.report = compatibility_report(self.pair)

    def test_report_binds_both_runs_to_candidate_and_published_assets(self):
        runs = release_hook.validate_compatibility_runs(
            self.report, candidate(), self.pair, baseline=baseline(),
            expected_ci_run_id="cloud-run-84"
        )
        self.assertEqual(len(runs), 2)

    def test_attempt_is_fixed_to_one_for_each_unique_cloud_run(self):
        self.assertEqual(self.report["producer"]["attempt"], 1)
        for mutate in (
            lambda value: value["producer"].update(attempt=2),
            lambda value: value["producer"].update(attempt=True),
            lambda value: value["runs"][0].update(attempt=2),
            lambda value: value["runs"][0].update(attempt=True),
        ):
            changed = copy.deepcopy(self.report)
            mutate(changed)
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "attempt"):
                release_hook.validate_compatibility_runs(
                    changed, candidate(), self.pair, baseline=baseline(),
                    expected_ci_run_id="cloud-run-84",
                )

    def test_missing_or_failed_client_checks_block(self):
        for mutation in (
            lambda report: report["runs"][0]["checks"].pop("catch_up"),
            lambda report: report["runs"][0]["checks"]["live_subscription"].update(status="skipped"),
            lambda report: report["runs"][1]["checks"]["roster"].update(observed=None),
        ):
            changed = copy.deepcopy(self.report)
            mutation(changed)
            with self.subTest(changed=changed["runs"][0]["checks"]):
                with self.assertRaises(release_hook.ReleaseHookError):
                    release_hook.validate_compatibility_runs(
                        changed, candidate(), self.pair, baseline=baseline()
                    )

    def test_mocked_path_missing_identity_and_unobserved_live_change_block(self):
        cases = [
            lambda run: run["checks"]["roster"].update(implementation="mock"),
            lambda run: run["checks"]["roster"].update(observed={"sessionIdentity": "missing", "parentRelation": "matched"}),
            lambda run: run["checks"]["live_subscription"].update(observed={}),
        ]
        for mutate in cases:
            changed = copy.deepcopy(self.report)
            mutate(changed["runs"][0])
            with self.assertRaises(release_hook.ReleaseHookError):
                release_hook.validate_compatibility_runs(
                    changed, candidate(), self.pair, baseline=baseline()
                )

    def test_claimed_pass_requires_expected_client_state_for_each_path(self):
        mutations = (
            lambda run: run["checks"]["initial_message_sync"]["observed"].update(clientStateMatched=False),
            lambda run: run["checks"]["read_marker_sync"]["observed"].update(clientStateMatched=False),
            lambda run: run["checks"]["catch_up"]["observed"].update(clientStateMatched=False),
            lambda run: run["checks"]["live_subscription"]["observed"].update(sessionIdentity="missing"),
            lambda run: run["baselineChecks"]["initial_message_sync"]["observed"].update(clientStateMatched=False),
        )
        for mutate in mutations:
            changed = copy.deepcopy(self.report)
            mutate(changed["runs"][0])
            with self.subTest(run=changed["runs"][0]):
                with self.assertRaises(release_hook.ReleaseHookError):
                    release_hook.validate_compatibility_runs(
                        changed, candidate(), self.pair, baseline=baseline()
                    )

    def test_candidate_release_asset_or_cloud_run_mismatch_blocks(self):
        changed = copy.deepcopy(self.report)
        changed["runs"][0]["candidate"]["commit"] = "c" * 40
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "exact numbered candidate"):
            release_hook.validate_compatibility_runs(changed, candidate(), self.pair, baseline=baseline())
        changed = copy.deepcopy(self.report)
        changed["runs"][0]["release"]["assetDigest"] = "0" * 64
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "digest"):
            release_hook.validate_compatibility_runs(changed, candidate(), self.pair, baseline=baseline())
        changed = copy.deepcopy(self.report)
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "this Xcode Cloud run"):
            release_hook.validate_compatibility_runs(
                changed, candidate(), self.pair, baseline=baseline(), expected_ci_run_id="other-run"
            )

    def test_generated_compatibility_line_rejects_conflicting_or_unverified_claim(self):
        expected = release_hook.compatibility_line(self.pair)
        self.assertEqual(
            release_hook.author_compatibility_line(
                "Tightbeam compatibility is generated from release checks. Chat stays separate.", expected
            ),
            expected + "\nChat stays separate.",
        )
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "disagrees"):
            release_hook.author_compatibility_line("Compatible with Tightbeam: v0.0.1", expected)
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "unsupported"):
            release_hook.author_compatibility_line("Also works with Tightbeam v0.1.0", expected)

    def test_archive_report_requires_completed_deterministic_detector_results_and_note_digest(self):
        note_data = {"build": 84, "items": [{"title": "Compatibility", "detail": "x"}]}
        pair_line = release_hook.compatibility_line(self.pair)
        note_data = {
            "version": "1.0", "build": 84, "date": "November 26, 2026",
            "items": [
                {"symbol": "checkmark", "title": "Compatibility", "detail": pair_line + "\nChat v0.1.104."},
                {"symbol": "exclamationmark.triangle", "title": "Breaking changes", "detail": "None."},
            ],
        }
        report = {
            "schemaVersion": 1,
            "status": "completed",
            "candidate": candidate(),
            "baseline": baseline(),
            "producer": {
                "runId": "cloud-run-84", "attempt": 1,
                "sourceCommit": candidate()["commit"], "sourceTree": candidate()["tree"],
                "buildNumber": candidate()["buildNumber"], "scheme": candidate()["scheme"],
                "configuration": candidate()["configuration"],
            },
            "releases": [
                {"id": item.release_id, "tag": item.tag, "assetId": item.asset_id,
                 "assetName": item.asset_name,
                 "assetDigest": item.asset_digest}
                for item in self.pair
            ],
            "currentNoteSha256": release_hook.note_digest(note_data),
            "breakingChangesSha256": release_hook.breaking_section_digest("None."),
            "detectors": {"status": "completed", "findings": [], "findingsSha256": release_hook.findings_digest([])},
            "compatibility": self.report,
        }
        self.assertEqual(len(release_hook.validate_archive_report(
            report, candidate=candidate(), baseline=baseline(), pair=self.pair, note_data=note_data,
            expected_ci_run_id="cloud-run-84",
        )), 2)
        for mutate in (
            lambda value: value["producer"].update(attempt=2),
            lambda value: value["detectors"].update(status="skipped"),
            lambda value: value["detectors"].update(findingsSha256="0" * 64),
            lambda value: value.update(currentNoteSha256="0" * 64),
        ):
            changed = copy.deepcopy(report)
            mutate(changed)
            with self.assertRaises(release_hook.ReleaseHookError):
                release_hook.validate_archive_report(
                    changed, candidate=candidate(), baseline=baseline(), pair=self.pair, note_data=note_data,
                    expected_ci_run_id="cloud-run-84",
                )


class CompatibilityMatrixWiringTests(unittest.TestCase):
    def test_candidate_attempt_is_fixed_even_if_an_attempt_environment_value_exists(self):
        environment = {
            "CI_COMMIT": "a" * 40,
            "CI_XCODE_SCHEME": "TightbeamTuner",
            "CI_BUILD_ID": "cloud-run-84",
            "CI_BUILD_ATTEMPT": "9",
            "TUNER_RELEASE_CONFIGURATION": "Release",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(
                compatibility_matrix, "_current_source", return_value=("a" * 40, "b" * 40)
            ):
                result = compatibility_matrix._prepare_candidate(
                    Path("."), {"scheme": "TightbeamTuner", "configuration": "Release"}, 84
                )
        self.assertEqual(result["attempt"], 1)

    def test_baseline_phase_identity_is_the_measured_release_identity(self):
        source = {
            "sourceCommit": baseline()["commit"],
            "sourceTree": baseline()["tree"],
            "scheme": baseline()["scheme"],
            "configuration": baseline()["configuration"],
            "buildNumber": baseline()["buildNumber"],
        }
        effective = {"minimumOS": "26.0", "deviceFamilies": ["1", "2"]}
        result = compatibility_matrix._baseline_phase_identity(source, effective)
        self.assertEqual(result, {
            "commit": baseline()["commit"],
            "tree": baseline()["tree"],
            "scheme": baseline()["scheme"],
            "configuration": baseline()["configuration"],
            "buildNumber": baseline()["buildNumber"],
            **effective,
        })
        self.assertNotIn("runId", result)
        self.assertNotIn("attempt", result)

    def test_xctest_inputs_are_available_in_both_supported_environment_forms(self):
        environment = {}
        compatibility_matrix._add_xctest_environment(
            environment, {"TUNER_COMPAT_PHASE": "candidate"}
        )
        self.assertEqual(environment["TUNER_COMPAT_PHASE"], "candidate")
        self.assertEqual(environment["TEST_RUNNER_TUNER_COMPAT_PHASE"], "candidate")

    def test_phase_results_combine_only_when_bound_to_the_measured_baseline(self):
        _, _, pair = pinned_pair()
        target = {
            **candidate(),
            "minimumOS": "26.0",
            "deviceFamilies": ["1", "2"],
            "runId": "cloud-run-84",
            "attempt": 1,
        }
        baseline_target = {
            **baseline(), "minimumOS": "26.0", "deviceFamilies": ["1", "2"]
        }
        observed_checks = {
            "roster": {
                "status": "passed", "implementation": "production-client",
                "observed": {"sessionIdentity": "matched", "parentRelation": "matched"},
            },
            "initial_message_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "sequenceSummaryDecoded": True, "messagePageDecoded": True,
                    "clientStateMatched": True,
                },
            },
            "read_marker_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {"pageDecoded": True, "clientStateMatched": True},
            },
            "catch_up": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "gatewayRestarted": True, "reconnected": True,
                    "snapshotReadCompleted": True, "clientStateMatched": True,
                },
            },
            "live_subscription": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "eventClass": "session.spawned", "observedByClient": True,
                    "sessionIdentity": "matched", "parentRelation": "matched",
                },
            },
        }
        phases = []
        for release in pair:
            for phase, source in (("baseline", baseline_target), ("candidate", target)):
                result = {
                    "releaseId": release.release_id,
                    "phase": phase,
                    "phaseSource": source,
                    "candidate": target,
                    "runId": "cloud-run-84",
                    "attempt": 1,
                    "simulator": {"deviceType": "iPhone", "runtime": "iOS 27.0"},
                    "checks": copy.deepcopy(observed_checks),
                }
                if phase == "candidate":
                    result["upgradeContinuity"] = {
                        "status": "completed",
                        "savedConnectionLoaded": True,
                        "rosterIdentityPreserved": True,
                    }
                phases.append(result)
        combined = compatibility_matrix._combine_results(phases, target, baseline_target, pair)
        self.assertEqual([run["release"]["tag"] for run in combined], [
            "v0.1.16+4304", "v0.1.15+4082"
        ])
        self.assertTrue(all(
            run["interfaceComparisons"]["roster"]["candidatePassed"] for run in combined
        ))
        phases[0]["phaseSource"] = {**baseline_target, "runId": "baseline-distribution"}
        with self.assertRaisesRegex(compatibility_matrix.MatrixError, "exact source inputs"):
            compatibility_matrix._combine_results(phases, target, baseline_target, pair)


class DetectorAndNotesTests(unittest.TestCase):
    def setUp(self):
        _, _, self.pair = pinned_pair()
        self.runs = compatibility_report(self.pair)["runs"]
        self.baseline = baseline()
        self.candidate_settings = candidate()

    def test_device_os_and_family_breaks_are_reported(self):
        changed = copy.deepcopy(self.candidate_settings)
        changed["minimumOS"] = "27.0"
        changed["deviceFamilies"] = ["1"]
        findings = release_hook.detect_breaking_changes(self.baseline, changed, self.runs)
        self.assertEqual(
            [item["detectorId"] for item in findings],
            ["device-support.family-removed", "device-support.minimum-os"],
        )

    def test_equivalent_versions_and_preserved_upgrade_have_no_findings(self):
        self.assertEqual(release_hook.detect_breaking_changes(
            self.baseline, self.candidate_settings, self.runs
        ), [])

    def test_missing_and_failed_detector_inputs_block(self):
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "device-support"):
            release_hook.detect_breaking_changes({}, self.candidate_settings, self.runs)
        changed = copy.deepcopy(self.candidate_settings)
        changed_runs = copy.deepcopy(self.runs)
        changed_runs[0]["upgradeContinuity"]["savedConnectionLoaded"] = "unknown"
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "savedConnectionLoaded"):
            release_hook.detect_breaking_changes(self.baseline, changed, changed_runs)
        broken_runs = copy.deepcopy(self.runs)
        broken_runs[0]["interfaceComparisons"].pop("live_subscription")
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "missing a required baseline comparison"):
            release_hook.detect_breaking_changes(self.baseline, self.candidate_settings, broken_runs)

    def test_upgrade_loss_and_tightbeam_regression_are_findings(self):
        changed = copy.deepcopy(self.candidate_settings)
        changed_runs = copy.deepcopy(self.runs)
        changed_runs[0]["upgradeContinuity"]["rosterIdentityPreserved"] = False
        changed_runs[0]["interfaceComparisons"]["live_subscription"] = {
            "baselinePassed": True, "candidatePassed": False,
        }
        findings = release_hook.detect_breaking_changes(self.baseline, changed, changed_runs)
        self.assertEqual({item["detectorId"] for item in findings}, {
            "upgrade-continuity.roster-identity-lost", "tightbeam-interface.regression",
        })

    def test_breaking_section_requires_substance_for_findings(self):
        findings = [{"detectorId": "device-support.minimum-os", "path": "devices", "before": "26", "after": "27"}]
        for detail in ("", "None.", "No breaking changes.", "TBD", "!!!"):
            with self.subTest(detail=detail), self.assertRaises(release_hook.ReleaseHookError):
                release_hook.validate_breaking_section(note(detail), findings)
        digest = release_hook.validate_breaking_section(
            note("Devices on iOS 26 cannot install this update. Update to iOS 27 or stay on the prior build."),
            findings,
        )
        self.assertEqual(len(digest), 64)
        self.assertEqual(release_hook.validate_breaking_section(note("None."), []),
                         release_hook.breaking_section_digest("None."))

    def test_baseline_hint_must_match_last_distributed_build(self):
        expected = {"buildNumber": 83, "sourceCommit": "b" * 40, "scheme": "TightbeamTuner", "configuration": "Release"}
        self.assertEqual(release_hook.baseline_reference(expected, expected), expected)
        changed = dict(expected, buildNumber=82)
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "disagrees"):
            release_hook.baseline_reference(changed, expected)
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "incomplete"):
            release_hook.baseline_reference({"buildNumber": 83}, expected)

    def test_history_requires_exact_record_or_explicit_pre_hook_unverified_note(self):
        history = (release_notes.Note(
            83,
            (
                release_notes.NoteItem("Compatibility", "Tightbeam compatibility was not verified for this build."),
                release_notes.NoteItem("Breaking changes", "None."),
            ),
        ),)
        release_hook.validate_history_claims(history)
        with self.assertRaisesRegex(release_hook.ReleaseHookError, "not verified"):
            release_hook.validate_history_claims((release_notes.Note(
                83,
                (
                    release_notes.NoteItem("Compatibility", "Compatible with Tightbeam: v0.1.16+4304"),
                    release_notes.NoteItem("Breaking changes", "None."),
                ),
            ),))


class SignedArchiveTests(unittest.TestCase):
    def setUp(self):
        _, _, self.pair = pinned_pair()
        self.repo = Path(__file__).resolve().parents[2]
        self.commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.repo, text=True).strip()
        self.tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=self.repo, text=True).strip()
        self.target = {
            "commit": self.commit,
            "tree": self.tree,
            "scheme": "TightbeamTuner",
            "configuration": "Release",
            "buildNumber": 84,
            "minimumOS": "26.0",
            "deviceFamilies": ["1", "2"],
        }
        self.baseline = baseline()
        self.note_data = {
            "version": "1.0", "build": 84, "date": "November 26, 2026",
            "items": [
                {
                    "symbol": "checkmark.seal", "title": "Compatibility",
                    "detail": release_hook.compatibility_line(self.pair) + "\nChat v0.1.104.",
                },
                {"symbol": "exclamationmark.triangle", "title": "Breaking changes", "detail": "None."},
            ],
        }
        matrix = compatibility_report(self.pair, self.target)
        findings = release_hook.detect_breaking_changes(self.baseline, self.target, matrix["runs"])
        self.report = {
            "schemaVersion": 1,
            "status": "completed",
            "candidate": self.target,
            "baseline": self.baseline,
            "producer": matrix["producer"],
            "releases": [
                {
                    "id": item.release_id, "tag": item.tag, "assetId": item.asset_id,
                    "assetName": item.asset_name, "assetDigest": item.asset_digest,
                }
                for item in self.pair
            ],
            "compatibility": matrix,
            "detectors": {
                "status": "completed", "findings": findings,
                "findingsSha256": release_hook.findings_digest(findings),
            },
            "breakingChangesSha256": release_hook.breaking_section_digest("None."),
            "currentNoteSha256": release_hook.note_digest(self.note_data),
        }
        self.history_data = json.loads(
            (self.repo / "ios" / "TightbeamTuner" / "ReleaseNotesHistory.json").read_text(encoding="utf-8")
        )
        self.info = {
            "CFBundleIdentifier": "co.clicketyclacks.tightbeam-tuner",
            "CFBundleVersion": "84",
            "MinimumOSVersion": "26.0",
            "UIDeviceFamily": [1, 2],
        }

    def _signed_export(self, root: Path) -> Path:
        export = root / "export"
        export.mkdir()
        ipa = export / "Tuner.ipa"
        app_root = "Payload/TightbeamTuner.app"
        with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(f"{app_root}/Info.plist", plistlib.dumps(self.info))
            archive.writestr(f"{app_root}/CurrentBuildReleaseNote.json", json.dumps(self.note_data))
            archive.writestr(f"{app_root}/ReleaseNotesHistory.json", json.dumps(self.history_data))
            archive.writestr(f"{app_root}/ReleaseCompatibilityReport.json", json.dumps(self.report))
        return export

    def test_signed_export_report_note_and_history_are_verified_and_rendered(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            signed = self._signed_export(root)
            output = root / "WhatToTest.txt"
            env = os.environ.copy()
            env.update({
                "CI_COMMIT": self.commit,
                "CI_BUILD_ID": "cloud-run-84",
                "CI_BUILD_NUMBER": "84",
                "CI_BUILD_ATTEMPT": "2",
                "CI_XCODE_SCHEME": "TightbeamTuner",
                "CI_PRIMARY_REPOSITORY_PATH": str(self.repo),
            })
            result = subprocess.run([
                sys.executable, str(Path(__file__).with_name("release_notes.py")), "render",
                "--build-number", "84", "--signed-app-path", str(signed),
                "--require-archive-evidence", "--output", str(output),
            ], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            rendered = output.read_text(encoding="utf-8")
            self.assertIn(release_hook.compatibility_line(self.pair), rendered)
            self.assertIn("Breaking changes\nNone.", rendered)

    def test_signed_export_blocks_report_mismatch_before_rendering(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.report["currentNoteSha256"] = "0" * 64
            signed = self._signed_export(root)
            output = root / "WhatToTest.txt"
            env = os.environ.copy()
            env.update({
                "CI_COMMIT": self.commit,
                "CI_BUILD_ID": "cloud-run-84",
                "CI_BUILD_NUMBER": "84",
                "CI_BUILD_ATTEMPT": "2",
                "CI_XCODE_SCHEME": "TightbeamTuner",
                "CI_PRIMARY_REPOSITORY_PATH": str(self.repo),
            })
            result = subprocess.run([
                sys.executable, str(Path(__file__).with_name("release_notes.py")), "render",
                "--build-number", "84", "--signed-app-path", str(signed),
                "--require-archive-evidence", "--output", str(output),
            ], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("note digest", result.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
