#!/usr/bin/env python3
"""Select and render the exact release note used by Tuner's app and TestFlight."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sys
import subprocess
import zipfile
from dataclasses import dataclass, field
from pathlib import Path


class ReleaseNoteError(ValueError):
    pass


# Xcode Cloud's CI_BUILD_ID uniquely identifies each run. It does not expose
# an attempt counter; this release hook executes one matrix invocation per run.
XCODE_CLOUD_ATTEMPT_NUMBER = 1


@dataclass(frozen=True)
class NoteItem:
    title: str
    detail: str
    symbol: str = field(default="", compare=False)


@dataclass(frozen=True)
class Note:
    build: int
    items: tuple[NoteItem, ...]
    version: str = field(default="1.0", compare=False)
    date: str = field(default="", compare=False)

    def tester_text(self) -> str:
        return "\n\n".join(f"{item.title}\n{item.detail}" for item in self.items) + "\n"


def _note_from_history_data(value: object) -> Note:
    if not isinstance(value, dict):
        raise ReleaseNoteError("each bundled history entry must be a JSON object")
    version, date, build, item_values = (
        value.get("version"), value.get("date"), value.get("build"), value.get("items")
    )
    if not isinstance(version, str) or not version.strip():
        raise ReleaseNoteError("history release-note version must not be empty")
    if not isinstance(date, str) or not date.strip():
        raise ReleaseNoteError("history release-note date must not be empty")
    if not isinstance(build, int) or isinstance(build, bool) or build <= 0:
        raise ReleaseNoteError("history release-note build must be a positive integer")
    if not isinstance(item_values, list) or not item_values:
        raise ReleaseNoteError("each history release note must contain items")
    items: list[NoteItem] = []
    for value in item_values:
        if not isinstance(value, dict):
            raise ReleaseNoteError("history release-note item must be a JSON object")
        symbol, title, detail = value.get("symbol"), value.get("title"), value.get("detail")
        if not all(isinstance(part, str) and part.strip() for part in (symbol, title, detail)):
            raise ReleaseNoteError("history release-note symbols, titles, and details must not be empty")
        items.append(NoteItem(title=title.strip(), detail=detail.strip(), symbol=symbol.strip()))
    return Note(build=build, items=tuple(items), version=version.strip(), date=date.strip())


def notes_from_history_data(value: object) -> tuple[Note, ...]:
    if not isinstance(value, list):
        raise ReleaseNoteError("bundled release-note history must be a JSON array")
    notes = tuple(_note_from_history_data(item) for item in value)
    builds = [note.build for note in notes]
    if len(set(builds)) != len(builds):
        raise ReleaseNoteError("ReleaseNotes.history contains duplicate build numbers")
    if builds != sorted(builds, reverse=True):
        raise ReleaseNoteError("ReleaseNotes.history must remain sorted newest build first")
    return notes


def load_notes(source_path: Path) -> tuple[Note, ...]:
    source = source_path.read_text(encoding="utf-8")
    try:
        values = json.loads(source)
    except json.JSONDecodeError as error:
        raise ReleaseNoteError(f"could not parse bundled release-note history as JSON: {error}") from error
    return notes_from_history_data(values)


def exact_note(notes: tuple[Note, ...], build_number: int) -> Note:
    for note in notes:
        if note.build == build_number:
            return note
    raise ReleaseNoteError(f"no user-facing release notes are recorded for build {build_number}")


def _default_source() -> Path:
    return Path(__file__).resolve().parent.parent / "TightbeamTuner" / "ReleaseNotesHistory.json"


def _default_current_source() -> Path:
    return Path(__file__).resolve().parent.parent / "TightbeamTuner" / "CurrentBuildReleaseNote.json"


def _note_from_data(
    data: dict, expected_build: int | None = None, allow_unbound: bool = False
) -> Note:
    if not isinstance(data, dict):
        raise ReleaseNoteError("current-build release note must be a JSON object")

    version = data.get("version")
    date = data.get("date")
    build = data.get("build")
    items_value = data.get("items")
    if not isinstance(version, str) or not version.strip():
        raise ReleaseNoteError("release-note version must not be empty")
    if not isinstance(date, str):
        raise ReleaseNoteError("release-note date must be a string")
    if not isinstance(build, int) or isinstance(build, bool) or build < 0:
        raise ReleaseNoteError("release-note build must be a nonnegative integer")
    if not isinstance(items_value, list) or not items_value:
        raise ReleaseNoteError("no user-facing release notes are recorded for this build")

    items: list[NoteItem] = []
    for item in items_value:
        if not isinstance(item, dict):
            raise ReleaseNoteError("release-note item must be a JSON object")
        symbol, title, detail = item.get("symbol"), item.get("title"), item.get("detail")
        if not all(isinstance(value, str) and value.strip() for value in (symbol, title, detail)):
            raise ReleaseNoteError("release-note symbols, titles, and details must not be empty")
        items.append(NoteItem(title=title.strip(), detail=detail.strip()))

    if expected_build is not None and build != expected_build:
        raise ReleaseNoteError(
            f"current-build release note is bound to build {build}, not build {expected_build}"
        )
    if build > 0 and not date.strip():
        raise ReleaseNoteError("numbered release notes must include a date")
    if build == 0 and not allow_unbound:
        raise ReleaseNoteError("current-build release note is not bound to a numbered build")
    return Note(build=build, items=tuple(items))


def load_current_note(source_path: Path, expected_build: int | None = None) -> tuple[Note, dict]:
    try:
        data = json.loads(source_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseNoteError(f"could not read the current-build release note: {error}") from error
    note = _note_from_data(data, expected_build=expected_build, allow_unbound=expected_build is None)
    return note, data


def _validate_current_build_against_history(note: Note, history_path: Path) -> None:
    history = load_notes(history_path)
    builds = {entry.build for entry in history}
    if note.build in builds:
        raise ReleaseNoteError(f"build {note.build} already has a historical release-note entry")
    if note.build <= history[0].build:
        raise ReleaseNoteError(
            f"build {note.build} does not follow latest historical note {history[0].build}"
        )


def validate_premerge_note(
    source_path: Path,
    history_path: Path,
    base_note_path: Path,
    pr_description: str | None = None,
) -> Note:
    """Require an author-bound note newer than both the base and shipped history."""
    note, _ = load_current_note(source_path)
    base_note, _ = load_current_note(base_note_path)
    if note.build <= 0:
        raise ReleaseNoteError("current-build release note is not bound to a numbered build")

    if note.build <= base_note.build:
        raise ReleaseNoteError(
            f"current release note build {note.build} must be greater than base note build {base_note.build}"
        )

    history = load_notes(history_path)
    history_builds = {entry.build for entry in history}
    if note.build in history_builds:
        raise ReleaseNoteError(
            f"current release note build {note.build} already appears in release-note history"
        )
    latest_history_build = max(history_builds)
    if note.build <= latest_history_build:
        raise ReleaseNoteError(
            f"current release note build {note.build} must be greater than latest historical note {latest_history_build}"
        )

    if pr_description is not None:
        declared_builds = re.findall(
            r"(?im)^Release note build number:\s*(\d+)\s*$", pr_description
        )
        if len(declared_builds) != 1:
            raise ReleaseNoteError(
                "PR description must contain exactly one `Release note build number: <build>` line"
            )
        if int(declared_builds[0]) != note.build:
            raise ReleaseNoteError(
                f"PR description names release-note build {declared_builds[0]}, but the current note is bound to build {note.build}"
            )

        observed_runs = re.findall(
            r"(?im)^Build number source:\s*latest Xcode Cloud run\s+#?(\d+)\b.*$",
            pr_description,
        )
        if len(observed_runs) != 1:
            raise ReleaseNoteError(
                "PR description must contain exactly one `Build number source: latest Xcode Cloud run <observed-number>` line"
            )
        observed_run = int(observed_runs[0])
        if note.build != observed_run + 1:
            raise ReleaseNoteError(
                f"current release note build {note.build} must be one greater than observed latest Xcode Cloud run {observed_run}"
            )

    compatibility_items = [item for item in note.items if item.title.casefold() == "compatibility"]
    if len(compatibility_items) != 1:
        raise ReleaseNoteError(
            "premerge release note must contain exactly one `Compatibility` item"
        )
    compatibility = compatibility_items[0].detail
    if not re.search(r"\bChat\s+v?\d+\.\d+\.\d+\b", compatibility, re.IGNORECASE):
        raise ReleaseNoteError(
            "premerge Compatibility item must name a Chat semantic version"
        )
    breaking_items = [item for item in note.items if item.title.casefold() == "breaking changes"]
    if len(breaking_items) != 1:
        raise ReleaseNoteError(
            "premerge release note must contain exactly one `Breaking changes` item"
        )

    return note


def note_for_build(source_path: Path, history_path: Path, build_number: int) -> Note:
    if build_number <= 0:
        raise ReleaseNoteError("Xcode Cloud build number must be positive")

    history = load_notes(history_path)
    try:
        return exact_note(history, build_number)
    except ReleaseNoteError:
        pass

    try:
        current, _ = load_current_note(source_path)
    except ReleaseNoteError:
        raise

    if current.build == 0:
        raise ReleaseNoteError(
            f"no exact user-facing release notes are recorded for build {build_number}; "
            "the current draft is not assigned to a numbered build"
        )
    _validate_current_build_against_history(current, history_path)
    if current.build == build_number:
        return current
    try:
        return exact_note(history, build_number)
    except ReleaseNoteError:
        raise ReleaseNoteError(
            f"no exact user-facing release notes are recorded for build {build_number}; "
            f"the current draft is assigned to build {current.build}"
        )


def _entry_names(names: list[str]) -> str:
    """Format names only for refusal diagnostics, keeping CI logs bounded."""
    ordered = sorted(set(names))
    shown = ordered[:40]
    summary = ", ".join(shown) if shown else "(none)"
    if len(ordered) > len(shown):
        summary += f", ... ({len(ordered) - len(shown)} more entries)"
    return summary


def _signed_export_app_contents(signed_app_path: Path, resource_names: tuple[str, ...] = ()) -> tuple[dict, dict[str, bytes]]:
    """Read the sole app Info.plist and selected resources from the signed IPA."""
    if not signed_app_path.is_dir():
        raise ReleaseNoteError("the Xcode Cloud signed-app export path is not a directory")
    try:
        export_entries = sorted(entry.name for entry in signed_app_path.iterdir())
    except OSError as error:
        raise ReleaseNoteError("could not list the Xcode Cloud signed-app export directory") from error

    ipa_paths = [
        signed_app_path / name
        for name in export_entries
        if name.lower().endswith(".ipa") and (signed_app_path / name).is_file()
    ]
    if len(ipa_paths) != 1:
        raise ReleaseNoteError(
            "the Xcode Cloud signed-app export must contain exactly one IPA; "
            f"found {len(ipa_paths)}; export entries: {_entry_names(export_entries)}"
        )

    ipa_path = ipa_paths[0]
    ipa_entries: list[str] = []
    try:
        with zipfile.ZipFile(ipa_path) as ipa:
            ipa_entries = ipa.namelist()
            app_info_entries = sorted(
                name
                for name in ipa_entries
                if name.startswith("Payload/")
                and name.endswith(".app/Info.plist")
                and name.count("/") == 2
            )
            app_bundles = [name.rsplit("/", 1)[0] for name in app_info_entries]
            if len(app_bundles) != 1 or len(set(app_bundles)) != 1:
                raise ReleaseNoteError(
                    "the Xcode Cloud signed IPA must contain exactly one app bundle; "
                    f"found {len(app_bundles)}; export entries: {_entry_names(export_entries)}; "
                    f"IPA entries: {_entry_names(ipa_entries)}"
                )
            with ipa.open(app_info_entries[0]) as info_file:
                info = plistlib.load(info_file)
            bundle_root = app_bundles[0]
            resources: dict[str, bytes] = {}
            for resource_name in resource_names:
                archive_name = f"{bundle_root}/{resource_name}"
                matches = [entry for entry in ipa.infolist() if entry.filename == archive_name]
                if len(matches) != 1:
                    raise ReleaseNoteError(
                        f"the signed app is missing one {resource_name} resource"
                    )
                resources[resource_name] = ipa.read(matches[0])
    except zipfile.BadZipFile as error:
        raise ReleaseNoteError(
            "the Xcode Cloud signed app is not a readable IPA; "
            f"export entries: {_entry_names(export_entries)}"
        ) from error
    except ReleaseNoteError:
        raise
    except (OSError, KeyError, RuntimeError, plistlib.InvalidFileException, ValueError) as error:
        raise ReleaseNoteError(
            "could not read the app Info.plist in the Xcode Cloud signed IPA; "
            f"IPA entries: {_entry_names(ipa_entries)}"
        ) from error
    if not isinstance(info, dict):
        raise ReleaseNoteError(
            "the app Info.plist in the Xcode Cloud signed IPA is not a dictionary; "
            f"IPA entries: {_entry_names(ipa_entries)}"
        )
    return info, resources


def _signed_export_app_info(signed_app_path: Path) -> dict:
    """Read the sole app Info.plist from Xcode Cloud's TestFlight-signed IPA."""
    info, _ = _signed_export_app_contents(signed_app_path)
    return info


