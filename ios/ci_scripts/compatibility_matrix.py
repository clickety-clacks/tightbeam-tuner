#!/usr/bin/env python3
"""Run candidate-bound published-runtime checks for diagnostics and TestFlight archives."""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import http.server
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import release_hook
import release_notes


class MatrixError(RuntimeError):
    def __init__(self, message: str, *, diagnostics: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.diagnostics = diagnostics


class _WebSocket:
    """Small RFC 6455 text client for the published runtime's supported /ws API."""

    def __init__(self, gateway_url: str, path: str = "/ws") -> None:
        endpoint = urllib.parse.urlsplit(gateway_url)
        if endpoint.scheme != "http" or endpoint.hostname != "127.0.0.1" or endpoint.port is None:
            raise MatrixError("compatibility fixture WebSocket must use the loopback gateway")
        self.socket = socket.create_connection((endpoint.hostname, endpoint.port), timeout=15)
        self.socket.settimeout(15)
        self.buffer = bytearray()
        nonce = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {endpoint.hostname}:{endpoint.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {nonce}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        self.socket.sendall(request.encode("ascii"))
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            byte = self.socket.recv(1)
            if not byte:
                self.close()
                raise MatrixError("published Tightbeam WebSocket closed during handshake")
            header.extend(byte)
            if len(header) > 16384:
                self.close()
                raise MatrixError("published Tightbeam WebSocket handshake was oversized")
        lines = header.decode("latin-1").split("\r\n")
        if not lines or " 101 " not in lines[0]:
            self.close()
            raise MatrixError("published Tightbeam WebSocket rejected the supported client handshake")
        values = {}
        for line in lines[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                values[key.strip().casefold()] = value.strip()
        expected = base64.b64encode(
            hashlib.sha1((nonce + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        if values.get("sec-websocket-accept") != expected:
            self.close()
            raise MatrixError("published Tightbeam WebSocket returned an invalid handshake")

    def _read_exact(self, length: int) -> bytes:
        while len(self.buffer) < length:
            block = self.socket.recv(max(4096, length - len(self.buffer)))
            if not block:
                raise MatrixError("published Tightbeam WebSocket closed before its expected frame")
            self.buffer.extend(block)
        result = bytes(self.buffer[:length])
        del self.buffer[:length]
        return result

    def send_json(self, value: dict[str, Any]) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = bytes([0x81, 0x80 | length])
        elif length < 65536:
            header = bytes([0x81, 0x80 | 126]) + struct.pack("!H", length)
        else:
            header = bytes([0x81, 0x80 | 127]) + struct.pack("!Q", length)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(header + mask + masked)

    def receive_json(self, timeout: float = 15) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.socket.settimeout(max(0.1, deadline - time.monotonic()))
            first, second = self._read_exact(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read_exact(8))[0]
            mask = self._read_exact(4) if second & 0x80 else None
            payload = self._read_exact(length)
            if mask is not None:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            if opcode == 0x8:
                return None
            if opcode == 0x9:
                self._send_control(0xA, payload)
                continue
            if opcode != 0x1:
                continue
            try:
                value = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise MatrixError("published Tightbeam WebSocket returned invalid JSON")
            return value if isinstance(value, dict) else None
        raise MatrixError("published Tightbeam WebSocket did not respond before timeout")

    def _send_control(self, opcode: int, payload: bytes) -> None:
        mask = os.urandom(4)
        header = bytes([0x80 | opcode, 0x80 | len(payload)])
        self.socket.sendall(header + mask + bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)))

    def close(self) -> None:
        try:
            self.socket.close()
        except OSError:
            pass

    def __enter__(self) -> "_WebSocket":
        return self

    def __exit__(self, _type: Any, _value: Any, _traceback: Any) -> None:
        self.close()


def _safe_fail(message: str) -> None:
    raise MatrixError(message)


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def _sse_data_event(value: Any) -> bytes:
    """Encode one JSON value as a single-line Server-Sent Events data event."""
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return f"data: {payload}\n\n".encode("utf-8")


def _write_json(path: Path, value: Any) -> None:
    path.write_bytes(_json_bytes(value))


def _isolated_environment(home: Path) -> dict[str, str]:
    """Use only toolchain variables plus task-owned user state for fixture children."""
    environment = {
        key: os.environ[key]
        for key in ("PATH", "DEVELOPER_DIR", "LANG", "LC_ALL", "TZ")
        if os.environ.get(key)
    }
    environment.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    environment["HOME"] = str(home)
    environment["TMPDIR"] = str(home / "tmp")
    environment["NPM_CONFIG_USERCONFIG"] = str(home / "npmrc")
    environment["npm_config_cache"] = str(home / "npm-cache")
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    return environment


def _run(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    timeout: int = 60,
    input_text: str | None = None,
    diagnostic_path: Path | None = None,
    diagnostic_redactions: set[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    def retain(contents: str | bytes | None) -> None:
        if diagnostic_path is None:
            return
        if isinstance(contents, bytes):
            text = contents.decode("utf-8", "replace")
        else:
            text = contents or ""
        safe = _safe_diagnostic_text(text, diagnostic_redactions or set())
        try:
            diagnostic_path.parent.mkdir(parents=True, exist_ok=True)
            diagnostic_path.write_text(safe, encoding="utf-8")
            diagnostic_path.chmod(0o600)
        except OSError as error:
            raise MatrixError("compatibility-matrix command diagnostics could not be retained") from error

    try:
        result = subprocess.run(
            args,
            cwd=cwd,
            env=env,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
        retain(result.stdout)
        return result
    except subprocess.TimeoutExpired as error:
        retain(error.output or error.stdout or error.stderr)
        raise MatrixError(
            f"required compatibility-matrix command timed out: {Path(args[0]).name}"
            + (f"; diagnostic retained as {diagnostic_path.name}" if diagnostic_path is not None else "")
        ) from error
    except OSError as error:
        retain(str(error))
        raise MatrixError(
            f"required compatibility-matrix command could not start: {Path(args[0]).name}"
            + (f"; diagnostic retained as {diagnostic_path.name}" if diagnostic_path is not None else "")
        ) from error


def _require_command(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        _safe_fail(f"compatibility matrix requires the approved CI tool {name}")
    return path


def _checked(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    timeout: int = 60,
    diagnostic_path: Path | None = None,
    diagnostic_redactions: set[str] | None = None,
) -> str:
    result = _run(
        args, env=env, cwd=cwd, timeout=timeout,
        diagnostic_path=diagnostic_path,
        diagnostic_redactions=diagnostic_redactions,
    )
    if result.returncode != 0:
        message = f"compatibility-matrix command failed: {Path(args[0]).name}"
        if diagnostic_path is not None:
            message += f"; diagnostic retained as {diagnostic_path.name}"
        _safe_fail(message)
    return result.stdout


def _preflight_pi_harness(
    pi_cli: Path,
    package_lock: Path,
    *,
    env: dict[str, str],
    cwd: Path,
    diagnostic_path: Path | None = None,
    diagnostic_redactions: set[str] | None = None,
) -> str:
    try:
        lock = json.loads(package_lock.read_text(encoding="utf-8"))
        package = lock.get("packages", {}).get("node_modules/@mariozechner/pi-coding-agent", {})
        version = package.get("version") if isinstance(package, dict) else None
    except (OSError, json.JSONDecodeError, AttributeError) as error:
        raise MatrixError("pinned Pi harness package lock is unavailable") from error
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version):
        _safe_fail("pinned Pi harness package version is invalid")
    version_output = _checked(
        [str(pi_cli), "--version"], env=env, cwd=cwd, timeout=120,
        diagnostic_path=diagnostic_path,
        diagnostic_redactions=diagnostic_redactions,
    )
    if not re.search(rf"(?<![0-9]){re.escape(version)}(?![0-9])", version_output):
        _safe_fail("pinned Pi harness executable did not report its locked version")
    return version


def _preflight_pi_model(
    pi_cli: Path,
    *,
    home: Path,
    endpoint: str,
    env: dict[str, str],
    cwd: Path,
    observed_requests: list[dict[str, str]],
    diagnostic_path: Path,
    diagnostic_redactions: set[str],
) -> dict[str, Any]:
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.port is None or parsed.path != "/v1":
        _safe_fail("Pi preflight endpoint must be the local compatibility model")

    agent_dir = home / ".pi" / "agent"
    agent_dir.mkdir(parents=True, exist_ok=True)
    model_configuration = {
        "providers": {
            "tunerci": {
                "baseUrl": endpoint,
                "api": "openai-completions",
                "apiKey": "local",
                "authHeader": True,
                "models": [{
                    "id": "tuner-fixture",
                    "name": "Tuner compatibility fixture",
                    "reasoning": False,
                    "input": ["text"],
                    "contextWindow": 4096,
                    "maxTokens": 256,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                }],
            }
        }
    }
    models_path = agent_dir / "models.json"
    models_path.write_bytes(_json_bytes(model_configuration))
    models_path.chmod(0o600)

    before = sum(
        request.get("path") == "/v1/chat/completions"
        and request.get("model") == "tuner-fixture"
        for request in observed_requests
    )
    prompt = "Reply with a short greeting for the Tuner compatibility fixture."
    try:
        result = _run(
            [
                str(pi_cli), "--model", "tunerci/tuner-fixture", "--print", "--no-session", "--no-tools", prompt,
            ],
            env=env,
            cwd=cwd,
            timeout=180,
            diagnostic_path=diagnostic_path,
            diagnostic_redactions=diagnostic_redactions,
        )
    except MatrixError as error:
        raise MatrixError(
            "Pi local-model preflight did not complete; inspect the retained Pi preflight log"
        ) from error
    if result.returncode != 0:
        raise MatrixError("Pi local-model preflight failed; inspect the retained Pi preflight log")
    if "Tightbeam compatibility fixture reply." not in result.stdout:
        raise MatrixError("Pi local-model preflight returned no deterministic fixture reply")
    after = sum(
        request.get("path") == "/v1/chat/completions"
        and request.get("model") == "tuner-fixture"
        for request in observed_requests
    )
    if after <= before:
        raise MatrixError("Pi local-model preflight made no request to the local completion endpoint")
    return {
        "status": "passed",
        "provider": "tunerci",
        "model": "tuner-fixture",
        "endpointScope": "loopback",
        "requestObserved": True,
        "diagnosticLog": diagnostic_path.name,
    }


def _http_json(
    url: str,
    *,
    method: str = "GET",
    payload: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 30,
) -> tuple[int, dict[str, Any]]:
    body = None if payload is None else _json_bytes(payload)
    request_headers = {"Accept": "application/json", **(headers or {})}
    if body is not None:
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=request_headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            data = response.read()
            status = int(response.status)
    except urllib.error.HTTPError as error:
        data = error.read()
        status = int(error.code)
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise MatrixError("isolated published-runtime request failed") from error
    try:
        value = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MatrixError("isolated published-runtime response was not valid JSON") from error
    if not isinstance(value, dict):
        raise MatrixError("isolated published-runtime response had an invalid shape")
    return status, value


def _wait_for_reply(gateway_url: str, session_key: str, client_message_id: str, timeout: int = 180) -> int:
    encoded_key = urllib.parse.quote(session_key, safe="")
    url = f"{gateway_url}/api/sessions/{encoded_key}/messages?tail=true&limit=500"
    deadline = time.monotonic() + timeout
    human_sequence: int | None = None
    while time.monotonic() < deadline:
        status, page = _http_json(url, timeout=10)
        if status == 200:
            items = page.get("items")
            if isinstance(items, list):
                human_sequences: list[int] = []
                for item in items:
                    if not isinstance(item, dict) or item.get("sessionKey") != session_key:
                        continue
                    if item.get("role") == "user" and item.get("clientMessageId") == client_message_id:
                        seq = item.get("seq")
                        if isinstance(seq, int) and not isinstance(seq, bool):
                            human_sequences.append(seq)
                if len(human_sequences) > 1:
                    raise MatrixError("published Tightbeam duplicated the uniquely identified fixture human post")
                if human_sequences:
                    human_sequence = human_sequences[0]
                if human_sequence is not None:
                    correlated = []
                    for item in items:
                        if not isinstance(item, dict) or item.get("sessionKey") != session_key:
                            continue
                        if (
                            item.get("role") == "assistant"
                            and item.get("turnIncludesHuman") is True
                            and isinstance(item.get("seq"), int)
                            and not isinstance(item.get("seq"), bool)
                            and item["seq"] > human_sequence
                        ):
                            reply_to = item.get("replyToClientMessageId")
                            if reply_to is None or reply_to == client_message_id:
                                correlated.append(int(item["seq"]))
                    if correlated:
                        return min(correlated)
        time.sleep(0.25)
    raise MatrixError("published Tightbeam did not persist a correlated assistant reply to the fixture human post")


def _failure_message(error: Exception) -> str:
    if isinstance(error, (MatrixError, release_hook.ReleaseHookError, release_notes.ReleaseNoteError)):
        return str(error)
    return "compatibility matrix received an invalid input or could not write its report"


def _available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def _shell_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _sha_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _listener_bindings(port: int, label: str) -> set[str]:
    lsof = shutil.which("lsof")
    if lsof is None:
        _safe_fail("compatibility matrix cannot inspect its local service listener")
    # Query only the allocated port because a service may bind from a child
    # process. Callers decide which listener addresses their service permits.
    result = _run(
        [lsof, "-nP", "-a", f"-iTCP:{port}", "-sTCP:LISTEN"],
        timeout=30,
    )
    if result.returncode != 0:
        _safe_fail(f"compatibility matrix could not verify the {label} listener")
    listeners = [
        line.split()[-2]
        for line in result.stdout.splitlines()
        if "(LISTEN)" in line and len(line.split()) >= 2
    ]

    def listener_kind(address: str) -> str:
        if not address.endswith(f":{port}"):
            return "unexpected listener entry"
        host = address.rsplit(":", 1)[0].strip("[]")
        if host in {"*", "0.0.0.0", "::"}:
            return "wildcard"
        try:
            parsed = ipaddress.ip_address(host)
        except ValueError:
            return "unrecognized address"
        if parsed.is_loopback:
            return "IPv4 loopback" if parsed.version == 4 else "IPv6 loopback"
        return "non-loopback IPv4" if parsed.version == 4 else "non-loopback IPv6"

    return {listener_kind(address) for address in listeners}


def _require_loopback_listener(port: int, label: str) -> None:
    kinds = _listener_bindings(port, label)
    if not kinds:
        _safe_fail(
            f"compatibility matrix {label} is not bound exclusively to loopback "
            "(lsof returned no TCP listener row for the assigned port)"
        )
    non_loopback = kinds - {"IPv4 loopback", "IPv6 loopback"}
    if non_loopback:
        _safe_fail(
            f"compatibility matrix {label} is not bound exclusively to loopback "
            f"(observed {', '.join(sorted(non_loopback))} listener)"
        )


def _remove_task_scratch(path: Path) -> None:
    """Retry scoped scratch removal when a transient writer races teardown."""
    last_error: OSError | None = None
    for attempt in range(5):
        try:
            shutil.rmtree(path)
            return
        except FileNotFoundError:
            return
        except OSError as error:
            last_error = error
            if attempt < 4:
                time.sleep(0.25)
    assert last_error is not None
    raise last_error


def _require_port_clear(port: int, label: str) -> None:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.25):
            _safe_fail(f"compatibility matrix did not release its owned {label} port")
    except OSError:
        return


def _current_source(repo: Path, commit_from_ci: str) -> tuple[str, str]:
    head = _checked(["git", "rev-parse", "HEAD"], cwd=repo).strip()
    tree = _checked(["git", "rev-parse", "HEAD^{tree}"], cwd=repo).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", head) or head != commit_from_ci:
        _safe_fail("CI checkout does not match CI_COMMIT")
    if not re.fullmatch(r"[0-9a-f]{40}", tree):
        _safe_fail("CI checkout has no verifiable Git tree")
    return head, tree


def _baseline_input(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError("release baseline input is unreadable") from error
    required = ("buildNumber", "sourceCommit", "sourceTree", "scheme", "configuration")
    if not isinstance(value, dict) or any(value.get(key) in (None, "") for key in required):
        _safe_fail("release baseline input is incomplete")
    if not isinstance(value["buildNumber"], int) or isinstance(value["buildNumber"], bool) or value["buildNumber"] <= 0:
        _safe_fail("release baseline build number is invalid")
    for key in ("sourceCommit", "sourceTree"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[0-9a-f]{40}", value[key]):
            _safe_fail(f"release baseline {key} is invalid")
    return value


def _ensure_baseline_commit(repo: Path, commit: str) -> None:
    check = _run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=repo)
    if check.returncode == 0:
        return
    remote = _run(["git", "fetch", "--no-tags", "origin", commit], cwd=repo, timeout=120)
    if remote.returncode != 0:
        _safe_fail("pinned baseline source commit is unavailable in the repository")
    check = _run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=repo)
    if check.returncode != 0:
        _safe_fail("pinned baseline source commit could not be verified")


def _inject_replied_observation(worktree: Path) -> None:
    source_path = worktree / "ios" / "TightbeamTuner" / "Replied.swift"
    try:
        source = source_path.read_text(encoding="utf-8")
    except OSError as error:
        raise MatrixError("baseline source has no Replies client to observe") from error
    properties = (
        "    private(set) var subscriptionReadyCount = 0\n"
        "    private(set) var snapshotCompletedCount = 0\n"
        "    private(set) var messageCreatedSequenceBySession: [String: Int] = [:]\n"
        "    private(set) var readMarkerEventBySession: [String: Int] = [:]\n"
    )
    ready_increment = "                            subscriptionReadyCount += 1\n"
    snapshot_increment = "                                self.snapshotCompletedCount += 1\n"
    instrumentation = (*properties.splitlines(), ready_increment.rstrip(), snapshot_increment.rstrip())
    if all(value in source for value in instrumentation):
        return
    if any(value in source for value in instrumentation):
        _safe_fail("baseline Replies client has partial compatibility observer instrumentation")
    state_marker = "    private(set) var state = RepliedState()\n    private(set) var shownSessionKey: String?\n"
    if source.count(state_marker) != 1:
        _safe_fail("baseline Replies client cannot accept compatibility observer instrumentation")
    source = source.replace(state_marker, state_marker + properties, 1)
    ready_marker = "                            ready = true\n"
    if source.count(ready_marker) != 1:
        _safe_fail("baseline Replies subscription cannot accept compatibility observer instrumentation")
    source = source.replace(ready_marker, ready_marker + ready_increment, 1)
    snapshot_marker = (
        "                                    mode: mode\n"
        "                                )\n"
        "                            }\n"
    )
    if source.count(snapshot_marker) != 1:
        _safe_fail("baseline Replies snapshot cannot accept compatibility observer instrumentation")
    source = source.replace(
        snapshot_marker,
        "                                    mode: mode\n"
        "                                )\n"
        + snapshot_increment
        + "                            }\n",
        1,
    )
    event_marker = (
        "                        default:\n"
        "                            apply(frame, userID: user)\n"
        "                            if frame.changesRoster { onRosterEvent(frame) }\n"
    )
    observer = (
        "                        default:\n"
        "                            switch frame {\n"
        "                            case .message(let message) where message.role == \"assistant\" && message.turnIncludesHuman:\n"
        "                                messageCreatedSequenceBySession[message.sessionKey] = max(\n"
        "                                    messageCreatedSequenceBySession[message.sessionKey] ?? Int.min,\n"
        "                                    message.seq\n"
        "                                )\n"
        "                            case .readMarker(let marker):\n"
        "                                let suffix = \":session-read-position\"\n"
        "                                if let value = marker.marker, marker.scopeKey.hasSuffix(suffix) {\n"
        "                                    let sessionKey = String(marker.scopeKey.dropLast(suffix.count))\n"
        "                                    readMarkerEventBySession[sessionKey] = value\n"
        "                                }\n"
        "                            default:\n"
        "                                break\n"
        "                            }\n"
        "                            apply(frame, userID: user)\n"
        "                            if frame.changesRoster { onRosterEvent(frame) }\n"
    )
    if source.count(event_marker) != 1:
        _safe_fail("baseline Replies event loop cannot accept compatibility observer instrumentation")
    source_path.write_text(source.replace(event_marker, observer, 1), encoding="utf-8")


def _inject_compatibility_test(worktree: Path, candidate_test: Path) -> None:
    test_target = worktree / "ios" / "Tests" / "ReleaseCompatibilityTests.swift"
    project = worktree / "ios" / "TightbeamTuner.xcodeproj" / "project.pbxproj"
    if not candidate_test.is_file() or not project.is_file():
        _safe_fail("baseline source does not support the release compatibility test harness")
    _inject_replied_observation(worktree)
    pbx = project.read_text(encoding="utf-8")
    if "ReleaseCompatibilityTests.swift" in pbx:
        test_target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(candidate_test, test_target)
        return
    build_id = "D61A9D384FA7407DAB23E109"
    file_id = "D61A9D384FA7407DAB23E10A"
    if build_id in pbx or file_id in pbx:
        _safe_fail("baseline project collides with the temporary compatibility harness IDs")
    marker_build = "\t\t610E617D511675CC7EDD51A7 /* ReleaseNotesTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A25E8652060F43158F6050F6 /* ReleaseNotesTests.swift */; };\n"
    marker_file = "\t\tA25E8652060F43158F6050F6 /* ReleaseNotesTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ReleaseNotesTests.swift; sourceTree = \"<group>\"; };\n"
    marker_group = "\t\t\t\tA25E8652060F43158F6050F6 /* ReleaseNotesTests.swift */,\n"
    marker_sources = "\t\t\t\t610E617D511675CC7EDD51A7 /* ReleaseNotesTests.swift in Sources */,\n"
    if any(marker not in pbx for marker in (marker_build, marker_file, marker_group, marker_sources)):
        _safe_fail("baseline Xcode project cannot be instrumented with the compatibility test")
    pbx = pbx.replace(
        marker_build,
        marker_build + f"\t\t{build_id} /* ReleaseCompatibilityTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id} /* ReleaseCompatibilityTests.swift */; }};\n",
        1,
    )
    pbx = pbx.replace(
        marker_file,
        marker_file + f"\t\t{file_id} /* ReleaseCompatibilityTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ReleaseCompatibilityTests.swift; sourceTree = \"<group>\"; }};\n",
        1,
    )
    pbx = pbx.replace(marker_group, marker_group + f"\t\t\t\t{file_id} /* ReleaseCompatibilityTests.swift */,\n", 1)
    pbx = pbx.replace(marker_sources, marker_sources + f"\t\t\t\t{build_id} /* ReleaseCompatibilityTests.swift in Sources */,\n", 1)
    test_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(candidate_test, test_target)
    project.write_text(pbx, encoding="utf-8")


def _effective_settings(project: Path, scheme: str, configuration: str, destination: str, cwd: Path) -> dict[str, str]:
    output = _checked([
        "xcodebuild", "-project", str(project), "-scheme", scheme,
        "-configuration", configuration, "-destination", destination,
        "-showBuildSettings",
    ], cwd=cwd, timeout=180)
    blocks = re.split(r"(?m)^Build settings for action .*? and target .*?:\s*$", output)
    headers = re.findall(r"(?m)^Build settings for action .*? and target (.*?):\s*$", output)
    selected: str | None = None
    for header, block in zip(headers, blocks[1:]):
        if header.strip() == "TightbeamTuner":
            selected = block
            break
    if selected is None:
        _safe_fail("Xcode could not resolve the Tuner app target build settings")
    values: dict[str, str] = {}
    for line in selected.splitlines():
        match = re.match(r"\s*([A-Z][A-Z0-9_]+)\s*=\s*(.*?)\s*$", line)
        if match:
            values[match.group(1)] = match.group(2).strip().strip('"')
    minimum = values.get("IPHONEOS_DEPLOYMENT_TARGET")
    families = values.get("TARGETED_DEVICE_FAMILY")
    if not minimum or not families:
        _safe_fail("Xcode did not resolve the Tuner deployment target and device families")
    family_values = [item.strip() for item in families.split(",") if item.strip()]
    if not family_values or not all(item in {"1", "2"} for item in family_values):
        _safe_fail("Xcode resolved an unsupported Tuner device-family setting")
    return {"minimumOS": minimum, "deviceFamilies": family_values}


def _baseline_phase_identity(
    baseline: dict[str, Any], effective_settings: dict[str, Any]
) -> dict[str, Any]:
    """Return the released baseline identity measured by this archive run."""
    return {
        "commit": baseline["sourceCommit"],
        "tree": baseline["sourceTree"],
        "scheme": baseline["scheme"],
        "configuration": baseline["configuration"],
        "buildNumber": baseline["buildNumber"],
        **effective_settings,
    }


def _add_xctest_environment(environment: dict[str, str], values: dict[str, str]) -> None:
    for key, value in values.items():
        # The Swift test reads the unprefixed value. Xcode Cloud's test runner
        # also accepts the prefixed form, which it exposes under the original
        # name in the XCTest process.
        environment[key] = value
        environment["TEST_RUNNER_" + key] = value


def _device_and_runtime(minimum_os: str) -> tuple[list[tuple[str, str]], str, str]:
    simctl = _require_command("xcrun")
    devicetypes = json.loads(_checked([simctl, "simctl", "list", "devicetypes", "--json"]))
    runtimes = json.loads(_checked([simctl, "simctl", "list", "runtimes", "--json"]))
    types = [
        item for item in devicetypes.get("devicetypes", [])
        if isinstance(item, dict) and item.get("productFamily") == "iPhone"
        and isinstance(item.get("identifier"), str) and isinstance(item.get("name"), str)
    ]
    ios_runtimes = [
        item for item in runtimes.get("runtimes", [])
        if isinstance(item, dict) and item.get("isAvailable") is True
        # Current simctl JSON reports the platform as "iOS". Older Xcode
        # versions used "iOS Simulator"; accept both documented forms.
        and item.get("platform") in {"iOS", "iOS Simulator"}
        and isinstance(item.get("identifier"), str)
        and isinstance(item.get("version"), str)
    ]
    minimum = release_hook._os_version(minimum_os)
    eligible = [item for item in ios_runtimes if release_hook._os_version(item["version"]) >= minimum]
    generic_runtimes = [
        item for item in eligible
        if re.fullmatch(r"iOS(?:-\d+)+", item["identifier"].rsplit(".", 1)[-1])
    ]
    if not generic_runtimes or not types:
        _safe_fail("Xcode has no available iPhone simulator runtime at the Tuner deployment target")
    selected_runtime = max(
        generic_runtimes,
        key=lambda item: release_hook._os_version(item["version"]),
    )
    compatible_types = [
        item for item in types
        if isinstance(item.get("minRuntimeVersionString"), str)
        and release_hook._os_version(item["minRuntimeVersionString"])
        <= release_hook._os_version(selected_runtime["version"])
    ]
    if not compatible_types:
        _safe_fail("Xcode has no iPhone simulator type compatible with the selected runtime")
    compatible_types.sort(
        key=lambda item: (
            release_hook._os_version(item["minRuntimeVersionString"]),
            item["name"],
        ),
        reverse=True,
    )
    return (
        [(str(item["identifier"]), str(item["name"])) for item in compatible_types],
        str(selected_runtime["identifier"]), "iOS " + str(selected_runtime["version"]),
    )


class LocalRuntimeFixture:
    def __init__(self, root: Path, pair: tuple[release_hook.PublishedRelease, release_hook.PublishedRelease], package_paths: dict[int, Path]):
        self.root = root
        self.pair = pair
        self.by_id = {item.release_id: item for item in pair}
        self.package_paths = package_paths
        self.gateway_port = _available_port()
        self.ssh_port = _available_port()
        while self.ssh_port == self.gateway_port:
            self.ssh_port = _available_port()
        self.fixture_token = secrets.token_hex(24)
        self.local_user = getpass.getuser()
        self.home_root = root / "home"
        self.home_root.mkdir(parents=True, exist_ok=True)
        (self.home_root / "tmp").mkdir(parents=True, exist_ok=True)
        (self.home_root / "npm-cache").mkdir(parents=True, exist_ok=True)
        self.base_environment = _isolated_environment(self.home_root)
        self.cli_link_dir = root / "runner-bin"
        self.cli_link = self.cli_link_dir / "tightbeam"
        self.shim_dir = root / "harness-shim"
        self.pi_package = root / "pi-fixture"
        self.pi_bin = self.pi_package / "node_modules" / ".bin"
        self.pi_harness_version: str | None = None
        self.pi_model_preflights: list[dict[str, Any]] = []
        self.command_log_sequence = 0
        self.model_port = _available_port()
        while self.model_port in {self.gateway_port, self.ssh_port}:
            self.model_port = _available_port()
        self.state_root = root / "runtime-state"
        self.state_root.mkdir(parents=True, exist_ok=True)
        self.runtime_base: dict[int, Path] = {}
        self.gateway_listener_bindings: dict[int, set[str]] = {}
        self.selected_release_id: int | None = None
        self.gateway_process: subprocess.Popen[bytes] | None = None
        self.gateway_log: Any = None
        self.sshd_process: subprocess.Popen[bytes] | None = None
        self.sshd_log: Any = None
        self.saved_state: dict[int, dict[str, Any]] = {}
        self.phase_results: list[dict[str, Any]] = []
        self.server: http.server.ThreadingHTTPServer | None = None
        self.server_thread: threading.Thread | None = None
        self.host_key = root / "ssh-host-key"
        self.authorized_keys = root / "authorized_keys"
        self.sshd_config = root / "sshd_config"
        self.force_command = root / "roster-command.sh"
        self.current_runtime_env = root / "current-runtime-env.sh"
        self.ssh_host_key_line = ""
        self.runtime_identities: dict[int, dict[str, Any]] = {}
        self.model_server: http.server.ThreadingHTTPServer | None = None
        self.model_thread: threading.Thread | None = None
        self.model_requests: list[dict[str, str]] = []
        try:
            self._prepare_tools()
            self._prepare_sshd()
            self._start_model_server()
            self._start_fixture_server()
        except BaseException:
            # A listener check can fail partway through startup. The caller
            # does not receive this object when __init__ raises, so release
            # anything this fixture already started here.
            try:
                self.close()
            except Exception:
                pass
            raise

    def _record_gateway_listener(self, release_id: int, port: int, label: str) -> None:
        bindings = _listener_bindings(port, label)
        if not bindings:
            _safe_fail(f"compatibility matrix could not observe the {label} listener")
        self.gateway_listener_bindings.setdefault(release_id, set()).update(bindings)

    def gateway_listener_report(self) -> list[dict[str, Any]]:
        return [
            {"releaseId": release_id, "observedBindings": sorted(bindings)}
            for release_id, bindings in sorted(self.gateway_listener_bindings.items())
        ]

    @property
    def fixture_url(self) -> str:
        assert self.server is not None
        return f"http://127.0.0.1:{self.server.server_port}"

    @property
    def gateway_url(self) -> str:
        return f"http://127.0.0.1:{self.gateway_port}"

    def _prepare_tools(self) -> None:
        self.cli_link_dir.mkdir(parents=True, exist_ok=True)
        self.shim_dir.mkdir(parents=True, exist_ok=True)
        for name in ("claude", "codex"):
            shim = self.shim_dir / name
            shim.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            shim.chmod(0o700)
        shutil.copytree(SCRIPT_DIR / "model-endpoint", self.pi_package)
        npm = _require_command("npm")
        _checked([
            npm, "ci", "--prefix", str(self.pi_package),
            "--ignore-scripts", "--no-audit", "--no-fund",
        ], env=self.base_environment, cwd=self.root, timeout=600)
        pi_cli = self.pi_bin / "pi"
        if not pi_cli.is_file():
            _safe_fail("pinned Pi harness package did not install its executable")
        # Exercise the real executable before booting the simulator so a slow
        # first launch cannot fail the runtime's readiness probe only under
        # Xcode test load.
        self.pi_harness_version = _preflight_pi_harness(
            pi_cli,
            self.pi_package / "package-lock.json",
            env=self.base_environment,
            cwd=self.root,
            diagnostic_path=self.root / "command-logs" / "pi-version.log",
            diagnostic_redactions={str(self.root), str(self.home_root)},
        )
        self.authorized_keys.write_text("", encoding="utf-8")
        self.authorized_keys.chmod(0o600)
        self.ssh_host_key_line = _checked([
            _require_command("ssh-keygen"), "-q", "-t", "ed25519", "-N", "",
            "-C", "tuner-compat-host", "-f", str(self.host_key),
        ], env=self.base_environment).strip()
        self.ssh_host_key_line = self.host_key.with_suffix(".pub").read_text(encoding="utf-8").strip()
        if not self.ssh_host_key_line.startswith("ssh-ed25519 "):
            _safe_fail("isolated SSH fixture did not create an Ed25519 host key")
        self._write_current_runtime_env(None)

    def _prepare_sshd(self) -> None:
        sshd = _require_command("sshd")
        if any(character.isspace() for character in str(self.root)):
            _safe_fail("isolated CI scratch path contains unsupported whitespace")
        wrapper = "\n".join([
            "#!/bin/sh",
            "set -eu",
            f". {_shell_quote(str(self.current_runtime_env))}",
            'if [ "${SSH_ORIGINAL_COMMAND:-}" != "$EXPECTED_COMMAND" ]; then exit 126; fi',
            f'exec {_shell_quote(_require_command("env"))} -i HOME={_shell_quote(str(self.home_root))} PATH={_shell_quote(self.base_environment["PATH"])} TIGHTBEAM_BASE_DIR="$TIGHTBEAM_BASE_DIR" TIGHTBEAM_PORT="$TIGHTBEAM_PORT" TIGHTBEAM_ADVERTISED_URL="$TIGHTBEAM_ADVERTISED_URL" "$TIGHTBEAM_CLI" list --as-user "$TIGHTBEAM_TEST_USER"',
            "",
        ])
        self.force_command.write_text(wrapper, encoding="utf-8")
        self.force_command.chmod(0o700)
        config = "\n".join([
            f"Port {self.ssh_port}",
            "ListenAddress 127.0.0.1",
            f"HostKey {self.host_key}",
            f"PidFile {self.root / 'sshd.pid'}",
            f"AuthorizedKeysFile {self.authorized_keys}",
            "StrictModes no",
            "PubkeyAuthentication yes",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "PermitRootLogin no",
            "AllowTcpForwarding no",
            "AllowStreamLocalForwarding no",
            "AllowAgentForwarding no",
            "X11Forwarding no",
            "PermitTunnel no",
            f"AllowUsers {self.local_user}",
            f"ForceCommand /bin/sh {self.force_command}",
            "LogLevel ERROR",
            "",
        ])
        self.sshd_config.write_text(config, encoding="utf-8")
        self.sshd_config.chmod(0o600)
        _checked([sshd, "-t", "-f", str(self.sshd_config)], env=self.base_environment, timeout=20)
        self._sshd_binary = sshd

    def _start_model_server(self) -> None:
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, _format: str, *args: Any) -> None:
                return

            def _send(self, status: int, payload: dict[str, Any]) -> None:
                body = _json_bytes(payload)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                if self.path != "/v1/models":
                    self._send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
                    return
                fixture.model_requests.append({"method": "GET", "path": self.path})
                self._send(200, {
                    "object": "list",
                    "data": [{"id": "tuner-fixture", "object": "model", "created": 1, "owned_by": "local"}],
                })

            def do_POST(self) -> None:
                if self.path != "/v1/chat/completions":
                    self._send(404, {"error": {"message": "not found", "type": "invalid_request_error"}})
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    value = json.loads(self.rfile.read(length).decode("utf-8"))
                    if not isinstance(value, dict) or value.get("model") != "tuner-fixture":
                        raise ValueError
                except (ValueError, json.JSONDecodeError):
                    self._send(400, {"error": {"message": "invalid fixture request", "type": "invalid_request_error"}})
                    return
                fixture.model_requests.append({
                    "method": "POST", "path": self.path, "model": "tuner-fixture",
                })
                completion_id = "chatcmpl-tuner-fixture"
                if value.get("stream") is True:
                    chunks = [
                        {"id": completion_id, "object": "chat.completion.chunk", "created": 1,
                         "model": "tuner-fixture", "choices": [{"index": 0, "delta": {"role": "assistant"}, "finish_reason": None}]},
                        {"id": completion_id, "object": "chat.completion.chunk", "created": 1,
                         "model": "tuner-fixture", "choices": [{"index": 0, "delta": {"content": "Tightbeam compatibility fixture reply."}, "finish_reason": None}]},
                        {"id": completion_id, "object": "chat.completion.chunk", "created": 1,
                         "model": "tuner-fixture", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
                    ]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Cache-Control", "no-cache")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    for chunk in chunks:
                        self.wfile.write(_sse_data_event(chunk))
                        self.wfile.flush()
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    return
                self._send(200, {
                    "id": completion_id,
                    "object": "chat.completion",
                    "created": 1,
                    "model": "tuner-fixture",
                    "choices": [{"index": 0, "message": {"role": "assistant", "content": "Tightbeam compatibility fixture reply."}, "finish_reason": "stop"}],
                })

        self.model_server = http.server.ThreadingHTTPServer(("127.0.0.1", self.model_port), Handler)
        self.model_server.daemon_threads = True
        self.model_thread = threading.Thread(target=self.model_server.serve_forever, daemon=True)
        self.model_thread.start()
        _require_loopback_listener(self.model_port, "deterministic model fixture")

    def _start_fixture_server(self) -> None:
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, _format: str, *args: Any) -> None:
                return

            def _send(self, status: int, payload: dict[str, Any]) -> None:
                body = _json_bytes(payload)
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                if self.headers.get("X-Test-Fixture-Token") != fixture.fixture_token:
                    self._send(403, {"error": "fixture token required"})
                    return
                if self.path == "/runtime-context" and fixture.selected_release_id is not None:
                    self._send(200, {"releaseId": fixture.selected_release_id})
                    return
                self._send(404, {"error": "unknown fixture route"})

            def do_POST(self) -> None:
                if self.headers.get("X-Test-Fixture-Token") != fixture.fixture_token:
                    self._send(403, {"error": "fixture token required"})
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    payload = json.loads(self.rfile.read(length).decode("utf-8"))
                    if not isinstance(payload, dict):
                        raise ValueError
                    result = fixture._route(self.path, payload)
                    self._send(200, result)
                except MatrixError as error:
                    # MatrixError messages are authored as credential-free summaries.
                    # Preserve the operation's safe reason so a failed XCTest points
                    # at the fixture/runtime boundary instead of a secondary decode.
                    self._send(500, {
                        "ok": False,
                        "error": "isolated fixture operation failed",
                        "diagnostic": str(error),
                    })
                except release_hook.ReleaseHookError as error:
                    self._send(500, {
                        "ok": False,
                        "error": "isolated fixture operation failed",
                        "diagnostic": str(error),
                    })
                except (ValueError, json.JSONDecodeError):
                    self._send(400, {"ok": False, "error": "invalid fixture request"})

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        _require_loopback_listener(self.server.server_port, "test fixture")

    def _runtime_env(self, release_id: int, *, port: int | None = None) -> dict[str, str]:
        package = self.package_paths[release_id]
        cli = release_hook.find_runtime_executable(package, "tightbeam")
        release_hook.find_runtime_executable(package, "tightbeam-gateway")
        env = self.base_environment.copy()
        env["TIGHTBEAM_BASE_DIR"] = str(self.runtime_base.setdefault(
            release_id, self.state_root / str(release_id) / "base"
        ))
        actual_port = self.gateway_port if port is None else port
        env["TIGHTBEAM_PORT"] = str(actual_port)
        env["TIGHTBEAM_ADVERTISED_URL"] = f"http://127.0.0.1:{actual_port}"
        env["PATH"] = os.pathsep.join([str(self.shim_dir), str(self.pi_bin), str(cli.parent), env["PATH"]])
        return env

    def _write_current_runtime_env(self, release_id: int | None, user_id: str = "") -> None:
        if release_id is None:
            values = {
                "TIGHTBEAM_BASE_DIR": str(self.state_root / "not-selected"),
                "TIGHTBEAM_PORT": str(self.gateway_port),
                "TIGHTBEAM_ADVERTISED_URL": self.gateway_url,
                "TIGHTBEAM_CLI": str(self.cli_link),
                "TIGHTBEAM_TEST_USER": "",
            }
        else:
            values = {
                "TIGHTBEAM_BASE_DIR": str(self.runtime_base[release_id]),
                "TIGHTBEAM_PORT": str(self.gateway_port),
                "TIGHTBEAM_ADVERTISED_URL": self.gateway_url,
                "TIGHTBEAM_CLI": str(self.cli_link),
                "TIGHTBEAM_TEST_USER": user_id,
            }
        expected = f"{_shell_quote(str(self.cli_link))} 'list' '--as-user' {_shell_quote(user_id)}"
        lines = [f"{key}={_shell_quote(value)}" for key, value in values.items()]
        lines.append(f"EXPECTED_COMMAND={_shell_quote(expected)}")
        self.current_runtime_env.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.current_runtime_env.chmod(0o600)

    def _start_sshd(self) -> None:
        if self.sshd_process is not None and self.sshd_process.poll() is None:
            return
        self.sshd_log = (self.root / "sshd.log").open("ab")
        self.sshd_process = subprocess.Popen(
            [self._sshd_binary, "-D", "-e", "-f", str(self.sshd_config)],
            env=self.base_environment,
            stdin=subprocess.DEVNULL, stdout=self.sshd_log, stderr=self.sshd_log,
        )
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.sshd_process.poll() is not None:
                _safe_fail("isolated SSH fixture did not start")
            try:
                with socket.create_connection(("127.0.0.1", self.ssh_port), timeout=0.2):
                    _require_loopback_listener(self.ssh_port, "SSH fixture")
                    return
            except OSError:
                time.sleep(0.1)
        _safe_fail("isolated SSH fixture did not become ready")

    def _start_gateway(self, release_id: int) -> None:
        env = self._runtime_env(release_id)
        package = self.package_paths[release_id]
        cli_binary = release_hook.find_runtime_executable(package, "tightbeam")
        gateway_binary = release_hook.find_runtime_executable(package, "tightbeam-gateway")
        self.cli_link.unlink(missing_ok=True)
        self.cli_link.symlink_to(cli_binary)
        base_dir = Path(env["TIGHTBEAM_BASE_DIR"])
        base_dir.parent.mkdir(parents=True, exist_ok=True)
        identity = self.runtime_identities.get(release_id, {})
        self._write_current_runtime_env(release_id, str(identity.get("userId", "")))
        self.gateway_log = (self.root / f"gateway-{release_id}.log").open("ab")
        self.gateway_process = subprocess.Popen(
            [str(gateway_binary)],
            cwd=self.root,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=self.gateway_log,
            stderr=self.gateway_log,
        )
        self.selected_release_id = release_id
        deadline = time.monotonic() + 60
        version_text = ""
        while time.monotonic() < deadline:
            if self.gateway_process.poll() is not None:
                _safe_fail("published Tightbeam gateway exited during isolated startup")
            try:
                request = urllib.request.Request(self.gateway_url + "/version")
                with urllib.request.urlopen(request, timeout=2) as response:
                    version_text = response.read(65536).decode("utf-8", "replace")
                break
            except (urllib.error.URLError, TimeoutError, OSError):
                time.sleep(0.25)
        if not version_text:
            _safe_fail("published Tightbeam gateway did not become ready on loopback")
        release = self.by_id[release_id]
        version_core = re.search(r"\d+\.\d+\.\d+", release.tag)
        build_part = release.tag.split("+", 1)[1] if "+" in release.tag else None
        if version_core is None or version_core.group(0) not in version_text or (build_part and build_part not in version_text):
            _safe_fail(f"published Tightbeam gateway version endpoint does not identify {release.tag}")
        self._record_gateway_listener(release_id, self.gateway_port, "published Tightbeam gateway")

    def _stop_gateway(self) -> None:
        process = self.gateway_process
        self.gateway_process = None
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if self.gateway_log is not None:
            self.gateway_log.close()
            self.gateway_log = None

    def _cli(self, release_id: int, *arguments: str, timeout: int = 300) -> str:
        self.command_log_sequence += 1
        command_name = re.sub(r"[^A-Za-z0-9_.-]", "_", arguments[0] if arguments else "command")
        diagnostic_path = self.root / "command-logs" / (
            f"runtime-{release_id}-{self.command_log_sequence:03d}-{command_name}.log"
        )
        result = _run(
            [str(self.cli_link), *arguments],
            env=self._runtime_env(release_id),
            cwd=self.root,
            timeout=timeout,
            diagnostic_path=diagnostic_path,
            diagnostic_redactions=self.diagnostic_redaction_values(),
        )
        if result.returncode != 0:
            raise MatrixError(
                f"published Tightbeam CLI operation failed: {arguments[0] if arguments else 'command'}; "
                f"diagnostic retained as {diagnostic_path.name}"
            )
        return result.stdout

    @staticmethod
    def _parse_cli_json(output: str, label: str) -> dict[str, Any]:
        try:
            value = json.loads(output)
        except json.JSONDecodeError:
            # Some CLI commands include a human-readable prelude; accept only a
            # single JSON object from the final complete line.
            try:
                value = json.loads(output.strip().splitlines()[-1])
            except (json.JSONDecodeError, IndexError) as error:
                raise MatrixError(f"published Tightbeam {label} did not return structured data") from error
        if not isinstance(value, dict):
            raise MatrixError(f"published Tightbeam {label} returned an invalid response")
        return value

    def _pair_first_device(self, release_id: int) -> dict[str, str]:
        device_id = "tuner-ci-" + secrets.token_hex(12)
        with _WebSocket(self.gateway_url) as ws:
            ws.send_json({
                "type": "pair_request",
                "protocolVersion": 1,
                "deviceId": device_id,
                "claimedName": "Tuner compatibility fixture",
                "deviceInfo": {"platform": "sim", "model": "iOS compatibility client"},
            })
            result = ws.receive_json(timeout=20)
        if (
            not isinstance(result, dict) or result.get("type") != "pair_result"
            or result.get("success") is not True
            or not isinstance(result.get("token"), str)
            or not isinstance(result.get("userId"), str)
        ):
            raise MatrixError("published Tightbeam did not auto-approve the first fixture device pair")
        return {
            "deviceId": device_id,
            "deviceToken": str(result["token"]),
            "userId": str(result["userId"]),
        }

    def _connect_device(self, token: str, device_id: str) -> None:
        auth_result: dict[str, Any] | None = None
        sync_complete = False
        with _WebSocket(self.gateway_url) as ws:
            ws.send_json({"type": "auth", "token": token, "deviceId": device_id})
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not sync_complete:
                frame = ws.receive_json(timeout=max(0.1, deadline - time.monotonic()))
                if frame is None:
                    raise MatrixError("published Tightbeam closed the authenticated fixture device connection")
                if frame.get("type") == "auth_result":
                    auth_result = frame
                elif frame.get("type") == "sync_complete":
                    sync_complete = True
        if not sync_complete or auth_result is None or auth_result.get("success") is not True:
            raise MatrixError("published Tightbeam rejected fixture device authentication or initial sync")

    def _post_human_message(
        self,
        gateway_url: str,
        context: dict[str, Any],
        session_key: str,
        message_id: str,
    ) -> int:
        authenticated = False
        acknowledged = False
        with _WebSocket(gateway_url) as ws:
            ws.send_json({
                "type": "auth",
                "token": str(context["deviceToken"]),
                "deviceId": str(context["deviceId"]),
            })
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not authenticated:
                frame = ws.receive_json(timeout=max(0.1, deadline - time.monotonic()))
                if frame is None:
                    raise MatrixError("published Tightbeam closed the fixture chat connection before sync")
                if frame.get("type") == "auth_result":
                    if frame.get("success") is not True or frame.get("userId") != context["userId"]:
                        raise MatrixError("published Tightbeam rejected the fixture chat identity")
                if frame.get("type") == "sync_complete":
                    authenticated = True
            if not authenticated:
                raise MatrixError("published Tightbeam did not complete fixture chat authentication")
            ws.send_json({
                "type": "message",
                "id": message_id,
                "sessionKey": session_key,
                "content": "Reply to this uniquely identified Tuner compatibility fixture message.",
            })
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and not acknowledged:
                frame = ws.receive_json(timeout=max(0.1, deadline - time.monotonic()))
                if frame is None:
                    break
                if frame.get("type") == "error" and frame.get("id") == message_id:
                    raise MatrixError("published Tightbeam rejected the fixture human message")
                if frame.get("type") == "ack" and frame.get("id") == message_id:
                    acknowledged = True
            if not acknowledged:
                raise MatrixError("published Tightbeam did not acknowledge the fixture human message")
        return _wait_for_reply(gateway_url, session_key, message_id)

    def _messages(self, gateway_url: str, session_key: str) -> list[dict[str, Any]]:
        encoded = urllib.parse.quote(session_key, safe="")
        _, page = _http_json(f"{gateway_url}/api/sessions/{encoded}/messages?tail=true&limit=500")
        items = page.get("items")
        if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
            raise MatrixError("published Tightbeam message page was invalid")
        return items

    def _latest_reply(self, gateway_url: str, context: dict[str, Any]) -> int:
        session_key = str(context["replySessionKey"])
        replies = [
            item for item in self._messages(gateway_url, session_key)
            if item.get("role") == "assistant" and item.get("turnIncludesHuman") is True
            and isinstance(item.get("seq"), int) and not isinstance(item.get("seq"), bool)
        ]
        if not replies:
            raise MatrixError("published Tightbeam did not retain a human-backed assistant reply")
        return max(int(item["seq"]) for item in replies)

    def _set_read_marker(self, gateway_url: str, context: dict[str, Any], marker: int) -> None:
        session_key = str(context["replySessionKey"])
        status, result = _http_json(
            gateway_url + "/agent/dispatch",
            method="POST",
            payload={
                "verb": "read-marker-set",
                "params": {"scopeKey": session_key + ":session-read-position", "marker": marker},
            },
            headers={"Authorization": "Bearer " + str(context["deviceToken"])},
        )
        if status != 200 or result.get("ok") is False or result.get("error"):
            raise MatrixError("published Tightbeam rejected the paired-device read-marker update")

    def _marker_value(self, gateway_url: str, context: dict[str, Any]) -> int:
        query = urllib.parse.urlencode({"asUser": context["userId"], "limit": 500})
        _, page = _http_json(gateway_url + "/api/read-markers?" + query)
        items = page.get("items")
        if not isinstance(items, list):
            raise MatrixError("published Tightbeam read-marker page was invalid")
        scope = str(context["replySessionKey"]) + ":session-read-position"
        for item in items:
            if (
                isinstance(item, dict) and item.get("userId") == context["userId"]
                and item.get("scopeKey") == scope and isinstance(item.get("marker"), int)
            ):
                return int(item["marker"])
        raise MatrixError("published Tightbeam did not retain the expected session read marker")

    def _post_and_mark(self, gateway_url: str, context: dict[str, Any], stage: str) -> tuple[int, int]:
        previous = context.get("latest", {"sequence": 0, "marker": 0})
        previous_sequence = previous.get("sequence", 0)
        previous_marker = previous.get("marker", 0)
        if (
            not isinstance(previous_sequence, int) or isinstance(previous_sequence, bool)
            or not isinstance(previous_marker, int) or isinstance(previous_marker, bool)
        ):
            raise MatrixError("fixture's prior Replies position was invalid")
        message_id = "c_tuner_ci_" + secrets.token_hex(12)
        sequence = self._post_human_message(gateway_url, context, str(context["replySessionKey"]), message_id)
        self._set_read_marker(gateway_url, context, sequence)
        marker = self._marker_value(gateway_url, context)
        if marker != sequence:
            raise MatrixError("published Tightbeam read marker did not match the correlated reply")
        context.setdefault("posts", {})[stage] = {
            "sequence": sequence,
            "marker": marker,
            "previousSequence": previous_sequence,
            "previousMarker": previous_marker,
        }
        context["latest"] = {"sequence": sequence, "marker": marker}
        return sequence, marker

    def _seed_replies(self, release_id: int) -> dict[str, Any]:
        context = self.runtime_identities.get(release_id)
        if context is None:
            paired = self._pair_first_device(release_id)
            context = {
                **paired,
                "posts": {},
            }
            self.runtime_identities[release_id] = context
            self._write_current_runtime_env(release_id, str(context["userId"]))
            self._connect_device(str(context["deviceToken"]), str(context["deviceId"]))
            endpoint = f"http://127.0.0.1:{self.model_port}/v1"
            self._cli(
                release_id, "onboard", "local-openai", "--name", "tunerci",
                "--endpoint", endpoint, "--as-user", str(context["userId"]),
                timeout=300,
            )
            preflight = _preflight_pi_model(
                self.pi_bin / "pi",
                home=self.home_root,
                endpoint=endpoint,
                env=self._runtime_env(release_id),
                cwd=self.root,
                observed_requests=self.model_requests,
                diagnostic_path=self.root / "command-logs" / f"pi-preflight-{release_id}.log",
                diagnostic_redactions=self.diagnostic_redaction_values(),
            )
            self.pi_model_preflights.append({"releaseId": release_id, **preflight})
            self._cli(
                release_id, "spawn", "--as-user", str(context["userId"]),
                "--display", "Tuner compatibility reply", "--harness", "pi",
                "--model", "tunerci/tuner-fixture", "--key", "tuner-ci-" + secrets.token_hex(12),
                timeout=300,
            )
            work_item = self._parse_cli_json(self._cli(
                release_id, "work-item-create", "--as-user", str(context["userId"]),
                "--title", "Tuner compatibility topology", "--key", "tuner-ci-" + secrets.token_hex(12),
            ), "work-item creation")
            work_item_id = self._find_cli_id(work_item, {"workItemId", "id"}, "wi_")
            roster = self._read_roster(release_id, str(context["userId"]))
            children = [item for item in roster if item.get("displayName") == "Tuner compatibility reply"]
            mains = [item for item in roster if item.get("displayName") == "Main"]
            if len(children) != 1 or len(mains) != 1:
                raise MatrixError("published Tightbeam roster did not contain the unique fixture Main and child sessions")
            child_key = children[0].get("sessionKey")
            main_key = mains[0].get("sessionKey")
            if not isinstance(child_key, str) or not isinstance(main_key, str) or not child_key or not main_key:
                raise MatrixError("published Tightbeam roster did not return the fixture session identities")
            assignment = self._parse_cli_json(self._cli(
                release_id, "assign", "--as-user", str(context["userId"]), "--session", child_key,
                "--subject", "Tuner compatibility topology", "--work-item", work_item_id,
                "--effect-kind", "evidence", "--key", "tuner-ci-" + secrets.token_hex(12),
            ), "session assignment")
            assignment_id = self._find_cli_id(assignment, {"assignmentId", "id"}, "asg_")
            self._cli(
                release_id, "session-reparent", "--as-user", str(context["userId"]),
                "--session", child_key, "--parent", main_key, "--assignment", assignment_id,
                "--key", "tuner-ci-" + secrets.token_hex(12),
            )
            roster = self._read_roster(release_id, str(context["userId"]))
            child = next((item for item in roster if item.get("sessionKey") == child_key), None)
            if not isinstance(child, dict) or child.get("currentParent") != main_key:
                raise MatrixError("published Tightbeam did not persist the assigned child's Main parent relation")
            context.update({
                "userId": str(context["userId"]),
                "mainSessionKey": main_key,
                "replySessionKey": child_key,
            })
            self._post_and_mark(self.gateway_url, context, "initial")
        sequence = self._latest_reply(self.gateway_url, context)
        marker = self._marker_value(self.gateway_url, context)
        context["latest"] = {"sequence": sequence, "marker": marker}
        return {
            "userId": context["userId"],
            "mainSessionKey": context["mainSessionKey"],
            "replySessionKey": context["replySessionKey"],
            "parentSessionKey": context["mainSessionKey"],
            "assistantSequence": sequence,
            "initialReadMarker": marker,
        }

    @staticmethod
    def _find_cli_id(value: Any, names: set[str], prefix: str) -> str:
        matches: list[str] = []
        if isinstance(value, dict):
            for key, child in value.items():
                if key in names and isinstance(child, str) and child.startswith(prefix):
                    matches.append(child)
                else:
                    matches.extend(LocalRuntimeFixture._find_cli_id_collect(child, names, prefix))
        else:
            matches.extend(LocalRuntimeFixture._find_cli_id_collect(value, names, prefix))
        unique = set(matches)
        if len(unique) != 1:
            raise MatrixError(f"published Tightbeam did not return one {prefix} identity")
        return unique.pop()

    @staticmethod
    def _find_cli_id_collect(value: Any, names: set[str], prefix: str) -> list[str]:
        if isinstance(value, dict):
            output: list[str] = []
            for key, child in value.items():
                if key in names and isinstance(child, str) and child.startswith(prefix):
                    output.append(child)
                else:
                    output.extend(LocalRuntimeFixture._find_cli_id_collect(child, names, prefix))
            return output
        if isinstance(value, list):
            return [match for item in value for match in LocalRuntimeFixture._find_cli_id_collect(item, names, prefix)]
        return []

    def _read_roster(self, release_id: int, user_id: str) -> list[dict[str, Any]]:
        value = self._parse_cli_json(self._cli(release_id, "list", "--as-user", user_id), "roster")
        sessions = value.get("sessions")
        if not isinstance(sessions, list) or any(not isinstance(item, dict) for item in sessions):
            raise MatrixError("published Tightbeam CLI returned an invalid roster")
        return sessions

    def _catch_up(self, release_id: int, session_key: str) -> dict[str, Any]:
        context = self.runtime_identities.get(release_id)
        if context is None or session_key != context.get("replySessionKey"):
            raise MatrixError("catch-up target did not match the seeded fixture session")
        previous = context.get("latest")
        if not isinstance(previous, dict):
            raise MatrixError("catch-up has no prior committed Replies position")
        self._stop_gateway()
        _require_port_clear(self.gateway_port, "published gateway during catch-up disconnect")
        temporary_port = _available_port()
        while temporary_port in {self.gateway_port, self.ssh_port, self.model_port}:
            temporary_port = _available_port()
        temporary_process: subprocess.Popen[bytes] | None = None
        temporary_log: Any = None
        try:
            package = self.package_paths[release_id]
            binary = release_hook.find_runtime_executable(package, "tightbeam-gateway")
            env = self._runtime_env(release_id, port=temporary_port)
            temporary_log = (self.root / f"gateway-catch-up-{release_id}.log").open("ab")
            temporary_process = subprocess.Popen(
                [str(binary)], cwd=self.root, env=env, stdin=subprocess.DEVNULL,
                stdout=temporary_log, stderr=temporary_log,
            )
            temporary_gateway = f"http://127.0.0.1:{temporary_port}"
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if temporary_process.poll() is not None:
                    raise MatrixError("published Tightbeam catch-up gateway exited during startup")
                try:
                    with urllib.request.urlopen(temporary_gateway + "/version", timeout=2) as response:
                        version_text = response.read(65536).decode("utf-8", "replace")
                    break
                except (urllib.error.URLError, TimeoutError, OSError):
                    time.sleep(0.25)
            else:
                raise MatrixError("published Tightbeam catch-up gateway did not become ready")
            release = self.by_id[release_id]
            version_core = re.search(r"\d+\.\d+\.\d+", release.tag)
            build_part = release.tag.split("+", 1)[1] if "+" in release.tag else None
            if version_core is None or version_core.group(0) not in version_text or (build_part and build_part not in version_text):
                raise MatrixError("published Tightbeam catch-up gateway did not match its pinned release")
            self._record_gateway_listener(release_id, temporary_port, "published catch-up gateway")
            sequence, marker = self._post_and_mark(temporary_gateway, context, "catch-up")
        finally:
            if temporary_process is not None and temporary_process.poll() is None:
                temporary_process.terminate()
                try:
                    temporary_process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    temporary_process.kill()
                    temporary_process.wait(timeout=5)
            if temporary_log is not None:
                temporary_log.close()
            if temporary_process is not None:
                _require_port_clear(temporary_port, "temporary catch-up gateway")
            self._start_gateway(release_id)
        return {
            "ok": True,
            "correlatedReply": True,
            "previousSequence": int(previous["sequence"]),
            "assistantSequence": sequence,
            "previousMarker": int(previous["marker"]),
            "marker": marker,
            "changedSessionMatched": True,
            "gatewayRestarted": True,
        }

    def _route(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        if path == "/select-runtime":
            release_id = payload.get("releaseId")
            if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id not in self.by_id:
                raise MatrixError("unknown pinned runtime")
            if self.selected_release_id != release_id or self.gateway_process is None or self.gateway_process.poll() is not None:
                self._stop_gateway()
                self._start_gateway(release_id)
            return {"ok": True}
        if path == "/seed-replies":
            release_id = payload.get("releaseId")
            if release_id != self.selected_release_id or release_id not in self.by_id:
                raise MatrixError("fixture seed does not match the selected published runtime")
            return self._seed_replies(int(release_id))
        if path == "/authorized-key":
            line = payload.get("publicKey")
            if not isinstance(line, str) or not re.fullmatch(r"ssh-ed25519\s+[A-Za-z0-9+/=]+(?:\s+[A-Za-z0-9_.-]+)?", line):
                raise MatrixError("invalid isolated roster key")
            self.authorized_keys.write_text(line.strip() + "\n", encoding="utf-8")
            self.authorized_keys.chmod(0o600)
            self._start_sshd()
            return {"ok": True}
        if path == "/record-baseline-state":
            release_id = payload.get("releaseId")
            connection = payload.get("connection")
            key = payload.get("publicKey")
            if release_id not in self.by_id or not isinstance(connection, dict) or not isinstance(key, str):
                raise MatrixError("baseline state is incomplete")
            self.saved_state[release_id] = {"connection": connection, "publicKey": key}
            return {"ok": True}
        if path == "/verify-upgrade-state":
            release_id = self.selected_release_id
            previous = self.saved_state.get(release_id) if release_id is not None else None
            connection = payload.get("connection")
            key = payload.get("publicKey")
            return {
                "ok": previous is not None,
                "savedConnectionLoaded": bool(previous and connection == previous["connection"]),
                "rosterIdentityPreserved": bool(previous and key == previous["publicKey"]),
            }
        if path == "/post-reply":
            if self.selected_release_id is None:
                raise MatrixError("no published runtime is selected")
            release_id = payload.get("releaseId")
            context = self.runtime_identities.get(release_id) if isinstance(release_id, int) else None
            if context is None or payload.get("sessionKey") != context.get("replySessionKey"):
                raise MatrixError("live reply target did not match the seeded fixture session")
            sequence, marker = self._post_and_mark(self.gateway_url, context, "live")
            observation = context["posts"]["live"]
            return {
                "ok": True,
                "correlatedReply": True,
                "previousSequence": observation["previousSequence"],
                "assistantSequence": sequence,
                "previousMarker": observation["previousMarker"],
                "marker": marker,
            }
        if path == "/catch-up":
            if self.selected_release_id is None:
                raise MatrixError("no published runtime is selected")
            release_id = payload.get("releaseId")
            if not isinstance(release_id, int) or release_id != self.selected_release_id:
                raise MatrixError("catch-up release identity did not match the selected runtime")
            session_key = payload.get("sessionKey")
            if not isinstance(session_key, str):
                raise MatrixError("catch-up session identity is missing")
            return self._catch_up(release_id, session_key)
        if path == "/phase-result":
            result = dict(payload)
            release_id = result.get("releaseId")
            if release_id not in self.by_id or result.get("phase") not in {"baseline", "candidate"}:
                raise MatrixError("compatibility phase result has an invalid release or phase")
            self.phase_results.append(result)
            return {"ok": True}
        raise MatrixError("unknown fixture route")

    def close(self) -> None:
        self._stop_gateway()
        if self.sshd_process is not None and self.sshd_process.poll() is None:
            self.sshd_process.terminate()
            try:
                self.sshd_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.sshd_process.kill()
                self.sshd_process.wait(timeout=5)
        if self.sshd_log is not None:
            self.sshd_log.close()
            self.sshd_log = None
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None
        if self.server_thread is not None:
            self.server_thread.join(timeout=5)
            self.server_thread = None
        if self.model_server is not None:
            self.model_server.shutdown()
            self.model_server.server_close()
            self.model_server = None
        if self.model_thread is not None:
            self.model_thread.join(timeout=5)
            self.model_thread = None
        _require_port_clear(self.gateway_port, "gateway")
        _require_port_clear(self.ssh_port, "SSH fixture")
        _require_port_clear(self.model_port, "model fixture")

    def diagnostic_redaction_values(self) -> set[str]:
        values = {
            self.fixture_token,
            self.local_user,
            self.ssh_host_key_line,
            str(self.root),
            str(self.home_root),
        }
        values.update(str(path) for path in self.package_paths.values())
        values.update(str(path) for path in self.runtime_base.values())

        def collect(value: Any, field: str = "") -> None:
            sensitive_field = any(part in field.casefold() for part in (
                "key", "token", "user", "session", "device", "credential", "password", "secret",
            ))
            if isinstance(value, str) and sensitive_field and len(value) >= 6:
                values.add(value)
            elif isinstance(value, dict):
                for name, child in value.items():
                    collect(child, str(name))
            elif isinstance(value, (list, tuple, set)):
                for child in value:
                    collect(child, field)

        collect(self.runtime_identities)
        collect(self.saved_state)
        collect(self.phase_results)
        for private_path in (self.host_key,):
            try:
                private_value = private_path.read_text(encoding="utf-8")
            except OSError:
                continue
            if private_value.strip():
                values.add(private_value.strip())
        return {value for value in values if len(value) >= 6}

    def export_safe_runtime_logs(self, destination: Path) -> list[str]:
        destination.mkdir(parents=True, exist_ok=True)
        redactions = self.diagnostic_redaction_values()
        retained: list[str] = []
        for source in sorted(self.root.rglob("*.log")):
            if not source.is_file():
                continue
            try:
                contents = source.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            relative_name = source.relative_to(self.root).as_posix()
            relative_name = _safe_diagnostic_text(relative_name, redactions).replace("/", "__")
            safe_name = re.sub(r"[^A-Za-z0-9_.-]", "_", relative_name)
            (destination / safe_name).write_text(
                _safe_diagnostic_text(contents, redactions), encoding="utf-8"
            )
            retained.append(safe_name)
        if not retained:
            marker = "no-runtime-logs-generated.txt"
            (destination / marker).write_text(
                "The compatibility fixture did not generate runtime log files.\n",
                encoding="utf-8",
            )
            retained.append(marker)
        return retained


def _create_simulator(
    device_types: list[tuple[str, str]],
    runtime_id: str,
    build_number: int,
    *,
    diagnostic_directory: Path | None = None,
) -> tuple[str, str, str, str]:
    simctl = _require_command("xcrun")
    name = f"TunerCompatibility-{build_number}"
    if not device_types:
        _safe_fail("Xcode has no candidate iPhone simulator types for the selected runtime")
    if diagnostic_directory is not None:
        diagnostic_directory.mkdir(parents=True, exist_ok=True)

    udid = ""
    selected_device_type = ""
    selected_device_name = ""
    selected_create_log: Path | None = None
    incompatible: list[str] = []
    for index, (device_type, device_name) in enumerate(device_types, start=1):
        create_log = None
        if diagnostic_directory is not None:
            filename = "simulator-create.log" if index == 1 else f"simulator-create-attempt-{index}.log"
            create_log = diagnostic_directory / filename
        created = _run(
            [simctl, "simctl", "create", name, device_type, runtime_id],
            timeout=60,
            diagnostic_path=create_log,
        )
        if created.returncode != 0:
            if "Incompatible device" in created.stdout:
                incompatible.append(device_name)
                continue
            message = "compatibility-matrix command failed: xcrun"
            if create_log is not None:
                message += f"; diagnostic retained as {create_log.name}"
            _safe_fail(message)
        udid = created.stdout.strip()
        selected_device_type = device_type
        selected_device_name = device_name
        selected_create_log = create_log
        break

    if not udid:
        details = ", ".join(incompatible)
        message = "Xcode rejected every eligible iPhone simulator type for the selected runtime"
        if details:
            message += f" ({details})"
        if diagnostic_directory is not None:
            message += f"; inspect simulator diagnostics in {diagnostic_directory.name}"
        _safe_fail(message)

    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", udid):
        _safe_fail("Xcode did not return an exact owned simulator identifier")
    if selected_create_log is not None:
        # A successful create returns the simulator UDID. Keep the success
        # marker, not the identifier, in the CI artifact.
        selected_create_log.write_text(
            "simulator create succeeded; identifier redacted\n", encoding="utf-8"
        )
        selected_create_log.chmod(0o600)
    redactions = {udid}
    failures: list[str] = []
    for attempt in (1, 2):
        boot_log = (
            diagnostic_directory / f"simulator-boot-attempt-{attempt}.log"
            if diagnostic_directory is not None else None
        )
        ready_log = (
            diagnostic_directory / f"simulator-readiness-attempt-{attempt}.log"
            if diagnostic_directory is not None else None
        )
        try:
            boot = _run(
                [simctl, "simctl", "boot", udid], timeout=90,
                diagnostic_path=boot_log, diagnostic_redactions=redactions,
            )
            if boot.returncode != 0:
                failures.append(f"boot attempt {attempt} exited unsuccessfully")
                raise MatrixError("simulator boot command failed")
            readiness = _run(
                [simctl, "simctl", "bootstatus", udid, "-b"], timeout=300,
                diagnostic_path=ready_log, diagnostic_redactions=redactions,
            )
            if readiness.returncode != 0:
                failures.append(f"readiness attempt {attempt} exited unsuccessfully")
                raise MatrixError("simulator readiness command failed")
            return udid, name, selected_device_type, selected_device_name
        except MatrixError:
            if not failures or not failures[-1].endswith(str(attempt)):
                failures.append(f"boot/readiness attempt {attempt} timed out or failed")
            if attempt == 1:
                shutdown_log = (
                    diagnostic_directory / "simulator-retry-shutdown.log"
                    if diagnostic_directory is not None else None
                )
                try:
                    _run(
                        [simctl, "simctl", "shutdown", udid], timeout=60,
                        diagnostic_path=shutdown_log, diagnostic_redactions=redactions,
                    )
                except MatrixError:
                    failures.append("simulator shutdown before retry failed")
                time.sleep(1)
    try:
        _delete_simulator(udid)
    except MatrixError:
        failures.append("owned simulator cleanup did not verify")
    diagnostic_note = (
        f"; inspect simulator diagnostics in {diagnostic_directory.name}"
        if diagnostic_directory is not None else ""
    )
    raise MatrixError(
        "Xcode simulator did not become ready after one retry"
        + (f" ({'; '.join(failures)})" if failures else "")
        + diagnostic_note
    )


def _delete_simulator(udid: str) -> None:
    simctl = _require_command("xcrun")
    try:
        _run([simctl, "simctl", "shutdown", udid], timeout=30)
    except MatrixError:
        # Still try to delete this exact task-owned device and verify its final
        # absence below. A stale shutdown result must not prevent cleanup.
        pass
    try:
        _run([simctl, "simctl", "delete", udid], timeout=60)
    except MatrixError:
        # simctl can report failure after completing the delete; the device
        # inventory below is the source of truth for whether cleanup finished.
        pass
    inventory = _run([simctl, "simctl", "list", "devices", "--json"], timeout=30)
    if inventory.returncode != 0:
        _safe_fail("Xcode could not verify the compatibility matrix simulator cleanup")
    try:
        devices = json.loads(inventory.stdout).get("devices", {})
    except (json.JSONDecodeError, AttributeError):
        _safe_fail("Xcode returned an invalid simulator inventory during cleanup")
    if any(
        isinstance(device, dict) and device.get("udid") == udid
        for runtime_devices in devices.values()
        if isinstance(runtime_devices, list)
        for device in runtime_devices
    ):
        _safe_fail("Xcode retained the compatibility matrix's owned simulator")


def _run_test_phase(
    *,
    source_root: Path,
    project: Path,
    derived_data: Path,
    result_bundle: Path,
    scheme: str,
    configuration: str,
    build_number: int,
    simulator_id: str,
    simulator_type_name: str,
    simulator_runtime_name: str,
    phase: str,
    phase_source: dict[str, Any],
    candidate: dict[str, Any],
    pair: tuple[release_hook.PublishedRelease, release_hook.PublishedRelease],
    fixture: LocalRuntimeFixture,
    attempt: int,
) -> None:
    derived_data.mkdir(parents=True, exist_ok=True)
    result_bundle.parent.mkdir(parents=True, exist_ok=True)
    if result_bundle.exists():
        _safe_fail("compatibility matrix result bundle path is already occupied")
    env = fixture.base_environment.copy()
    test_values = {
        "TUNER_COMPAT_PHASE": phase,
        "TUNER_COMPAT_FIXTURE_URL": fixture.fixture_url,
        "TUNER_COMPAT_FIXTURE_TOKEN": fixture.fixture_token,
        "TUNER_COMPAT_GATEWAY_URL": fixture.gateway_url,
        "TUNER_COMPAT_SSH_PORT": str(fixture.ssh_port),
        "TUNER_COMPAT_SSH_HOST_KEY": fixture.ssh_host_key_line,
        "TUNER_COMPAT_SSH_USER": fixture.local_user,
        "TUNER_COMPAT_CLI": str(fixture.cli_link),
        "TUNER_COMPAT_RELEASES_JSON": json.dumps([{"id": item.release_id} for item in pair], separators=(",", ":")),
        "TUNER_COMPAT_PHASE_SOURCE_JSON": json.dumps(phase_source, separators=(",", ":")),
        "TUNER_COMPAT_CANDIDATE_JSON": json.dumps(candidate, separators=(",", ":")),
        "TUNER_COMPAT_RUN_ID": candidate["runId"],
        "TUNER_COMPAT_ATTEMPT": str(attempt),
        "TUNER_COMPAT_SIMULATOR_TYPE": simulator_type_name,
        "TUNER_COMPAT_SIMULATOR_RUNTIME": simulator_runtime_name,
    }
    _add_xctest_environment(env, test_values)
    command = [
        "xcodebuild", "-project", str(project), "-scheme", scheme,
        "-configuration", configuration,
        "-destination", f"platform=iOS Simulator,id={simulator_id}",
        "-derivedDataPath", str(derived_data),
        "-resultBundlePath", str(result_bundle),
        "-parallel-testing-enabled", "NO",
        "-maximum-concurrent-test-simulator-destinations", "1",
        "-jobs", "2",
        "-only-testing:TightbeamTunerTests/ReleaseCompatibilityTests/testProductionRosterAndRepliesPathsAgainstPublishedRuntime",
        "test", f"CURRENT_PROJECT_VERSION={build_number}", "CODE_SIGNING_ALLOWED=NO",
        "ENABLE_TESTABILITY=YES",
        f"TUNER_EXPECTED_BUNDLE_IDENTIFIER={release_hook.expected_bundle_identifier()}",
    ]
    log_path = result_bundle.with_suffix(".log")
    try:
        with log_path.open("wb") as log:
            result = subprocess.run(
                command,
                cwd=source_root,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=1800,
                check=False,
            )
    except (OSError, subprocess.TimeoutExpired) as error:
        retained = _retain_xctest_diagnostics(result_bundle, log_path, fixture, phase)
        diagnostics = {
            **_safe_xcode_failure_summary(log_path),
            "retainedArtifacts": retained,
        }
        raise MatrixError(
            f"Xcode {phase} compatibility test did not complete", diagnostics=diagnostics
        ) from error
    if result.returncode != 0:
        # Do not echo raw xcodebuild output: the test process contains a private
        # fixture token and ephemeral user/key material in its environment.
        retained = _retain_xctest_diagnostics(result_bundle, log_path, fixture, phase)
        diagnostics = {
            **_safe_xcode_failure_summary(log_path),
            "retainedArtifacts": retained,
        }
        raise MatrixError(
            f"Xcode {phase} compatibility test failed; inspect the sanitized failure summary",
            diagnostics=diagnostics,
        )


def _safe_xcode_failure_summary(log_path: Path) -> dict[str, Any]:
    """Retain source locations and assertion kinds without copying private test output."""
    try:
        with log_path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - 1024 * 1024), os.SEEK_SET)
            lines = stream.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return {"available": False, "sourceLocations": [], "assertionKinds": [], "errorCount": 0}

    location_pattern = re.compile(
        r"(?P<file>[A-Za-z0-9_.-]+\.swift):(?P<line>\d+)(?::\d+)?:\s*(?P<severity>error|warning):",
        re.IGNORECASE,
    )
    assertion_pattern = re.compile(r"\b(XCTAssert[A-Za-z]*|XCTFail|XCTUnwrap)\b")
    locations: set[tuple[str, int, str]] = set()
    assertions: set[str] = set()
    errors = 0
    warnings = 0
    for line in lines:
        match = location_pattern.search(line)
        if match:
            source_name = match.group("file")
            line_number = int(match.group("line"))
            severity = match.group("severity").lower()
            locations.add((source_name, line_number, severity))
            errors += severity == "error"
            warnings += severity == "warning"
        if "error:" in line.casefold() and not match:
            errors += 1
        assertion = assertion_pattern.search(line)
        if assertion:
            assertions.add(assertion.group(1))

    return {
        "available": True,
        "sourceLocations": [
            {"file": filename, "line": line_number, "severity": severity}
            for filename, line_number, severity in sorted(locations)
        ][:50],
        "assertionKinds": sorted(assertions),
        "errorCount": errors,
        "warningCount": warnings,
    }


def _safe_diagnostic_text(text: str, redaction_values: set[str]) -> str:
    safe = text
    for value in sorted(redaction_values, key=len, reverse=True):
        safe = safe.replace(value, "[redacted]")
    safe = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}", r"\1[redacted]", safe)
    safe = re.sub(r"(?i)(x-test-fixture-token\s*[:=]\s*)[^\s,;]+", r"\1[redacted]", safe)
    safe = re.sub(r"(?i)(authorization\s*:\s*)[^\r\n]+", r"\1[redacted]", safe)
    safe = re.sub(r"ssh-ed25519\s+[A-Za-z0-9+/=]+(?:\s+[A-Za-z0-9_.-]+)?", "ssh-ed25519 [redacted]", safe)
    safe = re.sub(r"\bagent:[A-Za-z0-9:_-]{12,}", "[session-key]", safe)
    safe = re.sub(r"\b(?:user|device|wi|asg|art|dr)_[A-Za-z0-9_-]{8,}\b", "[private-id]", safe)
    safe = re.sub(
        r"(?<![A-Za-z0-9])[a-z]{2,4}\d{2}-[a-z]{2,5}\d{3,4}-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}-[0-9a-f]{12}(?![A-Za-z0-9])",
        "[runtime-session]",
        safe,
        flags=re.IGNORECASE,
    )
    safe = re.sub(
        r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
        "[private key redacted]",
        safe,
        flags=re.DOTALL,
    )
    return safe


def _contains_sensitive_bytes(bundle: Path, redaction_values: set[str]) -> bool:
    needles = [value.encode("utf-8") for value in redaction_values if len(value) >= 6]
    needles = [needle for needle in needles if needle]
    if not needles:
        return False
    overlap = max(map(len, needles)) - 1
    try:
        for source in bundle.rglob("*"):
            if not source.is_file():
                continue
            carry = b""
            with source.open("rb") as stream:
                while block := stream.read(1024 * 1024):
                    data = carry + block
                    if any(needle in data for needle in needles):
                        return True
                    carry = data[-overlap:] if overlap else b""
    except OSError:
        return True
    return False


def _retain_xctest_diagnostics(
    result_bundle: Path,
    log_path: Path,
    fixture: LocalRuntimeFixture,
    phase: str,
) -> dict[str, bool]:
    destination_value = os.environ.get("CI_DIAGNOSTIC_ARTIFACTS_PATH")
    if not destination_value:
        return {"xcodebuildLog": False, "xcresult": False, "readableTestResults": False}
    destination = Path(destination_value).expanduser().resolve() / "xctest"
    redactions = fixture.diagnostic_redaction_values()
    retained = {"xcodebuildLog": False, "xcresult": False, "readableTestResults": False}

    try:
        destination.mkdir(parents=True, exist_ok=True)
        log_contents = log_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        log_contents = "Xcode test log was not available.\n"
    try:
        (destination / f"{phase}-xcodebuild.log.txt").write_text(
            _safe_diagnostic_text(log_contents, redactions), encoding="utf-8"
        )
        retained["xcodebuildLog"] = True
    except OSError:
        pass

    if result_bundle.is_dir():
        if _contains_sensitive_bytes(result_bundle, redactions):
            try:
                (destination / f"{phase}-xcresult-omitted.txt").write_text(
                    "The result bundle contained a known ephemeral fixture value and was not uploaded.\n",
                    encoding="utf-8",
                )
            except OSError:
                pass
        else:
            try:
                shutil.copytree(result_bundle, destination / f"{phase}.xcresult")
                retained["xcresult"] = True
            except OSError:
                pass

        try:
            command = [
                _require_command("xcrun"), "xcresulttool", "get", "test-results", "tests",
                "--path", str(result_bundle),
            ]
            extracted = _run(command, cwd=result_bundle.parent, timeout=120)
            readable = extracted.stdout or extracted.stderr or "xcresulttool did not return test results.\n"
            readable = _safe_diagnostic_text(readable, redactions)
            readable_succeeded = extracted.returncode == 0
        except Exception:
            readable = "xcresulttool could not extract readable test results.\n"
            readable_succeeded = False
        try:
            (destination / f"{phase}-test-results.txt").write_text(readable, encoding="utf-8")
            retained["readableTestResults"] = readable_succeeded
        except OSError:
            pass
    return retained


def _retain_runtime_diagnostics(fixture: LocalRuntimeFixture | None) -> list[str] | None:
    destination_value = os.environ.get("CI_DIAGNOSTIC_ARTIFACTS_PATH")
    if not destination_value or fixture is None:
        return None
    return fixture.export_safe_runtime_logs(Path(destination_value).expanduser().resolve() / "runtime")


def _retain_fixture_startup_diagnostics(root: Path) -> list[str]:
    """Preserve safe command output when fixture construction fails before assignment."""
    destination_value = os.environ.get("CI_DIAGNOSTIC_ARTIFACTS_PATH")
    if not destination_value:
        return []
    destination = Path(destination_value).expanduser().resolve() / "fixture-startup"
    destination.mkdir(parents=True, exist_ok=True)
    redactions = {str(root.resolve())}
    retained: list[str] = []
    for source in sorted(root.rglob("*.log")):
        if not source.is_file():
            continue
        safe_name = re.sub(
            r"[^A-Za-z0-9_.-]", "_",
            _safe_diagnostic_text(source.relative_to(root).as_posix(), redactions).replace("/", "__"),
        )
        contents = source.read_text(encoding="utf-8", errors="replace")
        output = destination / safe_name
        output.write_text(_safe_diagnostic_text(contents, redactions), encoding="utf-8")
        output.chmod(0o600)
        retained.append(safe_name)
    if not retained:
        marker = "no-fixture-startup-logs-generated.txt"
        (destination / marker).write_text("No fixture startup command logs were generated.\n", encoding="utf-8")
        retained.append(marker)
    return retained


def _combine_results(
    phase_results: list[dict[str, Any]],
    candidate: dict[str, Any],
    baseline: dict[str, Any],
    pair: tuple[release_hook.PublishedRelease, release_hook.PublishedRelease],
) -> list[dict[str, Any]]:
    by_key: dict[tuple[int, str], dict[str, Any]] = {}
    for result in phase_results:
        release_id = result.get("releaseId")
        phase = result.get("phase")
        if not isinstance(release_id, int) or phase not in {"baseline", "candidate"}:
            _safe_fail("XCTest returned an invalid compatibility phase identity")
        key = (release_id, phase)
        if key in by_key:
            _safe_fail("XCTest returned duplicate results for a published runtime and phase")
        by_key[key] = result
    expected = {(item.release_id, phase) for item in pair for phase in ("baseline", "candidate")}
    if set(by_key) != expected:
        _safe_fail("XCTest omitted a baseline or candidate result for a published runtime")
    combined: list[dict[str, Any]] = []
    for release in pair:
        baseline_result = by_key[(release.release_id, "baseline")]
        candidate_result = by_key[(release.release_id, "candidate")]
        for result, phase, source in (
            (baseline_result, "baseline", baseline), (candidate_result, "candidate", candidate),
        ):
            if result.get("phaseSource") != source or result.get("candidate") != candidate:
                _safe_fail(f"XCTest {phase} result is not bound to the exact source inputs")
            if result.get("runId") != candidate["runId"] or result.get("attempt") != candidate["attempt"]:
                _safe_fail(f"XCTest {phase} result belongs to another CI run or attempt")
            if not isinstance(result.get("checks"), dict):
                _safe_fail(f"XCTest {phase} result has no per-path outcomes")
        if baseline_result.get("simulator") != candidate_result.get("simulator"):
            _safe_fail("baseline and candidate compatibility results used different simulators")
        simulator = baseline_result.get("simulator")
        if not isinstance(simulator, dict):
            _safe_fail("XCTest result has no simulator identity")
        baseline_checks = baseline_result["checks"]
        candidate_checks = candidate_result["checks"]
        interfaces = {
            path: {
                "baselinePassed": baseline_checks.get(path, {}).get("status") == "passed",
                "candidatePassed": candidate_checks.get(path, {}).get("status") == "passed",
            }
            for path in release_hook.REQUIRED_INTERFACE_PATHS
        }
        combined.append({
            "candidate": candidate,
            "baseline": baseline,
            "baselinePhaseSource": baseline_result["phaseSource"],
            "candidatePhaseSource": candidate_result["phaseSource"],
            "release": {
                "id": release.release_id,
                "tag": release.tag,
                "assetId": release.asset_id,
                "assetName": release.asset_name,
                "assetDigest": release.asset_digest,
            },
            "runId": candidate["runId"],
            "attempt": candidate["attempt"],
            "simulator": simulator,
            "baselineChecks": baseline_checks,
            "checks": candidate_checks,
            "interfaceComparisons": interfaces,
            "upgradeContinuity": candidate_result.get("upgradeContinuity"),
        })
    return combined


def _prepare_candidate(repo: Path, baseline_file: dict[str, Any], build_number: int) -> dict[str, Any]:
    commit_from_ci = os.environ.get("CI_COMMIT", "")
    scheme = os.environ.get("CI_XCODE_SCHEME", "")
    run_id = os.environ.get("CI_BUILD_ID", "")
    if not re.fullmatch(r"[0-9a-f]{40}", commit_from_ci) or not scheme or not run_id:
        _safe_fail("CI candidate identity is incomplete")
    commit, tree = _current_source(repo, commit_from_ci)
    configuration = "Release"
    if baseline_file["scheme"] != scheme or baseline_file["configuration"] != configuration:
        _safe_fail("candidate and pinned baseline use different release schemes or configurations")
    return {
        "commit": commit,
        "tree": tree,
        "scheme": scheme,
        "configuration": configuration,
        "buildNumber": build_number,
        "runId": run_id,
        "attempt": release_notes.XCODE_CLOUD_ATTEMPT_NUMBER,
    }


def _validate_execution_mode(diagnostic: bool) -> None:
    action = os.environ.get("CI_XCODEBUILD_ACTION", "").strip().casefold()
    if diagnostic:
        if action == "archive":
            _safe_fail("diagnostic compatibility matrix cannot run in an archive action")
        return
    try:
        expected_workflow = release_hook.expected_archive_workflow()
    except release_hook.ReleaseHookError as error:
        raise MatrixError(str(error)) from error
    if os.environ.get("CI_WORKFLOW", "").strip().casefold() != expected_workflow.casefold():
        if release_hook.configured_release_route() == release_hook.PRODUCTION_ROUTE:
            _safe_fail("compatibility matrix is restricted to the Internal Testflight Xcode Cloud workflow")
        _safe_fail("compatibility matrix is restricted to the configured proof release workflow")
    if action != "archive":
        _safe_fail("compatibility matrix requires the Xcode Cloud archive action")


def _review_confirmation(diagnostic: bool, commit: str, candidate_digest: str) -> dict[str, Any] | None:
    if diagnostic:
        return None
    return release_hook.latest_public_review_status(commit, candidate_digest)


def run_matrix(
    *, diagnostic: bool = False,
    planned_build_number: int | None = None,
    diagnostic_output: Path | None = None,
) -> None:
    _validate_execution_mode(diagnostic)
    if diagnostic:
        if (
            not isinstance(planned_build_number, int) or isinstance(planned_build_number, bool)
            or planned_build_number <= 0 or diagnostic_output is None
        ):
            _safe_fail("diagnostic matrix requires an explicit planned build number and report output path")
        build_number = planned_build_number
    else:
        if planned_build_number is not None or diagnostic_output is not None:
            _safe_fail("archive matrix cannot accept diagnostic-only inputs")
        build_number_value = os.environ.get("CI_BUILD_NUMBER", "")
        if not build_number_value.isdigit() or int(build_number_value) <= 0:
            _safe_fail("compatibility matrix has no positive numbered build")
        build_number = int(build_number_value)
    run_id = os.environ.get("CI_BUILD_ID", "")
    if not run_id:
        _safe_fail("compatibility matrix has no unique run ID")
    repo_value = os.environ.get("CI_PRIMARY_REPOSITORY_PATH")
    derived_value = os.environ.get("CI_DERIVED_DATA_PATH")
    if not repo_value or not derived_value:
        _safe_fail("compatibility matrix repository or DerivedData path is unavailable")
    repo = Path(repo_value).resolve()
    derived = Path(derived_value).resolve()
    if not repo.is_dir() or not derived.is_dir():
        _safe_fail("compatibility matrix repository or DerivedData path is unavailable")
    for tool in ("git", "xcodebuild", "xcrun", "ssh-keygen", "sshd", "lsof", "node"):
        _require_command(tool)
    test_root = derived / "TunerCompatibilityResults"
    test_root.mkdir(parents=True, exist_ok=True)
    repo_root = Path(tempfile.mkdtemp(prefix="tuner-compat-", dir=str(test_root))).resolve()
    if os.path.commonpath([str(derived), str(repo_root)]) != str(derived):
        _safe_fail("compatibility scratch escaped the configured DerivedData directory")

    report_path = (
        diagnostic_output.expanduser().resolve()
        if diagnostic and diagnostic_output is not None
        else repo / "ios" / "TightbeamTuner" / "ReleaseCompatibilityReport.json"
    )
    current_note_path = repo / "ios" / "TightbeamTuner" / "CurrentBuildReleaseNote.json"
    history_path = repo / "ios" / "TightbeamTuner" / "ReleaseNotesHistory.json"
    baseline_path = SCRIPT_DIR / "ReleaseBaseline.json"
    matrix_report: dict[str, Any] = {
        "schemaVersion": 1,
        "runMode": "diagnostic" if diagnostic else "archive",
        "status": "failed",
        "failure": "matrix did not complete",
    }
    fixture: LocalRuntimeFixture | None = None
    simulator_id: str | None = None
    worktree: Path | None = None
    pair: tuple[release_hook.PublishedRelease, release_hook.PublishedRelease] | None = None

    try:
        baseline_source = _baseline_input(baseline_path)
        candidate = _prepare_candidate(repo, baseline_source, build_number)
        if not diagnostic:
            release_hook.validate_release_tag_identity(
                repo,
                candidate["commit"],
                os.environ.get("CI_GIT_REF", ""),
                os.environ.get("CI_TAG", ""),
                candidate["buildNumber"],
            )
        matrix_report["candidate"] = candidate
        matrix_report["baseline"] = {
            "commit": baseline_source["sourceCommit"],
            "tree": baseline_source["sourceTree"],
            "scheme": baseline_source["scheme"],
            "configuration": baseline_source["configuration"],
            "buildNumber": baseline_source["buildNumber"],
        }
        release_hook.baseline_reference(baseline_source, {
            "buildNumber": baseline_source["buildNumber"],
            "sourceCommit": baseline_source["sourceCommit"],
            "sourceTree": baseline_source["sourceTree"],
            "scheme": baseline_source["scheme"],
            "configuration": baseline_source["configuration"],
        })
        latest_pair = release_hook.resolve_published_pair("darwin-aarch64")
        pair = latest_pair
        matrix_report["releases"] = [
            {
                "id": item.release_id,
                "tag": item.tag,
                "assetId": item.asset_id,
                "assetName": item.asset_name,
                "assetDigest": item.asset_digest,
            }
            for item in pair
        ]
        for item in pair:
            print(f"Pinned published Tightbeam release {item.tag} asset {item.asset_id} sha256:{item.asset_digest}")
        downloads = repo_root / "published-assets"
        packages: dict[int, Path] = {}
        for item in pair:
            archive = release_hook.download_verified_release_asset(item, downloads / item.asset_name)
            extracted = repo_root / "runtime-assets" / str(item.release_id)
            release_hook.extract_release_package(archive, extracted)
            packages[item.release_id] = extracted

        baseline_commit = baseline_source["sourceCommit"]
        _ensure_baseline_commit(repo, baseline_commit)
        worktree = repo_root / "baseline-source"
        _checked(["git", "worktree", "add", "--detach", str(worktree), baseline_commit], cwd=repo, timeout=180)
        actual_tree = _checked(["git", "rev-parse", "HEAD^{tree}"], cwd=worktree).strip()
        if actual_tree != baseline_source["sourceTree"]:
            _safe_fail("pinned baseline source tree does not match ReleaseBaseline.json")
        _inject_compatibility_test(worktree, repo / "ios" / "Tests" / "ReleaseCompatibilityTests.swift")

        baseline_project = worktree / "ios" / "TightbeamTuner.xcodeproj"
        candidate_project = repo / "ios" / "TightbeamTuner.xcodeproj"
        baseline_settings = _effective_settings(
            baseline_project, candidate["scheme"], candidate["configuration"],
            "generic/platform=iOS Simulator", worktree,
        )
        candidate_settings = _effective_settings(
            candidate_project, candidate["scheme"], candidate["configuration"],
            "generic/platform=iOS Simulator", repo,
        )
        baseline_identity = _baseline_phase_identity(baseline_source, baseline_settings)
        candidate.update(candidate_settings)
        matrix_report["baseline"] = baseline_identity
        matrix_report["candidate"] = candidate
        device_type_candidates, runtime_id, runtime_name = _device_and_runtime(
            candidate["minimumOS"]
        )
        # Install and launch the pinned Pi CLI before simulator boot adds CPU
        # pressure. The fixture starts only task-owned local services here.
        fixture = LocalRuntimeFixture(repo_root, pair, packages)
        simulator_id, simulator_name, device_type_id, device_type_name = _create_simulator(
            device_type_candidates, runtime_id, build_number,
            diagnostic_directory=repo_root / "simulator-diagnostics",
        )
        print(f"Created isolated simulator {simulator_name} ({device_type_name}, {runtime_name})")
        matrix_report["simulator"] = {
            "deviceType": device_type_name,
            "runtime": runtime_name,
        }
        candidate["runId"] = run_id
        candidate["attempt"] = release_notes.XCODE_CLOUD_ATTEMPT_NUMBER
        matrix_candidate = dict(candidate)
        baseline_phase_source = dict(baseline_identity)
        producer = {
            "runId": candidate["runId"],
            "attempt": candidate["attempt"],
            "sourceCommit": candidate["commit"],
            "sourceTree": candidate["tree"],
            "buildNumber": candidate["buildNumber"],
            "scheme": candidate["scheme"],
            "configuration": candidate["configuration"],
            "execution": "ios-simulator",
            "runtimeSource": "published-release-asset",
            "piHarnessVersion": fixture.pi_harness_version,
            "piModelPreflights": fixture.pi_model_preflights,
            "networkScope": "disposable-per-release-base-and-state",
            "modelEndpointNetworkScope": "loopback-only",
            "runtimeClientAddress": "loopback-advertised-url",
        }
        matrix_report["candidate"] = matrix_candidate
        matrix_report["producer"] = producer
        baseline_dd = derived / "TunerCompatibilityResults" / "baseline-derived-data"
        candidate_dd = derived / "TunerCompatibilityResults" / "candidate-derived-data"
        result_root = derived / "TunerCompatibilityResults" / "xcresults"
        _run_test_phase(
            source_root=worktree,
            project=baseline_project,
            derived_data=baseline_dd,
            result_bundle=result_root / "baseline.xcresult",
            scheme=candidate["scheme"],
            configuration=candidate["configuration"],
            build_number=build_number,
            simulator_id=simulator_id,
            simulator_type_name=device_type_name,
            simulator_runtime_name=runtime_name,
            phase="baseline",
            phase_source=baseline_phase_source,
            candidate=matrix_candidate,
            pair=pair,
            fixture=fixture,
            attempt=candidate["attempt"],
        )
        _run_test_phase(
            source_root=repo,
            project=candidate_project,
            derived_data=candidate_dd,
            result_bundle=result_root / "candidate.xcresult",
            scheme=candidate["scheme"],
            configuration=candidate["configuration"],
            build_number=build_number,
            simulator_id=simulator_id,
            simulator_type_name=device_type_name,
            simulator_runtime_name=runtime_name,
            phase="candidate",
            phase_source=matrix_candidate,
            candidate=matrix_candidate,
            pair=pair,
            fixture=fixture,
            attempt=candidate["attempt"],
        )

        baseline_report_identity = dict(baseline_identity)
        combined = _combine_results(fixture.phase_results, matrix_candidate, baseline_report_identity, pair)
        findings = release_hook.detect_breaking_changes(baseline_report_identity, matrix_candidate, combined)
        candidate_failures = [
            f"{run['release']['tag']}:{path}"
            for run in combined
            for path in release_hook.REQUIRED_CLIENT_CHECKS
            if run["checks"].get(path, {}).get("status") != "passed"
        ]
        base_note, note_data = release_notes.load_current_note(current_note_path, expected_build=build_number)
        history_data = json.loads(history_path.read_text(encoding="utf-8"))
        release_hook.validate_history_claims(release_notes.notes_from_history_data(history_data))
        original_compatibility = release_hook.section_details(base_note, release_hook.COMPATIBILITY_TITLE)
        generated_line = release_hook.compatibility_line(pair) if not candidate_failures else None
        updated_note_data = (
            release_hook.replace_compatibility_detail(note_data, generated_line)
            if generated_line is not None else note_data
        )
        updated_note = release_notes._note_from_data(updated_note_data, expected_build=build_number)
        breaking_detail = release_hook.section_details(updated_note, release_hook.BREAKING_TITLE)
        section_digest = release_hook.breaking_section_digest(breaking_detail)
        note_blocker = None
        try:
            section_digest = release_hook.validate_breaking_section(updated_note, findings)
        except release_hook.ReleaseHookError as error:
            note_blocker = str(error)
        compatibility = {
            "schemaVersion": 1,
            "candidate": matrix_candidate,
            "baseline": baseline_report_identity,
            "producer": producer,
            "runtimeGatewayListeners": fixture.gateway_listener_report(),
            "runs": combined,
        }
        matrix_report = {
            "schemaVersion": 1,
            "status": "completed" if not candidate_failures and note_blocker is None else "blocked",
            "candidate": matrix_candidate,
            "baseline": baseline_report_identity,
            "producer": producer,
            "releases": [
                {
                    "id": item.release_id,
                    "tag": item.tag,
                    "assetId": item.asset_id,
                    "assetName": item.asset_name,
                    "assetDigest": item.asset_digest,
                }
                for item in pair
            ],
            "runtimeGatewayListeners": fixture.gateway_listener_report(),
            "compatibility": compatibility,
            "detectors": {
                "status": "completed",
                "findings": findings,
                "findingsSha256": release_hook.findings_digest(findings),
            },
            "breakingChangesSha256": section_digest,
            "generatedCompatibilityLine": generated_line,
            "originalCompatibilityDetail": original_compatibility,
            "currentNoteSha256": release_hook.note_digest(updated_note_data),
        }
        if candidate_failures:
            matrix_report["blockers"] = ["required candidate compatibility paths failed"]
            matrix_report["failedCandidatePaths"] = candidate_failures
        if note_blocker is not None:
            matrix_report.setdefault("blockers", []).append("Breaking changes section requires correction")
            matrix_report["breakingChangesBlocker"] = note_blocker
        if matrix_report["status"] == "blocked":
            if generated_line is not None:
                current_note_path.write_bytes(_json_bytes(updated_note_data))
            _write_json(report_path, matrix_report)
            _safe_fail("compatibility matrix found a blocking failure; candidate cannot be archived")

        resolved_pair_after_tests = release_hook.resolve_published_pair("darwin-aarch64")
        release_hook.same_release_pair(pair, resolved_pair_after_tests)
        pair = resolved_pair_after_tests
        candidate_object = release_hook.candidate_object(
            matrix_candidate,
            baseline_report_identity,
            pair,
            findings,
            updated_note_data,
            history_data,
        )
        candidate_object_digest = release_hook.candidate_object_digest(candidate_object)
        if diagnostic:
            matrix_report["runMode"] = "diagnostic"
            matrix_report["archiveGate"] = "not-run"
            matrix_report["releaseClaimAuthorized"] = False
            matrix_report["candidateObject"] = candidate_object
            matrix_report["candidateObjectSha256"] = candidate_object_digest
            matrix_report["currentNoteSha256"] = release_hook.note_digest(updated_note_data)
            matrix_report["status"] = "completed"
            _write_json(report_path, matrix_report)
            print("Diagnostic compatibility matrix complete; no archive status or release note was installed")
            print(f"Observed compatibility line: {generated_line}")
            print(f"Detector findings: {len(findings)}")
            return

        confirmation = _review_confirmation(
            diagnostic, matrix_candidate["commit"], candidate_object_digest
        )
        pre_archive_gate = {
            "status": "passed",
            "sourceCommit": matrix_candidate["commit"],
            "candidateDigest": candidate_object_digest,
            **confirmation,
        }
        matrix_report["candidateObject"] = candidate_object
        matrix_report["candidateObjectSha256"] = candidate_object_digest
        matrix_report["preArchiveGate"] = pre_archive_gate
        note_bytes = _json_bytes(updated_note_data)
        matrix_report["currentNoteSha256"] = release_hook.note_digest(updated_note_data)
        release_hook.validate_archive_report(
            matrix_report,
            candidate=matrix_candidate,
            baseline=baseline_report_identity,
            pair=pair,
            note_data=updated_note_data,
            history_data=history_data,
            expected_ci_run_id=producer["runId"],
        )
        current_note_path.write_bytes(note_bytes)
        _write_json(report_path, matrix_report)
        print(f"Generated {generated_line}")
        print(f"Compatibility matrix complete; detector findings: {len(findings)}")
    except MatrixError as error:
        if matrix_report.get("status") != "blocked":
            matrix_report["status"] = "failed"
            matrix_report["failure"] = str(error)
        else:
            matrix_report.setdefault("failure", str(error))
        if error.diagnostics is not None:
            matrix_report["xcodeFailureSummary"] = error.diagnostics
        if fixture is not None and fixture.phase_results:
            matrix_report["observedPhaseResults"] = fixture.phase_results
        if fixture is not None:
            matrix_report["runtimeGatewayListeners"] = fixture.gateway_listener_report()
            matrix_report["piHarness"] = {
                "version": fixture.pi_harness_version,
                "modelPreflights": fixture.pi_model_preflights,
            }
        matrix_report.setdefault("detectors", {"status": "failed", "findings": [], "findingsSha256": release_hook.findings_digest([])})
        try:
            _write_json(report_path, matrix_report)
        except OSError:
            pass
        raise
    except (release_hook.ReleaseHookError, release_notes.ReleaseNoteError) as error:
        matrix_report["status"] = "failed"
        matrix_report["failure"] = _failure_message(error)
        matrix_report["detectors"] = {
            "status": "failed", "findings": [],
            "findingsSha256": release_hook.findings_digest([]),
        }
        if fixture is not None:
            matrix_report["runtimeGatewayListeners"] = fixture.gateway_listener_report()
        try:
            _write_json(report_path, matrix_report)
        except OSError:
            pass
        raise MatrixError(matrix_report["failure"]) from error
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        matrix_report["status"] = "failed"
        matrix_report["failure"] = _failure_message(error)
        matrix_report.setdefault("detectors", {"status": "failed", "findings": [], "findingsSha256": release_hook.findings_digest([])})
        try:
            _write_json(report_path, matrix_report)
        except OSError:
            pass
        raise MatrixError(str(matrix_report["failure"])) from error
    finally:
        cleanup_failures: list[str] = []
        diagnostic_capture_failures: list[str] = []
        active_error = sys.exc_info()[0] is not None
        if fixture is not None:
            try:
                fixture.close()
            except Exception:
                cleanup_failures.append("local fixture")
            if os.environ.get("CI_DIAGNOSTIC_ARTIFACTS_PATH"):
                try:
                    retained_logs = _retain_runtime_diagnostics(fixture)
                    matrix_report.setdefault("diagnosticArtifacts", {})[
                        "runtimeLogs"
                    ] = retained_logs or []
                except Exception:
                    diagnostic_capture_failures.append("runtime logs")
                    matrix_report.setdefault("diagnosticArtifacts", {})[
                        "runtimeLogs"
                    ] = []
        elif os.environ.get("CI_DIAGNOSTIC_ARTIFACTS_PATH"):
            try:
                retained_logs = _retain_fixture_startup_diagnostics(repo_root)
                matrix_report.setdefault("diagnosticArtifacts", {})[
                    "fixtureStartupLogs"
                ] = retained_logs
            except Exception:
                diagnostic_capture_failures.append("fixture startup logs")
                matrix_report.setdefault("diagnosticArtifacts", {})[
                    "fixtureStartupLogs"
                ] = []
        if simulator_id is not None:
            try:
                _delete_simulator(simulator_id)
            except Exception:
                cleanup_failures.append("owned simulator")
        if worktree is not None and worktree.exists():
            removed = _run(["git", "worktree", "remove", "--force", str(worktree)], cwd=repo, timeout=120)
            if removed.returncode != 0 or worktree.exists():
                cleanup_failures.append("baseline worktree")
        try:
            _remove_task_scratch(repo_root)
        except OSError:
            cleanup_failures.append("task scratch")
        if cleanup_failures:
            matrix_report["cleanupFailures"] = cleanup_failures
            if matrix_report.get("status") != "blocked":
                matrix_report["status"] = "failed"
            matrix_report.setdefault("failure", "compatibility matrix could not clean up all task-owned resources")
        if diagnostic_capture_failures:
            matrix_report["diagnosticArtifactCaptureFailures"] = diagnostic_capture_failures
            matrix_report["status"] = "failed"
            matrix_report.setdefault("failure", "compatibility matrix could not retain diagnostic artifacts")
        if cleanup_failures or diagnostic_capture_failures or matrix_report.get("diagnosticArtifacts"):
            try:
                _write_json(report_path, matrix_report)
            except OSError:
                pass
            if (cleanup_failures or diagnostic_capture_failures) and not active_error:
                if diagnostic_capture_failures:
                    raise MatrixError("compatibility matrix could not retain required diagnostic artifacts")
                raise MatrixError("compatibility matrix could not clean up all task-owned resources")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--diagnostic",
        action="store_true",
        help="run the isolated matrix without archive tag or reviewer-status gates; archive actions are refused",
    )
    parser.add_argument(
        "--build-number",
        type=int,
        help="planned release build number for a non-distributing diagnostic run",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="path to the captured diagnostic report; required with --diagnostic",
    )
    args = parser.parse_args(argv)
    if args.diagnostic and (args.build_number is None or args.output is None):
        parser.error("--diagnostic requires --build-number and --output")
    if not args.diagnostic and (args.build_number is not None or args.output is not None):
        parser.error("--build-number and --output are diagnostic-only")
    try:
        run_matrix(
            diagnostic=args.diagnostic,
            planned_build_number=args.build_number,
            diagnostic_output=args.output,
        )
    except (MatrixError, release_hook.ReleaseHookError, release_notes.ReleaseNoteError) as error:
        print(f"release compatibility matrix: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
