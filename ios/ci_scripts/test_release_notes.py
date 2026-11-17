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

TEST_BASE_BUILD = 900000
TEST_CURRENT_BUILD = 900001


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
        data["items"] = [
            item for item in data["items"]
            if item["title"].casefold() not in {"compatibility", "breaking changes"}
        ]
        data["items"].extend([
            {
                "symbol": "info.circle",
                "title": "Compatibility",
                "detail": "Tightbeam CLI 0.0.0 and Chat v0.0.0 (test fixture).",
            },
            {
                "symbol": "exclamationmark.triangle",
                "title": "Breaking changes",
                "detail": "Test fixture.",
            },
        ])
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
            "render", "--build-number", str(TEST_CURRENT_BUILD), "--source", str(source),
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

    def test_shipped_build_69_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 69)
        self.assertEqual(note.build, 69)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Keep waiting agents on their rows",
                    "After you send a prompt, the agent stays in its existing Recent and Agents rows with a spinner while it waits. Waiting agents stay in Recent even if the list grows beyond ten. After relaunch, agents still waiting regain their spinner, and existing Replies entries remain available. A reply stops the spinner and restores the existing Replies behavior; failed sends show no spinner.",
                ),
            ],
        )

    def test_shipped_build_70_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 70)
        self.assertEqual(note.build, 70)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Give the message field more room",
                    "The one-line message field is taller and keeps its ends fully rounded. Multiline editing and Send remain available.",
                ),
            ],
        )

    def test_shipped_build_71_notes_remain_available_after_current_note_advances(self):
        note = release_notes.exact_note(self.history, 71)
        self.assertEqual(note.build, 71)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Send photos from the message field",
                    "Tap + beside the status dot to paste a photo, choose photos from your library, or take one with the camera. Photos wait above the message field, where you can remove them, and send with or without words. A photo that does not send comes back with its words so you can retry. The + button appears when the conversation's Chat version accepts photos from Tuner; until then the message field is unchanged.",
                ),
            ],
        )

    def test_shipped_build_72_note_is_preserved_in_history(self):
        note = release_notes.exact_note(self.history, 72)
        self.assertEqual(note.build, 72)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "See the photo button in every conversation",
                    "The + button beside the status dot now always shows. It is greyed out when the conversation's Chat version does not yet accept photos from Tuner, and works as before when it does.",
                ),
            ],
        )

    def test_shipped_build_73_note_is_preserved_in_history(self):
        note = release_notes.exact_note(self.history, 73)
        self.assertEqual(note.build, 73)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Compatibility",
                    "Compatible with Tightbeam CLI 0.1.16 and Gateway 0.1.16 (build 4283), plus Chat v0.1.100, for the tested paths: the CLI roster returned the required fields, and Tuner opened a conversation, sent one prompt, and showed the reply. Tuner's in-app SSH roster fetch was not exercised.",
                ),
                ("Breaking changes", "None."),
            ],
        )

    def test_shipped_build_74_note_is_preserved_in_history(self):
        note = release_notes.exact_note(self.history, 74)
        self.assertEqual(note.build, 74)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Recover embedded Chat automatically",
                    "Tuner now checks embedded Chat after a navigation or connection failure and tries to restore it if it stays unavailable. When you return to Tuner, it waits before checking so a slow page has time to load.",
                ),
                (
                    "Compatibility",
                    "Compatible with Tightbeam CLI 0.1.16 and Gateway 0.1.16 (build 4283), plus Chat v0.1.100, for the tested paths: the CLI roster returned the required fields, and Tuner opened a conversation, sent one prompt, and showed the reply. Tuner's in-app SSH roster fetch was not exercised.",
                ),
                ("Breaking changes", "None."),
            ],
        )

    def test_shipped_build_75_note_is_preserved_in_history(self):
        note = release_notes.exact_note(self.history, 75)
        self.assertEqual(note.build, 75)
        self.assertEqual(
            [(item.title, item.detail) for item in note.items],
            [
                (
                    "Compatibility",
                    "Known compatibility evidence is limited to these checks: Tightbeam CLI 0.1.16 and Gateway 0.1.16 (build 4283) roster output contained the required string fields; a pre-recovery Tuner Debug build opened a conversation, sent one prompt, and displayed the reply with Chat v0.1.100. That conversation check predates the recovery change. The recovery change has not been exercised with Chat v0.1.101, and Tuner's in-app SSH roster fetch was not exercised.",
                ),
                ("Breaking changes", "None."),
            ],
        )

    def test_current_note_is_selected_only_for_its_assigned_build(self):
        current, _ = release_notes.load_current_note(self.current_source)
        self.assertEqual(current.build, 77)
        self.assertEqual(
            [item.title for item in current.items],
            ["Keep Replies current after reconnecting", "Compatibility", "Breaking changes"],
        )
        replies_detail = next(
            item.detail
            for item in current.items
            if item.title == "Keep Replies current after reconnecting"
        )
        self.assertIn(
            "A reply received during disconnection for an older agent may appear in Replies after its next live update; opening that chat still shows it.",
            replies_detail,
        )
        compatibility = next(
            item.detail for item in current.items if item.title == "Compatibility"
        )
        self.assertEqual(
            compatibility,
            "Compatible with: Tightbeam 0.1.16 (build 4283) and Chat v0.1.100. Chat v0.1.101 does not work in Tuner.",
        )
        breaking_changes = next(
            item.detail for item in current.items if item.title == "Breaking changes"
        )
        self.assertEqual(breaking_changes, "None.")

        if current.build == 0:
            with self.assertRaisesRegex(
                release_notes.ReleaseNoteError,
                "current draft is not assigned to a numbered build",
            ):
                release_notes.note_for_build(
                    self.current_source, self.history_source, 77
                )
            return

        selected = release_notes.note_for_build(
            self.current_source, self.history_source, current.build
        )
        self.assertEqual(selected, current)

        with self.assertRaisesRegex(
            release_notes.ReleaseNoteError,
            f"current draft is assigned to build {current.build}",
        ):
            release_notes.note_for_build(
                self.current_source, self.history_source, current.build + 1
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

    def test_testflight_text_includes_compatibility_and_breaking_change_items(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._numbered_note_copy(Path(temporary_directory), TEST_CURRENT_BUILD)
            note = release_notes.note_for_build(source, self.history_source, TEST_CURRENT_BUILD)
            text = note.tester_text()

        self.assertIn("Compatibility", text)
        self.assertIn("Tightbeam CLI 0.0.0 and Chat v0.0.0 (test fixture).", text)
        self.assertIn("Breaking changes", text)
        self.assertIn("Test fixture.", text)

    def test_selects_the_authored_note_only_for_its_exact_build_number(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            source = self._numbered_note_copy(Path(temporary_directory), TEST_CURRENT_BUILD)
            original = source.read_bytes()

            note = release_notes.note_for_build(source, self.history_source, TEST_CURRENT_BUILD)
            selected, data = release_notes.load_current_note(source, expected_build=TEST_CURRENT_BUILD)

            self.assertEqual(note.build, TEST_CURRENT_BUILD)
            self.assertEqual(selected, note)
            self.assertEqual(data["build"], TEST_CURRENT_BUILD)
            self.assertTrue(note.items)
            self.assertEqual(source.read_bytes(), original)

            with self.assertRaisesRegex(
                release_notes.ReleaseNoteError,
                f"current draft is assigned to build {TEST_CURRENT_BUILD}",
            ):
                release_notes.note_for_build(
                    source, self.history_source, TEST_CURRENT_BUILD + 1
                )

    def test_shipped_build_72_remains_selectable_after_current_note_advances(self):
        note = release_notes.note_for_build(
            self.current_source, self.history_source, 72
        )
        self.assertEqual(note.build, 72)
        self.assertEqual(len(note.items), 1)

        shipped = release_notes.note_for_build(
            self.current_source, self.history_source, 71
        )
        self.assertEqual(shipped, release_notes.exact_note(self.history, 71))

        shipped = release_notes.note_for_build(
            self.current_source, self.history_source, 70
        )
        self.assertEqual(shipped, release_notes.exact_note(self.history, 70))

        shipped = release_notes.note_for_build(
            self.current_source, self.history_source, 69
        )
        self.assertEqual(shipped, release_notes.exact_note(self.history, 69))

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
            "no exact user-facing release notes are recorded for build 61",
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

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "greater than latest historical note 75"):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note
                )

    def test_premerge_refuses_empty_author_note_items(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)
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
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)
            description = (
                f"Release note build number: {TEST_CURRENT_BUILD}\n"
                f"Build number source: latest Xcode Cloud run {TEST_BASE_BUILD} (test fixture)\n"
            )

            note = release_notes.validate_premerge_note(
                current_note, self.history_source, base_note, pr_description=description
            )

            self.assertEqual(note.build, TEST_CURRENT_BUILD)

    def test_premerge_rejects_pr_description_number_that_differs_from_the_note(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)
            description = (
                f"Release note build number: {TEST_BASE_BUILD}\n"
                f"Build number source: latest Xcode Cloud run {TEST_BASE_BUILD}\n"
            )

            with self.assertRaisesRegex(
                release_notes.ReleaseNoteError,
                f"names release-note build {TEST_BASE_BUILD}",
            ):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note, pr_description=description
                )

    def test_premerge_rejects_pr_description_source_that_does_not_imply_the_note_number(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)
            description = (
                f"Release note build number: {TEST_CURRENT_BUILD}\n"
                f"Build number source: latest Xcode Cloud run {TEST_BASE_BUILD - 2}\n"
            )

            with self.assertRaisesRegex(
                release_notes.ReleaseNoteError,
                f"one greater than observed latest Xcode Cloud run {TEST_BASE_BUILD - 2}",
            ):
                release_notes.validate_premerge_note(
                    current_note, self.history_source, base_note, pr_description=description
                )

    def test_premerge_cli_requires_pr_provenance_even_when_environment_value_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)
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
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)

            note = release_notes.validate_premerge_note(
                current_note, self.history_source, base_note
            )

            self.assertEqual(note.build, TEST_CURRENT_BUILD)

    def test_premerge_requires_compatibility_and_breaking_changes_items(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            current_note = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            base_note = self._premerge_base_copy(root, TEST_BASE_BUILD)
            data = json.loads(current_note.read_text(encoding="utf-8"))
            data["items"] = [item for item in data["items"] if item["title"] != "Compatibility"]
            current_note.write_text(json.dumps(data), encoding="utf-8")

            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "exactly one `Compatibility` item"):
                release_notes.validate_premerge_note(current_note, self.history_source, base_note)

            data["items"].append({
                "symbol": "info.circle",
                "title": "Compatibility",
                "detail": "Versions not specified yet.",
            })
            current_note.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "Tightbeam semantic version"):
                release_notes.validate_premerge_note(current_note, self.history_source, base_note)

            compatibility = next(item for item in data["items"] if item["title"] == "Compatibility")
            compatibility["detail"] = "Tightbeam CLI 0.0.0 (test fixture)."
            current_note.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "Chat semantic version"):
                release_notes.validate_premerge_note(current_note, self.history_source, base_note)

            compatibility["detail"] = "Tightbeam CLI 0.0.0 and Chat v0.0.0 (test fixture)."
            data["items"] = [item for item in data["items"] if item["title"] != "Breaking changes"]
            current_note.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(release_notes.ReleaseNoteError, "exactly one `Breaking changes` item"):
                release_notes.validate_premerge_note(current_note, self.history_source, base_note)

    def test_two_sequential_archive_workspaces_refuse_a_reused_note_draft(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            committed_draft = self._numbered_note_copy(root, TEST_CURRENT_BUILD).read_bytes()
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
                    "validate", "--build-number", str(TEST_CURRENT_BUILD), "--source", str(first_source),
                    "--history", str(self.history_source),
                ])
            second_errors = StringIO()
            with redirect_stderr(second_errors):
                second_status = release_notes.main([
                    "validate", "--build-number", str(TEST_CURRENT_BUILD + 1), "--source", str(second_source),
                    "--history", str(self.history_source),
                ])

            self.assertEqual(first_status, 0)
            self.assertEqual(second_status, 1)
            self.assertIn(
                f"current draft is assigned to build {TEST_CURRENT_BUILD}",
                second_errors.getvalue(),
            )
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
            source = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            signed_export = self._signed_export_copy(
                root, [("TightbeamTuner", TEST_CURRENT_BUILD)]
            )
            output = root / "WhatToTest.en-US.txt"

            status = self._render_signed_export(source, signed_export, output)

            self.assertEqual(status, 0)
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                release_notes.note_for_build(
                    source, self.history_source, TEST_CURRENT_BUILD
                ).tester_text(),
            )

    def test_render_rejects_an_exported_ipa_with_a_different_bundle_build(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            signed_export = self._signed_export_copy(
                root, [("TightbeamTuner", TEST_CURRENT_BUILD - 1)]
            )
            output = root / "WhatToTest.en-US.txt"
            errors = StringIO()

            with redirect_stderr(errors):
                status = self._render_signed_export(source, signed_export, output)

            self.assertEqual(status, 1)
            self.assertIn(
                "signed app CFBundleVersion "
                f"{TEST_CURRENT_BUILD - 1} does not match build {TEST_CURRENT_BUILD}",
                errors.getvalue(),
            )
            self.assertFalse(output.exists())

    def test_render_refuses_signed_ipa_with_no_app_bundles_and_lists_names_only(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
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
            source = self._numbered_note_copy(root, TEST_CURRENT_BUILD)
            signed_export = self._signed_export_copy(
                root,
                [
                    ("TightbeamTuner", TEST_CURRENT_BUILD),
                    ("UnexpectedApp", TEST_CURRENT_BUILD),
                ],
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
