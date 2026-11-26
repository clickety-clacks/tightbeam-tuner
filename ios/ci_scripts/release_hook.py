#!/usr/bin/env python3
"""Fail-closed rules for Tuner's Tightbeam compatibility release hook."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tarfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import release_notes


class ReleaseHookError(ValueError):
    pass


REQUIRED_CLIENT_CHECKS = (
    "roster",
    "initial_message_sync",
    "read_marker_sync",
    "catch_up",
    "live_subscription",
)
REQUIRED_INTERFACE_PATHS = (
    "roster",
    "initial_message_sync",
    "read_marker_sync",
    "catch_up",
    "live_subscription",
)
COMPATIBILITY_TITLE = "Compatibility"
BREAKING_TITLE = "Breaking changes"
TIGHTBEAM_RELEASES_API = "https://api.github.com/repos/clickety-clacks/tightbeam/releases"
GITHUB_USER_AGENT = "TightbeamTuner-release-check"
TUNER_REPOSITORY = "clickety-clacks/tightbeam-tuner"
RELEASE_REVIEW_CONTEXT = "tuner-ios/release-review"


@dataclass(frozen=True)
class PublishedRelease:
    release_id: int
    tag: str
    published_at: str
    asset_id: int
    asset_name: str
    asset_digest: str
    download_url: str

    def identity(self) -> tuple[int, str, int, str]:
        return self.release_id, self.tag, self.asset_id, self.asset_digest


def _fail(message: str) -> None:
    raise ReleaseHookError(message)


def _published_time(value: object) -> datetime:
    if not isinstance(value, str) or not value:
        _fail("published release has no publication time")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReleaseHookError("published release has an invalid publication time") from error
    if parsed.tzinfo is None:
        _fail("published release publication time has no timezone")
    return parsed


def _asset_for_release(release: dict[str, Any], platform_asset: str) -> PublishedRelease:
    release_id = release.get("id")
    tag = release.get("tag_name")
    published_at = release.get("published_at")
    assets = release.get("assets")
    if not isinstance(release_id, int) or release_id <= 0:
        _fail("published Tightbeam release has no verifiable release ID")
    if not isinstance(tag, str) or not tag:
        _fail("published Tightbeam release has no full release tag")
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:\+[A-Za-z0-9.-]+)?", tag):
        _fail("published Tightbeam release has an invalid full release tag")
    if not isinstance(assets, list):
        _fail(f"published Tightbeam release {tag} has no verifiable assets")
    # Release assets use the semantic version and short source revision in
    # their filename; the complete release tag (including its build suffix)
    # is bound separately by the release record and asset digest.
    version = tag[1:].split("+", 1)[0]
    asset_pattern = re.compile(
        rf"tightbeam-{re.escape(version)}-{re.escape(platform_asset)}-[0-9a-f]{{7,40}}\.tgz"
    )
    matches = [
        asset for asset in assets
        if isinstance(asset, dict)
        and isinstance(asset.get("name"), str)
        and asset_pattern.fullmatch(asset["name"])
        and asset.get("state") == "uploaded"
    ]
    if len(matches) != 1:
        _fail(f"published Tightbeam release {tag} has an ambiguous {platform_asset} package")
    asset = matches[0]
    asset_id = asset.get("id")
    digest = asset.get("digest")
    url = asset.get("browser_download_url")
    if not isinstance(asset_id, int) or asset_id <= 0:
        _fail(f"published Tightbeam release {tag} package has no asset ID")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        _fail(f"published Tightbeam release {tag} package has no SHA-256 digest")
    if not isinstance(url, str) or not url.startswith("https://github.com/"):
        _fail(f"published Tightbeam release {tag} package has no HTTPS download URL")
    _published_time(published_at)
    return PublishedRelease(
        release_id=release_id,
        tag=tag,
        published_at=published_at,
        asset_id=asset_id,
        asset_name=asset["name"],
        asset_digest=digest.removeprefix("sha256:"),
        download_url=url,
    )


def resolve_release_pair(
    latest_release: dict[str, Any],
    release_records: list[dict[str, Any]],
    platform_asset: str,
) -> tuple[PublishedRelease, PublishedRelease]:
    """Resolve GitHub Latest full release and its strictly earlier full release."""
    if latest_release.get("draft") is True or latest_release.get("prerelease") is True:
        _fail("GitHub Latest is not an eligible full Tightbeam release")
    latest_id = latest_release.get("id")
    eligible = [
        row for row in release_records
        if isinstance(row, dict)
        and row.get("draft") is not True
        and row.get("prerelease") is not True
        and row.get("published_at") is not None
    ]
    matching = [row for row in eligible if row.get("id") == latest_id]
    if len(matching) != 1:
        _fail("GitHub Latest release is absent or ambiguous in the published release records")
    latest_time = _published_time(latest_release.get("published_at"))
    predecessors = [
        row for row in eligible
        if _published_time(row.get("published_at")) < latest_time
    ]
    if not predecessors:
        _fail("fewer than two eligible published Tightbeam releases are available")
    predecessor_time = max(_published_time(row.get("published_at")) for row in predecessors)
    prior_rows = [
        row for row in predecessors
        if _published_time(row.get("published_at")) == predecessor_time
    ]
    if len(prior_rows) != 1:
        _fail("preceding published Tightbeam release is ambiguous")
    return (
        _asset_for_release(latest_release, platform_asset),
        _asset_for_release(prior_rows[0], platform_asset),
    )


def same_release_pair(
    before: tuple[PublishedRelease, PublishedRelease],
    after: tuple[PublishedRelease, PublishedRelease],
) -> None:
    if tuple(item.identity() for item in before) != tuple(item.identity() for item in after):
        _fail("required Tightbeam releases or pinned package assets changed while the archive was in flight")


def compatibility_line(pair: tuple[PublishedRelease, PublishedRelease]) -> str:
    return f"Compatible with Tightbeam: {pair[0].tag}, {pair[1].tag}"


def _read_github_json(url: str) -> tuple[Any, str | None]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": GITHUB_USER_AGENT,
        "X-GitHub-Api-Version": "2022-11-28",
    }
    # Public-release resolution may use the short-lived, read-only GitHub Actions
    # token to avoid the much lower anonymous API rate limit. This helper is only
    # used for public Tightbeam release metadata; the private reviewer-status
    # projection deliberately uses its own unauthenticated endpoint.
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
            return payload, response.headers.get("Link")
    except urllib.error.HTTPError as error:
        raise ReleaseHookError(
            f"could not resolve published Tightbeam releases from GitHub (HTTP {error.code})"
        ) from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise ReleaseHookError("could not resolve published Tightbeam releases from GitHub") from error


def resolve_published_pair(platform_asset: str) -> tuple[PublishedRelease, PublishedRelease]:
    """Resolve Latest and its immediately preceding published full release."""
    latest, _ = _read_github_json(TIGHTBEAM_RELEASES_API + "/latest")
    if not isinstance(latest, dict):
        _fail("GitHub Latest did not return a release record")
    records: list[dict[str, Any]] = []
    page = 1
    while True:
        value, link = _read_github_json(f"{TIGHTBEAM_RELEASES_API}?per_page=100&page={page}")
        if not isinstance(value, list):
            _fail("GitHub published release list did not return records")
        records.extend(row for row in value if isinstance(row, dict))
        if not any('rel="next"' in part for part in (link or "").split(",")):
            break
        page += 1
    return resolve_release_pair(latest, records, platform_asset)


def download_verified_release_asset(release: PublishedRelease, destination: Path) -> Path:
    """Download only the pinned public asset and verify its bytes before use."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    request = urllib.request.Request(release.download_url, headers={"User-Agent": GITHUB_USER_AGENT})
    digest = hashlib.sha256()
    try:
        with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
            while block := response.read(1024 * 1024):
                output.write(block)
                digest.update(block)
    except (OSError, urllib.error.URLError, TimeoutError) as error:
        destination.unlink(missing_ok=True)
        raise ReleaseHookError(f"could not download published package for {release.tag}") from error
    if digest.hexdigest() != release.asset_digest:
        destination.unlink(missing_ok=True)
        _fail(f"downloaded published package digest does not match release metadata for {release.tag}")
    return destination


