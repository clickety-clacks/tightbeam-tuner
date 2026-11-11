#!/usr/bin/env python3
"""Select and render the exact release note used by Tuner's app and TestFlight."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path


class ReleaseNoteError(ValueError):
    pass


@dataclass(frozen=True)
class NoteItem:
    title: str
    detail: str


@dataclass(frozen=True)
class Note:
    build: int
    items: tuple[NoteItem, ...]

    def tester_text(self) -> str:
        return "\n\n".join(f"{item.title}\n{item.detail}" for item in self.items) + "\n"


STRING = r'"(?:\\.|[^"\\])*"'
ENTRY_HEADER = re.compile(
    rf"\s*version:\s*({STRING})\s*,\s*build:\s*(\d+)\s*,\s*"
    rf"date:\s*({STRING})\s*,\s*items:\s*\[",
    re.DOTALL,
)
ITEM_FIELDS = re.compile(
    rf"\s*symbol:\s*({STRING})\s*,\s*title:\s*({STRING})\s*,\s*"
    rf"detail:\s*({STRING})\s*",
    re.DOTALL,
)


def _balanced_end(source: str, open_index: int, opening: str, closing: str) -> int:
    if open_index >= len(source) or source[open_index] != opening:
        raise ReleaseNoteError(f"expected {opening!r} at source offset {open_index}")

    depth = 0
    in_string = False
    escaped = False
    in_line_comment = False
    index = open_index
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == "/" and next_char == "/":
            in_line_comment = True
            index += 1
        elif char == '"':
            in_string = True
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
        index += 1

    raise ReleaseNoteError(f"unterminated {opening}{closing} group")


def _code_occurrences(source: str, token: str):
    """Yield token offsets outside Swift strings and line comments."""
    in_string = False
    escaped = False
    in_line_comment = False
    index = 0
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if in_line_comment:
            if char == "\n":
                in_line_comment = False
        elif in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == "/" and next_char == "/":
            in_line_comment = True
            index += 1
        elif char == '"':
            in_string = True
        elif source.startswith(token, index):
            before_ok = index == 0 or not (source[index - 1].isalnum() or source[index - 1] == "_")
            end = index + len(token)
            after_ok = end == len(source) or not (source[end].isalnum() or source[end] == "_")
            if before_ok and after_ok:
                yield index
            index = end - 1
        index += 1


def _decode_string(literal: str) -> str:
    try:
        value = json.loads(literal)
    except json.JSONDecodeError as error:
        raise ReleaseNoteError(f"unsupported Swift string literal {literal!r}: {error}") from error
    if not isinstance(value, str):
        raise ReleaseNoteError("release-note field is not a string")
    return value


def _parse_item(item_source: str) -> NoteItem:
    match = ITEM_FIELDS.fullmatch(item_source)
    if match is None:
        raise ReleaseNoteError("unrecognized release-note item; expected symbol, title, and detail")
    title = _decode_string(match.group(2)).strip()
    detail = _decode_string(match.group(3)).strip()
    if not title or not detail:
        raise ReleaseNoteError("release-note titles and details must not be empty")
    return NoteItem(title=title, detail=detail)


def _parse_entry(entry_source: str) -> Note:
    opening = entry_source.find("(")
    end = _balanced_end(entry_source, opening, "(", ")")
    if entry_source[end + 1 :].strip():
        raise ReleaseNoteError("unexpected text after a ReleaseNote entry")
    body = entry_source[opening + 1 : end]
    header = ENTRY_HEADER.match(body)
    if header is None:
        raise ReleaseNoteError("unrecognized ReleaseNote entry header")

    items_open = body.find("[", header.end() - 1)
    items_close = _balanced_end(body, items_open, "[", "]")
    if body[items_close + 1 :].strip():
        raise ReleaseNoteError("unexpected fields after ReleaseNote items")
    items_source = body[items_open + 1 : items_close]

    items: list[NoteItem] = []
    spans: list[tuple[int, int]] = []
    for offset in _code_occurrences(items_source, ".init"):
        open_index = items_source.find("(", offset + len(".init"))
        if open_index < 0:
            raise ReleaseNoteError("release-note item is missing its argument list")
        close_index = _balanced_end(items_source, open_index, "(", ")")
        items.append(_parse_item(items_source[open_index + 1 : close_index]))
        spans.append((offset, close_index + 1))

    residue = items_source
    for start, end in reversed(spans):
        residue = residue[:start] + residue[end:]
    if re.sub(r"[\s,]+", "", residue):
        raise ReleaseNoteError("unrecognized content in ReleaseNote items")
    if not items:
        raise ReleaseNoteError("each numbered build must have at least one release-note item")

    return Note(build=int(header.group(2)), items=tuple(items))


def load_notes(source_path: Path) -> tuple[Note, ...]:
    source = source_path.read_text(encoding="utf-8")
    marker = re.search(r"static\s+let\s+history\s*:\s*\[ReleaseNote\]\s*=\s*\[", source)
    if marker is None:
        raise ReleaseNoteError("could not find ReleaseNotes.history in the Swift source")
    array_open = marker.end() - 1
    array_close = _balanced_end(source, array_open, "[", "]")
    array_source = source[array_open + 1 : array_close]

    notes: list[Note] = []
    for offset in _code_occurrences(array_source, "ReleaseNote"):
        call_open = array_source.find("(", offset + len("ReleaseNote"))
        if call_open < 0 or array_source[offset + len("ReleaseNote") : call_open].strip():
            raise ReleaseNoteError("unrecognized ReleaseNote constructor")
        call_close = _balanced_end(array_source, call_open, "(", ")")
        notes.append(_parse_entry(array_source[offset : call_close + 1]))

    if not notes:
        raise ReleaseNoteError("ReleaseNotes.history contains no numbered notes")
    builds = [note.build for note in notes]
    if len(set(builds)) != len(builds):
        raise ReleaseNoteError("ReleaseNotes.history contains duplicate build numbers")
    if builds != sorted(builds, reverse=True):
        raise ReleaseNoteError("ReleaseNotes.history must remain sorted newest build first")
    return tuple(notes)


def exact_note(notes: tuple[Note, ...], build_number: int) -> Note:
    for note in notes:
        if note.build == build_number:
            return note
    raise ReleaseNoteError(f"no user-facing release notes are recorded for build {build_number}")


def _default_source() -> Path:
    return Path(__file__).resolve().parent.parent / "TightbeamTuner" / "ReleaseNotes.swift"


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


def _signed_export_app_info(signed_app_path: Path) -> dict:
    """Read the sole app Info.plist from Xcode Cloud's TestFlight-signed IPA."""
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
            app_info_entries = sorted({
                name
                for name in ipa_entries
                if name.startswith("Payload/")
                and name.endswith(".app/Info.plist")
                and name.count("/") == 2
            })
            app_bundles = [name.rsplit("/", 1)[0] for name in app_info_entries]
            if len(app_bundles) != 1:
                raise ReleaseNoteError(
                    "the Xcode Cloud signed IPA must contain exactly one app bundle; "
                    f"found {len(app_bundles)}; export entries: {_entry_names(export_entries)}; "
                    f"IPA entries: {_entry_names(ipa_entries)}"
                )
            with ipa.open(app_info_entries[0]) as info_file:
                info = plistlib.load(info_file)
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
    return info


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("validate", "render"))
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--source", type=Path, default=_default_current_source())
    parser.add_argument("--history", type=Path, default=_default_source())
    parser.add_argument("--signed-app-path", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    if args.build_number <= 0:
        parser.error("--build-number must be a positive integer")
    if args.action == "render" and args.output is None:
        parser.error("render requires --output")

    try:
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
            temporary = args.output.with_name(args.output.name + ".tmp")
            temporary.write_text(text, encoding="utf-8")
            os.replace(temporary, args.output)
            print(f"Generated TestFlight notes for build {args.build_number} from the bundled release-note data.")
        else:
            print(f"Found {len(note.items)} user-facing note item(s) for build {args.build_number}.")
    except (OSError, ReleaseNoteError) as error:
        print(f"release-note gate: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
