import json
import socket
import tempfile
import urllib.request
import unittest
from pathlib import Path
from unittest import mock

import compatibility_matrix


class SimulatorSelectionTests(unittest.TestCase):
    def _selection(self, runtime_platform, runtimes=None, devicetypes=None):
        device_payload = {
            "devicetypes": devicetypes or [
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "name": "iPhone 17 Pro",
                    "minRuntimeVersion": 1769472,
                    "minRuntimeVersionString": "27.0.0",
                }
            ]
        }
        runtime_payload = {
            "runtimes": runtimes or [
                {
                    "isAvailable": True,
                    "platform": runtime_platform,
                    "version": "27.0",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                }
            ]
        }
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix,
                "_checked",
                side_effect=[json.dumps(device_payload), json.dumps(runtime_payload)],
            ),
        ):
            return compatibility_matrix._device_and_runtime("26.0")

    def test_selects_current_simctl_ios_platform_and_version_string(self):
        self.assertEqual(
            self._selection("iOS"),
            (
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "iPhone 17 Pro",
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "iOS 27.0",
            ),
        )

    def test_keeps_compatibility_with_older_simulator_platform_label(self):
        self.assertEqual(self._selection("iOS Simulator")[1], "iPhone 17 Pro")

    def test_prefers_generic_runtime_and_newest_compatible_device_type(self):
        selected = self._selection(
            "iOS",
            runtimes=[
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
                },
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                },
            ],
            devicetypes=[
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-11",
                    "name": "iPhone 11",
                    "minRuntimeVersion": 1310720,
                    "minRuntimeVersionString": "20.0.0",
                },
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "name": "iPhone 17 Pro",
                    "minRuntimeVersion": 1769472,
                    "minRuntimeVersionString": "27.0.0",
                },
            ],
        )
        self.assertEqual(
            selected,
            (
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "iPhone 17 Pro",
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
                "iOS 27.2",
            ),
        )

    def test_rejects_only_device_specific_runtime_variants(self):
        runtimes = {
            "runtimes": [
                {
                    "isAvailable": True,
                    "platform": "iOS",
                    "version": "27.2",
                    "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4",
                }
            ]
        }
        devicetypes = {
            "devicetypes": [
                {
                    "productFamily": "iPhone",
                    "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                    "name": "iPhone 17 Pro",
                    "minRuntimeVersion": 1769472,
                    "minRuntimeVersionString": "27.0.0",
                }
            ]
        }
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix,
                "_checked",
                side_effect=[json.dumps(devicetypes), json.dumps(runtimes)],
            ),
            self.assertRaisesRegex(
                compatibility_matrix.MatrixError,
                "no available iPhone simulator runtime at the Tuner deployment target",
            ),
        ):
            compatibility_matrix._device_and_runtime("26.0")


