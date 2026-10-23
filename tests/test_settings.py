import json
import io
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.settings import discover_gateway, load_config, save_config


class SettingsTests(unittest.TestCase):
    def test_save_and_reload_connection_without_shell_expansion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested/config.json"
            with patch.dict(os.environ, {"TIGHTBEAM_TUNER_CONFIG": str(path)}):
                result = save_config({
                    "chatBase": "https://chat.example.test/",
                    "gatewayOrigin": "https://gateway.example.test:8443",
                    "cliCommand": "ssh host /opt/tightbeam/bin/tightbeam",
                    "rosterUser": "Example User",
                })
                saved = load_config()
            self.assertTrue(result["configured"])
            self.assertEqual(saved["rosterCommand"][-1], "Example User")
            self.assertEqual(saved["rosterCommand"][:3],
                             ["ssh", "host", "/opt/tightbeam/bin/tightbeam"])
            self.assertEqual(json.loads(path.read_text()), saved)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_rejects_credentialed_chat_url(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            with patch.dict(os.environ, {"TIGHTBEAM_TUNER_CONFIG": str(path)}):
                with self.assertRaises(ValueError):
                    save_config({
                        "chatBase": "https://user:secret@chat.example.test",
                        "gatewayOrigin": "https://gateway.example.test",
                        "cliCommand": "tightbeam",
                        "rosterUser": "example",
                    })
            self.assertFalse(path.exists())

    def test_discovers_gateway_from_chat_service(self):
        response = io.BytesIO(b'{"gateway":"https://gateway.example.test","sessionKey":"agent:main","principalKey":"example"}')
        with patch("scripts.settings.urlopen", return_value=response) as fetch:
            result = discover_gateway({"chatBase": "https://chat.example.test"})
        self.assertEqual(result, {
            "gatewayOrigin": "https://gateway.example.test",
            "rosterUser": "example",
        })
        self.assertEqual(fetch.call_args.args[0].full_url,
                         "https://chat.example.test/chat-config.json")

    def test_save_discovers_missing_gateway_and_user(self):
        response = io.BytesIO(b'{"gateway":"https://gateway.example.test","principalKey":"example"}')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            with patch.dict(os.environ, {"TIGHTBEAM_TUNER_CONFIG": str(path)}), \
                 patch("scripts.settings.urlopen", return_value=response):
                result = save_config({
                    "chatBase": "https://chat.example.test",
                    "gatewayOrigin": "",
                    "cliCommand": "tightbeam",
                    "rosterUser": "",
                })
            self.assertEqual(result["gatewayOrigin"], "https://gateway.example.test")
            self.assertEqual(result["rosterUser"], "example")


if __name__ == "__main__":
    unittest.main()
