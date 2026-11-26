#!/usr/bin/env python3
"""Run the candidate-bound published-runtime matrix before a TestFlight archive."""

from __future__ import annotations

import getpass
import hashlib
import http.server
import json
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import release_hook
import release_notes


class MatrixError(RuntimeError):
    pass


def _safe_fail(message: str) -> None:
    raise MatrixError(message)


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def _write_json(path: Path, value: Any) -> None:
    path.write_bytes(_json_bytes(value))


def _run(
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: Path | None = None,
    timeout: int = 60,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
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
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MatrixError(f"required compatibility-matrix command could not complete: {Path(args[0]).name}") from error


def _require_command(name: str) -> str:
    path = shutil.which(name)
    if path is None:
        _safe_fail(f"compatibility matrix requires the approved CI tool {name}")
    return path


def _checked(args: list[str], *, env: dict[str, str] | None = None, cwd: Path | None = None, timeout: int = 60) -> str:
    result = _run(args, env=env, cwd=cwd, timeout=timeout)
    if result.returncode != 0:
        _safe_fail(f"compatibility-matrix command failed: {Path(args[0]).name}")
    return result.stdout


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


def _require_loopback_listener(port: int, label: str) -> None:
    lsof = shutil.which("lsof")
    if lsof is None:
        _safe_fail("compatibility matrix cannot verify that its local service is loopback-only")
    result = _run([lsof, "-nP", "-iTCP", f"{port}", "-sTCP:LISTEN"], timeout=10)
    if result.returncode != 0:
        _safe_fail(f"compatibility matrix could not verify the {label} listener")
    listeners = [line.split()[-2] for line in result.stdout.splitlines() if "(LISTEN)" in line and len(line.split()) >= 2]
    local = [address for address in listeners if address.endswith(f":{port}")]
    if not local or any(not address.startswith("127.0.0.1:") for address in local):
        _safe_fail(f"compatibility matrix {label} is not bound exclusively to loopback")


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
        _safe_fail("Xcode Cloud checkout does not match CI_COMMIT")
    if not re.fullmatch(r"[0-9a-f]{40}", tree):
        _safe_fail("Xcode Cloud checkout has no verifiable Git tree")
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


def _inject_compatibility_test(worktree: Path, candidate_test: Path) -> None:
    test_target = worktree / "ios" / "Tests" / "ReleaseCompatibilityTests.swift"
    project = worktree / "ios" / "TightbeamTuner.xcodeproj" / "project.pbxproj"
    if not candidate_test.is_file() or not project.is_file():
        _safe_fail("baseline source does not support the release compatibility test harness")
    pbx = project.read_text(encoding="utf-8")
    if "ReleaseCompatibilityTests.swift" in pbx:
        _safe_fail("baseline source unexpectedly contains the candidate compatibility harness")
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


def _device_and_runtime(minimum_os: str) -> tuple[str, str, str, str]:
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
        and item.get("platform") == "iOS Simulator"
        and isinstance(item.get("identifier"), str)
        and isinstance(item.get("version"), str)
    ]
    minimum = release_hook._os_version(minimum_os)
    eligible = [item for item in ios_runtimes if release_hook._os_version(item["version"]) >= minimum]
    if not eligible or not types:
        _safe_fail("Xcode Cloud has no available iPhone simulator runtime at the Tuner deployment target")
    selected_runtime = max(eligible, key=lambda item: release_hook._os_version(item["version"]))
    compatible_types = [
        item for item in types
        if release_hook._os_version(item.get("minRuntimeVersion", "0"))
        <= release_hook._os_version(selected_runtime["version"])
    ]
    if not compatible_types:
        _safe_fail("Xcode Cloud has no iPhone simulator type compatible with the selected runtime")
    selected_type = sorted(compatible_types, key=lambda item: item["name"])[0]
    return (
        str(selected_type["identifier"]), str(selected_type["name"]),
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
        self.admin_user = "test" + secrets.token_hex(16)
        self.client_user = "test" + secrets.token_hex(16)
        self.local_user = getpass.getuser()
        self.cli_link_dir = root / "runner-bin"
        self.cli_link = self.cli_link_dir / "tightbeam"
        self.shim_dir = root / "harness-shim"
        self.state_root = root / "runtime-state"
        self.state_root.mkdir(parents=True, exist_ok=True)
        self.runtime_base: dict[int, Path] = {}
        self.initialized: set[int] = set()
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
        self._prepare_tools()
        self._prepare_sshd()
        self._start_fixture_server()

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
        for name in ("claude", "codex", "pi"):
            shim = self.shim_dir / name
            shim.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            shim.chmod(0o700)
        self.authorized_keys.write_text("", encoding="utf-8")
        self.authorized_keys.chmod(0o600)
        self.ssh_host_key_line = _checked([
            _require_command("ssh-keygen"), "-q", "-t", "ed25519", "-N", "",
            "-C", "tuner-compat-host", "-f", str(self.host_key),
        ]).strip()
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
            'unset TIGHTBEAM_HOME TIGHTBEAM_URL TIGHTBEAM_TOKEN TIGHTBEAM_SESSION TIGHTBEAM_LIVE_BASE_TRANSITION',
            'export TIGHTBEAM_BASE_DIR TIGHTBEAM_PORT TIGHTBEAM_ADVERTISED_URL',
            'exec "$TIGHTBEAM_CLI" list --as-user "$TIGHTBEAM_TEST_USER"',
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
        _checked([sshd, "-t", "-f", str(self.sshd_config)], timeout=20)
        self._sshd_binary = sshd

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
                except MatrixError:
                    self._send(500, {"ok": False, "error": "isolated fixture operation failed"})
                except (ValueError, json.JSONDecodeError):
                    self._send(400, {"ok": False, "error": "invalid fixture request"})

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        _require_loopback_listener(self.server.server_port, "test fixture")

    def _runtime_env(self, release_id: int) -> dict[str, str]:
        package = self.package_paths[release_id]
        cli_paths = list(package.rglob("tightbeam"))
        gateway_paths = list(package.rglob("tightbeam-gateway"))
        if len(cli_paths) != 1 or len(gateway_paths) != 1:
            _safe_fail("verified runtime asset does not have one CLI and one gateway")
        cli = cli_paths[0]
        gateway = gateway_paths[0]
        _require_command("node")
        _require_command("git")
        env = os.environ.copy()
        for key in (
            "TIGHTBEAM_HOME", "TIGHTBEAM_URL", "TIGHTBEAM_TOKEN", "TIGHTBEAM_SESSION",
            "TIGHTBEAM_LIVE_BASE_TRANSITION",
        ):
            env.pop(key, None)
        env["TIGHTBEAM_BASE_DIR"] = str(self.runtime_base.setdefault(
            release_id, self.state_root / str(release_id) / "base"
        ))
        env["TIGHTBEAM_PORT"] = str(self.gateway_port)
        env["TIGHTBEAM_ADVERTISED_URL"] = self.gateway_url
        env["PATH"] = os.pathsep.join([str(self.shim_dir), str(cli.parent), env.get("PATH", "")])
        return env

    def _write_current_runtime_env(self, release_id: int | None) -> None:
        if release_id is None:
            values = {
                "TIGHTBEAM_BASE_DIR": str(self.state_root / "not-selected"),
                "TIGHTBEAM_PORT": str(self.gateway_port),
                "TIGHTBEAM_ADVERTISED_URL": self.gateway_url,
                "TIGHTBEAM_CLI": str(self.cli_link),
                "TIGHTBEAM_TEST_USER": self.client_user,
            }
        else:
            values = {
                "TIGHTBEAM_BASE_DIR": str(self.runtime_base[release_id]),
                "TIGHTBEAM_PORT": str(self.gateway_port),
                "TIGHTBEAM_ADVERTISED_URL": self.gateway_url,
                "TIGHTBEAM_CLI": str(self.cli_link),
                "TIGHTBEAM_TEST_USER": self.client_user,
            }
        expected = f"{_shell_quote(str(self.cli_link))} 'list' '--as-user' {_shell_quote(self.client_user)}"
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
        cli = self.package_paths[release_id]
        cli_binary = next(path for path in cli.rglob("tightbeam") if path.is_file())
        gateway_binary = next(path for path in cli.rglob("tightbeam-gateway") if path.is_file())
        self.cli_link.unlink(missing_ok=True)
        self.cli_link.symlink_to(cli_binary)
        base_dir = Path(env["TIGHTBEAM_BASE_DIR"])
        base_dir.parent.mkdir(parents=True, exist_ok=True)
        self._write_current_runtime_env(release_id)
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
        _require_loopback_listener(self.gateway_port, "published Tightbeam gateway")
        if release_id not in self.initialized:
            cli_env = env.copy()
            first = _run([str(self.cli_link), "add-user", self.admin_user], env=cli_env, cwd=self.root, timeout=30)
            if first.returncode != 0:
                _safe_fail("published Tightbeam runtime could not seed its isolated test administrator")
            second = _run([
                str(self.cli_link), "add-user", self.client_user, "--as-user", self.admin_user,
            ], env=cli_env, cwd=self.root, timeout=30)
            if second.returncode != 0:
                _safe_fail("published Tightbeam runtime could not seed its isolated Tuner user")
            self.initialized.add(release_id)

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

    def _route(self, path: str, payload: dict[str, Any]) -> dict[str, Any]:
        if path == "/select-runtime":
            release_id = payload.get("releaseId")
            if not isinstance(release_id, int) or isinstance(release_id, bool) or release_id not in self.by_id:
                raise MatrixError("unknown pinned runtime")
            if self.selected_release_id != release_id or self.gateway_process is None or self.gateway_process.poll() is not None:
                self._stop_gateway()
                self._start_gateway(release_id)
            return {"ok": True}
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
        if path == "/add-user":
            user = payload.get("user")
            if not isinstance(user, str) or not re.fullmatch(r"test[a-f0-9]{32}", user):
                raise MatrixError("test user seed has an invalid identifier")
            if self.selected_release_id is None:
                raise MatrixError("no published runtime is selected")
            env = self._runtime_env(self.selected_release_id)
            result = _run([
                str(self.cli_link), "add-user", user, "--as-user", self.admin_user,
            ], env=env, cwd=self.root, timeout=30)
            if result.returncode != 0:
                raise MatrixError("published Tightbeam runtime rejected the isolated live-change seed")
            return {"ok": True}
        if path == "/restart-gateway":
            if self.selected_release_id is None:
                raise MatrixError("no published runtime is selected")
            release_id = self.selected_release_id
            self._stop_gateway()
            self._start_gateway(release_id)
            return {"ok": True}
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
        _require_port_clear(self.gateway_port, "gateway")
        _require_port_clear(self.ssh_port, "SSH fixture")


def _create_simulator(device_type: str, runtime_id: str, build_number: int) -> tuple[str, str]:
    simctl = _require_command("xcrun")
    name = f"TunerCompatibility-{build_number}"
    udid = _checked([simctl, "simctl", "create", name, device_type, runtime_id], timeout=60).strip()
    if not re.fullmatch(r"[0-9A-Fa-f-]{36}", udid):
        _safe_fail("Xcode did not return an exact owned simulator identifier")
    try:
        _checked([simctl, "simctl", "boot", udid], timeout=60)
        _checked([simctl, "simctl", "bootstatus", udid, "-b"], timeout=180)
    except MatrixError:
        _run([simctl, "simctl", "shutdown", udid], timeout=30)
        _run([simctl, "simctl", "delete", udid], timeout=30)
        raise
    return udid, name


def _delete_simulator(udid: str) -> None:
    simctl = _require_command("xcrun")
    shutdown = _run([simctl, "simctl", "shutdown", udid], timeout=30)
    delete = _run([simctl, "simctl", "delete", udid], timeout=60)
    if delete.returncode != 0:
        _safe_fail("Xcode did not delete the compatibility matrix's owned simulator")
    if shutdown.returncode != 0:
        # `delete` owns the device now; report cleanup as incomplete rather than
        # touching any other simulator or treating an unknown state as success.
        _safe_fail("Xcode did not shut down the compatibility matrix's owned simulator cleanly")


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
    env = os.environ.copy()
    test_values = {
        "TUNER_COMPAT_PHASE": phase,
        "TUNER_COMPAT_FIXTURE_URL": fixture.fixture_url,
        "TUNER_COMPAT_FIXTURE_TOKEN": fixture.fixture_token,
        "TUNER_COMPAT_GATEWAY_URL": fixture.gateway_url,
        "TUNER_COMPAT_SSH_PORT": str(fixture.ssh_port),
        "TUNER_COMPAT_SSH_HOST_KEY": fixture.ssh_host_key_line,
        "TUNER_COMPAT_SSH_USER": fixture.local_user,
        "TUNER_COMPAT_USER": fixture.client_user,
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
        raise MatrixError(f"Xcode {phase} compatibility test did not complete") from error
    if result.returncode != 0:
        # Do not echo raw xcodebuild output: the test process contains a private
        # fixture token and ephemeral user/key material in its environment.
        raise MatrixError(f"Xcode {phase} compatibility test failed; inspect the Xcode Cloud result bundle")


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
        _safe_fail("Xcode Cloud candidate identity is incomplete")
    commit, tree = _current_source(repo, commit_from_ci)
    configuration = os.environ.get("TUNER_RELEASE_CONFIGURATION", "Release")
    if baseline_file["scheme"] != scheme or baseline_file["configuration"] != configuration:
        _safe_fail("candidate and pinned baseline use different release schemes or configurations")
    attempt_value = os.environ.get("CI_BUILD_ATTEMPT", "1")
    if not attempt_value.isdigit() or int(attempt_value) < 1:
        _safe_fail("Xcode Cloud attempt number is invalid")
    return {
        "commit": commit,
        "tree": tree,
        "scheme": scheme,
        "configuration": configuration,
        "buildNumber": build_number,
        "runId": run_id,
        "attempt": int(attempt_value),
    }


def run_matrix() -> None:
    if os.environ.get("CI_WORKFLOW", "").strip().casefold() != "internal testflight":
        _safe_fail("compatibility matrix is restricted to the Internal Testflight Xcode Cloud workflow")
    if os.environ.get("CI_XCODEBUILD_ACTION", "").casefold() != "archive":
        _safe_fail("compatibility matrix requires the Xcode Cloud archive action")
    build_number_value = os.environ.get("CI_BUILD_NUMBER", "")
    if not build_number_value.isdigit() or int(build_number_value) <= 0:
        _safe_fail("Xcode Cloud archive has no positive numbered build")
    build_number = int(build_number_value)
    repo_value = os.environ.get("CI_PRIMARY_REPOSITORY_PATH")
    derived_value = os.environ.get("CI_DERIVED_DATA_PATH")
    if not repo_value or not derived_value:
        _safe_fail("Xcode Cloud repository or DerivedData path is unavailable")
    repo = Path(repo_value).resolve()
    derived = Path(derived_value).resolve()
    if not repo.is_dir() or not derived.is_dir():
        _safe_fail("Xcode Cloud repository or DerivedData path is unavailable")
    test_root = derived / "TunerCompatibilityResults"
    test_root.mkdir(parents=True, exist_ok=True)
    repo_root = Path(tempfile.mkdtemp(prefix="tuner-compat-", dir=str(test_root))).resolve()
    if os.path.commonpath([str(derived), str(repo_root)]) != str(derived):
        _safe_fail("compatibility scratch escaped Xcode Cloud DerivedData")
    for tool in ("git", "xcodebuild", "xcrun", "ssh-keygen", "sshd", "lsof", "node"):
        _require_command(tool)

    report_path = repo / "ios" / "TightbeamTuner" / "ReleaseCompatibilityReport.json"
    current_note_path = repo / "ios" / "TightbeamTuner" / "CurrentBuildReleaseNote.json"
    history_path = repo / "ios" / "TightbeamTuner" / "ReleaseNotesHistory.json"
    baseline_path = SCRIPT_DIR / "ReleaseBaseline.json"
    matrix_report: dict[str, Any] = {"schemaVersion": 1, "status": "failed", "failure": "matrix did not complete"}
    fixture: LocalRuntimeFixture | None = None
    simulator_id: str | None = None
    worktree: Path | None = None
    pair: tuple[release_hook.PublishedRelease, release_hook.PublishedRelease] | None = None

    try:
        baseline_source = _baseline_input(baseline_path)
        candidate = _prepare_candidate(repo, baseline_source, build_number)
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
        device_type_id, device_type_name, runtime_id, runtime_name = _device_and_runtime(
            candidate["minimumOS"]
        )
        simulator_id, simulator_name = _create_simulator(device_type_id, runtime_id, build_number)
        print(f"Created isolated simulator {simulator_name} ({device_type_name}, {runtime_name})")

        fixture = LocalRuntimeFixture(repo_root, pair, packages)
        candidate["runId"] = os.environ["CI_BUILD_ID"]
        candidate["attempt"] = int(os.environ.get("CI_BUILD_ATTEMPT", "1"))
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
            "networkScope": "loopback-only",
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
        release_hook.validate_history_claims(release_notes.load_notes(history_path))
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
        note_bytes = _json_bytes(updated_note_data)
        matrix_report["currentNoteSha256"] = release_hook.note_digest(updated_note_data)
        release_hook.validate_archive_report(
            matrix_report,
            candidate=matrix_candidate,
            baseline=baseline_report_identity,
            pair=pair,
            note_data=updated_note_data,
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
        if fixture is not None and fixture.phase_results:
            matrix_report["observedPhaseResults"] = fixture.phase_results
        matrix_report.setdefault("detectors", {"status": "failed", "findings": [], "findingsSha256": release_hook.findings_digest([])})
        try:
            _write_json(report_path, matrix_report)
        except OSError:
            pass
        raise
    except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
        matrix_report["status"] = "failed"
        matrix_report["failure"] = "compatibility matrix received an invalid input or could not write its report"
        matrix_report.setdefault("detectors", {"status": "failed", "findings": [], "findingsSha256": release_hook.findings_digest([])})
        try:
            _write_json(report_path, matrix_report)
        except OSError:
            pass
        raise MatrixError(str(matrix_report["failure"])) from error
    finally:
        cleanup_failures: list[str] = []
        active_error = sys.exc_info()[0] is not None
        if fixture is not None:
            try:
                fixture.close()
            except Exception:
                cleanup_failures.append("local fixture")
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
            shutil.rmtree(repo_root)
        except FileNotFoundError:
            pass
        except OSError:
            cleanup_failures.append("task scratch")
        if cleanup_failures:
            matrix_report["cleanupFailures"] = cleanup_failures
            if matrix_report.get("status") != "blocked":
                matrix_report["status"] = "failed"
            matrix_report.setdefault("failure", "compatibility matrix could not clean up all task-owned resources")
            try:
                _write_json(report_path, matrix_report)
            except OSError:
                pass
            if not active_error:
                raise MatrixError("compatibility matrix could not clean up all task-owned resources")


def main() -> int:
    try:
        run_matrix()
    except (MatrixError, release_hook.ReleaseHookError, release_notes.ReleaseNoteError) as error:
        print(f"release compatibility matrix: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
