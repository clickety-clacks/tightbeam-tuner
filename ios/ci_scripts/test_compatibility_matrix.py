import json
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


if __name__ == "__main__":
    unittest.main()
