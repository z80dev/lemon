#!/usr/bin/env python3
"""Unit tests for Lemon Bot Apple release packaging (products/lemon_bot/apple/release.py)."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

# Ensure products/lemon_bot/apple is on sys.path
HERE = Path(__file__).resolve().parent
if str(HERE) not in os.sys.path:
    os.sys.path.insert(0, str(HERE))

import release


def make_valid_manifest(version="2026.11.1", channel="preview", schema=2, artifacts=None):
    if artifacts is None:
        artifacts = [
            {
                "file": f"lemon-{version}-{channel}-darwin-arm64-lemon_runtime_full.tar.gz",
                "profile": "lemon_runtime_full",
                "platform": "darwin-arm64",
                "os": "darwin",
                "arch": "arm64",
                "sha256": "a" * 64,
                "size": 1048576,
            },
            {
                "file": f"lemon-{version}-{channel}-darwin-arm64-lemon_bot.tar.gz",
                "profile": "lemon_bot",
                "platform": "darwin-arm64",
                "os": "darwin",
                "arch": "arm64",
                "sha256": "b" * 64,
                "size": 2097152,
            },
        ]
    return {
        "schema": schema,
        "version": version,
        "channel": channel,
        "commit": "0123456789abcdef",
        "built_at": "2026-11-10T12:00:00Z",
        "otp": "28.5",
        "elixir": "1.19.5",
        "artifacts": artifacts,
    }


class RuntimeBaseUrlTest(unittest.TestCase):
    def test_valid_urls(self):
        self.assertEqual(
            release.validate_runtime_base_url("https://github.com/z80dev/lemon"),
            "https://github.com/z80dev/lemon",
        )
        self.assertEqual(
            release.validate_runtime_base_url("https://releases.example.com/lemon/builds"),
            "https://releases.example.com/lemon/builds",
        )

    def test_rejects_http_scheme(self):
        with self.assertRaises(ValueError) as ctx:
            release.validate_runtime_base_url("http://github.com/z80dev/lemon")
        self.assertIn("https://", str(ctx.exception))

    def test_rejects_trailing_slash(self):
        with self.assertRaises(ValueError) as ctx:
            release.validate_runtime_base_url("https://github.com/z80dev/lemon/")
        self.assertIn("trailing slash", str(ctx.exception))

    def test_rejects_query_string(self):
        with self.assertRaises(ValueError) as ctx:
            release.validate_runtime_base_url("https://github.com/z80dev/lemon?branch=main")
        self.assertIn("query", str(ctx.exception))

    def test_rejects_fragment(self):
        with self.assertRaises(ValueError) as ctx:
            release.validate_runtime_base_url("https://github.com/z80dev/lemon#readme")
        self.assertIn("fragment", str(ctx.exception))

    def test_rejects_empty_host(self):
        with self.assertRaises(ValueError) as ctx:
            release.validate_runtime_base_url("https://")
        self.assertIn("host", str(ctx.exception))

    def test_rejects_non_string(self):
        with self.assertRaises(ValueError) as ctx:
            release.validate_runtime_base_url(None)
        self.assertIn("string", str(ctx.exception))


class RuntimePinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write_manifest(self, data, raw=None):
        path = self.work / "manifest.json"
        if raw is not None:
            path.write_bytes(raw)
        else:
            path.write_text(json.dumps(data), encoding="utf-8")
        return path

    def test_valid_manifest_computes_sha256(self):
        data = make_valid_manifest()
        path = self.write_manifest(data)
        expected_sha = hashlib.sha256(path.read_bytes()).hexdigest()
        digest = release.runtime_pin(path, "2026.11.1", "preview")
        self.assertEqual(digest, expected_sha)
        self.assertEqual(len(digest), 64)

    def test_valid_manifest_with_extra_platform_artifacts(self):
        # Manifest can contain other non-darwin platform tarballs (e.g. linux-x86_64)
        data = make_valid_manifest()
        data["artifacts"].append({
            "file": "lemon-2026.11.1-preview-linux-x86_64-lemon_bot.tar.gz",
            "profile": "lemon_bot",
            "platform": "linux-x86_64",
            "os": "linux",
            "arch": "x86_64",
            "sha256": "c" * 64,
            "size": 500000,
        })
        path = self.write_manifest(data)
        expected_sha = hashlib.sha256(path.read_bytes()).hexdigest()
        digest = release.runtime_pin(path, "2026.11.1", "preview")
        self.assertEqual(digest, expected_sha)

    def test_file_not_found(self):
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(self.work / "nonexistent.json", "2026.11.1", "preview")
        self.assertIn("not found", str(ctx.exception))

    def test_exceeds_one_mib(self):
        oversized = b" " * (1024 * 1024 + 1)
        path = self.write_manifest(None, raw=oversized)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("1 MiB", str(ctx.exception))

    def test_invalid_json(self):
        path = self.write_manifest(None, raw=b"this is not json {")
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("valid JSON", str(ctx.exception))

    def test_json_not_object(self):
        path = self.write_manifest(None, raw=b'["item1", "item2"]')
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("JSON object", str(ctx.exception))

    def test_schema_mismatch(self):
        data = make_valid_manifest(schema=1)
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("schema 2", str(ctx.exception))

    def test_version_mismatch(self):
        data = make_valid_manifest(version="2026.11.2")
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("Manifest version mismatch", str(ctx.exception))

    def test_channel_mismatch(self):
        data = make_valid_manifest(channel="stable")
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("Manifest channel mismatch", str(ctx.exception))

    def test_missing_darwin_lemon_bot(self):
        # Keep only lemon_runtime_full
        data = make_valid_manifest()
        data["artifacts"] = [a for a in data["artifacts"] if a["profile"] != "lemon_bot"]
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("lemon_bot", str(ctx.exception))
        self.assertIn("got 0", str(ctx.exception))

    def test_missing_darwin_lemon_runtime_full(self):
        # Keep only lemon_bot
        data = make_valid_manifest()
        data["artifacts"] = [a for a in data["artifacts"] if a["profile"] != "lemon_runtime_full"]
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("lemon_runtime_full", str(ctx.exception))
        self.assertIn("got 0", str(ctx.exception))

    def test_duplicate_darwin_artifact_entry(self):
        data = make_valid_manifest()
        # Duplicate lemon_bot
        data["artifacts"].append(dict(data["artifacts"][1]))
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("lemon_bot", str(ctx.exception))
        self.assertIn("got 2", str(ctx.exception))

    def test_bad_sha256(self):
        for bad_sha in ["short", "a" * 63, "a" * 65, "g" * 64, "", 12345]:
            data = make_valid_manifest()
            data["artifacts"][0]["sha256"] = bad_sha
            path = self.write_manifest(data)
            with self.assertRaises(ValueError) as ctx:
                release.runtime_pin(path, "2026.11.1", "preview")
            self.assertIn("Invalid sha256", str(ctx.exception))

    def test_bad_size(self):
        for bad_size in [0, -1, "1048576", 1024.5, True]:
            data = make_valid_manifest()
            data["artifacts"][0]["size"] = bad_size
            path = self.write_manifest(data)
            with self.assertRaises(ValueError) as ctx:
                release.runtime_pin(path, "2026.11.1", "preview")
            self.assertIn("Invalid size", str(ctx.exception))

    def test_bad_filename_pattern(self):
        data = make_valid_manifest()
        data["artifacts"][0]["file"] = "lemon-custom-name.tar.gz"
        path = self.write_manifest(data)
        with self.assertRaises(ValueError) as ctx:
            release.runtime_pin(path, "2026.11.1", "preview")
        self.assertIn("Expected file", str(ctx.exception))


class InfoPlistMutationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_mac_app_with_manifest_pins(self):
        initial = {
            "CFBundleIdentifier": "org.lemonbot.mac",
            "CFBundleName": "Lemon Bot",
        }
        manifest_sha = "d" * 64
        base_url = "https://github.com/z80dev/lemon"
        updated = release.update_info_plist(
            initial,
            marketing="2026.11.1",
            build="2611.1.1",
            version="2026.11.1",
            channel="preview",
            manifest_sha=manifest_sha,
            base_url=base_url,
            is_mac_app=True,
        )
        self.assertEqual(updated["CFBundleShortVersionString"], "2026.11.1")
        self.assertEqual(updated["CFBundleVersion"], "2611.1.1")
        self.assertEqual(updated["LemonBotReleaseVersion"], "2026.11.1")
        self.assertEqual(updated["LemonBotReleaseChannel"], "preview")
        self.assertEqual(updated["LemonBotRuntimeManifestSHA256"], manifest_sha)
        self.assertEqual(updated["LemonBotRuntimeBaseURL"], base_url)

    def test_mac_app_without_manifest_pin(self):
        initial = {"CFBundleIdentifier": "org.lemonbot.mac"}
        updated = release.update_info_plist(
            initial,
            marketing="2026.11.1",
            build="2611.1.1",
            version="2026.11.1",
            channel="preview",
            manifest_sha=None,
            base_url="https://github.com/z80dev/lemon",
            is_mac_app=True,
        )
        self.assertNotIn("LemonBotRuntimeManifestSHA256", updated)
        self.assertNotIn("LemonBotRuntimeBaseURL", updated)
        self.assertEqual(updated["LemonBotReleaseVersion"], "2026.11.1")

    def test_ios_app_never_receives_manifest_pins(self):
        for is_mac in [False]:
            initial = {"CFBundleIdentifier": "org.lemonbot.ios"}
            updated = release.update_info_plist(
                initial,
                marketing="2026.11.1",
                build="2611.1.1",
                version="2026.11.1",
                channel="preview",
                manifest_sha="d" * 64,
                base_url="https://github.com/z80dev/lemon",
                is_mac_app=is_mac,
            )
            self.assertNotIn("LemonBotRuntimeManifestSHA256", updated)
            self.assertNotIn("LemonBotRuntimeBaseURL", updated)
            self.assertEqual(updated["LemonBotReleaseVersion"], "2026.11.1")

    def test_mutates_plist_file_on_disk(self):
        path = self.work / "Info.plist"
        initial = {"CFBundleIdentifier": "org.lemonbot.mac"}
        with path.open("wb") as f:
            plistlib.dump(initial, f)

        release.update_info_plist(
            path,
            marketing="2026.11.1",
            build="2611.1.1",
            version="2026.11.1",
            channel="preview",
            manifest_sha="e" * 64,
            base_url="https://github.com/z80dev/lemon",
            is_mac_app=True,
        )

        with path.open("rb") as f:
            reloaded = plistlib.load(f)
        self.assertEqual(reloaded["LemonBotRuntimeManifestSHA256"], "e" * 64)
        self.assertEqual(reloaded["LemonBotRuntimeBaseURL"], "https://github.com/z80dev/lemon")


class SigningArgsIsolationTest(unittest.TestCase):
    def test_preview_mode_drops_entitlements_and_profile_overrides(self):
        args = release.signing_args(preview=True)
        self.assertEqual(
            args,
            [
                "CODE_SIGN_STYLE=Manual",
                "CODE_SIGN_IDENTITY=-",
                "CODE_SIGNING_ALLOWED=YES",
            ],
        )
        for arg in args:
            self.assertFalse(arg.startswith("CODE_SIGN_ENTITLEMENTS="))
            self.assertFalse(arg.startswith("APS_ENVIRONMENT="))
            self.assertFalse(arg.startswith("PROVISIONING_PROFILE_SPECIFIER="))
            self.assertFalse(arg.startswith("LEMON_MAC_APP_PROFILE="))

    def test_preview_mode_with_development_team(self):
        args = release.signing_args(preview=True, team="ABCDE12345")
        self.assertIn("DEVELOPMENT_TEAM=ABCDE12345", args)
        self.assertIn("CODE_SIGN_IDENTITY=-", args)
        for arg in args:
            self.assertFalse(arg.startswith("CODE_SIGN_ENTITLEMENTS="))
            self.assertFalse(arg.startswith("PROVISIONING_PROFILE_SPECIFIER="))

    def test_signed_macos_mode_isolates_profile_as_lemon_mac_app_profile(self):
        identity = "Developer ID Application: Lemon Bot (ABCDE12345)"
        profile = "Lemon Bot Release Profile"
        team = "ABCDE12345"
        args = release.signing_args(preview=False, identity=identity, team=team, profile=profile)
        self.assertIn("CODE_SIGN_STYLE=Manual", args)
        self.assertIn(f"CODE_SIGN_IDENTITY={identity}", args)
        self.assertIn("CODE_SIGNING_ALLOWED=YES", args)
        self.assertIn(f"LEMON_MAC_APP_PROFILE={profile}", args)
        self.assertIn(f"DEVELOPMENT_TEAM={team}", args)

        # Crucial isolation requirements:
        for arg in args:
            self.assertFalse(arg.startswith("PROVISIONING_PROFILE_SPECIFIER="))
            self.assertFalse(arg.startswith("CODE_SIGN_ENTITLEMENTS="))
            self.assertFalse(arg.startswith("APS_ENVIRONMENT="))

    def test_xcodebuild_argv_does_not_contain_global_profile_override(self):
        # Assert full argv that xcodebuild would execute
        common = ["xcodebuild", "-project", "LemonBot.xcodeproj", "-scheme", "LemonBotMac"]
        signing = release.signing_args(
            preview=False,
            identity="Developer ID Application: Test (12345)",
            team="12345",
            profile="MyProfile",
        )
        full_argv = common + ["-destination", "generic/platform=macOS"] + signing + ["build"]
        self.assertNotIn("PROVISIONING_PROFILE_SPECIFIER=MyProfile", full_argv)
        self.assertIn("LEMON_MAC_APP_PROFILE=MyProfile", full_argv)


class NotarizeTest(unittest.TestCase):
    @mock.patch("subprocess.run")
    def test_notarize_success_sets_timeout_and_profile(self, mock_run):
        mock_run.return_value = mock.Mock(
            returncode=0,
            stdout=json.dumps({"id": "uuid-123", "status": "Accepted"}),
            stderr="",
        )
        with mock.patch.dict(os.environ, {}, clear=True):
            release.notarize(Path("/tmp/notary.zip"), "lemon-profile")

        mock_run.assert_called_once()
        cmd = mock_run.call_args[0][0]
        self.assertEqual(cmd[:4], ["xcrun", "notarytool", "submit", "/tmp/notary.zip"])
        self.assertIn("--keychain-profile", cmd)
        self.assertEqual(cmd[cmd.index("--keychain-profile") + 1], "lemon-profile")
        self.assertIn("--timeout", cmd)
        self.assertEqual(cmd[cmd.index("--timeout") + 1], "45m")
        self.assertIn("--wait", cmd)
        self.assertIn("--output-format", cmd)
        self.assertNotIn("--keychain", cmd)

    @mock.patch("subprocess.run")
    def test_notarize_passes_keychain_from_env_or_param(self, mock_run):
        mock_run.return_value = mock.Mock(
            returncode=0,
            stdout=json.dumps({"id": "uuid-123", "status": "Accepted"}),
            stderr="",
        )
        # 1. From env
        with mock.patch.dict(os.environ, {"APPLE_NOTARY_KEYCHAIN": "/path/to/keychain-db"}):
            release.notarize(Path("/tmp/notary.zip"), "lemon-profile")
            cmd = mock_run.call_args[0][0]
            self.assertIn("--keychain", cmd)
            self.assertEqual(cmd[cmd.index("--keychain") + 1], "/path/to/keychain-db")

        # 2. From parameter
        mock_run.reset_mock()
        with mock.patch.dict(os.environ, {}, clear=True):
            release.notarize(Path("/tmp/notary.zip"), "lemon-profile", keychain="/custom/keychain-db")
            cmd = mock_run.call_args[0][0]
            self.assertIn("--keychain", cmd)
            self.assertEqual(cmd[cmd.index("--keychain") + 1], "/custom/keychain-db")

    @mock.patch("subprocess.run")
    def test_notarize_rejection_fetches_log_to_stderr_and_raises(self, mock_run):
        submit_res = mock.Mock(
            returncode=0,
            stdout=json.dumps({"id": "submission-uuid-999", "status": "Invalid"}),
            stderr="",
        )
        log_res = mock.Mock(
            returncode=0,
            stdout="Notary log details: signature corrupt\n",
            stderr="",
        )
        mock_run.side_effect = [submit_res, log_res]

        stderr_capture = io.StringIO()
        with mock.patch("sys.stderr", stderr_capture):
            with self.assertRaises(ValueError) as ctx:
                release.notarize(Path("/tmp/notary.zip"), "lemon-profile", keychain="/path/kc")

        self.assertIn("Apple notarization was not Accepted (status: Invalid)", str(ctx.exception))
        self.assertEqual(mock_run.call_count, 2)
        log_cmd = mock_run.call_args_list[1][0][0]
        self.assertEqual(log_cmd[:4], ["xcrun", "notarytool", "log", "submission-uuid-999"])
        self.assertIn("--keychain-profile", log_cmd)
        self.assertIn("--keychain", log_cmd)
        self.assertIn("Notary log details: signature corrupt", stderr_capture.getvalue())

    @mock.patch("subprocess.run")
    def test_notarize_process_error_without_json_status(self, mock_run):
        mock_run.return_value = mock.Mock(
            returncode=1,
            stdout="",
            stderr="Network unreachable",
        )
        with self.assertRaises(subprocess.CalledProcessError):
            release.notarize(Path("/tmp/notary.zip"), "lemon-profile")


class ReceiptMetadataTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        self.dmg = self.work / "lemon-bot-2026.11.1-preview-darwin-arm64-notarized.dmg"
        self.dmg.write_bytes(b"DMG CONTENT")
        self.zip = self.work / "lemon-bot-2026.11.1-preview-darwin-arm64-notarized.zip"
        self.zip.write_bytes(b"ZIP CONTENT")

    def tearDown(self):
        self.tmp.cleanup()

    def test_signed_macos_receipt_omits_zip_and_includes_only_dmg(self):
        """Parent IRC regression requirement:
        Signed macOS receipt must list only DMG (CI specified upload only DMG+receipt;
        verifier checks every listed file). Keep generated ZIP local but omit it from signed receipt.
        """
        # In release.py for signed macOS (preview=False), artifacts is set to [(dmg, "dmg")]:
        artifacts = [(self.dmg, "dmg")]
        manifest_sha = "f" * 64
        meta = release.build_receipt_metadata(
            artifacts,
            mode="macos",
            version="2026.11.1",
            channel="preview",
            marketing="2026.11.1",
            build="2611.1.1",
            manifest_sha=manifest_sha,
        )
        self.assertEqual(meta["schemaVersion"], 1)
        self.assertEqual(meta["product"], "lemon_bot")
        self.assertEqual(meta["distribution"], "developer-id-notarized")
        self.assertEqual(meta["runtimeManifestSha256"], manifest_sha)
        self.assertFalse(meta["uploadAccepted"])
        self.assertEqual(len(meta["artifacts"]), 1)
        self.assertEqual(meta["artifacts"][0]["format"], "dmg")
        self.assertEqual(meta["artifacts"][0]["filename"], self.dmg.name)
        self.assertEqual(
            meta["artifacts"][0]["sha256"],
            hashlib.sha256(b"DMG CONTENT").hexdigest(),
        )

    def test_preview_receipt_lists_both_dmg_and_zip(self):
        # In preview mode, artifacts contains both DMG and ZIP:
        artifacts = [(self.dmg, "dmg"), (self.zip, "zip")]
        meta = release.build_receipt_metadata(
            artifacts,
            mode="macos-preview",
            version="2026.11.1",
            channel="preview",
            marketing="2026.11.1",
            build="2611.1.1",
            manifest_sha=None,
        )
        self.assertEqual(meta["distribution"], "local-preview")
        self.assertIsNone(meta["runtimeManifestSha256"])
        self.assertEqual(len(meta["artifacts"]), 2)
        formats = [a["format"] for a in meta["artifacts"]]
        self.assertIn("dmg", formats)
        self.assertIn("zip", formats)


class CliArgParsingTest(unittest.TestCase):
    def test_macos_mode_requires_runtime_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError) as ctx:
                release.main(["macos", "--version", "2026.11.1", "--build", "2611.1.1", "--output", tmp])
            self.assertIn("--runtime-manifest is required", str(ctx.exception))

    def test_ios_mode_rejects_runtime_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError) as ctx:
                release.main([
                    "ios",
                    "--version", "2026.11.1",
                    "--build", "2611.1.1",
                    "--output", tmp,
                    "--runtime-manifest", "/path/to/manifest.json",
                ])
            self.assertIn("--runtime-manifest is not supported", str(ctx.exception))

    def test_invalid_version_calver_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            for bad_ver in ["2026.13.1", "2026.00.1", "2026.1.1.1", "v2026.11.1"]:
                with self.assertRaises(ValueError) as ctx:
                    release.main(["macos-preview", "--version", bad_ver, "--build", "2611.1.1", "--output", tmp])
                self.assertIn("Expected CalVer", str(ctx.exception))

    def test_invalid_build_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            for bad_build in ["01.1", "1.2.3.4", "10000.1"]:
                with self.assertRaises(ValueError) as ctx:
                    release.main(["macos-preview", "--version", "2026.11.1", "--build", bad_build, "--output", tmp])
                self.assertIn("Expected CalVer", str(ctx.exception))

    def test_output_inside_source_root_rejected(self):
        source_root = Path(release.__file__).resolve().parent
        with self.assertRaises(ValueError) as ctx:
            release.main([
                "macos-preview",
                "--version", "2026.11.1",
                "--build", "2611.1.1",
                "--output", str(source_root / "nested-output"),
            ])
        self.assertIn("Release output must be outside", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
