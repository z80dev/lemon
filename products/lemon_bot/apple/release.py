#!/usr/bin/env python3
"""Explicit Apple packaging; never substitutes preview for signed distribution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def required(name):
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"Required environment input missing: {name}")
    return value


def validate_runtime_base_url(url):
    if not isinstance(url, str):
        raise ValueError("Runtime base URL must be a string")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https":
        raise ValueError(f"Runtime base URL must use https://, got {url!r}")
    if not parsed.netloc:
        raise ValueError(f"Runtime base URL must include a host, got {url!r}")
    if parsed.query:
        raise ValueError(f"Runtime base URL must not contain query parameters, got {url!r}")
    if parsed.fragment:
        raise ValueError(f"Runtime base URL must not contain a fragment, got {url!r}")
    if url.endswith("/"):
        raise ValueError(f"Runtime base URL must not have a trailing slash, got {url!r}")
    return url


def runtime_pin(path, version, channel):
    manifest_path = Path(path)
    if not manifest_path.is_file():
        raise ValueError(f"Runtime manifest not found: {manifest_path}")
    raw = manifest_path.read_bytes()
    if len(raw) > 1024 * 1024:
        raise ValueError("Runtime manifest exceeds 1 MiB limit")
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as err:
        raise ValueError(f"Runtime manifest is not valid JSON: {err}")
    if not isinstance(manifest, dict):
        raise ValueError("Runtime manifest must be a JSON object")
    if manifest.get("schema") != 2:
        raise ValueError(f"Expected manifest schema 2, got {manifest.get('schema')}")
    if manifest.get("version") != version:
        raise ValueError(f"Manifest version mismatch: expected {version}, got {manifest.get('version')}")
    if manifest.get("channel") != channel:
        raise ValueError(f"Manifest channel mismatch: expected {channel}, got {manifest.get('channel')}")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("Manifest artifacts must be a list")

    required_profiles = ("lemon_runtime_full", "lemon_bot")
    darwin_matches = {prof: [] for prof in required_profiles}
    for entry in artifacts:
        if not isinstance(entry, dict):
            continue
        is_darwin_platform = entry.get("platform") == "darwin-arm64"
        filename = entry.get("file", "")
        for prof in required_profiles:
            expected_file = f"lemon-{version}-{channel}-darwin-arm64-{prof}.tar.gz"
            if (is_darwin_platform and entry.get("profile") == prof) or filename == expected_file:
                darwin_matches[prof].append(entry)

    for prof in required_profiles:
        matches = darwin_matches[prof]
        if len(matches) != 1:
            raise ValueError(f"Expected exactly one darwin-arm64 entry for {prof}, got {len(matches)}")
        entry = matches[0]
        expected_file = f"lemon-{version}-{channel}-darwin-arm64-{prof}.tar.gz"
        if entry.get("file") != expected_file:
            raise ValueError(f"Expected file {expected_file} for {prof}, got {entry.get('file')}")
        if entry.get("platform") != "darwin-arm64":
            raise ValueError(f"Expected platform darwin-arm64 for {prof}, got {entry.get('platform')}")
        if entry.get("profile") != prof:
            raise ValueError(f"Expected profile {prof}, got {entry.get('profile')}")
        sha = entry.get("sha256")
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
            raise ValueError(f"Invalid sha256 for {prof}: {sha}")
        size = entry.get("size")
        if type(size) is not int or size <= 0:
            raise ValueError(f"Invalid size for {prof}: {size}")

    return hashlib.sha256(raw).hexdigest()


def update_info_plist(path_or_dict, marketing, build, version, channel,
                      manifest_sha=None, base_url=None, is_mac_app=False):
    is_path = isinstance(path_or_dict, (str, Path))
    if is_path:
        with Path(path_or_dict).open("rb") as stream:
            info = plistlib.load(stream)
    else:
        info = dict(path_or_dict)

    info.update(
        CFBundleShortVersionString=marketing,
        CFBundleVersion=build,
        LemonBotReleaseVersion=version,
        LemonBotReleaseChannel=channel,
    )
    if is_mac_app and manifest_sha is not None:
        info["LemonBotRuntimeManifestSHA256"] = manifest_sha
        if base_url is not None:
            info["LemonBotRuntimeBaseURL"] = base_url

    if is_path:
        with Path(path_or_dict).open("wb") as stream:
            plistlib.dump(info, stream)
    return info


def signing_args(preview, identity=None, team=None, profile=None):
    code_sign_identity = "-" if preview else (identity or "-")
    args = [
        "CODE_SIGN_STYLE=Manual",
        f"CODE_SIGN_IDENTITY={code_sign_identity}",
        "CODE_SIGNING_ALLOWED=YES",
    ]
    if not preview and profile:
        args.append(f"LEMON_MAC_APP_PROFILE={profile}")
    if team:
        args.append(f"DEVELOPMENT_TEAM={team}")
    return args


def notarize(path, profile, keychain=None):
    if keychain is None:
        keychain = os.environ.get("APPLE_NOTARY_KEYCHAIN")
    cmd = [
        "xcrun", "notarytool", "submit", str(path),
        "--keychain-profile", profile,
        "--wait", "--timeout", "45m",
        "--output-format", "json",
    ]
    if keychain:
        cmd.extend(["--keychain", str(keychain)])

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    payload = {}
    if proc.stdout:
        try:
            payload = json.loads(proc.stdout)
        except (json.JSONDecodeError, ValueError):
            payload = {}

    status = payload.get("status")
    submission_id = payload.get("id")

    if status != "Accepted":
        if submission_id:
            log_cmd = ["xcrun", "notarytool", "log", submission_id, "--keychain-profile", profile]
            if keychain:
                log_cmd.extend(["--keychain", str(keychain)])
            log_res = subprocess.run(log_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if log_res.stdout:
                sys.stderr.write(log_res.stdout)
                sys.stderr.flush()
        if proc.returncode != 0 and not status:
            raise subprocess.CalledProcessError(proc.returncode, cmd, output=proc.stdout, stderr=proc.stderr)
        raise ValueError(f"Apple notarization was not Accepted (status: {status}); artifact is not distributable")


def build_receipt_metadata(artifacts, mode, version, channel, marketing, build, manifest_sha=None):
    preview = mode == "macos-preview"
    mac = mode.startswith("macos")
    metadata = {
        "schemaVersion": 1,
        "product": "lemon_bot",
        "version": version,
        "channel": channel,
        "appleMarketingVersion": marketing,
        "appleBuildNumber": build,
        "distribution": "local-preview" if preview else "developer-id-notarized" if mac else "app-store",
        "runtimeManifestSha256": manifest_sha,
        "uploadAccepted": mode == "ios-upload",
        "artifacts": [],
    }
    for path, kind in artifacts:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        metadata["artifacts"].append({
            "filename": path.name,
            "format": kind,
            "platform": "darwin-arm64" if mac else "ios",
            "sha256": digest.hexdigest(),
            "sizeBytes": path.stat().st_size,
        })
    return metadata


def make_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["macos", "macos-preview", "ios", "ios-upload"])
    parser.add_argument("--version", required=True, help="Parent CalVer, YYYY.MM.PATCH")
    parser.add_argument("--build", required=True, help="Apple numeric build number, at most three components")
    parser.add_argument("--channel", choices=["preview", "stable"], default="preview")
    parser.add_argument("--output", required=True)
    parser.add_argument("--runtime-manifest", help="Path to release manifest.json")
    parser.add_argument("--runtime-base-url", default="https://github.com/z80dev/lemon",
                        help="Base URL for runtime downloads")
    return parser


def main(argv=None):
    parser = make_parser()
    args = parser.parse_args(argv)
    match = re.fullmatch(r"(\d{4})\.(0[1-9]|1[0-2])\.(0|[1-9]\d*)", args.version)
    if not match or not re.fullmatch(r"[1-9]\d{0,3}(?:\.\d{1,2}){0,2}", args.build):
        raise ValueError("Expected CalVer YYYY.MM.PATCH and Apple build (up to 4.2.2 digits)")
    # Preserve the canonical three-component CalVer with Apple-compatible integers.
    marketing = ".".join(str(int(part)) for part in match.groups()[:3])
    root = Path(__file__).resolve().parent
    output = Path(args.output).resolve()
    if output == root or root in output.parents:
        raise ValueError("Release output must be outside the Apple source directory")
    preview = args.mode == "macos-preview"
    mac = args.mode.startswith("macos")

    if args.mode == "macos":
        if not args.runtime_manifest:
            raise ValueError("--runtime-manifest is required for macos mode")
    elif args.mode.startswith("ios"):
        if args.runtime_manifest:
            raise ValueError("--runtime-manifest is not supported for iOS modes")

    base_url = validate_runtime_base_url(args.runtime_base_url)
    manifest_sha = None
    if args.runtime_manifest:
        manifest_sha = runtime_pin(args.runtime_manifest, args.version, args.channel)

    team = identity = profile = None
    mac_provisioning = None
    notary_keychain = os.environ.get("APPLE_NOTARY_KEYCHAIN")
    if not preview:
        team = required("APPLE_TEAM_ID")
        if mac:
            identity = required("APPLE_DEVELOPER_ID_APPLICATION")
            if not identity.startswith("Developer ID Application:"):
                raise ValueError("APPLE_DEVELOPER_ID_APPLICATION must be a Developer ID Application identity")
            identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
            if identity not in identities:
                raise ValueError("Configured Developer ID identity/private key is not available in the build keychain")
            profile = required("APPLE_NOTARY_KEYCHAIN_PROFILE")
            # Authenticate before building; profile is created externally with notarytool store-credentials.
            history_cmd = ["xcrun", "notarytool", "history", "--keychain-profile", profile]
            if notary_keychain:
                history_cmd.extend(["--keychain", notary_keychain])
            run(*history_cmd)
            mac_provisioning = required("APPLE_MAC_PROVISIONING_PROFILE_SPECIFIER")
        else:
            identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
            if not any("Apple Distribution:" in line and f"({team})" in line for line in identities.splitlines()):
                raise ValueError("Apple Distribution identity/private key for the configured team is missing")
            export_options = Path(required("APPLE_IOS_EXPORT_OPTIONS")).resolve()
            with export_options.open("rb") as stream:
                options = plistlib.load(stream)
            if options.get("method") != "app-store-connect" or options.get("teamID") != team:
                raise ValueError("Export options must use method=app-store-connect and the configured teamID")
            if options.get("destination", "export") != "export":
                raise ValueError("Export destination must be export; upload is a separate explicit mode")
            key_id = required("APPLE_ASC_KEY_ID")
            issuer = required("APPLE_ASC_ISSUER_ID")
            key_path = Path(required("APPLE_ASC_KEY_PATH")).resolve()
            if not key_path.is_file():
                raise ValueError("App Store Connect API private key file does not exist")
            auth = ["-authenticationKeyPath", key_path, "-authenticationKeyID", key_id,
                    "-authenticationKeyIssuerID", issuer, "-allowProvisioningUpdates"]
    for tool in ["xcodegen", "xcodebuild", "xcrun", "ditto"] + (["hdiutil", "codesign", "spctl"] if mac else []):
        if not shutil.which(tool):
            raise ValueError(f"Builder prerequisite missing: {tool}")
    output.mkdir(parents=True, exist_ok=True)
    # Generate only on the builder. Isolated copy excludes private/generated development state.
    with tempfile.TemporaryDirectory(prefix="lemon-bot-apple-release-") as temporary:
        work = Path(temporary)
        source = work / "source"
        shutil.copytree(root, source, ignore=shutil.ignore_patterns(".git", ".derivedData*", ".build", "*.xcodeproj", "release-output", "__pycache__"))
        # Preserve exact release CalVer independently of Apple's three-component version.
        for relative in ["LemonBotMac/Info.plist", "LemonBotiOS/Info.plist", "LemonBotiOS/ShareExtension/Info.plist"]:
            path = source / relative
            is_mac_app = relative == "LemonBotMac/Info.plist"
            update_info_plist(
                path,
                marketing=marketing,
                build=args.build,
                version=args.version,
                channel=args.channel,
                manifest_sha=manifest_sha if is_mac_app else None,
                base_url=base_url if is_mac_app else None,
                is_mac_app=is_mac_app,
            )
        run("xcodegen", "generate", "--spec", source / "project.yml", "--project", source)
        common = ["xcodebuild", "-project", source / "LemonBot.xcodeproj", "-scheme",
                  "LemonBotMac" if mac else "LemonBotiOS", "-configuration", "Debug" if preview else "Release",
                  "-derivedDataPath", work / "derived", f"MARKETING_VERSION={marketing}", f"CURRENT_PROJECT_VERSION={args.build}"]
        artifacts = []
        if mac:
            signing = signing_args(preview, identity=identity, team=team, profile=mac_provisioning)
            run(*common, "-destination", "generic/platform=macOS", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", *signing, "build")
            app = work / "derived/Build/Products" / ("Debug" if preview else "Release") / "Lemon Bot.app"
            run("codesign", "--verify", "--deep", "--strict", app)
            if not preview:
                submission = work / "notary.zip"
                run("ditto", "-c", "-k", "--keepParent", app, submission)
                notarize(submission, profile, notary_keychain)
                run("xcrun", "stapler", "staple", app)
                run("xcrun", "stapler", "validate", app)
                run("spctl", "--assess", "--type", "execute", app)
            suffix = "local-preview" if preview else "notarized"
            stem = f"lemon-bot-{args.version}-{args.channel}-darwin-arm64-{suffix}"
            stage = work / "dmg"
            stage.mkdir()
            run("ditto", app, stage / "Lemon Bot.app")
            (stage / "Applications").symlink_to("/Applications")
            dmg = output / f"{stem}.dmg"
            zip_path = output / f"{stem}.zip"
            run("hdiutil", "create", "-volname", "Lemon Bot", "-srcfolder", stage, "-format", "UDZO", "-ov", dmg)
            if not preview:
                run("codesign", "--sign", identity, "--timestamp", dmg)
                notarize(dmg, profile, notary_keychain)
                run("xcrun", "stapler", "staple", dmg)
                run("xcrun", "stapler", "validate", dmg)
                run("spctl", "-a", "-t", "open", "--context", "context:primary-signature", "-v", dmg)
            run("ditto", "-c", "-k", "--keepParent", app, zip_path)
            if preview:
                artifacts = [(dmg, "dmg"), (zip_path, "zip")]
            else:
                artifacts = [(dmg, "dmg")]
        else:
            archive = work / "LemonBot.xcarchive"
            run(*common, "-destination", "generic/platform=iOS", "-archivePath", archive,
                f"DEVELOPMENT_TEAM={team}", *auth, "archive")
            exported = work / "export"
            run("xcodebuild", "-exportArchive", "-archivePath", archive, "-exportPath", exported,
                "-exportOptionsPlist", export_options, *auth)
            ipas = list(exported.glob("*.ipa"))
            if len(ipas) != 1:
                raise ValueError("Expected exactly one real exported device IPA")
            ipa = output / f"lemon-bot-{args.version}-{args.channel}-ios-app-store.ipa"
            shutil.copyfile(ipas[0], ipa)
            if args.mode == "ios-upload":
                # altool discovers AuthKey_<id>.p8 in API_PRIVATE_KEYS_DIR.
                keys = work / "keys"
                keys.mkdir(mode=0o700)
                shutil.copyfile(key_path, keys / f"AuthKey_{key_id}.p8")
                subprocess.run(["xcrun", "altool", "--upload-app", "--type", "ios", "--file", str(ipa),
                                "--apiKey", key_id, "--apiIssuer", issuer],
                               env={**os.environ, "API_PRIVATE_KEYS_DIR": str(keys)}, check=True)
            artifacts = [(ipa, "ipa")]
        metadata = build_receipt_metadata(
            artifacts,
            mode=args.mode,
            version=args.version,
            channel=args.channel,
            marketing=marketing,
            build=args.build,
            manifest_sha=manifest_sha,
        )
        receipt = output / f"lemon-bot-{args.version}-{args.channel}-{args.mode}.json"
        receipt.write_text(json.dumps(metadata, indent=2) + "\n")
        print(receipt)
        if args.mode == "ios-upload":
            print("Upload accepted by transport; App Store Connect processing/TestFlight availability remains external.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Apple release failed: {error}", file=sys.stderr)
        sys.exit(1)
