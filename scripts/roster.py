#!/usr/bin/env python3
"""Read the authorized Tightbeam roster and produce safe UI data."""

import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlencode, urlsplit, urlunsplit


def origin(value: str, label: str) -> str:
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")):
        raise ValueError(f"{label} must be an HTTP(S) origin without credentials or a path")
    return urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))


def load_config() -> dict:
    config_path = Path(os.environ.get(
        "TIGHTBEAM_TUNER_CONFIG",
        Path.home() / ".config/tightbeam-tuner/config.json",
    ))
    config = json.loads(config_path.read_text())
    command = config.get("rosterCommand")
    if not isinstance(command, list) or not command or not all(
        isinstance(part, str) and part for part in command
    ):
        raise ValueError("rosterCommand must be a nonempty array of command arguments")
    config["chatBase"] = origin(config["chatBase"], "chatBase")
    config["gatewayOrigin"] = origin(config["gatewayOrigin"], "gatewayOrigin")
    return config


def normalize(config: dict, roster: dict) -> dict:
    sessions = roster.get("sessions")
    if not isinstance(sessions, list):
        raise ValueError("The roster has no sessions array")
    agents = []
    for session in sessions:
        if session.get("state") != "active":
            continue
        key = session.get("sessionKey")
        name = session.get("displayName")
        if not isinstance(key, str) or not isinstance(name, str) or not key or not name:
            continue
        query = urlencode({"gateway": config["gatewayOrigin"], "session": key})
        agents.append({
            "key": key,
            "name": name,
            "parent": session.get("currentParent") or session.get("topologyParent") or "",
            "archetype": session.get("archetype") or "unknown",
            "url": config["chatBase"] + "/?" + query,
        })
    return {"agents": agents}


def main() -> int:
    try:
        config = load_config()
        completed = subprocess.run(config["rosterCommand"], capture_output=True,
                                   text=True, timeout=20, check=True)
        print(json.dumps(normalize(config, json.loads(completed.stdout))))
        return 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        # Never echo CLI output: it can contain deployment details.
        print(json.dumps({"error": type(exc).__name__ + ": " + str(exc)[:180]}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
