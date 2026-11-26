import copy
import io
import json
import os
import plistlib
import sys
import subprocess
import tempfile
import tarfile
import unittest
import urllib.error
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
                "observed": {
                    "sessionIdentity": "matched", "parentRelation": "matched",
                    "sessionCount": 2,
                },
            },
            "initial_message_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "sequenceSummaryRoute": "not-supported", "sequenceSummaryDecoded": False,
                    "sequenceSummaryValid": True, "messagePageDecoded": True,
                    "clientStateMatched": True, "turnIncludesHuman": True,
                    "messageCount": 3, "latestReplySequence": 8,
                },
            },
            "read_marker_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "pageDecoded": True, "clientStateMatched": True,
                    "markerCount": 1, "replySessionMarkerPresent": True,
                },
            },
            "catch_up": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "gatewayRestarted": True,
                    "reconnected": True,
                    "subscriptionReadyCount": 2,
                    "snapshotCompletedCount": 2,
                    "snapshotReadCompleted": True,
                    "clientStateMatched": True,
                    "changeEventClass": "message.created",
                    "correlatedReply": True, "changedSessionMatched": True,
                    "previousSequence": 8, "changedSequence": 9,
                    "previousMarker": 7, "changedMarker": 8,
                },
            },
            "live_subscription": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "eventClass": "message.created", "observedByClient": True,
                    "sessionIdentity": "matched", "stateMatched": True,
                    "correlatedReply": True, "previousReplySequence": 7,
                    "replySequence": 8, "previousMarker": 6, "marker": 7,
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


class FakeHTTPResponse(io.BytesIO):
    def __init__(self, payload: dict, *, link: str = ""):
        super().__init__(json.dumps(payload).encode("utf-8"))
        self.status = 200
        self.headers = {"Link": link}

    def __enter__(self):
        return self

    def __exit__(self, _type, _value, _traceback):
        self.close()


