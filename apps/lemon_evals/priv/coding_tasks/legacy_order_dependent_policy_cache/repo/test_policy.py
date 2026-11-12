import unittest
from policy import Engine, compile_policy


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.engine = Engine({"edit": {"allow": ["reader"], "deny": ["blocked"]}})

    def test_temporary_grant(self):
        self.assertTrue(self.engine.allows("edit", "writer", ["writer"]))

    def test_default_denies_writer(self):
        self.assertFalse(self.engine.allows("edit", "writer"))

    def test_other_tenant(self):
        other = Engine({"edit": {"allow": ["writer"], "deny": ["reader"]}})
        self.assertTrue(other.allows("edit", "writer"))
        self.assertFalse(other.allows("edit", "reader"))

    def test_deny_wins(self):
        self.assertFalse(self.engine.allows("edit", "blocked", ["blocked"]))

    def test_unknown(self):
        self.assertFalse(self.engine.allows("unknown", "writer", ["writer"]))

    def test_snapshot(self):
        config = {"snapshot": {"allow": ["one"]}}
        engine = Engine(config)
        config["snapshot"]["allow"].append("two")
        self.assertFalse(engine.allows("snapshot", "two"))
        self.assertTrue(engine.allows("snapshot", "one"))