class LoopbackListenerTests(unittest.TestCase):
    def test_loopback_check_queries_only_the_assigned_port_and_rejects_wildcard(self):
        output = (
            "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n"
            "python 123 user 4u IPv4 0x1 0t0 TCP 127.0.0.1:19450 (LISTEN)\n"
        )
        with (
            mock.patch.object(compatibility_matrix.shutil, "which", return_value="/usr/sbin/lsof"),
            mock.patch.object(
                compatibility_matrix,
                "_run",
                return_value=mock.Mock(returncode=0, stdout=output),
            ) as run,
        ):
            compatibility_matrix._require_loopback_listener(19450, "fixture")
        self.assertEqual(
            run.call_args.args[0],
            ["/usr/sbin/lsof", "-nP", "-a", "-iTCP:19450", "-sTCP:LISTEN"],
        )
        self.assertEqual(run.call_args.kwargs["timeout"], 30)

        external_output = output + (
            "python 123 user 5u IPv6 0x2 0t0 TCP *:19450 (LISTEN)\n"
        )
        with (
            mock.patch.object(compatibility_matrix.shutil, "which", return_value="/usr/sbin/lsof"),
            mock.patch.object(
                compatibility_matrix,
                "_run",
                return_value=mock.Mock(returncode=0, stdout=external_output),
            ),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "not bound exclusively to loopback"),
        ):
            compatibility_matrix._require_loopback_listener(19450, "fixture")

    def test_published_runtime_wildcard_listener_is_recorded_not_rejected(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        fixture.gateway_listener_bindings = {}
        with mock.patch.object(
            compatibility_matrix, "_listener_bindings", return_value={"wildcard"}
        ):
            fixture._record_gateway_listener(4304, 19450, "published Tightbeam gateway")
        self.assertEqual(
            fixture.gateway_listener_report(),
            [{"releaseId": 4304, "observedBindings": ["wildcard"]}],
        )

    def test_command_timeout_is_reported_without_echoing_process_output(self):
        with (
            mock.patch.object(
                compatibility_matrix.subprocess,
                "run",
                side_effect=compatibility_matrix.subprocess.TimeoutExpired("lsof", 30),
            ),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "command timed out: lsof"),
        ):
            compatibility_matrix._run(["/usr/sbin/lsof", "-nP"], timeout=30)

    def test_command_timeout_retains_sanitized_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            diagnostic = Path(temporary) / "pi-preflight.log"
            with (
                mock.patch.object(
                    compatibility_matrix.subprocess,
                    "run",
                    side_effect=compatibility_matrix.subprocess.TimeoutExpired(
                        "pi", 180, output="startup failed bearer secret-value\n"
                    ),
                ),
                self.assertRaisesRegex(compatibility_matrix.MatrixError, "diagnostic retained as pi-preflight.log"),
            ):
                compatibility_matrix._run(
                    ["pi", "--print"], timeout=180, diagnostic_path=diagnostic,
                    diagnostic_redactions={"secret-value"},
                )

            retained = diagnostic.read_text(encoding="utf-8")
            self.assertIn("startup failed", retained)
            self.assertNotIn("secret-value", retained)


