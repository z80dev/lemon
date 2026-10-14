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


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def required(name):
    value = os.environ.get(name)
    if not value:
        raise ValueError(f"Required environment input missing: {name}")
    return value

def notarize(path, profile):
    result = subprocess.check_output([
        "xcrun", "notarytool", "submit", str(path), "--keychain-profile", profile,
        "--wait", "--output-format", "json"], text=True)
    if json.loads(result).get("status") != "Accepted":
        raise ValueError("Apple notarization was not Accepted; artifact is not distributable")



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["macos", "macos-preview", "ios", "ios-upload"])
    parser.add_argument("--version", required=True, help="Parent CalVer, YYYY.MM.DD[.revision]")
    parser.add_argument("--build", required=True, help="Apple numeric build number, at most three components")
    parser.add_argument("--channel", choices=["preview", "stable"], default="preview")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    match = re.fullmatch(r"(\d{4})\.(\d{2})\.(\d{2})(?:\.(\d+))?", args.version)
    if not match or not re.fullmatch(r"[1-9]\d{0,3}(?:\.\d{1,2}){0,2}", args.build):
        raise ValueError("Expected CalVer YYYY.MM.DD[.revision] and Apple build (up to 4.2.2 digits)")
    # Apple's marketing version permits three numeric components, not CalVer's fourth.
    marketing = ".".join(str(int(part)) for part in match.groups()[:3])
    root = Path(__file__).resolve().parent
    output = Path(args.output).resolve()
    if output == root or root in output.parents:
        raise ValueError("Release output must be outside the Apple source directory")
    preview = args.mode == "macos-preview"
    mac = args.mode.startswith("macos")
    team = identity = profile = None
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
            run("xcrun", "notarytool", "history", "--keychain-profile", profile)
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
    for tool in ["xcodegen", "xcodebuild", "xcrun", "ditto"] + (["hdiutil", "codesign"] if mac else []):
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
            with path.open("rb") as stream:
                info = plistlib.load(stream)
            info.update(CFBundleShortVersionString=marketing, CFBundleVersion=args.build,
                        LemonBotReleaseVersion=args.version, LemonBotReleaseChannel=args.channel)
            with path.open("wb") as stream:
                plistlib.dump(info, stream)
        run("xcodegen", "generate", "--spec", source / "project.yml", "--project", source)
        common = ["xcodebuild", "-project", source / "LemonBot.xcodeproj", "-scheme",
                  "LemonBotMac" if mac else "LemonBotiOS", "-configuration", "Debug" if preview else "Release",
                  "-derivedDataPath", work / "derived", f"MARKETING_VERSION={marketing}", f"CURRENT_PROJECT_VERSION={args.build}"]
        artifacts = []
        if mac:
            signing = ["CODE_SIGN_STYLE=Manual", f"CODE_SIGN_IDENTITY={'-' if preview else identity}",
                       "CODE_SIGNING_ALLOWED=YES", "APS_ENVIRONMENT=",
                       f"CODE_SIGN_ENTITLEMENTS={source / 'LemonBotMac/LemonBotMacDebug.entitlements'}"]
            if team:
                signing.append(f"DEVELOPMENT_TEAM={team}")
            run(*common, "-destination", "generic/platform=macOS", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", *signing, "build")
            app = work / "derived/Build/Products" / ("Debug" if preview else "Release") / "Lemon Bot.app"
            run("codesign", "--verify", "--deep", "--strict", app)
            if not preview:
                submission = work / "notary.zip"
                run("ditto", "-c", "-k", "--keepParent", app, submission)
                notarize(submission, profile)
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
                notarize(dmg, profile)
                run("xcrun", "stapler", "staple", dmg)
                run("xcrun", "stapler", "validate", dmg)
            run("ditto", "-c", "-k", "--keepParent", app, zip_path)
            artifacts = [(dmg, "dmg"), (zip_path, "zip")]
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
        metadata = {"schemaVersion": 1, "product": "lemon_bot", "version": args.version,
                    "channel": args.channel, "appleMarketingVersion": marketing, "appleBuildNumber": args.build,
                    "distribution": "local-preview" if preview else "developer-id-notarized" if mac else "app-store",
                    "uploadAccepted": args.mode == "ios-upload", "artifacts": []}
        for path, kind in artifacts:
            digest = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            metadata["artifacts"].append({"filename": path.name, "format": kind,
                "platform": "darwin-arm64" if mac else "ios", "sha256": digest.hexdigest(), "sizeBytes": path.stat().st_size})
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
