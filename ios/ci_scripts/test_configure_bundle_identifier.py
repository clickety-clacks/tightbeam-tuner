import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import configure_bundle_identifier
import release_hook


PROJECT = '''
buildSettings = {
    TUNER_EXPECTED_BUNDLE_IDENTIFIER = "co.clicketyclacks.tightbeam-tuner";
    PRODUCT_BUNDLE_IDENTIFIER = "$(TUNER_EXPECTED_BUNDLE_IDENTIFIER)";
};
buildSettings = {
    TUNER_EXPECTED_BUNDLE_IDENTIFIER = "co.clicketyclacks.tightbeam-tuner";
    PRODUCT_BUNDLE_IDENTIFIER = "$(TUNER_EXPECTED_BUNDLE_IDENTIFIER)";
};
buildSettings = {
    PRODUCT_BUNDLE_IDENTIFIER = "co.clicketyclacks.tightbeam-tuner.tests";
};
'''


class ConfigureBundleIdentifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name) / "project.pbxproj"
        self.project.write_text(PROJECT, encoding="utf-8")

    def test_proof_route_is_materialized_in_both_app_configurations(self):
        with mock.patch.dict(os.environ, {
            release_hook.RELEASE_ROUTE_ENV: "proof",
            release_hook.EXPECTED_BUNDLE_IDENTIFIER_ENV: release_hook.PROOF_BUNDLE_IDENTIFIER,
        }, clear=True):
            configured = configure_bundle_identifier.configure_project(self.project)

        contents = self.project.read_text(encoding="utf-8")
        self.assertEqual(configured, release_hook.PROOF_BUNDLE_IDENTIFIER)
        self.assertEqual(contents.count(f'TUNER_EXPECTED_BUNDLE_IDENTIFIER = "{release_hook.PROOF_BUNDLE_IDENTIFIER}";'), 2)
        self.assertEqual(contents.count('PRODUCT_BUNDLE_IDENTIFIER = "$(TUNER_EXPECTED_BUNDLE_IDENTIFIER)";'), 2)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "co.clicketyclacks.tightbeam-tuner.tests";', contents)

    def test_checked_in_project_accepts_the_proof_identity(self):
        checked_in = Path(__file__).resolve().parents[1] / "TightbeamTuner.xcodeproj" / "project.pbxproj"
        shutil.copyfile(checked_in, self.project)
        with mock.patch.dict(os.environ, {
            release_hook.RELEASE_ROUTE_ENV: "proof",
            release_hook.EXPECTED_BUNDLE_IDENTIFIER_ENV: release_hook.PROOF_BUNDLE_IDENTIFIER,
        }, clear=True):
            configure_bundle_identifier.configure_project(self.project)

        contents = self.project.read_text(encoding="utf-8")
        self.assertEqual(contents.count(f'TUNER_EXPECTED_BUNDLE_IDENTIFIER = "{release_hook.PROOF_BUNDLE_IDENTIFIER}";'), 2)
        self.assertEqual(contents.count('PRODUCT_BUNDLE_IDENTIFIER = "$(TUNER_EXPECTED_BUNDLE_IDENTIFIER)";'), 2)
        self.assertIn('PRODUCT_BUNDLE_IDENTIFIER = "co.clicketyclacks.tightbeam-tuner.tests";', contents)

    def test_production_default_is_preserved_without_cloud_override(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            configured = configure_bundle_identifier.configure_project(self.project)

        self.assertEqual(configured, release_hook.DEFAULT_BUNDLE_IDENTIFIER)
        self.assertEqual(self.project.read_text(encoding="utf-8"), PROJECT)

    def test_malformed_project_fails_closed_without_partial_write(self):
        malformed = PROJECT.replace(
            '    TUNER_EXPECTED_BUNDLE_IDENTIFIER = "co.clicketyclacks.tightbeam-tuner";\n',
            "",
            1,
        )
        self.project.write_text(malformed, encoding="utf-8")
        with mock.patch.dict(os.environ, {
            release_hook.RELEASE_ROUTE_ENV: "proof",
            release_hook.EXPECTED_BUNDLE_IDENTIFIER_ENV: release_hook.PROOF_BUNDLE_IDENTIFIER,
        }, clear=True):
            with self.assertRaisesRegex(release_hook.ReleaseHookError, "exactly two"):
                configure_bundle_identifier.configure_project(self.project)
        self.assertEqual(self.project.read_text(encoding="utf-8"), malformed)


if __name__ == "__main__":
    unittest.main()