class PiHarnessPreflightTests(unittest.TestCase):
    def test_preflights_the_locked_pi_executable_before_simulator_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / "package-lock.json"
            lock.write_text(json.dumps({
                "packages": {
                    "node_modules/@mariozechner/pi-coding-agent": {"version": "0.73.1"}
                }
            }), encoding="utf-8")
            pi_cli = root / "node_modules" / ".bin" / "pi"
            environment = {"HOME": str(root / "home")}
            diagnostic = root / "pi-version.log"

            with mock.patch.object(
                compatibility_matrix, "_checked", return_value="pi v0.73.1\n"
            ) as checked:
                version = compatibility_matrix._preflight_pi_harness(
                    pi_cli, lock, env=environment, cwd=root, diagnostic_path=diagnostic,
                )

        self.assertEqual(version, "0.73.1")
        self.assertEqual(checked.call_args.args[0], [str(pi_cli), "--version"])
        self.assertEqual(checked.call_args.kwargs["env"], environment)
        self.assertEqual(checked.call_args.kwargs["timeout"], 120)
        self.assertEqual(checked.call_args.kwargs["diagnostic_path"], diagnostic)

    def test_runs_the_locked_pi_against_the_loopback_completion_endpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            model_requests = []
            diagnostic = root / "diagnostics" / "pi-preflight.log"
            endpoint = "http://127.0.0.1:19451/v1"

            def run_pi(args, **kwargs):
                model_requests.append({
                    "method": "POST", "path": "/v1/chat/completions", "model": "tuner-fixture",
                })
                return compatibility_matrix.subprocess.CompletedProcess(
                    args, 0, "Tightbeam compatibility fixture reply.\n"
                )

            with mock.patch.object(
                compatibility_matrix.subprocess, "run", side_effect=run_pi
            ) as run:
                result = compatibility_matrix._preflight_pi_model(
                    root / "pi",
                    home=root / "home",
                    endpoint=endpoint,
                    env={"HOME": str(root / "home")},
                    cwd=root,
                    observed_requests=model_requests,
                    diagnostic_path=diagnostic,
                    diagnostic_redactions={"private-fixture-value"},
                )

            self.assertEqual(result["status"], "passed")
            self.assertTrue(result["requestObserved"])
            self.assertEqual(run.call_args.args[0][1:7], [
                "--model", "tunerci/tuner-fixture", "--print", "--no-session",
                "--no-tools",
                "Reply with a short greeting for the Tuner compatibility fixture.",
            ])
            self.assertEqual(run.call_args.kwargs["timeout"], 180)
            self.assertTrue(diagnostic.is_file())
            configured = json.loads((root / "home/.pi/agent/models.json").read_text(encoding="utf-8"))
            provider = configured["providers"]["tunerci"]
            self.assertEqual(provider["baseUrl"], endpoint)
            self.assertEqual(provider["api"], "openai-completions")
            self.assertEqual(diagnostic.read_text(encoding="utf-8").strip(), "Tightbeam compatibility fixture reply.")

    def test_rejects_preflight_without_a_local_completion_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            diagnostic = root / "pi-preflight.log"
            with (
                mock.patch.object(
                    compatibility_matrix.subprocess,
                    "run",
                    return_value=compatibility_matrix.subprocess.CompletedProcess(
                        ["pi"], 0, "Tightbeam compatibility fixture reply.\n"
                    ),
                ),
                self.assertRaisesRegex(compatibility_matrix.MatrixError, "made no request to the local completion endpoint"),
            ):
                compatibility_matrix._preflight_pi_model(
                    root / "pi",
                    home=root / "home",
                    endpoint="http://127.0.0.1:19451/v1",
                    env={"HOME": str(root / "home")},
                    cwd=root,
                    observed_requests=[],
                    diagnostic_path=diagnostic,
                    diagnostic_redactions=set(),
                )

    def test_rejects_non_loopback_model_endpoint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(compatibility_matrix.MatrixError, "endpoint must be the local compatibility model"):
                compatibility_matrix._preflight_pi_model(
                    root / "pi",
                    home=root / "home",
                    endpoint="https://model.example/v1",
                    env={"HOME": str(root / "home")},
                    cwd=root,
                    observed_requests=[],
                    diagnostic_path=root / "pi-preflight.log",
                    diagnostic_redactions=set(),
                )

    def test_rejects_a_pi_executable_that_disagrees_with_the_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / "package-lock.json"
            lock.write_text(json.dumps({
                "packages": {
                    "node_modules/@mariozechner/pi-coding-agent": {"version": "0.73.1"}
                }
            }), encoding="utf-8")
            with (
                mock.patch.object(compatibility_matrix, "_checked", return_value="pi v0.72.0"),
                self.assertRaisesRegex(compatibility_matrix.MatrixError, "locked version"),
            ):
                compatibility_matrix._preflight_pi_harness(
                    root / "pi", lock, env={}, cwd=root
                )


class LocalModelStreamingTests(unittest.TestCase):
    def test_streaming_completion_emits_compact_json_sse_data_lines(self):
        fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            fixture.model_port = reserve.getsockname()[1]
        fixture.model_requests = []
        fixture.model_server = None
        fixture.model_thread = None

        with mock.patch.object(compatibility_matrix, "_require_loopback_listener"):
            fixture._start_model_server()
        try:
            request = urllib.request.Request(
                f"http://127.0.0.1:{fixture.model_port}/v1/chat/completions",
                data=json.dumps({"model": "tuner-fixture", "stream": True}).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                self.assertEqual(response.headers.get_content_type(), "text/event-stream")
                body = response.read().decode("utf-8")
        finally:
            fixture.model_server.shutdown()
            fixture.model_server.server_close()
            fixture.model_thread.join(timeout=5)

        events = [event for event in body.split("\n\n") if event]
        self.assertEqual(len(events), 4)
        decoded = []
        for event in events[:-1]:
            self.assertTrue(event.startswith("data: "))
            payload = event.removeprefix("data: ")
            self.assertNotIn("\n", payload)
            decoded.append(json.loads(payload))
        self.assertEqual(events[-1], "data: [DONE]")
        self.assertEqual(decoded[0]["choices"][0]["delta"]["role"], "assistant")
        self.assertEqual(decoded[1]["choices"][0]["delta"]["content"], "Tightbeam compatibility fixture reply.")
        self.assertEqual(decoded[2]["choices"][0]["finish_reason"], "stop")
        self.assertEqual(fixture.model_requests, [{
            "method": "POST", "path": "/v1/chat/completions", "model": "tuner-fixture",
        }])


class SimulatorCleanupTests(unittest.TestCase):
    def test_delete_verifies_owned_device_absence_even_if_shutdown_result_is_stale(self):
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 1, "device is already shut down"),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "device already deleted"),
            compatibility_matrix.subprocess.CompletedProcess(
                [], 0, json.dumps({"devices": {"runtime": []}})
            ),
        ]
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
        ):
            compatibility_matrix._delete_simulator("12345678-1234-1234-1234-123456789012")
        self.assertEqual(len(run.call_args_list), 3)
        self.assertEqual(run.call_args_list[-1].args[0][2:], ["list", "devices", "--json"])

    def test_delete_fails_if_owned_device_remains_in_inventory(self):
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 0, ""),
            compatibility_matrix.subprocess.CompletedProcess([], 0, ""),
            compatibility_matrix.subprocess.CompletedProcess(
                [], 0, json.dumps({"devices": {"runtime": [{"udid": "task-device"}]}})
            ),
        ]
        with (
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "retained the compatibility matrix's owned simulator"),
        ):
            compatibility_matrix._delete_simulator("task-device")


