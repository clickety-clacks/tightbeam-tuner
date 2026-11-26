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


if __name__ == "__main__":
    unittest.main()