def extract_release_package(package: Path, destination: Path) -> Path:
    """Extract only regular files and directories from a verified package."""
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(package, "r:gz") as archive:
        members = archive.getmembers()
        for member in members:
            target = (destination / member.name).resolve()
            if target != root and root not in target.parents:
                _fail("published Tightbeam package contains an unsafe path")
            if not (member.isdir() or member.isfile()):
                _fail("published Tightbeam package contains an unsupported link or device entry")
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                _fail("published Tightbeam package contains an unreadable file")
            with source, target.open("xb") as output:
                shutil.copyfileobj(source, output)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    find_runtime_executable(destination, "tightbeam")
    return find_runtime_executable(destination, "tightbeam-gateway")


def find_runtime_executable(package_root: Path, name: str) -> Path:
    """Find exactly one regular executable file, ignoring same-named directories."""
    matches = sorted(
        path for path in package_root.rglob(name)
        if path.is_file() and os.access(path, os.X_OK)
    )
    if len(matches) != 1:
        _fail(f"published package must contain exactly one executable {name}")
    return matches[0]


def _candidate_key(candidate: dict[str, Any]) -> tuple[Any, ...]:
    required = ("commit", "tree", "scheme", "configuration", "buildNumber")
    missing = [key for key in required if candidate.get(key) in (None, "")]
    if missing:
        _fail("candidate identity is missing: " + ", ".join(missing))
    return tuple(candidate[key] for key in required)


