import json
import plistlib
from contextlib import redirect_stderr
from io import StringIO
import tempfile
import unittest
from pathlib import Path

import release_notes


class ExactReleaseNoteSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.history_source = release_notes._default_source()
        cls.current_source = release_notes._default_current_source()
        cls.history = release_notes.load_notes(cls.history_source)

    def _draft_copy(self, root):
        path = root / "CurrentBuildReleaseNote.json"
        data = json.loads(self.current_source.read_text(encoding="utf-8"))
        data["build"] = 0
        data["date"] = ""
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path

    def _numbered_note_copy(self, root, build_number):
        path = self._draft_copy(root)
        data = json.loads(path.read_text(encoding="utf-8"))
        data["build"] = build_number
        data["date"] = "January 1, 2027"
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path

    def _archive_copy(self, root, app_bundles):
        archive = root / "TightbeamTuner.xcarchive"
        applications = archive / "Products" / "Applications"
        applications.mkdir(parents=True)
        with (archive / "Info.plist").open("wb") as info_file:
            plistlib.dump({"ApplicationProperties": {"CFBundleVersion": "56"}}, info_file)
        for app_name, build_number in app_bundles:
            app = applications / f"{app_name}.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": str(build_number)}, info_file)
        (applications / "archive-entry.txt").write_text(
            "CONTENT_SENTINEL_MUST_NOT_BE_LOGGED", encoding="utf-8"
        )
        return archive

    def _render_archive(self, source, archive, output):
        return release_notes.main([
            "render", "--build-number", "57", "--source", str(source),
            "--history", str(self.history_source), "--archive-path", str(archive),
            "--output", str(output),
        ])

    def test_selects_only_the_exact_historical_build(self):
        note = release_notes.exact_note(self.history, 52)
        self.assertEqual(note.build, 52)
        self.assertTrue(note.items)
        self.assertTrue(all(item.title.strip() and item.detail.strip() for item in note.items))

    def test_missing_historical_build_does_not_fall_back_to_latest(self):
        with self.assertRaisesRegex(release_notes.ReleaseNoteError, "build 57"):
            release_notes.exact_note(self.history, 57)

    def test_testflight_text_uses_the_same_titles_and_details(self):
        note = release_notes.exact_note(self.history, 52)
        text = note.tester_text()
        for item in note.items:
            self.assertIn(item.title, text)
            self.assertIn(item.detail, text)

    def test_selects_the_authored_note_only_for_its_exact_build_number(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._numbered_note_copy(Path(temporary_directory), 57)
            original = source.read_bytes()

            note = release_notes.note_for_build(source, self.history_source, 57)
            selected, data = release_notes.load_current_note(source, expected_build=57)

            self.assertEqual(note.build, 57)
            self.assertEqual(selected, note)
            self.assertEqual(data["build"], 57)
            self.assertTrue(note.items)
            self.assertEqual(source.read_bytes(), original)

    def test_current_proof_note_is_selected_only_for_build_58(self):
        note = release_notes.note_for_build(
            self.current_source, self.history_source, 58
        )
        self.assertEqual(note.build, 58)
        self.assertEqual(len(note.items), 6)

        with self.assertRaisesRegex(
            release_notes.ReleaseNoteError,
            "current draft is assigned to build 58",
        ):
            release_notes.note_for_build(self.current_source, self.history_source, 57)

    def test_two_sequential_archive_workspaces_refuse_a_reused_note_draft(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            committed_draft = self._numbered_note_copy(root, 57).read_bytes()
            first_workspace = root / "archive-one"
            second_workspace = root / "archive-two"
            first_workspace.mkdir()
            second_workspace.mkdir()
            first_source = first_workspace / "CurrentBuildReleaseNote.json"
            second_source = second_workspace / "CurrentBuildReleaseNote.json"
            first_source.write_bytes(committed_draft)
            second_source.write_bytes(committed_draft)

            first_errors = StringIO()
            with redirect_stderr(first_errors):
                first_status = release_notes.main([
                    "validate", "--build-number", "57", "--source", str(first_source),
                    "--history", str(self.history_source),
                ])
            second_errors = StringIO()
            with redirect_stderr(second_errors):
                second_status = release_notes.main([
                    "validate", "--build-number", "58", "--source", str(second_source),
                    "--history", str(self.history_source),
                ])

            self.assertEqual(first_status, 0)
            self.assertEqual(second_status, 1)
            self.assertIn("current draft is assigned to build 57", second_errors.getvalue())
            self.assertEqual(first_source.read_bytes(), committed_draft)
            self.assertEqual(second_source.read_bytes(), committed_draft)

    def test_empty_author_notes_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            data = json.loads(source.read_text(encoding="utf-8"))
            data["items"] = []
            source.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "no user-facing release notes"):
                release_notes.note_for_build(source, self.history_source, 57)

    def test_existing_exact_historical_note_is_selected_without_mutating_the_draft(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            original = source.read_bytes()
            note = release_notes.note_for_build(source, self.history_source, 52)
            selected, data = release_notes.load_current_note(source)

            self.assertEqual(note, release_notes.exact_note(self.history, 52))
            self.assertEqual(selected.build, 0)
            self.assertEqual(data["build"], 0)
            self.assertEqual(source.read_bytes(), original)

    def test_selection_uses_exact_history_before_the_unbound_current_draft(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))

            selected = release_notes.note_for_build(source, self.history_source, 52)

            self.assertEqual(selected, release_notes.exact_note(self.history, 52))

    def test_unbound_draft_does_not_supply_notes_for_a_new_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            data = json.loads(source.read_text(encoding="utf-8"))
            data["items"] = []
            source.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "no user-facing release notes"):
                release_notes.note_for_build(source, self.history_source, 57)

    def test_unbound_draft_cannot_be_used_for_an_archive(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "current draft is not assigned"):
                release_notes.note_for_build(source, self.history_source, 57)

    def test_numbered_current_note_must_follow_history(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._numbered_note_copy(Path(temporary_directory), 12)
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "does not follow latest"):
                release_notes.note_for_build(source, self.history_source, 12)

    def test_render_reads_the_app_version_from_the_xcode_cloud_archive(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 57)
            archive = self._archive_copy(root, [("TightbeamTuner", 57)])
            output = root / "WhatToTest.en-US.txt"

            status = self._render_archive(source, archive, output)

            self.assertEqual(status, 0)
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                release_notes.note_for_build(source, self.history_source, 57).tester_text(),
            )

    def test_render_rejects_an_archive_with_a_different_bundle_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 57)
            archive = self._archive_copy(root, [("TightbeamTuner", 56)])
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_archive(source, archive, output)

            self.assertEqual(status, 1)
            self.assertIn("archive CFBundleVersion 56 does not match build 57", errors.getvalue())
            self.assertFalse(output.exists())

    def test_render_refuses_archive_with_no_app_bundles_and_lists_names_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 57)
            archive = self._archive_copy(root, [])
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_archive(source, archive, output)

            diagnostic = errors.getvalue()
            self.assertEqual(status, 1)
            self.assertIn("found 0", diagnostic)
            self.assertIn("archive-entry.txt", diagnostic)
            self.assertNotIn("CONTENT_SENTINEL_MUST_NOT_BE_LOGGED", diagnostic)
            self.assertFalse(output.exists())

    def test_render_refuses_archive_with_multiple_app_bundles_and_lists_names_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 57)
            archive = self._archive_copy(
                root, [("TightbeamTuner", 57), ("UnexpectedApp", 57)]
            )
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_archive(source, archive, output)

            diagnostic = errors.getvalue()
            self.assertEqual(status, 1)
            self.assertIn("found 2", diagnostic)
            self.assertIn("TightbeamTuner.app", diagnostic)
            self.assertIn("UnexpectedApp.app", diagnostic)
            self.assertNotIn("CONTENT_SENTINEL_MUST_NOT_BE_LOGGED", diagnostic)
            self.assertFalse(output.exists())

    def test_duplicate_historical_build_numbers_fail_closed(self):
        source = self.history_source.read_text(encoding="utf-8")
        marker = "static let history: [ReleaseNote] = ["
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