def _decode_signed_json(resources: dict[str, bytes], name: str) -> object:
    try:
        return json.loads(resources[name].decode("utf-8"))
    except (KeyError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseNoteError(f"the signed app's {name} resource is invalid JSON") from error


def _validate_signed_candidate(signed_app_path: Path, build_number: int) -> tuple[Note, dict, object, dict]:
    info, resources = _signed_export_app_contents(
        signed_app_path,
        ("CurrentBuildReleaseNote.json", "ReleaseNotesHistory.json", "ReleaseCompatibilityReport.json"),
    )
    note_data = _decode_signed_json(resources, "CurrentBuildReleaseNote.json")
    history_data = _decode_signed_json(resources, "ReleaseNotesHistory.json")
    report = _decode_signed_json(resources, "ReleaseCompatibilityReport.json")
    if not isinstance(note_data, dict) or not isinstance(report, dict):
        raise ReleaseNoteError("the signed app note or compatibility report has an invalid shape")

    commit = os.environ.get("CI_COMMIT", "")
    run_id = os.environ.get("CI_BUILD_ID", "")
    scheme = os.environ.get("CI_XCODE_SCHEME", "")
    configuration = "Release"
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not run_id or not scheme:
        raise ReleaseNoteError("Xcode Cloud candidate identity is incomplete during signed-export verification")
    repo = Path(os.environ.get("CI_PRIMARY_REPOSITORY_PATH", Path(__file__).resolve().parents[2])).resolve()
    try:
        tree_result = subprocess.run(
            ["git", "rev-parse", "HEAD^{tree}"], cwd=repo, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=15, check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseNoteError("could not verify the signed candidate Git tree") from error
    tree = tree_result.stdout.strip()
    if tree_result.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", tree):
        raise ReleaseNoteError("could not verify the signed candidate Git tree")

    baseline_path = repo / "ios" / "ci_scripts" / "ReleaseBaseline.json"
    try:
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseNoteError("the pinned preceding-build reference is unreadable") from error
    if not isinstance(baseline, dict):
        raise ReleaseNoteError("the pinned preceding-build reference is invalid")
    expected_candidate = {
        "commit": commit,
        "tree": tree,
        "scheme": scheme,
        "configuration": configuration,
        "buildNumber": build_number,
    }
    expected_baseline = {
        "commit": baseline.get("sourceCommit"),
        "tree": baseline.get("sourceTree"),
        "scheme": baseline.get("scheme"),
        "configuration": baseline.get("configuration"),
        "buildNumber": baseline.get("buildNumber"),
    }
    try:
        import release_hook

        git_ref = os.environ.get("CI_GIT_REF", "")
        tag = os.environ.get("CI_TAG", "")
        release_hook.validate_signed_archive(
            report,
            note_data,
            history_data,
            info,
            expected_candidate=expected_candidate,
            baseline_reference_data=expected_baseline,
            expected_ci_run_id=run_id,
            expected_attempt=XCODE_CLOUD_ATTEMPT_NUMBER,
            expected_build_number=build_number,
            expected_git_ref=git_ref,
            expected_tag=tag,
            repo=repo,
        )
        note = _note_from_data(note_data, expected_build=build_number)
    except release_hook.ReleaseHookError as error:
        raise ReleaseNoteError(str(error)) from error
    return note, note_data, history_data, report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("validate", "render", "premerge"))
    parser.add_argument("--build-number", type=int)
    parser.add_argument("--source", type=Path, default=_default_current_source())
    parser.add_argument("--history", type=Path, default=_default_source())
    parser.add_argument("--base-note", type=Path)
    parser.add_argument("--require-pr-provenance", action="store_true")
    parser.add_argument("--signed-app-path", type=Path)
    parser.add_argument("--require-archive-evidence", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    if args.action in ("validate", "render") and args.build_number is None:
        parser.error(f"{args.action} requires --build-number")
    if args.build_number is not None and args.build_number <= 0:
        parser.error("--build-number must be a positive integer")
    if args.action == "render" and args.output is None:
        parser.error("render requires --output")
    if args.action == "premerge" and args.base_note is None:
        parser.error("premerge requires --base-note")
    if args.action == "premerge" and args.signed_app_path is not None:
        parser.error("premerge does not accept --signed-app-path")
    if args.require_archive_evidence and (args.action != "render" or args.signed_app_path is None):
        parser.error("--require-archive-evidence requires render and --signed-app-path")
    if args.action == "premerge" and args.output is not None:
        parser.error("premerge does not accept --output")
    if args.require_pr_provenance and args.action != "premerge":
        parser.error("--require-pr-provenance is only valid for premerge")

    try:
        if args.action == "premerge":
            description = os.environ.get("TUNER_PR_DESCRIPTION", "") if args.require_pr_provenance else None
            note = validate_premerge_note(
                args.source,
                args.history,
                args.base_note,
                pr_description=description,
            )
            print(f"Release note build {note.build} is fresh against the base and history.")
            return 0

        if args.signed_app_path is not None and args.require_archive_evidence:
            if args.action != "render":
                parser.error("--signed-app-path is only valid for render")
            note, _, _, gate_report = _validate_signed_candidate(args.signed_app_path, args.build_number)
        else:
            note = note_for_build(args.source, args.history, args.build_number)
            if args.signed_app_path is not None:
                info = _signed_export_app_info(args.signed_app_path)
                app_build = info.get("CFBundleVersion")
                if not isinstance(app_build, str) or not app_build.isdigit() or int(app_build) <= 0:
                    raise ReleaseNoteError("the signed app has no numeric CFBundleVersion")
                if app_build != str(args.build_number):
                    raise ReleaseNoteError(
                        f"signed app CFBundleVersion {app_build} does not match build {args.build_number}"
                    )
        text = note.tester_text()
        if not text.strip():
            raise ReleaseNoteError(f"release notes for build {args.build_number} are empty")
        if args.action == "render":
            args.output.parent.mkdir(parents=True, exist_ok=True)
            if args.require_archive_evidence:
                gate_outcome = {
                    "schemaVersion": 1,
                    "candidate": gate_report.get("candidateObject"),
                    "candidateObjectSha256": gate_report.get("candidateObjectSha256"),
                    "preArchiveGate": gate_report.get("preArchiveGate"),
                    "finalArchiveGate": gate_report.get("finalArchiveGate"),
                }
                if not all(isinstance(gate_outcome[key], dict) for key in (
                    "candidate", "preArchiveGate", "finalArchiveGate"
                )) or not isinstance(gate_outcome["candidateObjectSha256"], str):
                    raise ReleaseNoteError("signed archive has incomplete captured release-gate outcomes")
                outcome_path = args.output.parent / "ReleaseGateOutcome.json"
                outcome_temporary = outcome_path.with_name(outcome_path.name + ".tmp")
                outcome_temporary.write_text(
                    json.dumps(gate_outcome, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
                    encoding="utf-8",
                )
                os.replace(outcome_temporary, outcome_path)
            temporary = args.output.with_name(args.output.name + ".tmp")
            temporary.write_text(text, encoding="utf-8")
            os.replace(temporary, args.output)
            source = "the signed app note" if args.require_archive_evidence else "the selected release-note data"
            print(f"Generated TestFlight notes for build {args.build_number} from {source}.")
        else:
            print(f"Found {len(note.items)} user-facing note item(s) for build {args.build_number}.")
    except (OSError, ReleaseNoteError) as error:
        print(f"release-note gate: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