def validate_compatibility_runs(
    report: dict[str, Any],
    candidate: dict[str, Any],
    pair: tuple[PublishedRelease, PublishedRelease],
    *,
    baseline: dict[str, Any],
    expected_ci_run_id: str | None = None,
) -> list[dict[str, Any]]:
    """Require one candidate-bound iOS-client result for each pinned runtime."""
    if report.get("schemaVersion") != 1:
        _fail("compatibility report is missing or has an unsupported schema version")
    report_candidate = report.get("candidate")
    if not isinstance(report_candidate, dict) or _candidate_key(report_candidate) != _candidate_key(candidate):
        _fail("compatibility report is for a different commit, tree, scheme, configuration, or build")
    report_baseline = report.get("baseline")
    if not isinstance(report_baseline, dict) or _candidate_key(report_baseline) != _candidate_key(baseline):
        _fail("compatibility report is not bound to the exact preceding distributed build")
    producer = report.get("producer")
    if not isinstance(producer, dict):
        _fail("compatibility report has no CI producer identity")
    if not isinstance(producer.get("runId"), str) or not producer["runId"]:
        _fail("compatibility report has no CI run ID")
    if (
        type(producer.get("attempt")) is not int
        or producer["attempt"] != release_notes.XCODE_CLOUD_ATTEMPT_NUMBER
    ):
        _fail("compatibility report does not use the fixed attempt number for its unique CI run")
    if producer.get("sourceCommit") != candidate["commit"] or producer.get("sourceTree") != candidate["tree"]:
        _fail("compatibility CI producer ran a different source commit or tree")
    if expected_ci_run_id is not None and producer.get("runId") != expected_ci_run_id:
        _fail("compatibility report does not belong to this Xcode Cloud run")
    if producer.get("buildNumber") != candidate["buildNumber"]:
        _fail("compatibility CI producer ran a different numbered candidate")
    if producer.get("scheme") != candidate["scheme"] or producer.get("configuration") != candidate["configuration"]:
        _fail("compatibility CI producer used a different scheme or release configuration")
    if producer.get("execution") != "ios-simulator" or producer.get("runtimeSource") != "published-release-asset":
        _fail("compatibility result was not produced by the required isolated simulator and published runtime")
    if (
        producer.get("networkScope") != "disposable-per-release-base-and-state"
        or producer.get("modelEndpointNetworkScope") != "loopback-only"
        or producer.get("runtimeClientAddress") != "loopback-advertised-url"
    ):
        _fail("compatibility run did not use isolated runtime state, a loopback model endpoint, and the loopback client URL")
    listener_rows = report.get("runtimeGatewayListeners")
    expected_release_ids = {item.release_id for item in pair}
    if not isinstance(listener_rows, list) or len(listener_rows) != len(expected_release_ids):
        _fail("compatibility report does not record gateway listener bindings for both published releases")
    observed_release_ids: set[int] = set()
    allowed_binding_labels = {
        "wildcard", "IPv4 loopback", "IPv6 loopback", "non-loopback IPv4",
        "non-loopback IPv6", "unrecognized address", "unexpected listener entry",
    }
    for row in listener_rows:
        if not isinstance(row, dict):
            _fail("compatibility report contains an invalid gateway listener observation")
        release_id = row.get("releaseId")
        bindings = row.get("observedBindings")
        if (
            type(release_id) is not int or release_id not in expected_release_ids
            or release_id in observed_release_ids
            or not isinstance(bindings, list) or not bindings
            or any(not isinstance(value, str) or value not in allowed_binding_labels for value in bindings)
        ):
            _fail("compatibility report contains incomplete or unrecognized gateway listener observations")
        observed_release_ids.add(release_id)
    if observed_release_ids != expected_release_ids:
        _fail("compatibility report does not identify both published gateway listeners")
    runs = report.get("runs")
    if not isinstance(runs, list) or len(runs) != 2:
        _fail("compatibility report must contain exactly two per-release CI runs")
    validated: list[dict[str, Any]] = []
    expected_pair = {item.release_id: item for item in pair}
    seen: set[int] = set()
    for run in runs:
        if not isinstance(run, dict):
            _fail("compatibility report contains an invalid per-release run")
        release = run.get("release")
        if not isinstance(release, dict):
            _fail("compatibility run does not identify its published Tightbeam release")
        release_id = release.get("id")
        expected = expected_pair.get(release_id)
        if expected is None or release_id in seen:
            _fail("compatibility run set does not match the two pinned published releases")
        seen.add(release_id)
        if release.get("tag") != expected.tag or release.get("assetId") != expected.asset_id:
            _fail("compatibility run tested a different Tightbeam release or package asset")
        if release.get("assetDigest") != expected.asset_digest:
            _fail("compatibility run package digest does not match the pinned published asset")
        run_candidate = run.get("candidate")
        if not isinstance(run_candidate, dict) or _candidate_key(run_candidate) != _candidate_key(candidate):
            _fail("per-release result is not bound to this exact numbered candidate")
        if not isinstance(run.get("runId"), str) or not run["runId"]:
            _fail("per-release compatibility result has no CI run ID")
        if run["runId"] != producer["runId"]:
            _fail("per-release compatibility result belongs to a different CI run")
        if type(run.get("attempt")) is not int or run["attempt"] != producer["attempt"]:
            _fail("per-release compatibility result belongs to a different CI attempt")
        simulator = run.get("simulator")
        if not isinstance(simulator, dict) or not all(
            isinstance(simulator.get(field), str) and simulator[field]
            for field in ("deviceType", "runtime")
        ):
            _fail("per-release compatibility result does not identify its simulator and iOS runtime")
        if not simulator["runtime"].startswith("iOS "):
            _fail("compatibility run did not use an iOS simulator")
        run_baseline = run.get("baseline")
        if not isinstance(run_baseline, dict) or _candidate_key(run_baseline) != _candidate_key(baseline):
            _fail("per-release result is not bound to the exact preceding distributed build")
        baseline_phase = run.get("baselinePhaseSource")
        candidate_phase = run.get("candidatePhaseSource")
        if not isinstance(baseline_phase, dict) or _candidate_key(baseline_phase) != _candidate_key(baseline):
            _fail("baseline client result was not produced from the pinned baseline source")
        if not isinstance(candidate_phase, dict) or _candidate_key(candidate_phase) != _candidate_key(candidate):
            _fail("candidate client result was not produced from the exact numbered candidate")
        baseline_checks = run.get("baselineChecks")
        checks = run.get("checks")
        for label, values in (("baseline", baseline_checks), ("candidate", checks)):
            if not isinstance(values, dict) or set(values) != set(REQUIRED_CLIENT_CHECKS):
                _fail(f"{label} compatibility result for {expected.tag} is missing a required client path")
            for check_name in REQUIRED_CLIENT_CHECKS:
                check = values.get(check_name)
                if not isinstance(check, dict) or check.get("status") not in {"passed", "failed"}:
                    _fail(f"{label} check {check_name} did not complete for {expected.tag}")
                if check.get("implementation") != "production-client":
                    _fail(f"{label} check {check_name} did not use Tuner's production client path")
                if not isinstance(check.get("observed"), dict):
                    _fail(f"{label} check {check_name} has no observed client result for {expected.tag}")
        for label, phase_checks in (("baseline", baseline_checks), ("candidate", checks)):
            roster = phase_checks["roster"]["observed"]
            if (
                roster.get("sessionIdentity") not in {"matched", "missing"}
                or roster.get("parentRelation") not in {"matched", "mismatched"}
                or not isinstance(roster.get("sessionCount"), int)
                or isinstance(roster.get("sessionCount"), bool)
                or roster.get("sessionCount", 0) < 2
            ):
                _fail(f"{label} roster result for {expected.tag} lacks a nonempty identity or parent observation")
            if (phase_checks["roster"]["status"] == "passed") != (
                roster.get("sessionIdentity") == "matched"
                and roster.get("parentRelation") == "matched"
                and roster.get("sessionCount", 0) >= 2
            ):
                _fail(f"{label} roster pass status for {expected.tag} conflicts with the observed identity")

            live = phase_checks["live_subscription"]["observed"]
            if live.get("eventClass") not in {"message.created", "not-observed"}:
                _fail(f"{label} live subscription for {expected.tag} has an invalid event observation")
            if (
                not isinstance(live.get("observedByClient"), bool)
                or not isinstance(live.get("stateMatched"), bool)
                or not isinstance(live.get("correlatedReply"), bool)
                or live.get("sessionIdentity") not in {"matched", "missing"}
                or not isinstance(live.get("previousReplySequence"), int)
                or isinstance(live.get("previousReplySequence"), bool)
                or not isinstance(live.get("replySequence"), int)
                or isinstance(live.get("replySequence"), bool)
                or live.get("replySequence", 0) <= live.get("previousReplySequence", 0)
                or not isinstance(live.get("previousMarker"), int)
                or isinstance(live.get("previousMarker"), bool)
                or not isinstance(live.get("marker"), int)
                or isinstance(live.get("marker"), bool)
                or live.get("marker", 0) <= live.get("previousMarker", 0)
            ):
                _fail(f"{label} live subscription for {expected.tag} lacks its observed client state")
            live_passed = (
                live.get("eventClass") == "message.created"
                and live.get("observedByClient") is True
                and live.get("stateMatched") is True
                and live.get("correlatedReply") is True
                and live.get("sessionIdentity") == "matched"
            )
            if (phase_checks["live_subscription"]["status"] == "passed") != live_passed:
                _fail(f"{label} live subscription pass status for {expected.tag} conflicts with the observed event state")

            initial = phase_checks["initial_message_sync"]["observed"]
            if (
                initial.get("sequenceSummaryRoute") not in {"available", "not-supported"}
                or not all(isinstance(initial.get(key), bool) for key in (
                    "sequenceSummaryDecoded", "sequenceSummaryValid", "messagePageDecoded",
                    "clientStateMatched", "turnIncludesHuman"
                ))
                or not isinstance(initial.get("messageCount"), int)
                or isinstance(initial.get("messageCount"), bool)
                or initial["messageCount"] <= 0
                or not isinstance(initial.get("latestReplySequence"), int)
                or isinstance(initial.get("latestReplySequence"), bool)
                or initial["latestReplySequence"] <= 0
            ):
                _fail(f"{label} initial message sync is missing decoded response or client-state observations")
            if (initial["sequenceSummaryRoute"] == "available") != initial["sequenceSummaryDecoded"]:
                _fail(f"{label} sequence-summary route status for {expected.tag} conflicts with its response")
            if (phase_checks["initial_message_sync"]["status"] == "passed") != all(
                initial[key] for key in (
                    "sequenceSummaryValid", "messagePageDecoded", "clientStateMatched", "turnIncludesHuman"
                )
            ):
                _fail(f"{label} initial message sync pass status for {expected.tag} conflicts with observed state")

            marker = phase_checks["read_marker_sync"]["observed"]
            if (
                not all(isinstance(marker.get(key), bool) for key in (
                    "pageDecoded", "clientStateMatched", "replySessionMarkerPresent"
                ))
                or not isinstance(marker.get("markerCount"), int)
                or isinstance(marker.get("markerCount"), bool)
                or marker["markerCount"] <= 0
            ):
                _fail(f"{label} read-marker sync is missing its decoded-page or client-state observation")
            if (phase_checks["read_marker_sync"]["status"] == "passed") != all(
                marker[key] for key in ("pageDecoded", "clientStateMatched", "replySessionMarkerPresent")
            ):
                _fail(f"{label} read-marker sync pass status for {expected.tag} conflicts with observed state")

            catch_up = phase_checks["catch_up"]["observed"]
            if not all(isinstance(catch_up.get(key), bool) for key in (
                "gatewayRestarted", "reconnected", "snapshotReadCompleted", "clientStateMatched",
                "correlatedReply", "changedSessionMatched"
            )):
                _fail(f"{label} catch-up result for {expected.tag} is missing an observed reconnect or state step")
            if any(
                not isinstance(catch_up.get(key), int)
                or isinstance(catch_up.get(key), bool)
                or catch_up.get(key, 0) < 2
                for key in ("subscriptionReadyCount", "snapshotCompletedCount")
            ):
                _fail(f"{label} catch-up result for {expected.tag} lacks initial and reconnect observations")
            if (
                catch_up.get("changeEventClass") != "message.created"
                or not isinstance(catch_up.get("previousSequence"), int)
                or isinstance(catch_up.get("previousSequence"), bool)
                or not isinstance(catch_up.get("changedSequence"), int)
                or isinstance(catch_up.get("changedSequence"), bool)
                or catch_up.get("changedSequence", 0) <= catch_up.get("previousSequence", 0)
                or not isinstance(catch_up.get("previousMarker"), int)
                or isinstance(catch_up.get("previousMarker"), bool)
                or not isinstance(catch_up.get("changedMarker"), int)
                or isinstance(catch_up.get("changedMarker"), bool)
                or catch_up.get("changedMarker", 0) <= catch_up.get("previousMarker", 0)
            ):
                _fail(f"{label} catch-up result for {expected.tag} lacks an actual changed Replies value")
            if (phase_checks["catch_up"]["status"] == "passed") != all(
                catch_up[key] for key in (
                    "gatewayRestarted", "reconnected", "snapshotReadCompleted", "clientStateMatched",
                    "changedSessionMatched", "correlatedReply",
                )
            ):
                _fail(f"{label} catch-up pass status for {expected.tag} conflicts with observed state")
        interfaces = run.get("interfaceComparisons")
        if not isinstance(interfaces, dict) or set(interfaces) != set(REQUIRED_INTERFACE_PATHS):
            _fail(f"Tightbeam interface detector is missing a required baseline comparison for {expected.tag}")
        for path in REQUIRED_INTERFACE_PATHS:
            result = interfaces[path]
            if not isinstance(result, dict) or not all(
                isinstance(result.get(key), bool) for key in ("baselinePassed", "candidatePassed")
            ):
                _fail(f"Tightbeam interface detector could not measure {path} on {expected.tag}")
            if result["baselinePassed"] != (baseline_checks[path]["status"] == "passed"):
                _fail(f"Tightbeam interface baseline result for {path} on {expected.tag} is inconsistent")
            if result["candidatePassed"] != (checks[path]["status"] == "passed"):
                _fail(f"Tightbeam interface candidate result for {path} on {expected.tag} is inconsistent")
        continuity = run.get("upgradeContinuity")
        if not isinstance(continuity, dict) or continuity.get("status") != "completed":
            _fail(f"upgrade-continuity detector did not complete for {expected.tag}")
        if not all(isinstance(continuity.get(key), bool) for key in ("savedConnectionLoaded", "rosterIdentityPreserved")):
            _fail(f"upgrade-continuity detector is missing a result for {expected.tag}")
        validated.append(run)
    if seen != set(expected_pair):
        _fail("compatibility report omitted a required published Tightbeam release")
    return validated


