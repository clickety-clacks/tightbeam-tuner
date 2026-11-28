#!/usr/bin/env python3
"""Read the authorized Tightbeam roster and produce safe UI data."""

import json
import subprocess
import sys
from urllib.parse import urlencode

try:
    from .settings import load_config, origin
except ImportError:  # Direct execution from the installed scripts directory.
    from settings import load_config, origin


def normalize(config: dict, roster: dict) -> dict:
    if not isinstance(roster, dict):
        raise ValueError("The roster must be an object")
    sessions = roster.get("sessions")
    if not isinstance(sessions, list):
        raise ValueError("The roster has no sessions array")
    agents = []
    incomplete_count = 0
    for session in sessions:
        if not isinstance(session, dict):
            incomplete_count += 1
            continue
        state = session.get("state")
        if not isinstance(state, str):
            incomplete_count += 1
            continue
        if state != "active":
            continue
        key = session.get("sessionKey")
        name = session.get("displayName")
        if not isinstance(key, str) or not isinstance(name, str) or not key or not name:
            incomplete_count += 1
            continue

        row_incomplete = False
        parent = ""
        for field in ("currentParent", "topologyParent"):
            value = session.get(field)
            if value is None:
                continue
            if not isinstance(value, str):
                row_incomplete = True
            elif not parent and value:
                parent = value

        archetype = session.get("archetype")
        if archetype is None or archetype == "":
            archetype = "unknown"
        elif not isinstance(archetype, str):
            archetype = "unknown"
            row_incomplete = True
        if row_incomplete:
            incomplete_count += 1

        query = urlencode({"gateway": config["gatewayOrigin"], "session": key})
        agents.append({
            "key": key,
            "name": name,
            "parent": parent,
            "archetype": archetype,
            "url": config["chatBase"] + "/?" + query,
        })
    return {"agents": agents, "incompleteCount": incomplete_count}


def main() -> int:
    request_id = sys.argv[1] if len(sys.argv) > 1 else None
    try:
        config = load_config()
        completed = subprocess.run(config["rosterCommand"], capture_output=True,
                                   text=True, timeout=20, check=True)
        result = normalize(config, json.loads(completed.stdout))
        if request_id is not None:
            result["requestId"] = request_id
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, KeyError, json.JSONDecodeError,
            subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
        # Never echo CLI output: it can contain deployment details.
        result = {"error": type(exc).__name__ + ": " + str(exc)[:180]}
        if request_id is not None:
            result["requestId"] = request_id
        print(json.dumps(result))
        return 1


if __name__ == "__main__":
    sys.exit(main())
