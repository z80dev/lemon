#!/usr/bin/env python3
"""Release archives must have complete contents and confined symlink graphs."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PYTHON_FILES = (
    "python/bin/python3",
    "python/licenses/CPYTHON-LICENSE.txt",
    "python/licenses/PYTHON-BUILD-STANDALONE-LICENSE.txt",
)


class ReleaseArchiveTests(unittest.TestCase):
    def verify(self, profile_to_change=None, missing=(), link=None, empty=None, executable=True,
               backend_links=()):
        with tempfile.TemporaryDirectory(prefix="lemon-artifact-test-") as temporary:
            directory = Path(temporary)
            manifest = dict(schema=2, version="2026.11.1", channel="stable", commit="abcdef123",
                            built_at="2026-11-10T00:00:00Z", otp="28.5", elixir="1.19.5",
                            artifacts=[], scripts=[])
            for profile in ("lemon_runtime_min", "lemon_runtime_full", "lemon_tui", "lemon_bot"):
                filename = f"lemon-2026.11.1-stable-darwin-arm64-{profile}.tar.gz"
                path = directory / filename
                if profile == "lemon_bot":
                    files = ("bot/bin/lemon-bot", "bot/web/index.html", "bot/web/assets/app.js",
                             "bot/node_modules/@img/sharp-darwin-arm64/package.json",
                             "bot/node_modules/@img/sharp-darwin-arm64/sharp.node",
                             "bot/node_modules/@img/sharp-libvips-darwin-arm64/package.json")
                elif profile == "lemon_tui":
                    files = ("tui/bin/lemon-tui",)
                else:
                    files = ("bin/lemon",) + PYTHON_FILES
                with tarfile.open(path, "w:gz") as archive:
                    for name in files:
                        changed = profile == profile_to_change
                        if changed and name in missing:
                            continue
                        entry = tarfile.TarInfo(name)
                        content = b"fixture\n"
                        entry.mode = 0o755
                        if changed and name == "python/bin/python3" and not executable:
                            entry.mode = 0o644
                        if changed and name == empty:
                            content = b""
                        entry.size = len(content)
                        if changed and name == link:
                            entry.type = tarfile.SYMTYPE
                            entry.linkname = "python3.13"
                            entry.size = 0
                        archive.addfile(entry, io.BytesIO(content))
                    if profile == "lemon_bot":
                        for name, target in backend_links:
                            entry = tarfile.TarInfo(name)
                            entry.type = tarfile.SYMTYPE
                            entry.linkname = target
                            archive.addfile(entry)
                data = path.read_bytes()
                manifest["artifacts"].append(dict(file=filename, profile=profile, platform="darwin-arm64",
                                                   os="darwin", arch="arm64", size=len(data),
                                                   sha256=hashlib.sha256(data).hexdigest()))
            for kind, filename in (("installer", "install.sh"), ("node_join", "join-node.sh")):
                data = b"#!/bin/sh\n"
                (directory / filename).write_bytes(data)
                manifest["scripts"].append(dict(kind=kind, filename=filename, size_bytes=len(data),
                                                sha256=hashlib.sha256(data).hexdigest()))
            (directory / "manifest.json").write_text(json.dumps(manifest))
            return subprocess.run([str(ROOT / "scripts/verify_release_artifacts"), "--platform",
                                   "darwin-arm64", str(directory)], capture_output=True, text=True)

    def test_complete_archives_pass(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_both_runtime_profiles_require_python_and_notices(self):
        for profile in ("lemon_runtime_min", "lemon_runtime_full"):
            for missing in (PYTHON_FILES, *( (name,) for name in PYTHON_FILES )):
                with self.subTest(profile=profile, missing=missing):
                    result = self.verify(profile, missing=missing)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(missing[0], result.stderr)

    def test_python_must_be_regular_and_executable(self):
        for options in ({"link": PYTHON_FILES[0]}, {"executable": False}):
            with self.subTest(options=options):
                result = self.verify("lemon_runtime_full", **options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing regular executable python/bin/python3", result.stderr)

    def test_license_notices_must_be_nonempty_regular_files(self):
        for notice in PYTHON_FILES[1:]:
            for options in ({"empty": notice}, {"link": notice}):
                with self.subTest(options=options):
                    result = self.verify("lemon_runtime_min", **options)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"missing nonempty regular {notice}", result.stderr)

    def test_backend_rejects_escape_after_repeated_symlink_expansion(self):
        links = (
            ("bot/d/a", "../x"),
            ("bot/x/a", "."),
            ("bot/leak", "d/a/a/a/a/../../../../../config.toml"),
        )
        for ordering in (links, tuple(reversed(links))):
            with self.subTest(links=ordering):
                result = self.verify(backend_links=ordering)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unconfined archive symlink", result.stderr)

    def test_backend_rejects_symlink_cycles(self):
        for links in (
            (("bot/self", "self"),),
            (("bot/first", "second"), ("bot/second", "first")),
            (("bot/recursive", "recursive/child"),),
        ):
            with self.subTest(links=links):
                result = self.verify(backend_links=links)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("cyclic archive symlink", result.stderr)

    def test_backend_allows_confined_chains_and_repeated_link_expansion(self):
        result = self.verify(backend_links=(
            ("bot/d/a", "../x"),
            ("bot/x/a", "."),
            ("bot/safe", "d/a/a/a/a/../web/index.html"),
            ("bot/root", "."),
            ("bot/alias", "safe"),
        ))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_backend_rejects_absolute_and_parent_symlink_escapes(self):
        for target in ("/etc/passwd", "../config.toml", "web/../../config.toml"):
            with self.subTest(target=target):
                result = self.verify(backend_links=(("bot/leak", target),))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unconfined archive symlink", result.stderr)

    def test_backend_rejects_entries_that_mutate_the_symlink_graph(self):
        for links, error in (
            ((("bot/alias", "web"), ("bot/alias/child", "assets")),
             "archive entry traverses a symlink"),
            ((("bot/alias", "web"), ("./bot/alias", "bin")),
             "duplicate archive entry"),
        ):
            with self.subTest(links=links):
                result = self.verify(backend_links=links)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stderr)


if __name__ == "__main__":
    unittest.main()