def findings_digest(findings: list[dict[str, Any]]) -> str:
    return canonical_digest(findings)


def breaking_section_digest(detail: str) -> str:
    normalized = detail.replace("\r\n", "\n").replace("\r", "\n").strip()
    return hashlib.sha256(f"{BREAKING_TITLE}\n{normalized}\n".encode("utf-8")).hexdigest()


def section_details(note: release_notes.Note, title: str) -> str:
    sections = [item.detail for item in note.items if item.title.casefold() == title.casefold()]
    if len(sections) != 1:
        _fail(f"release note must contain exactly one {title!r} section")
    return sections[0]


def validate_breaking_section(note: release_notes.Note, findings: list[dict[str, Any]]) -> str:
    detail = section_details(note, BREAKING_TITLE)
    normalized = detail.replace("\r\n", "\n").replace("\r", "\n").strip()
    if not findings:
        if not normalized:
            _fail("Breaking changes section must not be empty")
        return breaking_section_digest(normalized)
    if not normalized:
        _fail("detected breaking changes require a substantive user-facing explanation")
    generic = {
        "none", "none.", "no breaking changes", "no breaking changes.",
        "tbd", "todo", "n/a", "na", "coming soon", "placeholder",
    }
    if normalized.casefold() in generic or re.fullmatch(r"[\W_]+", normalized, re.UNICODE):
        _fail("detected breaking changes require a substantive user-facing explanation")
    if re.search(r"\b(?:TBD|TODO|N/?A|placeholder)\b", normalized, re.IGNORECASE):
        _fail("detected breaking changes cannot use placeholder text")
    if re.fullmatch(
        r"(?is)\s*(?:there (?:are|were|have been) )?(?:no|none)"
        r"(?:\s+(?:known|identified|detected|reported))?"
        r"(?:\s+(?:breaking )?changes?)?"
        r"(?:\s+(?:are|were|have been))?"
        r"(?:\s+(?:known|identified|detected|reported|found))?"
        r"(?:\s+in (?:this|the) (?:release|update|build))?"
        r"(?:\s*,?\s*(?:nothing changes|no changes))?\s*[.!?]*\s*",
        normalized,
    ):
        _fail("detected breaking changes cannot be declared absent")
    return breaking_section_digest(normalized)


