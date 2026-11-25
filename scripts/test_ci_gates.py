#!/usr/bin/env python3
"""Hermetic checks that the dependency (OSV) and Dialyzer gates cover shipped code."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
OSV_WORKFLOW = ROOT / ".github/workflows/osv-scanner.yml"
DIALYZER_GATE = ROOT / "scripts/dialyzer_gate.sh"

# Package-manager lockfiles OSV-Scanner parses. The coding-task fixtures are
# evaluation inputs, not shipped code.
LOCKFILE_NAMES = {
    "mix.lock", "package-lock.json", "bun.lock", "Cargo.lock", "Package.resolved",
    "yarn.lock", "pnpm-lock.yaml", "uv.lock", "poetry.lock", "Gemfile.lock", "go.sum",
}
NOT_SHIPPED = ("apps/lemon_evals/priv/coding_tasks/",)
PUBLISHED = ("lemon_core", "lemon_ai", "lemon_agent")


def shipped_lockfiles():
    files = subprocess.run(["git", "ls-files"], cwd=ROOT, check=True, capture_output=True,
                           text=True).stdout.splitlines()
    return sorted(path for path in files
                  if Path(path).name in LOCKFILE_NAMES and not path.startswith(NOT_SHIPPED))


def workflow_paths(trigger):
    """The `paths` filter list of one `on:` trigger, read line by line."""
    lines = OSV_WORKFLOW.read_text().splitlines()
    start = lines.index(f"  {trigger}:")
    paths, inside = [], False
    for line in lines[start + 1:]:
        if line and not line.startswith("    "):
            break
        if line == "    paths:":
            inside = True
        elif inside and line.startswith("      - "):
            paths.append(line.removeprefix("      - ").strip('"'))
        elif inside:
            break
    return paths


def github_glob(pattern):
    """GitHub path-filter glob: `*` stays within a directory, `**` crosses them."""
    parts = re.split(r"(\*\*|\*)", pattern)
    regex = "".join(".*" if part == "**" else "[^/]*" if part == "*" else re.escape(part)
                    for part in parts)
    return re.compile(f"^{regex}$")


def gated_apps():
    source = DIALYZER_GATE.read_text()
    block = re.search(r"^GATED_APPS=\(\n(.*?)^\)", source, re.S | re.M).group(1)
    return [line.split("#")[0].strip() for line in block.splitlines() if line.split("#")[0].strip()]


class OsvGateTest(unittest.TestCase):
    def test_every_shipped_lockfile_is_scanned_and_nothing_stale(self):
        scanned = re.findall(r"^\s+--lockfile=(\S+)$", OSV_WORKFLOW.read_text(), re.M)
        self.assertEqual(sorted(scanned), shipped_lockfiles())

    def test_path_filters_fire_for_every_lockfile_and_the_allowlist(self):
        for trigger in ("pull_request", "push"):
            filters = [github_glob(pattern) for pattern in workflow_paths(trigger)]
            for path in shipped_lockfiles() + ["osv-scanner.toml"]:
                with self.subTest(trigger=trigger, path=path):
                    self.assertTrue(any(f.match(path) for f in filters), path)

    def test_findings_fail_the_job_and_the_allowlist_is_loaded(self):
        workflow = OSV_WORKFLOW.read_text()
        self.assertRegex(workflow, r"(?m)^\s+fail-on-vuln: true$")
        self.assertRegex(workflow, r"(?m)^\s+--config=osv-scanner.toml$")
        self.assertTrue((ROOT / "osv-scanner.toml").is_file())


class DialyzerGateTest(unittest.TestCase):
    def gate(self, report):
        with tempfile.NamedTemporaryFile("w", suffix=".out", delete=False) as handle:
            handle.write(report)
        self.addCleanup(Path(handle.name).unlink)
        return subprocess.run(["bash", str(DIALYZER_GATE), handle.name], cwd=ROOT,
                              capture_output=True, text=True)

    def test_published_packages_are_gated(self):
        for app in PUBLISHED:
            self.assertIn(app, gated_apps())

    def test_a_finding_in_each_published_package_fails_the_gate(self):
        for app in PUBLISHED:
            source = next((ROOT / "apps" / app).glob("lib/**/*.ex")).relative_to(ROOT / "apps" / app)
            report = ("Total errors: 1, Skipped: 0, Unnecessary Skips: 0\n"
                      f"{source}:1:1: The call 'Elixir.Fixture':f(1) breaks the contract (binary()) -> 'ok'\n")
            with self.subTest(app=app):
                result = self.gate(report)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(f"{app}: {source}:1:1", result.stderr)

    def test_a_clean_report_passes_and_an_unusable_one_is_refused(self):
        clean = self.gate("Total errors: 0, Skipped: 0, Unnecessary Skips: 0\ndone\n")
        self.assertEqual(clean.returncode, 0, clean.stdout + clean.stderr)
        self.assertEqual(self.gate("Starting Dialyzer\n").returncode, 2)
        self.assertEqual(self.gate("Total errors: 3, Skipped: 0, Unnecessary Skips: 1\n").returncode, 2)


if __name__ == "__main__":
    unittest.main()
