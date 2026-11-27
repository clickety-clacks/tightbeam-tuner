#!/usr/bin/env python3
"""Materialize the configured release app identity in the Xcode project."""

from __future__ import annotations

import os
import re
import stat
import sys
import tempfile
from pathlib import Path

import release_hook


SETTING = "TUNER_EXPECTED_BUNDLE_IDENTIFIER"
SETTING_PATTERN = re.compile(
    rf'(?m)^(?P<indent>[ \t]*){SETTING}[ \t]*=[ \t]*"[^"\r\n]*";[ \t]*$'
)
PRODUCT_PATTERN = re.compile(
    r'(?m)^[ \t]*PRODUCT_BUNDLE_IDENTIFIER[ \t]*=[ \t]*"\$\(TUNER_EXPECTED_BUNDLE_IDENTIFIER\)";[ \t]*$'
)


def configure_project(project_path: Path) -> str:
    """Set the app target's Debug and Release identity from the selected route."""
    identifier = release_hook.expected_bundle_identifier()
    path = Path(project_path)
    try:
        original = path.read_text(encoding="utf-8")
        mode = stat.S_IMODE(path.stat().st_mode)
    except OSError as error:
        raise release_hook.ReleaseHookError("Xcode project bundle identity settings are unavailable") from error

    if len(PRODUCT_PATTERN.findall(original)) != 2:
        raise release_hook.ReleaseHookError("Xcode project does not bind both app configurations to the route identity")

    replacement = rf'\g<indent>{SETTING} = "{identifier}";'
    updated, count = SETTING_PATTERN.subn(replacement, original)
    if count != 2:
        raise release_hook.ReleaseHookError("Xcode project must contain exactly two app bundle identity settings")
    if updated == original:
        return identifier

    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="", dir=path.parent,
            prefix=f".{path.name}.", suffix=".tmp", delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            temporary.write(updated)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
        temporary_path = None
    except OSError as error:
        raise release_hook.ReleaseHookError("Xcode project bundle identity could not be configured") from error
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return identifier


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: configure_bundle_identifier.py <project.pbxproj>", file=sys.stderr)
        return 2
    try:
        configure_project(Path(argv[1]))
    except (OSError, release_hook.ReleaseHookError) as error:
        print(f"release-note gate: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
