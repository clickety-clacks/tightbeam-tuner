#!/usr/bin/env python3
"""Select and render the exact release note used by Tuner's app and TestFlight."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import sys
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
    marker = re.search(r"static\s+let\s+all\s*:\s*\[ReleaseNote\]\s*=\s*\[", source)
    if marker is None:
        raise ReleaseNoteError("could not find ReleaseNotes.all in the Swift source")
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
        raise ReleaseNoteError("ReleaseNotes.all contains no numbered notes")
    builds = [note.build for note in notes]
    if len(set(builds)) != len(builds):
        raise ReleaseNoteError("ReleaseNotes.all contains duplicate build numbers")
    if builds != sorted(builds, reverse=True):
        raise ReleaseNoteError("ReleaseNotes.all must remain sorted newest build first")
    return tuple(notes)


def exact_note(notes: tuple[Note, ...], build_number: int) -> Note:
    for note in notes:
        if note.build == build_number:
            return note
    raise ReleaseNoteError(f"no user-facing release notes are recorded for build {build_number}")


def _default_source() -> Path:
    return Path(__file__).resolve().parent.parent / "TightbeamTuner" / "ReleaseNotes.swift"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("validate", "render"))
    parser.add_argument("--build-number", required=True, type=int)
    parser.add_argument("--source", type=Path, default=_default_source())
    parser.add_argument("--app-path", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)

    if args.build_number <= 0:
        parser.error("--build-number must be a positive integer")
    if args.action == "render" and args.output is None:
        parser.error("render requires --output")

    try:
        notes = load_notes(args.source)
        note = exact_note(notes, args.build_number)
        if args.app_path is not None:
            info_path = args.app_path / "Info.plist"
            try:
                with info_path.open("rb") as info_file:
                    info = plistlib.load(info_file)
            except (OSError, plistlib.InvalidFileException, ValueError) as error:
                raise ReleaseNoteError(f"could not read archived app Info.plist: {error}") from error
            app_build = info.get("CFBundleVersion") if isinstance(info, dict) else None
            if not isinstance(app_build, str) or not app_build.isdigit() or int(app_build) <= 0:
                raise ReleaseNoteError("the archived app has no numeric CFBundleVersion")
            if app_build != str(args.build_number):
                raise ReleaseNoteError(
                    f"archive CFBundleVersion {app_build} does not match build {args.build_number}"
                )
        text = note.tester_text()
        if not text.strip():
            raise ReleaseNoteError(f"release notes for build {args.build_number} are empty")
        if args.action == "render":
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_name(args.output.name + ".tmp")
            temporary.write_text(text, encoding="utf-8")
            os.replace(temporary, args.output)
            print(f"Generated TestFlight notes for build {args.build_number} from ReleaseNotes.swift.")
        else:
            print(f"Found {len(note.items)} user-facing note item(s) for build {args.build_number}.")
    except (OSError, ReleaseNoteError) as error:
        print(f"release-note gate: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
