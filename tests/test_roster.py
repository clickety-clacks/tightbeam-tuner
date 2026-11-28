import json
import unittest
from contextlib import redirect_stdout
from io import StringIO
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

from scripts import roster
from scripts.roster import normalize, origin


class RosterTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "chatBase": "https://chat.example.test",
            "gatewayOrigin": "https://gateway.example.test:8443",
        }

    def test_active_agents_and_opaque_session_urls(self):
        roster = {"sessions": [
            {"sessionKey": "agent:root", "displayName": "Main", "state": "active",
             "archetype": "default"},
            {"sessionKey": "agent:root s_12 34", "displayName": "Child", "state": "active",
             "archetype": "worker", "currentParent": "agent:root"},
            {"sessionKey": "retired", "displayName": "Old", "state": "retired"},
        ]}
        result = normalize(self.config, roster)
        agents = result["agents"]
        self.assertEqual([agent["name"] for agent in agents], ["Main", "Child"])
        self.assertEqual(result["incompleteCount"], 0)
        self.assertEqual(agents[1]["parent"], "agent:root")
        self.assertEqual(agents[1]["archetype"], "worker")
        parsed = urlsplit(agents[1]["url"])
        self.assertEqual(parse_qs(parsed.query), {
            "gateway": ["https://gateway.example.test:8443"],
            "session": ["agent:root s_12 34"],
        })

    def test_additive_envelope_and_row_fields_are_accepted(self):
        result = normalize(self.config, {
            "version": 2,
            "newEnvelopeField": {"ignored": True},
            "sessions": [{
                "sessionKey": "agent:root s_12 34",
                "displayName": "Child",
                "state": "active",
                "currentParent": "agent:root",
                "newRowField": [1, 2, 3],
            }],
        })
        self.assertEqual(result["incompleteCount"], 0)
        self.assertEqual(result["agents"][0]["key"], "agent:root s_12 34")

    def test_malformed_rows_keep_usable_agents_and_report_incomplete_count(self):
        result = normalize(self.config, {"sessions": [
            {"sessionKey": "agent:root", "displayName": "Main", "state": "active"},
            {"state": "retired"},  # Intentionally inactive rows are not malformed.
            None,  # Non-object rows cannot be inspected.
            {"state": "active", "sessionKey": "", "displayName": "Unnamed"},
            {"state": 7, "sessionKey": "unknown", "displayName": "Unknown"},
            {
                "sessionKey": "agent:child opaque key",
                "displayName": "Child",
                "state": "active",
                "currentParent": {"bad": "parent"},
                "topologyParent": "agent:root",
                "archetype": ["bad", "type"],
            },
        ]})

        self.assertEqual([agent["name"] for agent in result["agents"]], ["Main", "Child"])
        child = result["agents"][1]
        self.assertEqual(child["key"], "agent:child opaque key")
        self.assertEqual(child["parent"], "agent:root")
        self.assertEqual(child["archetype"], "unknown")
        self.assertEqual(result["incompleteCount"], 4)

    def test_malformed_envelopes_use_the_documented_error(self):
        for roster in (None, [], {}, {"sessions": None}, {"sessions": {}}):
            with self.subTest(roster=roster):
                with self.assertRaises(ValueError):
                    normalize(self.config, roster)

    def test_malformed_envelope_uses_error_path_and_one_batched_cli_call(self):
        config = dict(self.config, rosterCommand=[
            "tightbeam", "list", "--as-user", "mike",
        ])
        completed = roster.subprocess.CompletedProcess(
            args=config["rosterCommand"], returncode=0, stdout="[]", stderr=""
        )
        output = StringIO()
        with patch("scripts.roster.load_config", return_value=config), \
                patch("scripts.roster.subprocess.run", return_value=completed) as run, \
                patch("scripts.roster.sys.argv", ["roster.py", "request-7"]), \
                redirect_stdout(output):
            exit_code = roster.main()

        self.assertEqual(exit_code, 1)
        self.assertEqual(json.loads(output.getvalue()), {
            "error": "ValueError: The roster must be an object",
            "requestId": "request-7",
        })
        run.assert_called_once_with(
            config["rosterCommand"], capture_output=True, text=True,
            timeout=20, check=True,
        )

    def test_rejects_credentialed_origin(self):
        with self.assertRaises(ValueError):
            origin("https://user:password@chat.example.test", "chatBase")


if __name__ == "__main__":
    unittest.main()
