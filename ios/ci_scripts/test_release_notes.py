import json
import plistlib
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
        path.write_bytes(self.current_source.read_bytes())
        return path

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

    def test_binds_the_authored_note_to_the_assigned_build_number(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))

            note = release_notes.bind_current_note(source, self.history_source, 57)
            selected, data = release_notes.load_current_note(source, expected_build=57)

            self.assertEqual(note.build, 57)
            self.assertEqual(selected, note)
            self.assertEqual(data["build"], 57)
            self.assertTrue(note.items)

    def test_repeated_binding_is_idempotent_only_for_the_same_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))

            first = release_notes.bind_current_note(source, self.history_source, 57)
            second = release_notes.bind_current_note(source, self.history_source, 57)

            self.assertEqual(second, first)
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "already bound to build 57"):
                release_notes.bind_current_note(source, self.history_source, 58)

    def test_empty_author_notes_are_refused(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            data = json.loads(source.read_text(encoding="utf-8"))
            data["items"] = []
            source.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "no user-facing release notes"):
                release_notes.bind_current_note(source, self.history_source, 57)

    def test_existing_exact_historical_note_is_reused_without_rebinding(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            note = release_notes.bind_current_note(source, self.history_source, 52)
            selected, data = release_notes.load_current_note(source)

            self.assertEqual(note, release_notes.exact_note(self.history, 52))
            self.assertEqual(selected.build, 0)
            self.assertEqual(data["build"], 0)

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

    def test_binding_rejects_an_unnoted_build_below_history(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._draft_copy(Path(temporary_directory))
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "does not follow latest"):
                release_notes.bind_current_note(source, self.history_source, 12)

    def test_render_uses_the_same_exact_note_as_the_app_resource(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._draft_copy(root)
            note = release_notes.bind_current_note(source, self.history_source, 57)
            app = root / "TightbeamTuner.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": "57"}, info_file)
            output = root / "WhatToTest.en-US.txt"

            status = release_notes.main([
                "render", "--build-number", "57", "--source", str(source),
                "--history", str(self.history_source), "--app-path", str(app),
                "--output", str(output),
            ])

            self.assertEqual(status, 0)
            self.assertEqual(output.read_text(encoding="utf-8"), note.tester_text())

    def test_render_rejects_a_different_bundle_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._draft_copy(root)
            release_notes.bind_current_note(source, self.history_source, 57)
            app = root / "TightbeamTuner.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as info_file:
                plistlib.dump({"CFBundleVersion": "56"}, info_file)
            output = root / "WhatToTest.en-US.txt"

            status = release_notes.main([
                "render", "--build-number", "57", "--source", str(source),
                "--history", str(self.history_source), "--app-path", str(app),
                "--output", str(output),
            ])

            self.assertEqual(status, 1)
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