class ReleaseResolutionTests(unittest.TestCase):
    def test_public_release_api_uses_scoped_actions_token_without_logging_it(self):
        latest, _, _ = pinned_pair()
        response = FakeHTTPResponse(latest)
        with mock.patch.dict(os.environ, {"GITHUB_TOKEN": "ephemeral-read-only-token"}):
            with mock.patch.object(release_hook.urllib.request, "urlopen", return_value=response) as urlopen:
                payload, _ = release_hook._read_github_json("https://api.github.com/repos/example/releases/latest")
        self.assertEqual(payload, latest)
        request = urlopen.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer ephemeral-read-only-token")

    def test_public_release_api_reports_http_status_without_response_body(self):
        error = urllib.error.HTTPError(
            "https://api.github.com/repos/example/releases/latest",
            403,
            "rate limited",
            {},
            io.BytesIO(b"body must not be copied into the error"),
        )
        with mock.patch.object(release_hook.urllib.request, "urlopen", side_effect=error):
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "HTTP 403") as raised:
                release_hook._read_github_json("https://api.github.com/repos/example/releases/latest")
        self.assertNotIn("body must not be copied", str(raised.exception))

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

    def test_runtime_extractor_ignores_directory_named_tightbeam(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "runtime.tgz"
            with tarfile.open(package, "w:gz") as archive:
                directory = tarfile.TarInfo("tightbeam")
                directory.type = tarfile.DIRTYPE
                directory.mode = 0o755
                archive.addfile(directory)
                for name, contents in (
                    ("tightbeam/bin/tightbeam", b"cli"),
                    ("tightbeam/bin/tightbeam-gateway", b"gateway"),
                ):
                    info = tarfile.TarInfo(name)
                    info.mode = 0o755
                    info.size = len(contents)
                    archive.addfile(info, io.BytesIO(contents))
            gateway = release_hook.extract_release_package(package, root / "unpacked")
            self.assertEqual(gateway.relative_to(root / "unpacked").as_posix(), "tightbeam/bin/tightbeam-gateway")
            self.assertTrue(release_hook.find_runtime_executable(root / "unpacked", "tightbeam").is_file())


class ReleaseReviewStatusTests(unittest.TestCase):
    commit = "a" * 40
    digest = "b" * 64

    def _status(self, state="success", description=None, timestamp="2026-11-26T08:00:00Z"):
        return {
            "context": release_hook.RELEASE_REVIEW_CONTEXT,
            "state": state,
            "description": description if description is not None else f"sha256:{self.digest}",
            "updated_at": timestamp,
        }

    def test_requires_latest_matching_status_and_follows_all_status_pages(self):
        first = FakeHTTPResponse(
            {"sha": self.commit, "statuses": [self._status(timestamp="2026-11-25T08:00:00Z")]},
            link=(f'<https://api.github.com/repos/{release_hook.TUNER_REPOSITORY}/commits/'
                  f'{self.commit}/status?per_page=100&page=2>; rel="next"'),
        )
        second = FakeHTTPResponse({"sha": self.commit, "statuses": [self._status(timestamp="2026-11-26T08:00:00Z")]})
        with mock.patch.object(release_hook.urllib.request, "urlopen", side_effect=[first, second]) as opened:
            result = release_hook.latest_public_review_status(self.commit, self.digest)
        self.assertEqual(result["description"], f"sha256:{self.digest}")
        self.assertEqual(opened.call_count, 2)

    def test_newer_rejection_and_digest_mismatch_block(self):
        rejection = self._status("failure", timestamp="2026-11-26T08:01:00Z")
        older_success = self._status(timestamp="2026-11-26T08:00:00Z")
        with mock.patch.object(
            release_hook.urllib.request, "urlopen",
            side_effect=[FakeHTTPResponse({"sha": self.commit, "statuses": [older_success, rejection]})],
        ), self.assertRaisesRegex(release_hook.ReleaseHookError, "not successful"):
            release_hook.latest_public_review_status(self.commit, self.digest)

        stale = self._status(description=f"sha256:{'c' * 64}")
        with mock.patch.object(
            release_hook.urllib.request, "urlopen",
            return_value=FakeHTTPResponse({"sha": self.commit, "statuses": [stale]}),
        ), self.assertRaisesRegex(release_hook.ReleaseHookError, "does not match"):
            release_hook.latest_public_review_status(self.commit, self.digest)

    def test_absent_or_unreadable_confirmation_blocks(self):
        with mock.patch.object(
            release_hook.urllib.request, "urlopen",
            return_value=FakeHTTPResponse({"sha": self.commit, "statuses": []}),
        ), self.assertRaisesRegex(release_hook.ReleaseHookError, "missing"):
            release_hook.latest_public_review_status(self.commit, self.digest)

        wrong_host_link = FakeHTTPResponse(
            {"sha": self.commit, "statuses": []},
            link='<https://example.com/status?page=2>; rel="next"',
        )
        with mock.patch.object(
            release_hook.urllib.request, "urlopen", return_value=wrong_host_link,
        ), self.assertRaisesRegex(release_hook.ReleaseHookError, "left the expected"):
            release_hook.latest_public_review_status(self.commit, self.digest)


class ReleaseTagIdentityTests(unittest.TestCase):
    def test_release_ref_must_point_to_the_candidate_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@example.invalid"], check=True)
            (repo / "file.txt").write_text("candidate\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "file.txt"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-qm", "candidate"], check=True)
            commit = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
            subprocess.run(["git", "-C", str(repo), "tag", "tuner-ios-build-84", commit], check=True)
            release_hook.validate_release_tag_identity(
                repo, commit, "refs/tags/tuner-ios-build-84", "tuner-ios-build-84", 84
            )
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "dedicated tag"):
                release_hook.validate_release_tag_identity(
                    repo, commit, "refs/heads/main", "tuner-ios-build-84", 84
                )
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "dedicated tag"):
                release_hook.validate_release_tag_identity(
                    repo, commit, "refs/tags/anything", "anything", 84
                )
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "dedicated tag"):
                release_hook.validate_release_tag_identity(
                    repo, commit, "refs/tags/tuner-ios-build-84", "tuner-ios-build-84", 85
                )
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "does not identify"):
                release_hook.validate_release_tag_identity(
                    repo, "0" * 40, "refs/tags/tuner-ios-build-84", "tuner-ios-build-84", 84
                )


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

    def test_empty_seeded_paths_and_roster_relations_cannot_claim_pass(self):
        mutations = (
            lambda run: run["checks"]["roster"]["observed"].update(parentRelation="mismatched"),
            lambda run: run["checks"]["initial_message_sync"]["observed"].update(messageCount=0),
            lambda run: run["checks"]["read_marker_sync"]["observed"].update(markerCount=0),
            lambda run: run["checks"]["catch_up"]["observed"].update(changedMarker=2),
            lambda run: run["checks"]["live_subscription"]["observed"].update(eventClass="session.spawned"),
        )
        for mutate in mutations:
            changed = copy.deepcopy(self.report)
            mutate(changed["runs"][0])
            with self.subTest(run=changed["runs"][0]):
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

    def test_claimed_replies_pass_requires_correlated_advanced_positions(self):
        mutations = (
            lambda run: run["checks"]["initial_message_sync"]["observed"].update(turnIncludesHuman=False),
            lambda run: run["checks"]["live_subscription"]["observed"].update(correlatedReply=False),
            lambda run: run["checks"]["live_subscription"]["observed"].update(replySequence=7),
            lambda run: run["checks"]["catch_up"]["observed"].update(correlatedReply=False),
            lambda run: run["checks"]["catch_up"]["observed"].update(changedSequence=8),
            lambda run: run["checks"]["catch_up"]["observed"].update(snapshotCompletedCount=1),
        )
        for mutate in mutations:
            changed = copy.deepcopy(self.report)
            mutate(changed["runs"][0])
            with self.subTest(changed=changed["runs"][0]["checks"]):
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
        for unsupported in (
            "Also tested with Tightbeam release 0.1.14",
            "Also supports Tightbeam build 4283",
            "Also works with Tightbeam: 0.1.14.",
            "Also supports Tightbeam versions 0.1.14.",
            "Works with older Tightbeam releases.",
        ):
            with self.subTest(unsupported=unsupported), self.assertRaisesRegex(
                release_hook.ReleaseHookError, "unsupported"
            ):
                release_hook.author_compatibility_line(unsupported, expected)

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
        history_data = []
        candidate_object = release_hook.candidate_object(
            candidate(), baseline(), self.pair, [], note_data, history_data
        )
        candidate_digest = release_hook.candidate_object_digest(candidate_object)
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
            "candidateObject": candidate_object,
            "candidateObjectSha256": candidate_digest,
            "preArchiveGate": {
                "status": "passed", "sourceCommit": candidate()["commit"],
                "candidateDigest": candidate_digest,
                "context": release_hook.RELEASE_REVIEW_CONTEXT, "state": "success",
                "description": f"sha256:{candidate_digest}",
            },
        }
        self.assertEqual(len(release_hook.validate_archive_report(
            report, candidate=candidate(), baseline=baseline(), pair=self.pair, note_data=note_data,
            history_data=history_data,
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
                    history_data=history_data,
                    expected_ci_run_id="cloud-run-84",
                )


class CompatibilityInstrumentationTests(unittest.TestCase):
    def test_replied_observer_is_added_to_baseline_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_path = Path(temporary) / "ios" / "TightbeamTuner" / "Replied.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "struct RepliedFeed {\n"
                "    private(set) var state = RepliedState()\n"
                "    private(set) var shownSessionKey: String?\n"
                "    func run() {\n"
                "                            ready = true\n"
                "                            snapshotTask = Task {\n"
                "                                await self.loadSnapshot(\n"
                "                                    mode: mode\n"
                "                                )\n"
                "                            }\n"
                "                        default:\n"
                "                            apply(frame, userID: user)\n"
                "                            if frame.changesRoster { onRosterEvent(frame) }\n"
                "                }\n"
                "    }\n"
                "}\n",
                encoding="utf-8",
            )
            worktree = Path(temporary)
            compatibility_matrix._inject_replied_observation(worktree)
            first = source_path.read_text(encoding="utf-8")
            compatibility_matrix._inject_replied_observation(worktree)
            second = source_path.read_text(encoding="utf-8")
            self.assertEqual(first, second)
            self.assertIn("messageCreatedSequenceBySession", second)
            self.assertIn("readMarkerEventBySession", second)
            self.assertIn('case .message(let message) where message.role == "assistant"', second)
            self.assertEqual(second.count("subscriptionReadyCount += 1"), 1)
            self.assertEqual(second.count("self.snapshotCompletedCount += 1"), 1)

    def test_baseline_observer_rejects_partial_counter_instrumentation(self):
        with tempfile.TemporaryDirectory() as temporary:
            source_path = Path(temporary) / "ios" / "TightbeamTuner" / "Replied.swift"
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "    private(set) var state = RepliedState()\n"
                "    private(set) var shownSessionKey: String?\n"
                "    private(set) var subscriptionReadyCount = 0\n"
                "                        ready = true\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                compatibility_matrix.MatrixError, "partial compatibility observer"
            ):
                compatibility_matrix._inject_replied_observation(Path(temporary))


class CompatibilityMatrixWiringTests(unittest.TestCase):
    def test_fixture_child_environment_uses_scratch_home_and_drops_host_credentials(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch_home = Path(temporary) / "home"
            with mock.patch.dict(
                os.environ,
                {
                    "HOME": "/Users/private",
                    "PATH": "/usr/bin:/bin",
                    "OPENAI_API_KEY": "must-not-be-inherited",
                    "TIGHTBEAM_TOKEN": "must-not-be-inherited",
                    "TIGHTBEAM_BASE_DIR": "/live/tightbeam",
                },
                clear=True,
            ):
                child = compatibility_matrix._isolated_environment(scratch_home)
            self.assertEqual(child["HOME"], str(scratch_home))
            self.assertEqual(child["TMPDIR"], str(scratch_home / "tmp"))
            self.assertNotIn("OPENAI_API_KEY", child)
            self.assertNotIn("TIGHTBEAM_TOKEN", child)
            self.assertNotIn("TIGHTBEAM_BASE_DIR", child)

    def test_diagnostic_matrix_is_non_archive_and_needs_no_cloud_workflow(self):
        with mock.patch.dict(os.environ, {"CI_XCODEBUILD_ACTION": "test"}, clear=True):
            compatibility_matrix._validate_execution_mode(diagnostic=True)

        with mock.patch.dict(os.environ, {"CI_XCODEBUILD_ACTION": "archive"}, clear=True):
            with self.assertRaisesRegex(compatibility_matrix.MatrixError, "cannot run in an archive action"):
                compatibility_matrix._validate_execution_mode(diagnostic=True)

        with mock.patch.dict(
            os.environ,
            {"CI_WORKFLOW": "Internal TestFlight", "CI_XCODEBUILD_ACTION": "archive"},
            clear=True,
        ):
            compatibility_matrix._validate_execution_mode(diagnostic=False)

        with mock.patch.dict(
            os.environ,
            {"CI_WORKFLOW": "Unrecognized Upload Workflow", "CI_XCODEBUILD_ACTION": "archive"},
            clear=True,
        ), self.assertRaisesRegex(compatibility_matrix.MatrixError, "Internal Testflight"):
            compatibility_matrix._validate_execution_mode(diagnostic=False)

    def test_diagnostic_matrix_never_reads_or_projects_release_confirmation(self):
        with mock.patch.object(
            release_hook, "latest_public_review_status", return_value={"status": "success"}
        ) as read_status:
            self.assertIsNone(
                compatibility_matrix._review_confirmation(True, "a" * 40, "b" * 64)
            )
            read_status.assert_not_called()
            self.assertEqual(
                compatibility_matrix._review_confirmation(False, "a" * 40, "b" * 64),
                {"status": "success"},
            )
            read_status.assert_called_once_with("a" * 40, "b" * 64)

    def test_candidate_attempt_is_fixed_per_unique_cloud_run(self):
        environment = {
            "CI_COMMIT": "a" * 40,
            "CI_XCODE_SCHEME": "TightbeamTuner",
            "CI_BUILD_ID": "cloud-run-84",
        }
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(
                compatibility_matrix, "_current_source", return_value=("a" * 40, "b" * 40)
            ):
                result = compatibility_matrix._prepare_candidate(
                    Path("."), {"scheme": "TightbeamTuner", "configuration": "Release"}, 84
                )
        self.assertEqual(result["attempt"], 1)
        self.assertEqual(result["configuration"], "Release")

    def test_loopback_probe_uses_lsof_tcp_port_filter(self):
        output = (
            "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
            "beam.smp 991 runner 4u IPv4 0x0 0t0 TCP 127.0.0.1:19450 (LISTEN)\n"
        )
        with mock.patch.object(compatibility_matrix.shutil, "which", return_value="/usr/bin/lsof"):
            with mock.patch.object(
                compatibility_matrix,
                "_run",
                return_value=subprocess.CompletedProcess([], 0, output),
            ) as run:
                compatibility_matrix._require_loopback_listener(19450, "test fixture")
        self.assertEqual(
            run.call_args.args[0],
            ["/usr/bin/lsof", "-nP", "-a", "-iTCP:19450", "-sTCP:LISTEN"],
        )

    def test_loopback_probe_rejects_wildcard_listener(self):
        output = (
            "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
            "beam.smp 991 runner 4u IPv4 0x0 0t0 TCP *:19450 (LISTEN)\n"
        )
        with mock.patch.object(compatibility_matrix.shutil, "which", return_value="/usr/bin/lsof"):
            with mock.patch.object(
                compatibility_matrix,
                "_run",
                return_value=subprocess.CompletedProcess([], 0, output),
            ):
                with self.assertRaisesRegex(
                    compatibility_matrix.MatrixError,
                    "not bound exclusively to loopback",
                ):
                    compatibility_matrix._require_loopback_listener(19450, "test fixture")

    def test_existing_compatibility_test_source_is_replaced_without_reediting_project(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            test_path = root / "ios/Tests/ReleaseCompatibilityTests.swift"
            test_path.parent.mkdir(parents=True)
            test_path.write_text("old test", encoding="utf-8")
            project = root / "ios/TightbeamTuner.xcodeproj/project.pbxproj"
            project.parent.mkdir(parents=True)
            original_project = "/* ReleaseCompatibilityTests.swift is already integrated */\n"
            project.write_text(original_project, encoding="utf-8")
            replied = root / "ios/TightbeamTuner/Replied.swift"
            replied.parent.mkdir(parents=True)
            replied.write_text(
                "    private(set) var state = RepliedState()\n"
                "    private(set) var shownSessionKey: String?\n"
                "                            ready = true\n"
                "                            snapshotTask = Task {\n"
                "                                await self.loadSnapshot(\n"
                "                                    mode: mode\n"
                "                                )\n"
                "                            }\n"
                "                        default:\n"
                "                            apply(frame, userID: user)\n"
                "                            if frame.changesRoster { onRosterEvent(frame) }\n",
                encoding="utf-8",
            )
            candidate_test = Path(__file__).resolve().parents[1] / "Tests/ReleaseCompatibilityTests.swift"
            compatibility_matrix._inject_compatibility_test(root, candidate_test)
            self.assertEqual(test_path.read_bytes(), candidate_test.read_bytes())
            self.assertEqual(project.read_text(encoding="utf-8"), original_project)
            self.assertIn("messageCreatedSequenceBySession", replied.read_text(encoding="utf-8"))

    def test_matrix_keeps_release_hook_failure_reason(self):
        self.assertEqual(
            compatibility_matrix._failure_message(release_hook.ReleaseHookError("pinned package digest mismatch")),
            "pinned package digest mismatch",
        )
        self.assertEqual(
            compatibility_matrix._failure_message(compatibility_matrix.MatrixError("runtime asset is incomplete")),
            "runtime asset is incomplete",
        )
        self.assertEqual(
            compatibility_matrix._failure_message(ValueError("unexpected value")),
            "compatibility matrix received an invalid input or could not write its report",
        )

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
                "observed": {
                    "sessionIdentity": "matched", "parentRelation": "matched",
                    "sessionKey": "agent:fixture:reply", "parentSessionKey": "agent:fixture:parent",
                },
            },
            "initial_message_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "sequenceSummaryRoute": "available", "sequenceSummaryDecoded": True,
                    "sequenceSummaryValid": True, "messagePageDecoded": True,
                    "clientStateMatched": True, "messageCount": 2, "latestReplySequence": 2,
                },
            },
            "read_marker_sync": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "pageDecoded": True, "clientStateMatched": True,
                    "markerCount": 1, "replySessionMarkerPresent": True,
                },
            },
            "catch_up": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "gatewayRestarted": True, "reconnected": True,
                        "snapshotReadCompleted": True, "clientStateMatched": True,
                        "changeEventClass": "read_marker.updated",
                        "changedSessionKey": "agent:fixture:reply",
                        "previousMarker": 2, "changedMarker": 3,
                },
            },
            "live_subscription": {
                "status": "passed", "implementation": "production-client",
                "observed": {
                    "eventClass": "read_marker.updated", "observedByClient": True,
                    "sessionKey": "agent:fixture:reply", "stateMatched": True, "marker": 4,
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


class XcodeCloudArchiveScriptTests(unittest.TestCase):
    def run_script(self, name, workflow, *, signed_export=None):
        script_directory = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            call_log = root / "python-calls.txt"
            python = fake_bin / "python3"
            python.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\nexit 0\n",
                encoding="utf-8",
            )
            python.chmod(0o700)
            environment = {
                "PATH": f"{fake_bin}:/usr/bin:/bin",
                "CALL_LOG": str(call_log),
                "CI_XCODE_CLOUD": "TRUE",
                "CI_XCODEBUILD_ACTION": "archive",
                "CI_BUILD_NUMBER": "84",
                "CI_WORKFLOW": workflow,
            }
            if name == "ci_post_xcodebuild.sh":
                export_path = signed_export or root / "signed-export"
                Path(export_path).mkdir()
                environment["CI_XCODEBUILD_EXIT_CODE"] = "0"
                environment["CI_APP_STORE_SIGNED_APP_PATH"] = str(export_path)
            result = subprocess.run(
                ["sh", str(script_directory / name)],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            calls = call_log.read_text(encoding="utf-8").splitlines() if call_log.exists() else []
            return result, calls

    def test_pre_archive_gates_case_variant_and_rejects_other_archive_workflows(self):
        result, calls = self.run_script("ci_pre_xcodebuild.sh", "Internal TestFlight")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("compatibility_matrix.py", calls[0])
        self.assertIn("release_notes.py validate", calls[1])

        result, calls = self.run_script("ci_pre_xcodebuild.sh", "Unrecognized Upload Workflow")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_post_archive_fails_closed_for_other_archive_workflows(self):
        result, calls = self.run_script("ci_post_xcodebuild.sh", "Internal TestFlight")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(calls), 1)
        self.assertIn("release_notes.py render", calls[0])

        result, calls = self.run_script("ci_post_xcodebuild.sh", "Renamed Upload Workflow")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


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
        for detail in (
            "", "None.", "None identified.", "No breaking changes.",
            "No breaking changes in this release.", "There are no known breaking changes.",
            "None, nothing changes.", "No.", "No breaking changes were found.", "TBD", "!!!",
        ):
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
        # Keep this archive fixture independent from the app's moving release
        # history. Build 83 represents a pre-hook historical note; the signed
        # export test should remain valid after later releases add entries.
        self.history_data = [
            {
                "version": "1.0",
                "build": 83,
                "date": "November 25, 2026",
                "items": [
                    {
                        "symbol": "checkmark.seal",
                        "title": "Compatibility",
                        "detail": "Tightbeam compatibility was not verified for this build.",
                    },
                    {
                        "symbol": "exclamationmark.triangle",
                        "title": "Breaking changes",
                        "detail": "None.",
                    },
                ],
            }
        ]
        candidate_object = release_hook.candidate_object(
            self.target, self.baseline, self.pair, findings, self.note_data, self.history_data
        )
        candidate_digest = release_hook.candidate_object_digest(candidate_object)
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
            "candidateObject": candidate_object,
            "candidateObjectSha256": candidate_digest,
            "preArchiveGate": {
                "status": "passed", "sourceCommit": self.target["commit"],
                "candidateDigest": candidate_digest,
                "context": release_hook.RELEASE_REVIEW_CONTEXT,
                "state": "success", "description": f"sha256:{candidate_digest}",
            },
        }
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
                "CI_TAG": "tuner-ios-build-84",
                "CI_GIT_REF": "refs/tags/tuner-ios-build-84",
                "CI_XCODE_SCHEME": "TightbeamTuner",
                "CI_PRIMARY_REPOSITORY_PATH": str(self.repo),
            })
            with (
                mock.patch.dict(os.environ, env, clear=True),
                mock.patch.object(release_hook, "validate_release_tag_identity"),
                mock.patch.object(release_hook, "resolve_published_pair", return_value=self.pair),
                mock.patch.object(release_hook, "latest_public_review_status", return_value={
                    "context": release_hook.RELEASE_REVIEW_CONTEXT,
                    "state": "success",
                    "description": f"sha256:{self.report['candidateObjectSha256']}",
                }),
            ):
                result = release_notes.main([
                    "render", "--build-number", "84", "--signed-app-path", str(signed),
                    "--require-archive-evidence", "--output", str(output),
                ])
            self.assertEqual(result, 0)
            rendered = output.read_text(encoding="utf-8")
            self.assertIn(release_hook.compatibility_line(self.pair), rendered)
            self.assertIn("Breaking changes\nNone.", rendered)
            gate_outcome = json.loads((root / "ReleaseGateOutcome.json").read_text(encoding="utf-8"))
            self.assertEqual(gate_outcome["candidateObjectSha256"], self.report["candidateObjectSha256"])
            self.assertEqual(gate_outcome["preArchiveGate"]["status"], "passed")
            self.assertEqual(gate_outcome["finalArchiveGate"]["status"], "passed")

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
                "CI_TAG": "tuner-ios-build-84",
                "CI_GIT_REF": "refs/tags/tuner-ios-build-84",
                "CI_XCODE_SCHEME": "TightbeamTuner",
                "CI_PRIMARY_REPOSITORY_PATH": str(self.repo),
            })
            error_output = io.StringIO()
            with (
                mock.patch.dict(os.environ, env, clear=True),
                mock.patch("sys.stderr", error_output),
            ):
                result = release_notes.main([
                    "render", "--build-number", "84", "--signed-app-path", str(signed),
                    "--require-archive-evidence", "--output", str(output),
                ])
            self.assertNotEqual(result, 0)
            self.assertIn("note digest", error_output.getvalue())
            self.assertFalse(output.exists())
            self.assertFalse((root / "ReleaseGateOutcome.json").exists())


if __name__ == "__main__":
    unittest.main()
