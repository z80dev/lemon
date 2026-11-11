#!/usr/bin/env python3
"""Hermetic behavioral unit and integration tests for scripts/verify_apple_release.

Run directly via: python3 scripts/test_verify_apple_release.py
"""

import copy
import hashlib
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

SCRIPT_PATH = Path(__file__).resolve().parent / "verify_apple_release"

# Dynamically load the extensionless Python script as a module
loader = importlib.machinery.SourceFileLoader("verify_apple_release", str(SCRIPT_PATH))
spec = importlib.util.spec_from_loader("verify_apple_release", loader)
verifier_mod = importlib.util.module_from_spec(spec)
loader.exec_module(verifier_mod)
verify_apple_release = verifier_mod.verify_apple_release


class VerifyAppleReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory(prefix="lemon-test-verify-apple-")
        self.root = Path(self.tmp_dir.name)
        self.version = "2026.11.1"
        self.channel = "preview"

    def tearDown(self):
        self.tmp_dir.cleanup()

    def create_fixture(
        self,
        version=None,
        channel=None,
        dmg_content=b"NOTARIZED_DMG_CONTENT_FOR_TESTING_12345",
        extra_files=None,
        corrupt_manifest_sha=False,
        receipt_override=None,
    ):
        v = version or self.version
        c = channel or self.channel

        # 1. Create manifest.json
        manifest_data = {
            "schema": 2,
            "version": v,
            "channel": c,
            "commit": "0123456789abcdef0123456789abcdef01234567",
            "built_at": "2026-11-10T12:00:00Z",
            "otp": "28.5",
            "elixir": "1.19.5",
            "artifacts": [],
        }
        manifest_file = self.root / "manifest.json"
        manifest_bytes = json.dumps(manifest_data, indent=2).encode("utf-8")
        manifest_file.write_bytes(manifest_bytes)
        manifest_sha = hashlib.sha256(manifest_bytes).hexdigest()

        # 2. Create the notarized DMG
        dmg_filename = f"lemon-bot-{v}-{c}-darwin-arm64-notarized.dmg"
        dmg_file = self.root / dmg_filename
        dmg_file.write_bytes(dmg_content)
        dmg_sha = hashlib.sha256(dmg_content).hexdigest()
        dmg_size = len(dmg_content)

        # 3. Create the Apple receipt
        receipt_filename = f"lemon-bot-{v}-{c}-macos.json"
        receipt_data = {
            "schemaVersion": 1,
            "product": "lemon_bot",
            "version": v,
            "channel": c,
            "appleMarketingVersion": "2026.11.1",
            "appleBuildNumber": "2611.1.1",
            "distribution": "developer-id-notarized",
            "uploadAccepted": False,
            "runtimeManifestSha256": (
                "0" * 64 if corrupt_manifest_sha else manifest_sha
            ),
            "artifacts": [
                {
                    "filename": dmg_filename,
                    "format": "dmg",
                    "platform": "darwin-arm64",
                    "sha256": dmg_sha,
                    "sizeBytes": dmg_size,
                }
            ],
        }

        if receipt_override:
            receipt_data.update(receipt_override)

        receipt_file = self.root / receipt_filename
        receipt_file.write_text(json.dumps(receipt_data, indent=2) + "\n", encoding="utf-8")

        # 4. Optional extra files
        if extra_files:
            for rel_path, content in extra_files.items():
                target = self.root / rel_path
                target.parent.mkdir(parents=True, exist_ok=True)
                if isinstance(content, str):
                    target.write_text(content, encoding="utf-8")
                else:
                    target.write_bytes(content)

        return {
            "manifest_file": manifest_file,
            "manifest_sha": manifest_sha,
            "dmg_file": dmg_file,
            "dmg_filename": dmg_filename,
            "dmg_sha": dmg_sha,
            "dmg_size": dmg_size,
            "receipt_file": receipt_file,
            "receipt_filename": receipt_filename,
            "receipt_data": receipt_data,
        }

    def run_cli(self, args):
        cmd = [sys.executable, str(SCRIPT_PATH)] + args
        return subprocess.run(cmd, capture_output=True, text=True)

    # ── Happy Path Tests ─────────────────────────────────────────────────────────

    def test_valid_preview_release_succeeds(self):
        self.create_fixture(version="2026.11.1", channel="preview")
        errors = verify_apple_release(self.root, "2026.11.1", "preview")
        self.assertEqual(errors, [])

        proc = self.run_cli([str(self.root), "--version", "2026.11.1", "--channel", "preview"])
        self.assertEqual(proc.returncode, 0)
        self.assertIn("ok lemon-bot-2026.11.1-preview-macos.json verified against manifest.json", proc.stdout)
        self.assertIn("ok verified Apple release artifacts", proc.stdout)

    def test_valid_stable_release_succeeds(self):
        self.create_fixture(version="2026.11.1", channel="stable")
        errors = verify_apple_release(self.root, "2026.11.1", "stable")
        self.assertEqual(errors, [])

        proc = self.run_cli([str(self.root), "--version", "2026.11.1", "--channel", "stable"])
        self.assertEqual(proc.returncode, 0)

    def test_stable_alias_dmg_matching_orig_sha_succeeds(self):
        fixture = self.create_fixture(version="2026.11.1", channel="stable")
        alias_path = self.root / "Lemon-Bot-darwin-arm64.dmg"
        shutil.copyfile(fixture["dmg_file"], alias_path)

        errors = verify_apple_release(self.root, "2026.11.1", "stable")
        self.assertEqual(errors, [])

        proc = self.run_cli([str(self.root), "--version", "2026.11.1", "--channel", "stable"])
        self.assertEqual(proc.returncode, 0)

    def test_receipt_using_size_key_instead_of_sizebytes_succeeds(self):
        fixture = self.create_fixture()
        receipt = fixture["receipt_data"]
        artifact = receipt["artifacts"][0]
        size_val = artifact.pop("sizeBytes")
        artifact["size"] = size_val
        fixture["receipt_file"].write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertEqual(errors, [])

    def test_multiple_valid_artifacts_in_receipt_succeeds(self):
        extra_content = b"EXTRA_PACKAGING_ARTIFACT_OR_ZIP"
        extra_filename = f"lemon-bot-{self.version}-{self.channel}-darwin-arm64-notarized.zip"
        extra_file = self.root / extra_filename
        extra_file.write_bytes(extra_content)

        fixture = self.create_fixture()
        receipt = fixture["receipt_data"]
        receipt["artifacts"].append(
            {
                "filename": extra_filename,
                "format": "zip",
                "platform": "darwin-arm64",
                "sha256": hashlib.sha256(extra_content).hexdigest(),
                "sizeBytes": len(extra_content),
            }
        )
        fixture["receipt_file"].write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertEqual(errors, [])

    # ── Local-Preview Rejection Tests ───────────────────────────────────────────

    def test_local_preview_file_is_strictly_rejected(self):
        self.create_fixture()
        preview_dmg = self.root / f"lemon-bot-{self.version}-{self.channel}-darwin-arm64-local-preview.dmg"
        preview_dmg.write_bytes(b"PREVIEW_DMG")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("rejected local-preview artifact found" in err for err in errors))

        proc = self.run_cli([str(self.root), "--version", self.version, "--channel", self.channel])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("rejected local-preview artifact found", proc.stderr)

    def test_local_preview_directory_is_rejected(self):
        self.create_fixture()
        preview_dir = self.root / "apple-local-preview"
        preview_dir.mkdir()
        (preview_dir / "foo.txt").write_text("bar")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("rejected local-preview artifact found" in err for err in errors))

    def test_nested_local_preview_file_is_rejected(self):
        self.create_fixture()
        sub = self.root / "nested"
        sub.mkdir()
        (sub / "lemon-bot-local-preview.zip").write_text("data")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("rejected local-preview artifact found" in err for err in errors))

    # ── Receipt Discovery & Uniqueness Tests ────────────────────────────────────

    def test_missing_receipt_fails(self):
        fixture = self.create_fixture()
        fixture["receipt_file"].unlink()

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("missing required Apple publish receipt" in err for err in errors))

    def test_multiple_receipts_fail(self):
        self.create_fixture()
        second_receipt = self.root / f"lemon-bot-{self.version}-stable-macos.json"
        second_receipt.write_text("{}", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("expected exactly one Apple receipt" in err for err in errors))

    def test_extra_preview_receipt_fails(self):
        self.create_fixture()
        preview_receipt = self.root / f"lemon-bot-{self.version}-{self.channel}-macos-preview.json"
        preview_receipt.write_text("{}", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("unexpected additional receipt(s) found" in err for err in errors))

    def test_extra_bot_receipt_fails(self):
        self.create_fixture()
        extra_receipt = self.root / "lemon-bot-other.json"
        extra_receipt.write_text("{}", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("unexpected additional receipt(s) found" in err for err in errors))

    def test_malformed_json_receipt_fails(self):
        fixture = self.create_fixture()
        fixture["receipt_file"].write_text("{ unclosed json ...", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("invalid JSON" in err for err in errors))

    def test_non_dict_json_receipt_fails(self):
        fixture = self.create_fixture()
        fixture["receipt_file"].write_text("[\"item1\", \"item2\"]", encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("receipt root must be a JSON object" in err for err in errors))

    def test_null_json_receipt_fails(self):
        fixture = self.create_fixture()
        fixture["receipt_file"].write_text("null", encoding="utf-8")
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("receipt root must be a JSON object" in err for err in errors))

    # ── Receipt Metadata Assertions ─────────────────────────────────────────────

    def test_invalid_schema_version_fails(self):
        for bad_schema in [2, "1", None, True]:
            self.create_fixture(receipt_override={"schemaVersion": bad_schema})
            errors = verify_apple_release(self.root, self.version, self.channel)
            self.assertTrue(any("schemaVersion must be 1" in err for err in errors))

    def test_invalid_product_fails(self):
        self.create_fixture(receipt_override={"product": "lemon"})
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("product must be 'lemon_bot'" in err for err in errors))

    def test_invalid_distribution_fails(self):
        for bad_dist in ["local-preview", "app-store", "adhoc", None]:
            self.create_fixture(receipt_override={"distribution": bad_dist})
            errors = verify_apple_release(self.root, self.version, self.channel)
            self.assertTrue(any("distribution must be 'developer-id-notarized'" in err for err in errors))

    def test_version_mismatch_fails(self):
        self.create_fixture(receipt_override={"version": "2026.10.1"})
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("version mismatch" in err for err in errors))

    def test_channel_mismatch_fails(self):
        self.create_fixture(receipt_override={"channel": "stable"})
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("channel mismatch" in err for err in errors))

    # ── Manifest & runtimeManifestSha256 Pin Tests ──────────────────────────────

    def test_missing_manifest_fails(self):
        fixture = self.create_fixture()
        fixture["manifest_file"].unlink()

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("manifest.json missing" in err for err in errors))

    def test_manifest_sha_mismatch_fails(self):
        self.create_fixture(corrupt_manifest_sha=True)
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("runtimeManifestSha256 mismatch" in err for err in errors))

    def test_manifest_tampered_after_receipt_fails(self):
        fixture = self.create_fixture()
        # Tamper with manifest bytes
        fixture["manifest_file"].write_bytes(b'{"schema": 2, "tampered": true}')

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("runtimeManifestSha256 mismatch" in err for err in errors))

    def test_missing_runtime_manifest_sha_fails(self):
        for bad_val in [None, "", "not-a-hex", "1234"]:
            self.create_fixture(receipt_override={"runtimeManifestSha256": bad_val})
            errors = verify_apple_release(self.root, self.version, self.channel)
            self.assertTrue(any("runtimeManifestSha256 must be a 64-character hex string" in err for err in errors))

    def test_manifest_version_mismatch_fails(self):
        fixture = self.create_fixture()
        # Change version in manifest.json and update receipt runtimeManifestSha256 to match
        manifest_data = json.loads(fixture["manifest_file"].read_text())
        manifest_data["version"] = "2026.10.1"
        new_manifest_bytes = json.dumps(manifest_data).encode("utf-8")
        fixture["manifest_file"].write_bytes(new_manifest_bytes)
        new_sha = hashlib.sha256(new_manifest_bytes).hexdigest()

        receipt_data = fixture["receipt_data"]
        receipt_data["runtimeManifestSha256"] = new_sha
        fixture["receipt_file"].write_text(json.dumps(receipt_data))

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("manifest.json version mismatch" in err for err in errors))

    # ── Artifact Validation Tests ───────────────────────────────────────────────

    def test_missing_artifacts_list_in_receipt_fails(self):
        for bad_artifacts in [[], None, "invalid"]:
            self.create_fixture(receipt_override={"artifacts": bad_artifacts})
            errors = verify_apple_release(self.root, self.version, self.channel)
            self.assertTrue(
                any("artifacts must be a non-empty list" in err or "missing expected DMG artifact" in err for err in errors)
            )

    def test_missing_dmg_artifact_in_receipt_fails(self):
        self.create_fixture(
            receipt_override={
                "artifacts": [
                    {
                        "filename": "other.zip",
                        "format": "zip",
                        "platform": "darwin-arm64",
                        "sha256": "0" * 64,
                        "sizeBytes": 10,
                    }
                ]
            }
        )
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("missing expected DMG artifact" in err for err in errors))

    def test_dmg_filename_mismatch_in_receipt_fails(self):
        self.create_fixture(
            receipt_override={
                "artifacts": [
                    {
                        "filename": "wrong-name.dmg",
                        "format": "dmg",
                        "platform": "darwin-arm64",
                        "sha256": "0" * 64,
                        "sizeBytes": 10,
                    }
                ]
            }
        )
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("DMG filename must equal" in err for err in errors))

    def test_artifact_missing_from_disk_fails(self):
        fixture = self.create_fixture()
        fixture["dmg_file"].unlink()

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("artifact file missing from" in err for err in errors))

    def test_artifact_size_mismatch_fails(self):
        fixture = self.create_fixture()
        # Truncate or append to DMG file
        fixture["dmg_file"].write_bytes(b"SHORT")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("size mismatch" in err for err in errors))

    def test_artifact_sha256_mismatch_fails(self):
        fixture = self.create_fixture()
        # Same length, different content
        tampered = b"X" * fixture["dmg_size"]
        fixture["dmg_file"].write_bytes(tampered)

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("sha256 mismatch" in err for err in errors))

    def test_artifact_path_traversal_fails(self):
        self.create_fixture(
            receipt_override={
                "artifacts": [
                    {
                        "filename": "../escape.dmg",
                        "format": "dmg",
                        "platform": "darwin-arm64",
                        "sha256": "0" * 64,
                        "sizeBytes": 10,
                    }
                ]
            }
        )
        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("artifact filename must be a simple basename" in err for err in errors))

    def test_duplicate_artifact_filename_in_receipt_fails(self):
        fixture = self.create_fixture()
        dmg_entry = fixture["receipt_data"]["artifacts"][0]
        fixture["receipt_data"]["artifacts"].append(copy.deepcopy(dmg_entry))
        fixture["receipt_file"].write_text(json.dumps(fixture["receipt_data"]), encoding="utf-8")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("duplicate artifact filename in receipt" in err for err in errors))

    def test_unexpected_dmg_on_disk_fails(self):
        self.create_fixture()
        rogue_dmg = self.root / "rogue.dmg"
        rogue_dmg.write_bytes(b"UNEXPECTED")

        errors = verify_apple_release(self.root, self.version, self.channel)
        self.assertTrue(any("unexpected DMG artifact found in directory: rogue.dmg" in err for err in errors))

    def test_stable_alias_on_preview_channel_fails(self):
        fixture = self.create_fixture(channel="preview")
        alias_path = self.root / "Lemon-Bot-darwin-arm64.dmg"
        shutil.copyfile(fixture["dmg_file"], alias_path)

        errors = verify_apple_release(self.root, self.version, "preview")
        self.assertTrue(any("unexpected DMG artifact found in directory: Lemon-Bot-darwin-arm64.dmg" in err for err in errors))

    def test_stable_alias_sha_mismatch_fails(self):
        self.create_fixture(channel="stable")
        alias_path = self.root / "Lemon-Bot-darwin-arm64.dmg"
        alias_path.write_bytes(b"DIFFERENT_CONTENT")

        errors = verify_apple_release(self.root, self.version, "stable")
        self.assertTrue(any("stable alias Lemon-Bot-darwin-arm64.dmg sha256" in err for err in errors))

    # ── CLI & Parameter Validation Tests ────────────────────────────────────────

    def test_cli_missing_required_args_exits_2(self):
        proc = self.run_cli([])
        self.assertEqual(proc.returncode, 2)

        proc = self.run_cli([str(self.root), "--version", self.version])
        self.assertEqual(proc.returncode, 2)

        proc = self.run_cli([str(self.root), "--channel", self.channel])
        self.assertEqual(proc.returncode, 2)

    def test_cli_nonexistent_directory_exits_1(self):
        missing_dir = self.root / "does_not_exist"
        proc = self.run_cli([str(missing_dir), "--version", self.version, "--channel", self.channel])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("artifact directory not found", proc.stderr)

    def test_cli_invalid_calver_version_fails(self):
        self.create_fixture()
        for bad_v in ["v2026.11.1", "latest", "1.0.0", ""]:
            proc = self.run_cli([str(self.root), "--version", bad_v, "--channel", self.channel])
            self.assertEqual(proc.returncode, 1)
            self.assertIn("version must be", proc.stderr)

    def test_cli_invalid_channel_fails(self):
        self.create_fixture()
        proc = self.run_cli([str(self.root), "--version", self.version, "--channel", "bad channel;"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("channel contains invalid characters", proc.stderr)


if __name__ == "__main__":
    unittest.main()