def detect_breaking_changes(
    baseline: dict[str, Any],
    candidate: dict[str, Any],
    compatibility_runs: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Run the three specified detectors; missing measurements block the release."""
    required_os = ("minimumOS", "deviceFamilies")
    if any(key not in baseline for key in required_os) or any(key not in candidate for key in required_os):
        _fail("device-support detector is missing baseline or candidate settings")
    baseline_os = _os_version(baseline["minimumOS"])
    candidate_os = _os_version(candidate["minimumOS"])
    baseline_families = baseline["deviceFamilies"]
    candidate_families = candidate["deviceFamilies"]
    if (
        not isinstance(baseline_families, list)
        or not baseline_families
        or not isinstance(candidate_families, list)
        or not candidate_families
        or not all(isinstance(family, (str, int)) and str(family) for family in baseline_families + candidate_families)
    ):
        _fail("device-support detector requires device-family lists")
    findings: list[dict[str, Any]] = []
    if candidate_os > baseline_os:
        findings.append({
            "detectorId": "device-support.minimum-os",
            "path": "all-supported-devices",
            "before": ".".join(map(str, baseline_os)),
            "after": ".".join(map(str, candidate_os)),
        })
    removed = sorted(set(baseline_families) - set(candidate_families))
    for family in removed:
        findings.append({
            "detectorId": "device-support.family-removed",
            "path": str(family),
            "before": "supported",
            "after": "unsupported",
        })

    if len(compatibility_runs) != 2:
        _fail("upgrade-continuity detector requires both published-runtime comparisons")
    for run in compatibility_runs:
        upgrade = run.get("upgradeContinuity")
        if not isinstance(upgrade, dict) or upgrade.get("status") != "completed":
            _fail("upgrade-continuity detector did not complete")
        tag = run.get("release", {}).get("tag", "unknown release")
        for check_name, detector_id, path in (
            ("savedConnectionLoaded", "upgrade-continuity.connection-lost", "saved-connection"),
            ("rosterIdentityPreserved", "upgrade-continuity.roster-identity-lost", "roster-ssh-identity"),
        ):
            if not isinstance(upgrade.get(check_name), bool):
                _fail(f"upgrade-continuity detector is missing {check_name}")
            if not upgrade[check_name]:
                findings.append({
                    "detectorId": detector_id,
                    "path": path,
                    "audience": tag,
                    "before": "usable without re-entry",
                    "after": "lost or requires re-entry",
                })

    if len(compatibility_runs) != 2:
        _fail("Tightbeam-interface detector requires both published-runtime comparisons")
    for run in compatibility_runs:
        interfaces = run.get("interfaceComparisons")
        if not isinstance(interfaces, dict) or set(interfaces) != set(REQUIRED_INTERFACE_PATHS):
            _fail("Tightbeam-interface detector is missing a required baseline comparison")
        tag = run.get("release", {}).get("tag", "unknown release")
        for path in REQUIRED_INTERFACE_PATHS:
            result = interfaces[path]
            if not isinstance(result, dict) or not all(
                isinstance(result.get(key), bool) for key in ("baselinePassed", "candidatePassed")
            ):
                _fail(f"Tightbeam-interface detector could not measure {path} on {tag}")
            if result["baselinePassed"] and not result["candidatePassed"]:
                findings.append({
                    "detectorId": "tightbeam-interface.regression",
                    "path": path,
                    "audience": tag,
                    "before": "passed",
                    "after": "failed",
                })
    return sorted(findings, key=lambda row: (
        row.get("detectorId", ""), row.get("path", ""), row.get("audience", ""),
        row.get("before", ""), row.get("after", ""),
    ))


def author_compatibility_line(detail: str, expected: str) -> str:
    declared = re.findall(r"(?im)^\s*Compatible with Tightbeam:.*$", detail)
    if len(declared) > 1:
        _fail("Compatibility section contains more than one Tightbeam declaration")
    if declared and declared[0].strip() != expected:
        _fail("authored Tightbeam compatibility declaration disagrees with successful CI runs")
    remainder = re.sub(r"(?im)^\s*Compatible with Tightbeam:.*\n?", "", detail)
    remainder = re.sub(
        r"(?i)Tightbeam compatibility is generated from release checks\.?\s*", "", remainder
    ).strip()
    if re.search(r"\bTightbeam\b", remainder, re.IGNORECASE):
        _fail("Compatibility section contains an unsupported Tightbeam claim")
    return expected + ("\n" + remainder if remainder else "")


def replace_compatibility_detail(note_data: dict[str, Any], line: str) -> dict[str, Any]:
    items = note_data.get("items")
    if not isinstance(items, list):
        _fail("current release note has no item list")
    matches = [item for item in items if isinstance(item, dict) and item.get("title", "").casefold() == COMPATIBILITY_TITLE.casefold()]
    if len(matches) != 1 or not isinstance(matches[0].get("detail"), str):
        _fail("current release note must contain exactly one Compatibility section")
    matches[0]["detail"] = author_compatibility_line(matches[0]["detail"], line)
    return note_data


def validate_history_claims(history: tuple[release_notes.Note, ...]) -> None:
    """Check public history shape; private exact-record matching stays external."""
    for note in history:
        compatibility_items = [item for item in note.items if item.title.casefold() == COMPATIBILITY_TITLE.casefold()]
        breaking_items = [item for item in note.items if item.title.casefold() == BREAKING_TITLE.casefold()]
        for item in note.items:
            if item.title.casefold() != COMPATIBILITY_TITLE.casefold() and re.search(
                r"\bTightbeam(?:\s+CLI|\s+Gateway)?\s+v?\d+\.\d+\.\d+(?:\+[A-Za-z0-9.-]+)?\b", item.detail, re.IGNORECASE
            ):
                _fail(f"historical build {note.build} contains a Tightbeam version outside its Compatibility section")
        if note.build <= 83:
            # Builds before 73 predate the Compatibility/Breaking changes note
            # format; preserve those legacy entries while refusing any version
            # claim they might contain.
            if note.build < 73:
                if len(compatibility_items) > 1 or len(breaking_items) > 1:
                    _fail(f"historical build {note.build} contains duplicate compatibility sections")
                if any(re.search(
                    r"\bTightbeam(?:\s+CLI|\s+Gateway)?\s+v?\d+\.\d+\.\d+(?:\+[A-Za-z0-9.-]+)?\b",
                    item.detail,
                    re.IGNORECASE,
                ) for item in note.items):
                    _fail(f"historical build {note.build} contains an unverified Tightbeam version claim")
                continue
            compatibility = section_details(note, COMPATIBILITY_TITLE)
            section_details(note, BREAKING_TITLE)
            if "Tightbeam compatibility was not verified for this build" not in compatibility:
                _fail(f"historical build {note.build} must state that Tightbeam compatibility was not verified")
            if re.search(r"\bCompatible with Tightbeam\b", compatibility, re.IGNORECASE):
                _fail(f"historical build {note.build} contains an unverified Tightbeam compatibility claim")
        else:
            compatibility = section_details(note, COMPATIBILITY_TITLE)
            section_details(note, BREAKING_TITLE)
            if re.search(r"\bTightbeam\s+v?\d+\.\d+\.\d+", compatibility, re.IGNORECASE):
                _fail(f"historical build {note.build} uses a legacy Tightbeam version claim")


def _os_version(value: object) -> tuple[int, ...]:
    if not isinstance(value, (str, int)) or not re.fullmatch(r"\d+(?:\.\d+)*", str(value)):
        _fail("device-support detector received an invalid minimum OS version")
    parts = tuple(int(part) for part in str(value).split("."))
    return parts + (0,) * (3 - len(parts)) if len(parts) < 3 else parts


def baseline_reference(candidate_input: dict[str, Any], actual_baseline: dict[str, Any]) -> dict[str, Any]:
    """Require the candidate-side baseline hint to match the last real distribution."""
    keys = ("buildNumber", "sourceCommit", "scheme", "configuration")
    if any(candidate_input.get(key) in (None, "") for key in keys):
        _fail("candidate baseline reference is incomplete")
    if any(actual_baseline.get(key) in (None, "") for key in keys):
        _fail("last distributed baseline could not be established")
    if any(candidate_input[key] != actual_baseline[key] for key in keys):
        _fail("candidate baseline reference disagrees with the last distributed build")
    return {key: actual_baseline[key] for key in keys}


def note_digest(note_data: dict[str, Any]) -> str:
    return canonical_digest(note_data)


def canonical_json(value: Any) -> str:
    """Serialize the fixed JSON payloads used by the release contract canonically."""
    def validate(item: Any) -> None:
        if item is None or isinstance(item, (str, bool)):
            return
        if isinstance(item, int) and not isinstance(item, bool):
            return
        if isinstance(item, list):
            for child in item:
                validate(child)
            return
        if isinstance(item, dict) and all(isinstance(key, str) for key in item):
            for child in item.values():
                validate(child)
            return
        raise ReleaseHookError("candidate digest contains a value outside the canonical JSON schema")

    validate(value)
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def candidate_object(
    candidate: dict[str, Any],
    baseline: dict[str, Any],
    pair: tuple[PublishedRelease, PublishedRelease],
    findings: list[dict[str, Any]],
    note_data: dict[str, Any],
    history_data: object,
) -> dict[str, Any]:
    _candidate_key(candidate)
    _candidate_key(baseline)
    if not isinstance(history_data, list):
        _fail("candidate history is not a JSON array")
    release_notes.notes_from_history_data(history_data)
    return {
        "schemaVersion": 1,
        "repository": TUNER_REPOSITORY,
        "sourceCommit": candidate["commit"],
        "sourceTree": candidate["tree"],
        "scheme": candidate["scheme"],
        "configuration": candidate["configuration"],
        "buildNumber": candidate["buildNumber"],
        "baseline": {
            "buildNumber": baseline["buildNumber"],
            "sourceCommit": baseline["commit"],
        },
        "requiredTightbeamReleases": [
            {"tag": release.tag, "releaseId": release.release_id, "assetSha256": release.asset_digest}
            for release in pair
        ],
        "detectorFindingsSha256": findings_digest(findings),
        "currentNoteSha256": note_digest(note_data),
        "historySha256": canonical_digest(history_data),
    }


def candidate_object_digest(value: dict[str, Any]) -> str:
    return canonical_digest(value)


def validate_release_tag_identity(
    repo: Path, commit: str, git_ref: str, tag: str, build_number: int
) -> None:
    if (
        not re.fullmatch(r"[0-9a-f]{40}", commit)
        or not isinstance(build_number, int) or isinstance(build_number, bool) or build_number <= 0
        or not isinstance(tag, str) or tag != f"tuner-ios-build-{build_number}"
        or git_ref != f"refs/tags/{tag}"
    ):
        _fail("upload-capable archive must use the dedicated tag for its planned build number")
    try:
        result = subprocess.run(
            ["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], cwd=repo, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseHookError("could not verify the release tag's source commit") from error
    if result.returncode != 0 or result.stdout.strip() != commit:
        _fail("release tag does not identify the exact checked-out candidate commit")


def latest_public_review_status(commit: str, digest: str) -> dict[str, str]:
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        _fail("release review status input is invalid")
    url = f"https://api.github.com/repos/{TUNER_REPOSITORY}/commits/{commit}/status?per_page=100&page=1"
    statuses: list[dict[str, Any]] = []
    expected_path = f"/repos/{TUNER_REPOSITORY}/commits/{commit}/status"
    while url:
        request = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": GITHUB_USER_AGENT,
            "X-GitHub-Api-Version": "2022-11-28",
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status != 200:
                    _fail("release review status could not be read from GitHub")
                payload = json.loads(response.read().decode("utf-8"))
                link_header = response.headers.get("Link", "")
        except ReleaseHookError:
            raise
        except (urllib.error.URLError, TimeoutError, OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ReleaseHookError("release review status could not be read from GitHub") from error
        if not isinstance(payload, dict) or payload.get("sha") != commit:
            _fail("GitHub returned a release review status for a different commit")
        page_statuses = payload.get("statuses")
        if not isinstance(page_statuses, list) or any(not isinstance(item, dict) for item in page_statuses):
            _fail("GitHub release review status response is incomplete")
        statuses.extend(page_statuses)
        next_links = [
            target for target, relation in re.findall(r'<([^>]+)>;\s*rel="([^"]+)"', link_header)
            if relation == "next"
        ]
        if len(next_links) > 1:
            _fail("GitHub release review status pagination is ambiguous")
        if not next_links:
            url = ""
            continue
        next_url = urllib.parse.urlsplit(next_links[0])
        if (
            next_url.scheme != "https" or next_url.netloc != "api.github.com"
            or next_url.path != expected_path
        ):
            _fail("GitHub release review status pagination left the expected public endpoint")
        url = next_links[0]
    matching = [item for item in statuses if isinstance(item, dict) and item.get("context") == RELEASE_REVIEW_CONTEXT]
    if not matching:
        _fail("release reviewer confirmation is missing")
    times: list[tuple[datetime, dict[str, Any]]] = []
    for item in matching:
        stamp = item.get("updated_at") or item.get("created_at")
        if not isinstance(stamp, str):
            _fail("release reviewer confirmation timestamp is unreadable")
        try:
            parsed = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        except ValueError as error:
            raise ReleaseHookError("release reviewer confirmation timestamp is unreadable") from error
        if parsed.tzinfo is None:
            _fail("release reviewer confirmation timestamp has no timezone")
        times.append((parsed, item))
    latest_at = max(stamp for stamp, _ in times)
    latest = [item for stamp, item in times if stamp == latest_at]
    if len(latest) != 1:
        _fail("latest release reviewer confirmation is ambiguous")
    status = latest[0]
    if status.get("state") != "success":
        _fail("latest release reviewer confirmation is not successful")
    if status.get("description") != f"sha256:{digest}":
        _fail("latest release reviewer confirmation does not match the candidate digest")
    return {
        "context": RELEASE_REVIEW_CONTEXT,
        "state": "success",
        "description": f"sha256:{digest}",
    }


def validate_archive_report(
    report: dict[str, Any],
    *,
    candidate: dict[str, Any],
    baseline: dict[str, Any],
    pair: tuple[PublishedRelease, PublishedRelease],
    note_data: dict[str, Any],
    history_data: object,
    expected_ci_run_id: str,
) -> list[dict[str, Any]]:
    """Cross-check the machine-readable archive report against its inputs."""
    if report.get("schemaVersion") != 1:
        _fail("archive report is missing or has an unsupported schema version")
    if report.get("status") != "completed":
        _fail("archive report is incomplete or failed")
    report_candidate = report.get("candidate")
    if not isinstance(report_candidate, dict) or _candidate_key(report_candidate) != _candidate_key(candidate):
        _fail("archive report is for a different candidate")
    report_baseline = report.get("baseline")
    if not isinstance(report_baseline, dict) or _candidate_key(report_baseline) != _candidate_key(baseline):
        _fail("archive report is for a different preceding distributed build")
    producer = report.get("producer")
    if not isinstance(producer, dict) or producer.get("runId") != expected_ci_run_id:
        _fail("archive report is not bound to this Xcode Cloud run")
    if producer.get("sourceCommit") != candidate["commit"] or producer.get("sourceTree") != candidate["tree"]:
        _fail("archive report source identity does not match the candidate")
    if (
        producer.get("buildNumber") != candidate["buildNumber"]
        or producer.get("scheme") != candidate["scheme"]
        or producer.get("configuration") != candidate["configuration"]
        or type(producer.get("attempt")) is not int
        or producer["attempt"] != release_notes.XCODE_CLOUD_ATTEMPT_NUMBER
    ):
        _fail("archive report has a mismatched build, scheme, configuration, or attempt")
    expected_releases = [
        {
            "id": item.release_id, "tag": item.tag, "assetId": item.asset_id,
            "assetName": item.asset_name, "assetDigest": item.asset_digest,
        }
        for item in pair
    ]
    if report.get("releases") != expected_releases:
        _fail("archive report does not carry the pinned current and preceding releases")
    if report.get("currentNoteSha256") != note_digest(note_data):
        _fail("archive report note digest does not match the generated release note")
    detector = report.get("detectors")
    if not isinstance(detector, dict) or detector.get("status") != "completed":
        _fail("breaking-change detectors are missing, skipped, or failed")
    findings = detector.get("findings")
    if not isinstance(findings, list):
        _fail("detector report has no findings list")
    if any(
        not isinstance(row, dict)
        or any(
            not isinstance(row.get(field), str)
            for field in ("detectorId", "path", "before", "after")
        )
        or ("audience" in row and not isinstance(row["audience"], str))
        for row in findings
    ):
        _fail("detector findings are missing required before-and-after evidence")
    if findings != sorted(findings, key=lambda row: (
        row.get("detectorId", ""), row.get("path", ""), row.get("audience", ""),
        row.get("before", ""), row.get("after", ""),
    )):
        _fail("detector findings are not in deterministic order")
    if detector.get("findingsSha256") != findings_digest(findings):
        _fail("detector findings digest is invalid")
    runs = validate_compatibility_runs(
        report.get("compatibility", {}), candidate, pair, baseline=baseline,
        expected_ci_run_id=expected_ci_run_id
    )
    expected_findings = detect_breaking_changes(baseline, candidate, runs)
    if findings != expected_findings:
        _fail("detector findings do not match the measured baseline and candidate results")
    note = release_notes._note_from_data(note_data, expected_build=candidate["buildNumber"])
    compatibility = section_details(note, COMPATIBILITY_TITLE)
    if author_compatibility_line(compatibility, compatibility_line(pair)) != compatibility:
        _fail("generated compatibility line is missing or differs from the pinned release pair")
    findings = detector["findings"]
    breaking_digest = validate_breaking_section(note, findings)
    if report.get("breakingChangesSha256") != breaking_digest:
        _fail("archive report Breaking changes digest does not match the generated note")
    expected_object = candidate_object(candidate, baseline, pair, findings, note_data, history_data)
    expected_object_digest = candidate_object_digest(expected_object)
    if report.get("candidateObject") != expected_object:
        _fail("archive report candidate object differs from the measured inputs")
    if report.get("candidateObjectSha256") != expected_object_digest:
        _fail("archive report candidate object digest is invalid")
    pre_gate = report.get("preArchiveGate")
    if (
        not isinstance(pre_gate, dict)
        or pre_gate.get("status") != "passed"
        or pre_gate.get("sourceCommit") != candidate["commit"]
        or pre_gate.get("candidateDigest") != expected_object_digest
        or pre_gate.get("context") != RELEASE_REVIEW_CONTEXT
        or pre_gate.get("state") != "success"
        or pre_gate.get("description") != f"sha256:{expected_object_digest}"
    ):
        _fail("archive report does not contain a successful candidate-bound pre-archive review gate")
    for run in runs:
        if any(run["checks"][path]["status"] != "passed" for path in REQUIRED_CLIENT_CHECKS):
            _fail(f"candidate compatibility checks failed for Tightbeam {run['release']['tag']}")
    return runs


def _published_pair_from_archive_report(report: dict[str, Any]) -> tuple[PublishedRelease, PublishedRelease]:
    releases = report.get("releases")
    if not isinstance(releases, list) or len(releases) != 2:
        _fail("signed compatibility report must contain the two pinned published releases")
    parsed: list[PublishedRelease] = []
    for item in releases:
        if not isinstance(item, dict):
            _fail("signed compatibility report contains an invalid published release")
        release_id = item.get("id")
        tag = item.get("tag")
        asset_id = item.get("assetId")
        asset_name = item.get("assetName")
        asset_digest = item.get("assetDigest")
        if (
            not isinstance(release_id, int) or isinstance(release_id, bool) or release_id <= 0
            or not isinstance(tag, str)
            or not isinstance(asset_id, int) or isinstance(asset_id, bool) or asset_id <= 0
            or not isinstance(asset_name, str)
            or not isinstance(asset_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", asset_digest)
        ):
            _fail("signed compatibility report has an unverifiable release or asset identity")
        tag_match = re.fullmatch(r"v(\d+\.\d+\.\d+)(?:\+[A-Za-z0-9.-]+)?", tag)
        if tag_match is None:
            _fail("signed compatibility report has an invalid full Tightbeam release tag")
        expected_asset = re.compile(
            rf"tightbeam-{re.escape(tag_match.group(1))}-darwin-aarch64-[0-9a-f]{{7,40}}\.tgz"
        )
        if expected_asset.fullmatch(asset_name) is None:
            _fail("signed compatibility report asset name does not match its Darwin runtime tag")
        parsed.append(PublishedRelease(
            release_id=release_id,
            tag=tag,
            published_at="1970-01-01T00:00:00Z",
            asset_id=asset_id,
            asset_name=asset_name,
            asset_digest=asset_digest,
            download_url="https://github.com/clickety-clacks/tightbeam/releases/download/verified/runtime.tgz",
        ))
    if parsed[0].release_id == parsed[1].release_id or parsed[0].tag == parsed[1].tag:
        _fail("signed compatibility report does not contain two distinct published releases")
    return parsed[0], parsed[1]


def validate_signed_archive(
    report: dict[str, Any],
    note_data: dict[str, Any],
    history_data: object,
    app_info: dict[str, Any],
    *,
    expected_candidate: dict[str, Any],
    baseline_reference_data: dict[str, Any],
    expected_ci_run_id: str,
    expected_attempt: int,
    expected_build_number: int,
    expected_git_ref: str,
    expected_tag: str,
    repo: Path,
) -> None:
    """Verify that the signed app carries the completed archive-side evidence and note."""
    if app_info.get("CFBundleIdentifier") != "co.clicketyclacks.tightbeam-tuner":
        _fail("signed IPA is not the Tuner iOS app")
    if app_info.get("CFBundleVersion") != str(expected_build_number):
        _fail("signed IPA build number does not match the Xcode Cloud archive")
    minimum_os = app_info.get("MinimumOSVersion")
    families = app_info.get("UIDeviceFamily")
    if not isinstance(minimum_os, str) or not isinstance(families, list) or not families:
        _fail("signed IPA is missing its effective minimum OS or supported device families")
    if not all(isinstance(value, int) and not isinstance(value, bool) for value in families):
        _fail("signed IPA has invalid supported device-family metadata")

    report_candidate = report.get("candidate")
    if not isinstance(report_candidate, dict) or _candidate_key(report_candidate) != _candidate_key(expected_candidate):
        _fail("signed archive report does not match this Xcode Cloud checkout")
    if report_candidate.get("minimumOS") != minimum_os:
        _fail("signed IPA minimum OS does not match the compatibility detector input")
    reported_families = report_candidate.get("deviceFamilies")
    if not isinstance(reported_families, list) or sorted(str(value) for value in reported_families) != sorted(
        str(value) for value in families
    ):
        _fail("signed IPA supported device families do not match the detector input")
    report_baseline = report.get("baseline")
    if not isinstance(report_baseline, dict) or _candidate_key(report_baseline) != _candidate_key(
        baseline_reference_data
    ):
        _fail("signed archive report does not match the pinned preceding-build reference")
    producer = report.get("producer")
    if not isinstance(producer, dict):
        _fail("signed archive report has no Xcode Cloud producer identity")
    if (
        type(expected_attempt) is not int
        or expected_attempt != release_notes.XCODE_CLOUD_ATTEMPT_NUMBER
        or producer.get("runId") != expected_ci_run_id
        or type(producer.get("attempt")) is not int
        or producer.get("attempt") != release_notes.XCODE_CLOUD_ATTEMPT_NUMBER
    ):
        _fail("signed archive report belongs to another Xcode Cloud run or attempt")
    if not isinstance(history_data, list):
        _fail("signed app has no bundled release-note history")
    history = release_notes.notes_from_history_data(history_data)
    validate_history_claims(history)
    pair = _published_pair_from_archive_report(report)
    validate_archive_report(
        report,
        candidate=report_candidate,
        baseline=report_baseline,
        pair=pair,
        note_data=note_data,
        history_data=history_data,
        expected_ci_run_id=expected_ci_run_id,
    )
    validate_release_tag_identity(
        repo, report_candidate["commit"], expected_git_ref, expected_tag,
        report_candidate["buildNumber"],
    )
    current_pair = resolve_published_pair("darwin-aarch64")
    same_release_pair(pair, current_pair)
    digest = report["candidateObjectSha256"]
    latest_public_review_status(report_candidate["commit"], digest)
    report["finalArchiveGate"] = {
        "status": "passed",
        "sourceCommit": report_candidate["commit"],
        "candidateDigest": digest,
        "context": RELEASE_REVIEW_CONTEXT,
        "state": "success",
        "description": f"sha256:{digest}",
        "releasePairUnchanged": True,
    }