class SimulatorBootRetryTests(unittest.TestCase):
    def test_simulator_create_failure_retains_xcrun_output(self):
        create_error = "simctl create failed: selected iOS runtime is unavailable"
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(
                compatibility_matrix.subprocess,
                "run",
                return_value=compatibility_matrix.subprocess.CompletedProcess([], 1, create_error),
            ) as subprocess_run,
            self.assertRaisesRegex(
                compatibility_matrix.MatrixError,
                "diagnostic retained as simulator-create.log",
            ),
        ):
            diagnostic_directory = Path(temporary) / "simulator-diagnostics"
            compatibility_matrix._create_simulator(
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                86,
                diagnostic_directory=diagnostic_directory,
            )
            self.assertEqual(
                subprocess_run.call_args.args[0][1:3],
                ["simctl", "create"],
            )
            self.assertEqual(
                (diagnostic_directory / "simulator-create.log").read_text(encoding="utf-8"),
                create_error,
            )

    def test_retries_boot_once_after_bounded_readiness_failure(self):
        udid = "12345678-1234-1234-1234-123456789012"
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 0, udid),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "first boot failed"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "shutdown complete"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "boot complete"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "ready"),
        ]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
            mock.patch.object(compatibility_matrix.time, "sleep"),
        ):
            result = compatibility_matrix._create_simulator(
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                86,
                diagnostic_directory=Path(temporary) / "simulator-diagnostics",
            )

        self.assertEqual(result, (udid, "TunerCompatibility-86"))
        self.assertEqual(run.call_args_list[1].args[0][2:4], ["boot", udid])
        self.assertEqual(run.call_args_list[2].args[0][2:4], ["shutdown", udid])
        self.assertEqual(run.call_args_list[3].args[0][2:4], ["boot", udid])
        self.assertEqual(run.call_args_list[4].args[0][2:5], ["bootstatus", udid, "-b"])
        self.assertEqual(run.call_args_list[1].kwargs["timeout"], 90)
        self.assertEqual(run.call_args_list[4].kwargs["timeout"], 300)

    def test_boot_failure_retains_diagnostics_and_deletes_only_owned_simulator(self):
        udid = "12345678-1234-1234-1234-123456789012"
        responses = [
            compatibility_matrix.subprocess.CompletedProcess([], 0, udid),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "boot one failed"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "shutdown"),
            compatibility_matrix.subprocess.CompletedProcess([], 1, "boot two failed"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "shutdown"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, "deleted"),
            compatibility_matrix.subprocess.CompletedProcess([], 0, json.dumps({"devices": {"runtime": []}})),
        ]
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix, "_require_command", return_value="xcrun"),
            mock.patch.object(compatibility_matrix, "_run", side_effect=responses) as run,
            mock.patch.object(compatibility_matrix.time, "sleep"),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "after one retry"),
        ):
            compatibility_matrix._create_simulator(
                "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                86,
                diagnostic_directory=Path(temporary) / "simulator-diagnostics",
            )

        self.assertEqual(run.call_args_list[-2].args[0][2:4], ["delete", udid])

    def test_fixture_constructor_releases_local_servers_when_listener_gate_fails(self):
        server = mock.Mock(server_port=19450)
        thread = mock.Mock()
        with (
            tempfile.TemporaryDirectory() as temporary,
            mock.patch.object(compatibility_matrix.LocalRuntimeFixture, "_prepare_tools"),
            mock.patch.object(compatibility_matrix.LocalRuntimeFixture, "_prepare_sshd"),
            mock.patch.object(
                compatibility_matrix.http.server, "ThreadingHTTPServer", return_value=server
            ),
            mock.patch.object(compatibility_matrix.threading, "Thread", return_value=thread),
            mock.patch.object(
                compatibility_matrix, "_require_loopback_listener",
                side_effect=compatibility_matrix.MatrixError("listener probe timed out"),
            ),
            self.assertRaisesRegex(compatibility_matrix.MatrixError, "listener probe timed out"),
        ):
            compatibility_matrix.LocalRuntimeFixture(Path(temporary), (), {})
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()
        thread.join.assert_called_once_with(timeout=5)


