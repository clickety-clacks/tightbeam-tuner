#!/usr/bin/env python3
"""Read and save Tuner's nonsecret connection settings."""

import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from urllib.request import Request, urlopen


def config_path() -> Path:
    override = os.environ.get("TIGHTBEAM_TUNER_CONFIG")
    if override:
        return Path(override).expanduser()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return config_home / "tightbeam-tuner/config.json"


def origin(value: str, label: str) -> str:
    parsed = urlsplit(value)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")):
        raise ValueError(f"{label} must be an HTTP(S) origin without credentials or a path")
    try:
        parsed.port
    except ValueError as exc:
        raise ValueError(f"{label} has an invalid port") from exc
    return urlunsplit((parsed.scheme, parsed.netloc, "", "", ""))


def normalize_config(data: dict) -> dict:
    command = data.get("rosterCommand")
    if not isinstance(command, list) or len(command) < 4 or not all(
        isinstance(part, str) and part for part in command
    ) or command[-3:-1] != ["list", "--as-user"]:
        raise ValueError("Tightbeam CLI location and user are required")
    return {
        "chatBase": origin(data["chatBase"], "Chat server URL"),
        "gatewayOrigin": origin(data["gatewayOrigin"], "Gateway URL"),
        "rosterCommand": command,
    }


def load_config() -> dict:
    return normalize_config(json.loads(config_path().read_text()))


def display_config(data: dict) -> dict:
    return {
        "configured": True,
        "chatBase": data["chatBase"],
        "gatewayOrigin": data["gatewayOrigin"],
        "cliCommand": shlex.join(data["rosterCommand"][:-3]),
        "rosterUser": data["rosterCommand"][-1],
    }


def save_config(data: dict) -> dict:
    cli_command = shlex.split(data["cliCommand"].strip())
    gateway = data["gatewayOrigin"].strip()
    user = data["rosterUser"].strip()
    if not gateway or not user:
        discovered = discover_gateway(data)
        gateway = gateway or discovered["gatewayOrigin"]
        user = user or discovered.get("rosterUser", "")
    if not cli_command or not user or user.startswith("-"):
        raise ValueError("Tightbeam CLI location and user are required")
    command = cli_command + ["list", "--as-user", user]
    normalized = normalize_config({
        "chatBase": data["chatBase"].strip(),
        "gatewayOrigin": gateway,
        "rosterCommand": command,
    })
    path = config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=".config-",
                                     delete=False) as temporary:
        temporary_path = Path(temporary.name)
        os.chmod(temporary_path, 0o600)
        json.dump(normalized, temporary, indent=2)
        temporary.write("\n")
    os.replace(temporary_path, path)
    return display_config(normalized)


def discover_gateway(data: dict) -> dict:
    base = origin(data["chatBase"].strip(), "Chat server URL")
    request = Request(base + "/chat-config.json", headers={"Accept": "application/json"})
    with urlopen(request, timeout=6) as response:
        target = json.load(response)
    if not target.get("gateway"):
        raise ValueError("This Chat server has no default gateway; enter its URL manually")
    result = {"gatewayOrigin": origin(target["gateway"], "Gateway URL")}
    principal = target.get("principalKey")
    if isinstance(principal, str):
        user = principal[5:] if principal.startswith("user:") else principal
        if re.fullmatch(r"[A-Za-z0-9_.@-]+", user):
            result["rosterUser"] = user
    return result


def main() -> int:
    try:
        if sys.argv[1:] == ["show"]:
            try:
                result = display_config(load_config())
            except FileNotFoundError:
                result = {"configured": False}
            except (ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
                result = {"configured": False, "error": str(exc)}
        elif sys.argv[1:] == ["save"]:
            result = save_config(json.loads(sys.stdin.readline()))
        elif sys.argv[1:] == ["discover"]:
            result = discover_gateway(json.loads(sys.stdin.readline()))
        else:
            raise ValueError("Expected show, save, or discover")
        print(json.dumps(result))
        return 0
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
