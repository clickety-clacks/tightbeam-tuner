import tempfile
import unittest
from pathlib import Path
import os
import plistlib
import shutil
import subprocess

import release_notes


class ExactReleaseNoteSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = release_notes._default_source()
        cls.notes = release_notes.load_notes(cls.source)

    def test_selects_only_the_exact_numbered_note(self):
        note = release_notes.exact_note(self.notes, 52)
        self.assertEqual(note.build, 52)
        self.assertTrue(note.items)
        self.assertTrue(all(item.title.strip() and item.detail.strip() for item in note.items))

    def test_missing_build_does_not_fall_back_to_latest_note(self):
        with self.assertRaisesRegex(release_notes.ReleaseNoteError, "build 57"):
            release_notes.exact_note(self.notes, 57)

    def test_testflight_text_uses_the_same_titles_and_details(self):
        note = release_notes.exact_note(self.notes, 52)
        text = note.tester_text()
        for item in note.items:
            self.assertIn(item.title, text)
            self.assertIn(item.detail, text)

    def test_render_command_writes_the_exact_note_text(self):
        note = release_notes.exact_note(self.notes, 52)
        with tempfile.TemporaryDirectory() as temporary_directory:
            output = Path(temporary_directory) / "WhatToTest.en-US.txt"
            status = release_notes.main([
                "render", "--build-number", "52", "--output", str(output)
            ])
            self.assertEqual(status, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), note.tester_text())

    def test_render_rejects_an_archive_with_a_different_bundle_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = root / "TightbeamTuner.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": "51"}, info_file)
            output = root / "WhatToTest.en-US.txt"

            status = release_notes.main([
                "render", "--build-number", "52", "--app-path", str(app),
                "--output", str(output),
            ])

            self.assertEqual(status, 1)
            self.assertFalse(output.exists())

    def test_render_accepts_matching_archive_and_uses_the_same_note(self):
        note = release_notes.exact_note(self.notes, 52)
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            app = root / "TightbeamTuner.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": "52"}, info_file)
            output = root / "WhatToTest.en-US.txt"

            status = release_notes.main([
                "render", "--build-number", "52", "--app-path", str(app),
                "--output", str(output),
            ])

            self.assertEqual(status, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), note.tester_text())

    def test_cloud_archive_gate_requires_an_exact_note(self):
        gate = Path(__file__).with_name("ci_pre_xcodebuild.sh")

        def run(action, build_number, cloud="TRUE"):
            environment = os.environ.copy()
            environment.pop("CI", None)
            environment["CI_XCODE_CLOUD"] = cloud
            environment["CI_XCODEBUILD_ACTION"] = action
            environment["CI_BUILD_NUMBER"] = build_number
            return subprocess.run(
                ["/bin/sh", str(gate)],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

        accepted = run("archive", "52")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)

        refused = run("archive", "57")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("no user-facing release notes", refused.stderr)

        non_archive = run("test", "57")
        self.assertEqual(non_archive.returncode, 0, non_archive.stderr)

    def test_post_archive_hook_writes_exact_notes_for_matching_testflight_bundle(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project = root / "ios"
            scripts = project / "ci_scripts"
            app = root / "TightbeamTuner.app"
            scripts.mkdir(parents=True)
            app.mkdir()
            shutil.copy2(Path(__file__).with_name("ci_post_xcodebuild.sh"), scripts)
            shutil.copy2(Path(__file__).with_name("release_notes.py"), scripts)
            source_dir = project / "TightbeamTuner"
            source_dir.mkdir()
            shutil.copy2(self.source, source_dir / "ReleaseNotes.swift")
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": "52"}, info_file)

            environment = os.environ.copy()
            environment.update({
                "CI_XCODE_CLOUD": "TRUE",
                "CI_XCODEBUILD_ACTION": "archive",
                "CI_XCODEBUILD_EXIT_CODE": "0",
                "CI_BUILD_NUMBER": "52",
                "CI_APP_STORE_SIGNED_APP_PATH": str(app),
            })
            result = subprocess.run(
                ["/bin/sh", str(scripts / "ci_post_xcodebuild.sh")],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            output = project / "TestFlight" / "WhatToTest.en-US.txt"
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                release_notes.exact_note(self.notes, 52).tester_text(),
            )

    def test_post_archive_hook_rejects_bundle_number_that_differs_from_cloud_number(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            project = root / "ios"
            scripts = project / "ci_scripts"
            app = root / "TightbeamTuner.app"
            scripts.mkdir(parents=True)
            app.mkdir()
            shutil.copy2(Path(__file__).with_name("ci_post_xcodebuild.sh"), scripts)
            shutil.copy2(Path(__file__).with_name("release_notes.py"), scripts)
            source_dir = project / "TightbeamTuner"
            source_dir.mkdir()
            shutil.copy2(self.source, source_dir / "ReleaseNotes.swift")
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": "51"}, info_file)

            environment = os.environ.copy()
            environment.update({
                "CI_XCODE_CLOUD": "TRUE",
                "CI_XCODEBUILD_ACTION": "archive",
                "CI_XCODEBUILD_EXIT_CODE": "0",
                "CI_BUILD_NUMBER": "52",
                "CI_APP_STORE_SIGNED_APP_PATH": str(app),
            })
            result = subprocess.run(
                ["/bin/sh", str(scripts / "ci_post_xcodebuild.sh")],
                capture_output=True,
                text=True,
                env=environment,
                check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("CFBundleVersion 51 does not match build 52", result.stderr)
            self.assertFalse((project / "TestFlight" / "WhatToTest.en-US.txt").exists())

    def test_duplicate_build_numbers_fail_closed(self):
        source = self.source.read_text(encoding="utf-8")
        marker = "static let all: [ReleaseNote] = ["
        start = source.index(marker) + len(marker)
        open_index = start - 1
        close_index = release_notes._balanced_end(source, open_index, "[", "]")
        array_content = source[open_index + 1 : close_index]
        first_entry = next(release_notes._code_occurrences(array_content, "ReleaseNote"))
        call_open = array_content.find("(", first_entry + len("ReleaseNote"))
        call_close = release_notes._balanced_end(array_content, call_open, "(", ")")
        duplicate = array_content[first_entry : call_close + 1]
        changed = source[:close_index] + ",\n" + duplicate + source[close_index:]

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_source = Path(temporary_directory) / "ReleaseNotes.swift"
            temporary_source.write_text(changed, encoding="utf-8")
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "duplicate build numbers"):
                release_notes.load_notes(temporary_source)


if __name__ == "__main__":
    unittest.main()
