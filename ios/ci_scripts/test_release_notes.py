import json
import plistlib
from contextlib import redirect_stderr
from io import StringIO
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

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
        path = root / "CurrentBuildReleaseNote.json"
        data = json.loads(self.current_source.read_text(encoding="utf-8"))
        data["build"] = 0
        data["date"] = ""
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        data = json.loads(path.read_text(encoding="utf-8"))
        data["build"] = build_number
        data["date"] = "January 1, 2027"
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path

    def _premerge_base_copy(self, root, build_number):
        path = root / "BaseBuildReleaseNote.json"
        data = json.loads(self.current_source.read_text(encoding="utf-8"))
        data["build"] = build_number
        data["date"] = "January 1, 2027"
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path

    def _signed_export_copy(self, root, app_bundles):
        signed_export = root / "signed-export"
        signed_export.mkdir()
        ipa_path = signed_export / "TightbeamTuner.ipa"
        with zipfile.ZipFile(ipa_path, "w", compression=zipfile.ZIP_DEFLATED) as ipa:
            for app_name, build_number in app_bundles:
                info = plistlib.dumps({
                    "CFBundleVersion": str(build_number),
                    "ContentSentinel": "CONTENT_SENTINEL_MUST_NOT_BE_LOGGED",
                })
                ipa.writestr(f"Payload/{app_name}.app/Info.plist", info)
            if not app_bundles:
                ipa.writestr("ExportMetadata/empty.txt", "CONTENT_SENTINEL_MUST_NOT_BE_LOGGED")
        return signed_export

    def _render_signed_export(self, source, signed_export, output):
        return release_notes.main([
            "render", "--build-number", "69", "--source", str(source),
            "--history", str(self.history_source), "--signed-app-path", str(signed_export),
            "--output", str(output),
        ])

    def test_selects_only_the_exact_historical_build(self):
        note = release_notes.exact_note(self.history, 52)
        self.assertEqual(note.build, 52)
        self.assertTrue(note.items)
        self.assertTrue(all(item.title.strip() and item.detail.strip() for item in note.items))

    def test_shipped_build_59_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 59)
        self.assertEqual(note.build, 59)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Keep Chat clear during its first layout",
                    "Tuner reserves space for its message field before Chat's first layout measurement, keeping the conversation controls clear.",
                ),
                (
                    "See your saved agents at launch",
                    "Tuner shows the saved agent list as soon as it opens, then reconciles it with the current roster.",
                ),
                (
                    "Send sits beside the message field",
                    "Send is a separate control beside the field and stays aligned with the last line as the field grows.",
                ),
                (
                    "See when an agent is replying",
                    "After you send a prompt, its row moves to Replies with a spinner until a new assistant message arrives. If sending fails, the row stays where it was.",
                ),
                (
                    "Send matches the message field",
                    "The one-line Send control matches the 44-point field height, while multiline drafts keep it aligned with the last line.",
                ),
                (
                    "Release notes match the build",
                    "Each numbered archive requires notes for that exact build. Tuner's What's Changed and TestFlight use the same authored notes.",
                ),
            ],
        )

    def test_shipped_build_62_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 62)
        self.assertEqual(note.build, 62)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "See when an agent is replying",
                    "After an accepted prompt, the agent moves from Agents to Replies with a spinner until a new assistant message arrives. If sending fails, the agent stays in Agents.",
                ),
                (
                    "Keep release notes with every update",
                    "Each numbered update needs its own author-written notes before release. The same notes appear in What's Changed and TestFlight.",
                ),
            ],
        )

    def test_shipped_build_63_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 63)
        self.assertEqual(note.build, 63)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Match Chat colors across appearances",
                    "Chat's background, composer accents, and connection indicator now match Chat in both light and dark appearances.",
                ),
            ],
        )

    def test_shipped_build_67_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 67)
        self.assertEqual(note.build, 67)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Let the conversation run under the message field",
                    "The conversation fills the chat screen, folded or unfolded, in portrait and landscape. The toolbar and message field float over it, with no empty or white bars, and Latest messages stays clear of the message field.",
                ),
                (
                    "Leave room above the keyboard",
                    "With the keyboard up, the message field sits a small gap above it. The message field now follows the system layout instead of lining up with Filter agents.",
                ),
            ],
        )

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
            source = self._numbered_note_copy(Path(temporary_directory), 69)
            original = source.read_bytes()

            note = release_notes.note_for_build(source, self.history_source, 69)
            selected, data = release_notes.load_current_note(source, expected_build=69)

            self.assertEqual(note.build, 69)
            self.assertEqual(selected, note)
            self.assertEqual(data["build"], 69)
            self.assertTrue(note.items)
            self.assertEqual(source.read_bytes(), original)

    def test_current_proof_note_is_selected_only_for_build_69(self):
        note = release_notes.note_for_build(
            self.current_source, self.history_source, 69
        )
        self.assertEqual(note.build, 69)
        self.assertEqual(len(note.items), 1)

        shipped = release_notes.note_for_build(
            self.current_source, self.history_source, 68
        )
        self.assertEqual(shipped, release_notes.exact_note(self.history, 68))

        shipped = release_notes.note_for_build(
            self.current_source, self.history_source, 63
        )
        self.assertEqual(shipped, release_notes.exact_note(self.history, 63))

        with self.assertRaisesRegex(
            release_notes.ReleaseNoteError,
            "current draft is assigned to build 69",
        ):
            release_notes.note_for_build(self.current_source, self.history_source, 61)

    def test_premerge_refuses_a_missing_current_note(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            base_note = self._premerge_base_copy(root, 68)
            missing_note = root / "missing-current-note.json"

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "could not read the current-build release note"):
                release_notes.validate_premerge_note(
                    missing_note, self.history_source, base_note
                )

    def test_premerge_refuses_a_note_stale_against_its_base(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 59)
            base_note = self._premerge_base_copy(root, 59)

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "greater than base note build 59"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note
                )

    def test_premerge_refuses_a_build_already_in_history(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 52)
            base_note = self._premerge_base_copy(root, 51)

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "build 52 already appears in release-note history"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note
                )

    def test_premerge_refuses_a_build_older_than_history_even_if_not_listed(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 12)
            base_note = self._premerge_base_copy(root, 11)

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "greater than latest historical note 68"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note
                )

    def test_premerge_refuses_empty_author_note_items(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 69)
            base_note = self._premerge_base_copy(root, 68)
            data = json.loads(current_note.read_text(encoding="utf-8"))
            data["items"] = []
            current_note.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "no user-facing release notes"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note
                )

    def test_premerge_accepts_fresh_note_with_matching_pr_number_and_run_source(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 69)
            base_note = self._premerge_base_copy(root, 68)
            description = (
                "Release note build number: 69\n"
                "Build number source: latest Xcode Cloud run 68 (read at release-window preflight)\n"
            )

            note = release_notes.validate_premerge_note(
                current_note, self.history_source, base_note, pr_description=description
            )

            self.assertEqual(note.build, 69)

    def test_premerge_rejects_pr_description_number_that_differs_from_the_note(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 69)
            base_note = self._premerge_base_copy(root, 68)
            description = (
                "Release note build number: 70\n"
                "Build number source: latest Xcode Cloud run 68\n"
            )

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "names release-note build 70"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note, pr_description=description
                )

    def test_premerge_rejects_pr_description_source_that_does_not_imply_the_note_number(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 69)
            base_note = self._premerge_base_copy(root, 68)
            description = (
                "Release note build number: 69\n"
                "Build number source: latest Xcode Cloud run 62\n"
            )

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "one greater than observed latest Xcode Cloud run 62"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note, pr_description=description
                )

    def test_premerge_cli_requires_pr_provenance_even_when_environment_value_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 69)
            base_note = self._premerge_base_copy(root, 68)
            errors = StringIO()

            with patch.dict("os.environ", {}, clear=True), redirect_stderr(errors):
                status = release_notes.main([
                    "premerge", "--source", str(current_note),
                    "--history", str(self.history_source), "--base-note", str(base_note),
                    "--require-pr-provenance",
                ])

            self.assertEqual(status, 1)
            self.assertIn("PR description must contain exactly one", errors.getvalue())

    def test_premerge_main_commit_does_not_require_a_pr_description(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, 69)
            base_note = self._premerge_base_copy(root, 68)

            note = release_notes.validate_premerge_note(
                current_note, self.history_source, base_note
            )

            self.assertEqual(note.build, 69)

    def test_two_sequential_archive_workspaces_refuse_a_reused_note_draft(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            committed_draft = self._numbered_note_copy(root, 69).read_bytes()
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
                    "validate", "--build-number", "69", "--source", str(first_source),
                    "--history", str(self.history_source),
                ])
            second_errors = StringIO()
            with redirect_stderr(second_errors):
                second_status = release_notes.main([
                    "validate", "--build-number", "70", "--source", str(second_source),
                    "--history", str(self.history_source),
                ])

            self.assertEqual(first_status, 0)
            self.assertEqual(second_status, 1)
            self.assertIn("current draft is assigned to build 69", second_errors.getvalue())
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

    def test_render_reads_the_app_version_from_the_exported_testflight_ipa(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 69)
            signed_export = self._signed_export_copy(root, [("TightbeamTuner", 69)])
            output = root / "WhatToTest.en-US.txt"

            status = self._render_signed_export(source, signed_export, output)

            self.assertEqual(status, 0)
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                release_notes.note_for_build(source, self.history_source, 69).tester_text(),
            )

    def test_render_rejects_an_exported_ipa_with_a_different_bundle_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 69)
            signed_export = self._signed_export_copy(root, [("TightbeamTuner", 63)])
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_signed_export(source, signed_export, output)

            self.assertEqual(status, 1)
            self.assertIn("signed app CFBundleVersion 63 does not match build 69", errors.getvalue())
            self.assertFalse(output.exists())

    def test_render_refuses_signed_ipa_with_no_app_bundles_and_lists_names_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 69)
            signed_export = self._signed_export_copy(root, [])
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_signed_export(source, signed_export, output)

            diagnostic = errors.getvalue()
            self.assertEqual(status, 1)
            self.assertIn("found 0", diagnostic)
            self.assertIn("ExportMetadata/empty.txt", diagnostic)
            self.assertNotIn("CONTENT_SENTINEL_MUST_NOT_BE_LOGGED", diagnostic)
            self.assertFalse(output.exists())

    def test_render_refuses_signed_ipa_with_multiple_app_bundles_and_lists_names_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, 69)
            signed_export = self._signed_export_copy(
                root, [("TightbeamTuner", 69), ("UnexpectedApp", 69)]
            )
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_signed_export(source, signed_export, output)

            diagnostic = errors.getvalue()
            self.assertEqual(status, 1)
            self.assertIn("found 2", diagnostic)
            self.assertIn("Payload/TightbeamTuner.app/Info.plist", diagnostic)
            self.assertIn("Payload/UnexpectedApp.app/Info.plist", diagnostic)
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
