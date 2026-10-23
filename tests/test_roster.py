import unittest
from urllib.parse import parse_qs, urlsplit

from scripts.roster import normalize, origin


class RosterTests(unittest.TestCase):
    def test_active_agents_and_opaque_session_urls(self):
        config = {
            "chatBase": "https://chat.example.test",
            "gatewayOrigin": "https://gateway.example.test:8443",
        }
        roster = {"sessions": [
            {"sessionKey": "agent:root", "displayName": "Main", "state": "active",
             "archetype": "default"},
            {"sessionKey": "agent:root s_12 34", "displayName": "Child", "state": "active",
             "archetype": "worker", "currentParent": "agent:root"},
            {"sessionKey": "retired", "displayName": "Old", "state": "retired"},
        ]}
        agents = normalize(config, roster)["agents"]
        self.assertEqual([agent["name"] for agent in agents], ["Main", "Child"])
        self.assertEqual(agents[1]["parent"], "agent:root")
        self.assertEqual(agents[1]["archetype"], "worker")
        parsed = urlsplit(agents[1]["url"])
        self.assertEqual(parse_qs(parsed.query), {
            "gateway": ["https://gateway.example.test:8443"],
            "session": ["agent:root s_12 34"],
        })

    def test_rejects_credentialed_origin(self):
        with self.assertRaises(ValueError):
            origin("https://user:password@chat.example.test", "chatBase")


if __name__ == "__main__":
    unittest.main()
