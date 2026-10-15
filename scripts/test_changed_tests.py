#!/usr/bin/env python3
"""Hermetic selector, changelog and diff-lane regression tests (stdlib only)."""

import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent


def load_script(name):
    loader = importlib.machinery.SourceFileLoader(name, str(SCRIPTS / name))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


selector = load_script("changed_tests")
changelog = load_script("check_changelog")


class SelectorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lemon-selector-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "selector@example.invalid")
        self.git("config", "user.name", "Selector fixture")
        dependencies = {
            "lemon_core": [], "lemon_sim": ["lemon_core"],
            "lemon_sim_ui": ["lemon_sim"], "lemon_honcho": ["lemon_core"],
            "lemon_router": ["lemon_core"], "lemon_control_plane": ["lemon_router"],
            "lemon_channels": ["lemon_core"], "lemon_platform_test": ["lemon_channels"],
            "coding_agent": ["lemon_platform_test"],
        }
        for app, deps in dependencies.items():
            declarations = ",\n".join(f"{{:{dep}, only: :test, in_umbrella: true, runtime: false}}" for dep in deps)
            self.put(f"apps/{app}/mix.exs", f"if @umbrella, do: [{declarations}], else: []\n")
            self.put(f"apps/{app}/lib/sample.ex", "# fixture\n")
        self.put("apps/lemon_core/test/env_test.exs", 'File.read!("docs/config-registry.md")\n')
        self.put("apps/lemon_control_plane/test/tui_test.exs", 'Path.join(root, "clients/tui")\n')
        self.put("apps/lemon_sim/test/sample_test.exs", "# fixture test\n")
        self.put("docs/config-registry.md", "registry\n")
        self.put("docs/unreferenced.md", "guide\n")
        self.put("clients/tui/src/index.ts", "// fixture\n")
        self.put("mix.lock", "%{}\n")
        self.put(".gitignore", "ignored/\n")
        self.put("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\nNo unreleased changes yet.\n")
        for script in ("test", "changed_tests", "check_changelog"):
            destination = self.root / "scripts" / script
            destination.parent.mkdir(exist_ok=True)
            shutil.copy2(SCRIPTS / script, destination)
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.root), *args], check=True, capture_output=True)

    def put(self, path, text="changed\n"):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def selection(self, **kwargs):
        return selector.select(self.root, **kwargs)

    def test_clean_branch_and_ignored_files(self):
        self.put("ignored/file")
        result = self.selection()
        self.assertEqual(result["scope"], "none")
        self.assertEqual(result["changed_files"], [])

    def test_app_reverse_dependencies(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        self.assertEqual(self.selection()["apps"], ["lemon_sim", "lemon_sim_ui"])

    def test_core_includes_transitive_and_test_only_dependencies(self):
        self.put("apps/lemon_core/lib/sample.ex")
        self.assertEqual(len(self.selection()["apps"]), 9)

    def test_satellite_has_no_reverse_dependencies(self):
        self.put("apps/lemon_honcho/lib/sample.ex")
        self.assertEqual(self.selection()["apps"], ["lemon_honcho"])

    def test_conditional_platform_dependency(self):
        self.put("apps/lemon_channels/test/test_helper.exs")
        self.assertEqual(self.selection()["apps"], ["coding_agent", "lemon_channels", "lemon_platform_test"])

    def test_shared_and_unknown_paths_are_full(self):
        for path in ("mix.lock", "unexpected.txt", "scripts/new_tool", "apps/lemon_sim/config/test.exs", "apps/lemon_sim/mix.exs", "apps/lemon_sim/.formatter.exs", ".github/workflows/example.yml"):
            with self.subTest(path=path):
                self.put(path)
                result = self.selection()
                self.assertEqual(result["scope"], "full")
                self.assertTrue(result["lanes"]["clients"])
                self.assertTrue(any(path in reason for reason in result["reasons"]))
                # Each case starts from the same content, not the previous full trigger.
                self.commit()
                self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def test_document_reference_selects_reader_not_reverse_dependencies(self):
        self.put("docs/config-registry.md")
        result = self.selection()
        self.assertEqual(result["apps"], ["lemon_core"])
        self.assertTrue(result["lanes"]["docs"])

    def test_unreferenced_document_has_no_app_tests(self):
        self.put("docs/unreferenced.md")
        self.assertEqual(self.selection()["scope"], "none")

    def test_client_ancestor_reference_and_lane(self):
        self.put("clients/tui/src/index.ts")
        result = self.selection()
        self.assertEqual(result["apps"], ["lemon_control_plane"])
        self.assertTrue(result["lanes"]["clients"])

    def test_bare_directory_is_not_reference_pattern(self):
        self.put("apps/lemon_router/test/not_a_reader.exs", '"docs"\n')
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.put("docs/unreferenced.md")
        self.assertEqual(self.selection()["scope"], "none")

    def test_committed_staged_unstaged_deleted_and_untracked_paths(self):
        self.put("apps/lemon_sim/lib/committed.ex")
        self.commit()
        self.put("apps/lemon_sim/lib/staged.ex")
        self.git("add", "apps/lemon_sim/lib/staged.ex")
        self.put("apps/lemon_sim/lib/sample.ex")
        (self.root / "apps/lemon_honcho/lib/sample.ex").unlink()
        self.put("apps/lemon_router/lib/untracked.ex")
        result = self.selection()
        self.assertEqual(len(result["changed_files"]), 5)
        self.assertIn("lemon_honcho", result["apps"])
        self.assertIn("lemon_control_plane", result["apps"])

    def test_uses_merge_base_not_the_newer_base_tip(self):
        base = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.git("checkout", "-qb", "base-tip")
        self.put("mix.lock", "%{base: true}\n")
        self.commit()
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("checkout", "-qb", "topic", base)
        self.put("apps/lemon_sim/lib/sample.ex")
        self.assertEqual(self.selection()["apps"], ["lemon_sim", "lemon_sim_ui"])

    def test_missing_base_falls_back_to_full(self):
        result = self.selection(base="no-such-ref")
        self.assertEqual(result["scope"], "full")
        self.assertIn("no-such-ref", result["reasons"][0])

    def test_wasm_flags(self):
        self.put("apps/coding_agent/lib/coding_agent/wasm/runtime.ex")
        self.assertTrue(self.selection()["lanes"]["wasm"])
        self.put("native/runtime/src/lib.rs")
        result = self.selection()
        self.assertTrue(result["lanes"]["wasm"])
        self.assertEqual(result["scope"], "full")

    def test_focused_paths_exist_and_handle_spaces(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        self.put("apps/lemon_sim/test/space name_test.exs")
        self.put("apps/lemon_sim/test/deleted_test.exs")
        self.commit()
        (self.root / "apps/lemon_sim/test/deleted_test.exs").unlink()
        result = self.selection(focused=True)
        self.assertEqual(result["focused_test_files"], ["apps/lemon_sim/test/sample_test.exs", "apps/lemon_sim/test/space name_test.exs"])

    def test_github_outputs_append_exact_keys_and_summary(self):
        output = Path(self.temp.name) / "output"
        summary = Path(self.temp.name) / "summary"
        output.write_text("existing=value\n")
        with patch.dict(os.environ, GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary)):
            selector.github(self.selection())
        self.assertEqual(output.read_text(), "existing=value\nscope=none\napps=\ntest_paths=\nclients=false\nwasm=false\ndocs=false\n")
        self.assertIn("**none**", summary.read_text())

    def run_lane(self, *args, fail_command=""):
        commands = Path(self.temp.name) / "commands"
        commands.mkdir(exist_ok=True)
        mix = commands / "mix"
        mix.write_text('#!/usr/bin/env python3\nimport json, os, sys\nwith open(os.environ["COMMAND_LOG"], "a") as log: log.write(json.dumps(sys.argv[1:]) + "\\n")\nsys.exit(7 if sys.argv[1] == os.environ.get("FAIL_COMMAND") else 0)\n')
        mix.chmod(0o755)
        log = Path(self.temp.name) / "commands.jsonl"
        home = Path(self.temp.name) / "home"
        home.mkdir(exist_ok=True)
        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           HOME=str(home), COMMAND_LOG=str(log), FAIL_COMMAND=fail_command)
        environment.pop("LEMON_TEST_ALLOW_LIVE_CREDENTIALS", None)
        result = subprocess.run([str(self.root / "scripts/test"), *args], cwd=self.root,
                                env=environment, capture_output=True, text=True)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls

    def test_changed_runner_scopes_and_preserves_arguments(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        result, calls = self.run_lane("changed", "--seed", "1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [["compile", "--warnings-as-errors"], ["test", "--exclude", "integration", "apps/lemon_sim/test", "apps/lemon_sim_ui/test", "--seed", "1"]])

    def test_focused_runner_does_not_run_app_paths(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        result, calls = self.run_lane("changed", "--focused")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-1], ["test", "--exclude", "integration", "apps/lemon_sim/test/sample_test.exs"])
        self.assertIn("NOT a substitute", result.stdout)

    def test_empty_runner_skips_exunit(self):
        result, calls = self.run_lane("changed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        self.assertIn("skipping ExUnit", result.stdout)

    def test_premerge_order_and_failure_stops_before_tests(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        result, calls = self.run_lane("premerge", fail_command="credo")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual([call[0] for call in calls], ["format", "credo"])
        self.assertIn("premerge credo failed", result.stderr)

    def test_premerge_compile_failure_stops_before_exunit(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        result, calls = self.run_lane("premerge", fail_command="compile")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual([call[0] for call in calls], ["format", "credo", "compile"])
        self.assertIn("premerge changed failed", result.stderr)

    def test_premerge_end_to_end_command_order(self):
        self.put("apps/lemon_sim/lib/sample.ex")
        result, calls = self.run_lane("premerge")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call[0] for call in calls], ["format", "credo", "compile", "test"])
        self.assertIn("Not covered: full suite", result.stdout)


class ChangelogTest(unittest.TestCase):
    def errors(self, text):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CHANGELOG.md"
            path.write_text(text, encoding="utf-8")
            return [error for _, error in changelog.validate(path)]

    def test_valid_empty_and_categorized_unreleased(self):
        self.assertEqual(self.errors("## [Unreleased]\n\nNo unreleased changes yet.\n"), [])
        self.assertEqual(self.errors("## [Unreleased]\n### Fixed\n- Fix\n## [0.2.0] - 2026-10-13\n### Historical heading\n- Old\n"), [])

    def test_rejects_missing_late_bare_and_duplicate_unreleased(self):
        for text in ("## [0.2.0]\n", "## [0.2.0]\n## [Unreleased]\n", "## Unreleased\n", "## [Unreleased]\n## [Unreleased]\n"):
            with self.subTest(text=text):
                self.assertTrue(self.errors(text))

    def test_rejects_uncategorized_bullets_unknown_and_duplicate_categories(self):
        for body in ("- Entry", "### Notes\n- Entry", "### Fixed\n- One\n### Fixed\n- Two"):
            with self.subTest(body=body):
                self.assertTrue(self.errors("## [Unreleased]\n" + body))

    def test_dates_are_valid_and_consistent(self):
        for body in ("## [0.2.0] - 2026-99-99", "## [0.2.0] - 2026-10-13\n## [0.1.0]", "## [0.2.0] typo"):
            with self.subTest(body=body):
                self.assertTrue(self.errors("## [Unreleased]\n" + body))

    def test_code_fences_do_not_create_sections_or_bullets(self):
        self.assertEqual(self.errors("## [Unreleased]\n```md\n## [fake]\n### Not a category\n- Example\n```\n### Added\n- Real\n"), [])


if __name__ == "__main__":
    unittest.main()