class DiagnosticArgumentsTests(unittest.TestCase):
    def test_fixture_startup_logs_are_retained_with_task_paths_redacted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "command-logs" / "pi-version.log"
            source.parent.mkdir(parents=True)
            source.write_text(f"pi v0.73.1 from {root}\n", encoding="utf-8")
            destination = root / "artifacts"

            with mock.patch.dict(
                compatibility_matrix.os.environ,
                {"CI_DIAGNOSTIC_ARTIFACTS_PATH": str(destination)},
                clear=False,
            ):
                retained = compatibility_matrix._retain_fixture_startup_diagnostics(root)

            self.assertEqual(retained, ["command-logs__pi-version.log"])
            safe_log = (destination / "fixture-startup" / retained[0]).read_text(encoding="utf-8")
            self.assertIn("pi v0.73.1", safe_log)
            self.assertNotIn(str(root), safe_log)

    def test_diagnostic_requires_build_number_and_captured_report_path(self):
        with self.assertRaises(SystemExit) as error:
            compatibility_matrix.main(["--diagnostic"])
        self.assertEqual(error.exception.code, 2)

    def test_diagnostic_passes_explicit_plan_and_output_to_matrix(self):
        output = Path("/tmp/compatibility-report.json")
        with mock.patch.object(compatibility_matrix, "run_matrix") as run:
            self.assertEqual(
                compatibility_matrix.main(
                    ["--diagnostic", "--build-number", "84", "--output", str(output)]
                ),
                0,
            )
        run.assert_called_once_with(
            diagnostic=True,
            planned_build_number=84,
            diagnostic_output=output,
        )

    def test_archive_cannot_receive_diagnostic_only_arguments(self):
        with self.assertRaises(SystemExit) as error:
            compatibility_matrix.main(["--build-number", "84", "--output", "/tmp/report.json"])
        self.assertEqual(error.exception.code, 2)

    def test_diagnostic_workflow_checks_out_and_reports_the_pull_request_head(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release-note-gate.yml").read_text(
            encoding="utf-8"
        )
        expression = "${{ github.event.pull_request.head.sha || github.sha }}"
        self.assertEqual(workflow.count(expression), 3)
        self.assertIn(f"CI_COMMIT: {expression}", workflow)
        self.assertIn(f"ref: {expression}", workflow)

    def test_xcode_failure_summary_keeps_locations_but_not_sensitive_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            log_path = Path(temporary) / "baseline.log"
            log_path.write_text(
                "/Volumes/private-task/ReleaseCompatibilityTests.swift:426: error: token=do-not-retain XCTAssertTrue failed - ssh-ed25519 key data\n"
                "xcodebuild: error: test failed\n",
                encoding="utf-8",
            )
            summary = compatibility_matrix._safe_xcode_failure_summary(log_path)

        self.assertEqual(summary["sourceLocations"], [
            {"file": "ReleaseCompatibilityTests.swift", "line": 426, "severity": "error"}
        ])
        self.assertEqual(summary["assertionKinds"], ["XCTAssertTrue"])
        self.assertEqual(summary["errorCount"], 2)
        self.assertNotIn("private-task", json.dumps(summary))
        self.assertNotIn("do-not-retain", json.dumps(summary))
        self.assertNotIn("ssh-ed25519", json.dumps(summary))

    def test_readable_ci_diagnostics_redact_fixture_values_and_private_identifiers(self):
        runtime_session = "aaa00-bb0000-11111111-2222-3333-4444-555555555555-aaaaaaaaaaaa"
        raw = (
            "Authorization: Bearer secret-bearer-value\n"
            "X-Test-Fixture-Token: fixture-token-value\n"
            "agent:main:clawline:temporary-user:main user_private_12345678\n"
            f"adapter session {runtime_session}\n"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIprivate host\n"
            "/private/task-root/fixture.log\n"
            "ReleaseCompatibilityTests.swift:426: error: XCTAssertTrue failed\n"
        )
        safe = compatibility_matrix._safe_diagnostic_text(
            raw,
            {"secret-bearer-value", "fixture-token-value", "/private/task-root"},
        )

        for secret in (
            "secret-bearer-value", "fixture-token-value", "agent:main:clawline",
            "user_private_12345678", "AAAAC3NzaC1lZDI1NTE5AAAAIprivate",
            "/private/task-root", runtime_session,
        ):
            self.assertNotIn(secret, safe)
        self.assertIn("ReleaseCompatibilityTests.swift:426: error: XCTAssertTrue failed", safe)

    def test_result_bundle_scan_detects_known_ephemeral_fixture_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "failure.xcresult"
            bundle.mkdir()
            (bundle / "data.bin").write_bytes(b"prefix-fixture-token-value-suffix")

            self.assertTrue(
                compatibility_matrix._contains_sensitive_bytes(bundle, {"fixture-token-value"})
            )

            (bundle / "data.bin").write_bytes(b"public diagnostic text only")
            self.assertFalse(
                compatibility_matrix._contains_sensitive_bytes(bundle, {"fixture-token-value"})
            )

    def test_runtime_log_export_includes_nested_logs_and_redacts_fixture_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime_session = "aaa00-bb0000-11111111-2222-3333-4444-555555555555-aaaaaaaaaaaa"
            runtime_log = (
                root / "runtime-state" / "4304" / "base"
                / f"adapter-pi_shared_{runtime_session}.stderr.log"
            )
            runtime_log.parent.mkdir(parents=True)
            runtime_log.write_text(
                f"{runtime_session} fixture-token-value roster loaded\n",
                encoding="utf-8",
            )
            host_key = root / "ssh-host-key"
            host_key.write_text("private-key-bytes", encoding="utf-8")

            fixture = object.__new__(compatibility_matrix.LocalRuntimeFixture)
            fixture.root = root
            fixture.fixture_token = "fixture-token-value"
            fixture.local_user = "user_private_12345678"
            fixture.ssh_host_key_line = "ssh-ed25519 public-key-line"
            fixture.home_root = root / "home"
            fixture.package_paths = {}
            fixture.runtime_base = {}
            fixture.runtime_identities = {}
            fixture.saved_state = {}
            fixture.phase_results = []
            fixture.host_key = host_key

            destination = root / "retained"
            retained = fixture.export_safe_runtime_logs(destination)
            self.assertEqual(len(retained), 1)
            exported = destination / retained[0]
            safe = exported.read_text(encoding="utf-8")
            self.assertIn("roster loaded", safe)
            self.assertNotIn("fixture-token-value", safe)
            self.assertNotIn(runtime_session, exported.name)
            self.assertNotIn("aaa00-bb0000", exported.name)
            self.assertNotIn(runtime_session, safe)
            self.assertIn("runtime-state__4304__base__", exported.name)

    def test_failure_artifact_workflow_uploads_report_and_diagnostics(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release-note-gate.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'export CI_DIAGNOSTIC_ARTIFACTS_PATH="$RUNNER_TEMP/TunerCompatibilityDiagnostics"',
            workflow,
        )
        self.assertIn("${{ runner.temp }}/ReleaseCompatibilityReport.json", workflow)
        self.assertIn("${{ runner.temp }}/TunerCompatibilityDiagnostics/", workflow)
        self.assertIn("if-no-files-found: error", workflow)


if __name__ == "__main__":
    unittest.main()
