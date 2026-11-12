#!/usr/bin/env python3
"""Exercise release cuts in scratch clones, without committing or tagging."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RELEASE_FILES = (
    "CHANGELOG.md",
    "mix.exs",
    "clients/tui/package.json",
    "clients/lemon-browser-node/package.json",
    "clients/lemon-browser-node/package-lock.json",
)
NOTES = "### Fixed\n\n- Release transaction regression fixture."
CHANGELOG = f"# Changelog\n\n## [Unreleased]\n\n{NOTES}\n\n---\n\n## [2020.01.0]\n\n### Added\n\n- Older release.\n"


class ProductReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="lemon-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.scratch = Path(self.temporary.name)
        self.repo = self.scratch / "repo"
        subprocess.run(["git", "clone", "--quiet", "--shared", str(ROOT), str(self.repo)],
                       check=True, capture_output=True, text=True)
        # Test the working scripts even before the contributor commits them.
        for name in ("prepare_product_release", "bump_version.sh", "prepare_release_notes"):
            shutil.copy2(ROOT / "scripts" / name, self.repo / "scripts" / name)
        (self.repo / "CHANGELOG.md").write_text(CHANGELOG)
        self.set_current_version("2099.02.4")
        (self.repo / "mix.exs.bak").write_text("Keep the user's existing backup.\n")
        # Freeze only the date query used by --auto; sed and every other tool
        # remain the host's real implementations (BSD sed on the macOS lane).
        tools = self.scratch / "tools"
        tools.mkdir()
        date = tools / "date"
        date.write_text('#!/bin/sh\n[ "$*" = "-u +%Y.%m" ] || exit 99\nprintf "2099.02\\n"\n')
        date.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")

    def set_current_version(self, version):
        path = self.repo / "mix.exs"
        path.write_text(re.sub(r'(?m)^(\s*version: ")[0-9.]+("[,]$)',
                               rf'\g<1>{version}\2', path.read_text(), count=1))

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo)

    def state(self):
        return (
            {name: ((self.repo / name).read_bytes(), (self.repo / name).stat().st_mode)
             for name in RELEASE_FILES},
            self.git("diff", "--binary"),
            self.git("diff", "--cached", "--binary"),
            self.git("ls-files", "--others", "--exclude-standard"),
            (self.repo / "mix.exs.bak").read_bytes(),
        )

    def prepare(self):
        return subprocess.run(["scripts/prepare_product_release", "--auto"], cwd=self.repo,
                              env=self.env, capture_output=True, text=True)

    def assert_prepared(self, version):
        before = {name: (self.repo / name).read_text() for name in RELEASE_FILES}
        head = self.git("rev-parse", "HEAD")
        tags = self.git("tag", "--list")
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = dict(before)
        expected["mix.exs"] = re.sub(r'(?m)^(\s*version: ")[0-9.]+("[,]$)',
                                     rf'\g<1>{version}\2', before["mix.exs"], count=1)
        for name in RELEASE_FILES[2:]:
            value = json.loads(before[name])
            value["version"] = version
            if name.endswith("package-lock.json"):
                value["packages"][""]["version"] = version
            expected[name] = json.dumps(value, indent=2) + "\n"
        expected["CHANGELOG.md"] = CHANGELOG.replace(
            f"## [Unreleased]\n\n{NOTES}",
            f"## [Unreleased]\n\nNo unreleased changes yet.\n\n---\n\n## [{version}]\n\n{NOTES}",
        )
        for name, text in expected.items():
            with self.subTest(file=name):
                self.assertEqual((self.repo / name).read_text(), text)
        notes = subprocess.run(["scripts/prepare_release_notes", version], cwd=self.repo,
                               capture_output=True, text=True, check=True)
        self.assertEqual(notes.stdout.strip(), NOTES + "\n\n---")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("tag", "--list"), tags)
        self.assertEqual((self.repo / "mix.exs.bak").read_text(),
                         "Keep the user's existing backup.\n")

    def test_auto_increments_month_patch_and_matches_expected_portable_diff(self):
        self.assert_prepared("2099.02.5")

    def test_auto_resets_patch_in_new_month(self):
        self.set_current_version("2020.01.9")
        self.assert_prepared("2099.02.0")

    def test_midway_json_failure_preserves_dirty_files_and_index(self):
        tui = self.repo / "clients/tui/package.json"
        value = json.loads(tui.read_text())
        value["releaseTest"] = "preserve staged local edits"
        tui.write_text(json.dumps(value, indent=2) + "\n")
        self.git("add", "clients/tui/package.json")
        (self.repo / "clients/lemon-browser-node/package.json").write_text("invalid json\n")
        before = self.state()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("JSONDecodeError", result.stderr)
        self.assertIn("clients/tui/package.json:", result.stdout)
        self.assertEqual(self.state(), before)

    def test_final_notes_failure_restores_all_versions_and_changelog(self):
        (self.repo / "scripts/prepare_release_notes").write_text("#!/bin/sh\nexit 42\n")
        before = self.state()
        result = self.prepare()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("root version -> 2099.02.5", result.stdout)
        self.assertEqual(self.state(), before)

    def test_invalid_unreleased_notes_do_not_change_files(self):
        (self.repo / "CHANGELOG.md").write_text("# Changelog\n\n## [Unreleased]\n\nNo unreleased changes yet.\n")
        before = self.state()
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no unreleased changes", result.stderr)
        self.assertEqual(self.state(), before)


if __name__ == "__main__":
    unittest.main(verbosity=2)
