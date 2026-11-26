import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import compatibility_matrix


class SimulatorSelectionTests(unittest.TestCase):
    def _selection(self, runtime_platform):
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
        runtimes = {
            "runtimes": [
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
                side_effect=[json.dumps(devicetypes), json.dumps(runtimes)],
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


class LoopbackListenerTests(unittest.TestCase):
    def test_listener_check_scopes_lsof_to_owner_and_rejects_non_loopback_bind(self):
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
            compatibility_matrix._require_loopback_listener(19450, "fixture", 123)
        self.assertEqual(
            run.call_args.args[0],
            ["/usr/sbin/lsof", "-nP", "-a", "-p", "123", "-iTCP:19450", "-sTCP:LISTEN"],
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
            compatibility_matrix._require_loopback_listener(19450, "fixture", 123)

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
        raw = (
            "Authorization: Bearer secret-bearer-value\n"
            "X-Test-Fixture-Token: fixture-token-value\n"
            "agent:main:clawline:temporary-user:main user_private_12345678\n"
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
            "/private/task-root",
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
            runtime_log = root / "runtime-state" / "4304" / "base" / "gateway.log"
            runtime_log.parent.mkdir(parents=True)
            runtime_log.write_text(
                "fixture-token-value user_private_12345678 roster loaded\n", encoding="utf-8"
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
            self.assertNotIn("user_private_12345678", safe)
            self.assertIn("runtime-state__4304__base__gateway.log", exported.name)

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
