import itertools
import unittest

from policy import Engine, compile_policy


class PolicyRegressionTests(unittest.TestCase):
    def test_cache_uses_semantic_content_not_role_order_or_duplicates(self):
        first = compile_policy("canonical-regression", {
            "allow": ["b", "a", "a"], "deny": ["blocked", "blocked"]
        })
        second = compile_policy("canonical-regression", {
            "deny": ["blocked"], "allow": ["a", "b"]
        })
        self.assertIs(first, second)
        self.assertIsNot(first, compile_policy("canonical-regression", {
            "allow": ["a"], "deny": ["blocked"]
        }))
        self.assertIsNot(first, compile_policy("canonical-regression", {
            "allow": ["a", "b"], "deny": ["a"]
        }))
        self.assertIs(compile_policy("empty-regression", {}),
                      compile_policy("empty-regression", {"allow": [], "deny": []}))

    def test_shared_names_are_isolated_in_every_evaluation_order(self):
        specs = [
            {"allow": ["a"], "deny": ["x"]},
            {"allow": ["b"], "deny": ["a"]},
            {"allow": [], "deny": ["b"]},
        ]
        for order in itertools.permutations(range(len(specs))):
            engines = [Engine({"shared-regression": spec}) for spec in specs]
            for index in order + tuple(reversed(order)):
                for role in ["a", "b", "x", "temporary"]:
                    with self.subTest(order=order, index=index, role=role):
                        engine, spec = engines[index], specs[index]
                        expected = role in spec["allow"] and role not in spec["deny"]
                        self.assertEqual(engine.allows("shared-regression", role), expected)
                        self.assertEqual(engine.allows("shared-regression", role, [role]),
                                         role not in spec["deny"])
                        self.assertEqual(engine.allows("shared-regression", role), expected)
                        self.assertFalse(engine.allows("missing-regression", role, [role]))

    def test_grants_do_not_mutate_cached_state_or_caller_input(self):
        spec = {"allow": ["reader", "blocked"], "deny": ["blocked"]}
        engine = Engine({"grant-regression": spec})
        peer = Engine({"grant-regression": spec})
        compiled = compile_policy("grant-regression", spec)
        extra = ["writer", "blocked"]
        self.assertTrue(engine.allows("grant-regression", "writer", extra))
        self.assertFalse(engine.allows("grant-regression", "blocked", extra))
        self.assertFalse(engine.allows("grant-regression", "writer"))
        self.assertFalse(peer.allows("grant-regression", "writer"))
        self.assertEqual(extra, ["writer", "blocked"])
        self.assertEqual(compiled["allow"], {"reader", "blocked"})
        self.assertEqual(compiled["deny"], {"blocked"})
        self.assertIs(compiled, compile_policy("grant-regression", spec))

    def test_caller_mutation_before_and_after_compilation_does_not_change_snapshot(self):
        for compile_first in [False, True]:
            with self.subTest(compile_first=compile_first):
                config = {"snapshot-regression": {"allow": ["yes"], "deny": ["no"]}}
                engine = Engine(config)
                if compile_first:
                    self.assertTrue(engine.allows("snapshot-regression", "yes"))
                config["snapshot-regression"]["allow"].clear()
                config["snapshot-regression"]["deny"].append("yes")
                config["new-regression"] = {"allow": ["yes"]}
                self.assertTrue(engine.allows("snapshot-regression", "yes"))
                self.assertFalse(engine.allows("snapshot-regression", "no", ["no"]))
                self.assertFalse(engine.allows("new-regression", "yes", ["yes"]))
                self.assertFalse(Engine(config).allows("snapshot-regression", "yes"))
                del config["snapshot-regression"]
                self.assertTrue(engine.allows("snapshot-regression", "yes"))

    def test_public_cached_policy_cannot_be_mutated(self):
        spec = {"allow": ["reader"], "deny": ["blocked"]}
        compiled = compile_policy("immutable-regression", spec)
        with self.assertRaises(TypeError):
            compiled["allow"] = frozenset(["writer"])
        with self.assertRaises(AttributeError):
            compiled["deny"].clear()
        spec["allow"].append("writer")
        self.assertEqual(compiled["allow"], {"reader"})
        self.assertIsNot(compiled, compile_policy("immutable-regression", spec))
