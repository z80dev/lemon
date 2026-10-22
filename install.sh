#!/bin/sh
# verify_boot and verify_bot_runtime are ( ) subshell functions so their
# throwaway HOME/Store/release exports never leak into the installer.
# shellcheck disable=SC2030,SC2031
# Lemon installer.
#
#   curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
#
# Downloads a published Lemon release tarball for the detected platform,
# verifies its SHA-256 against the release manifest, and installs it into
# ~/.lemon using the layout shared with `lemon update`:
#
#   ~/.lemon/versions/<version>/   extracted release
#   ~/.lemon/versions/current      symlink, atomic flip point
#   ~/.lemon/bin/lemon             -> ../versions/current/bin/lemon
#
# Releases that publish one also install the terminal UI alongside the runtime,
# into ~/.lemon/versions/<version>/tui/bin/lemon-tui. Both tarballs are
# downloaded and verified before either is extracted, and both land in the same
# staging directory, so the single rename + symlink flip installs them
# together or not at all.
#
# Backend only: sh install.sh --profile lemon_bot
# Installs bot/ into ~/.lemon/lemon_bot/versions/<version>-<channel>-<platform>,
# flips ~/.lemon/lemon_bot/current, and links ~/.local/bin/lemon-bot.
# Runtime state remains in ~/.lemon/lemon_bot, outside the versioned tree.
#
# POSIX sh: no bashisms, no arrays, no [[ ]], no local.
set -eu

DEFAULT_BASE_URL="https://github.com/z80dev/lemon"
DOCS_URL="https://github.com/z80dev/lemon/blob/main/docs/install.md"
SOURCE_URL="https://github.com/z80dev/lemon"
GLIBC_MIN_MAJOR=2
GLIBC_MIN_MINOR=39

FORCE=0
VERIFY=0
MODIFY_PATH=1
SKIP_SETUP=0
RESOLVE_VERSION=0
REQUIRE_BOT=0


BASE_URL="${LEMON_INSTALL_BASE_URL:-$DEFAULT_BASE_URL}"
CHANNEL="${LEMON_CHANNEL:-stable}"
CHANNEL_EXPLICIT=0
if [ -n "${LEMON_CHANNEL:-}" ]; then
  CHANNEL_EXPLICIT=1
fi
PIN="${LEMON_VERSION:-}"
PROFILE_INPUT="${LEMON_PROFILE:-lemon_runtime_full}"

usage() {
  cat <<EOF
Lemon installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
  sh install.sh [--profile NAME] [--force] [--verify] [--no-modify-path] [--skip-setup] [--require-bot]
  sh install.sh --resolve-version

Options:
  --profile NAME  Select full, min, sim, or lemon_bot (backend only, no BEAM/TUI).
  --force         Reinstall even if the target version is already present.
  --verify        Boot on ephemeral ports, then stop. Native: poll /healthz.
                  Backend: check /v1/setup and web before promotion.
                  Fails the install if the smoke check fails.
  --no-modify-path
                  Do not add the launcher directory (~/.lemon/bin for native,
                  ~/.local/bin for lemon_bot) to your shell rc file; print
                  the PATH line instead. --modify-path is the default.
  --skip-setup    Do not start the interactive provider setup wizard after
                  installing. Run \$HOME/.lemon/bin/lemon setup later to
                  configure Lemon.
  --require-bot   Install only a bot-capable native runtime (full or min; never the
                  lemon_bot backend, sim, or the TUI). The staged runtime must pass
                  \`lemon node capabilities --json --require-bot\` and report the
                  manifest version before anything is promoted.
  --resolve-version
                  Print the version this run would install, then exit without
                  installing anything.
  --help          Show this help.

Prerequisites:
  curl, tar, and python3. python3 parses the release manifest and performs the
  atomic symlink flip; there is no jq dependency. Install it with
  \`xcode-select --install\` on macOS or your distribution's python3 package.

Environment:
  LEMON_VERSION               Pin an exact version, e.g. 2026.08.0. Required for
                              any channel other than stable. A pin without an
                              explicit LEMON_CHANNEL accepts the channel the
                              pinned release manifest publishes.
  LEMON_CHANNEL               Release channel. Default: stable for unpinned
                              installs. An explicit value must match the manifest.
  LEMON_PROFILE               full | min | sim | lemon_bot, or a full profile name
                              (lemon_runtime_full, lemon_runtime_min,
                              sim_broadcast_platform). Default: lemon_runtime_full.
  LEMON_NO_TUI                Set to 1 to install the runtime only, skipping the
                              terminal UI (\`lemon-tui\`). Roughly halves the
                              download. The sim profile never ships a TUI.
  LEMON_INSTALL_IGNORE_GLIBC  Set to 1 to silence the Linux glibc baseline check.
  LEMON_INSTALL_BASE_URL      Override the GitHub release base URL (test seam).

Native installs into \$HOME/.lemon/versions. Backend installs into
\$HOME/.lemon/lemon_bot/versions with an independent current pointer and
\$HOME/.local/bin/lemon-bot launcher. Backend state is \$HOME/.lemon/lemon_bot,
outside the versioned tree; LEMON_BOT_DATA_DIR can override it at runtime.
Backend version verification needs no Bun, Node, or source checkout.
Docs: $DOCS_URL
EOF
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 is required but was not found on PATH. See $DOCS_URL"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --verify) VERIFY=1 ;;
    --modify-path) MODIFY_PATH=1 ;;
    --no-modify-path) MODIFY_PATH=0 ;;
    --skip-setup) SKIP_SETUP=1 ;;
    --require-bot) REQUIRE_BOT=1 ;;
    --profile)
      [ "$#" -ge 2 ] || die "--profile needs a profile name"
      PROFILE_INPUT="$2"
      shift
      ;;
    --resolve-version) RESOLVE_VERSION=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

need_cmd curl
need_cmd tar
need_cmd uname
if ! command -v python3 >/dev/null 2>&1; then
  die "python3 is required to read the release manifest.
  macOS:  xcode-select --install
  Debian: sudo apt-get install python3
  Or install from source instead: $DOCS_URL"
fi

# ---------------------------------------------------------------- platform ---

case "$(uname -s)" in
  Linux) PLATFORM_OS="linux" ;;
  Darwin) PLATFORM_OS="darwin" ;;
  *) PLATFORM_OS="" ;;
esac

case "$(uname -m)" in
  x86_64|amd64) PLATFORM_ARCH="x86_64" ;;
  arm64|aarch64) PLATFORM_ARCH="arm64" ;;
  *) PLATFORM_ARCH="" ;;
esac

if [ -z "$PLATFORM_OS" ] || [ -z "$PLATFORM_ARCH" ]; then
  die "no prebuilt Lemon release for $(uname -s) $(uname -m).
  Supported: linux-x86_64, linux-arm64, darwin-arm64.
  Install from source instead: $SOURCE_URL (see $DOCS_URL)"
fi

PLATFORM="$PLATFORM_OS-$PLATFORM_ARCH"

case "$PLATFORM" in
  linux-x86_64|linux-arm64|darwin-arm64) ;;
  *)
    die "no prebuilt Lemon release for $PLATFORM.
  Supported: linux-x86_64, linux-arm64, darwin-arm64.
  Install from source instead: $SOURCE_URL (see $DOCS_URL)"
    ;;
esac

check_glibc() {
  [ "$PLATFORM_OS" = "linux" ] || return 0
  [ "${LEMON_INSTALL_IGNORE_GLIBC:-0}" != "1" ] || return 0

  if ! command -v getconf >/dev/null 2>&1; then
    warn "cannot detect the C library (getconf missing); Linux tarballs are built against glibc ${GLIBC_MIN_MAJOR}.${GLIBC_MIN_MINOR}. Continuing."
    return 0
  fi

  glibc_version="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
  if [ -z "$glibc_version" ]; then
    warn "no glibc detected (musl or another libc?). Lemon Linux tarballs are built against glibc ${GLIBC_MIN_MAJOR}.${GLIBC_MIN_MINOR} and may not run here. Continuing."
    return 0
  fi

  # "glibc 2.39" -> "2.39"
  glibc_version="${glibc_version##* }"
  glibc_major="${glibc_version%%.*}"
  glibc_rest="${glibc_version#*.}"
  glibc_minor="${glibc_rest%%.*}"

  case "$glibc_major$glibc_minor" in
    *[!0-9]*|"")
      warn "could not parse glibc version '$glibc_version'; expected at least ${GLIBC_MIN_MAJOR}.${GLIBC_MIN_MINOR}. Continuing."
      return 0
      ;;
  esac

  if [ "$glibc_major" -lt "$GLIBC_MIN_MAJOR" ] ||
    { [ "$glibc_major" -eq "$GLIBC_MIN_MAJOR" ] && [ "$glibc_minor" -lt "$GLIBC_MIN_MINOR" ]; }; then
    warn "glibc $glibc_version is older than the ${GLIBC_MIN_MAJOR}.${GLIBC_MIN_MINOR} baseline Lemon Linux tarballs are built against. The runtime will probably fail to start. Install from source ($DOCS_URL) or set LEMON_INSTALL_IGNORE_GLIBC=1 to silence this warning. Continuing."
  fi
}

check_glibc

# ----------------------------------------------------------------- profile ---

case "$PROFILE_INPUT" in
  full|lemon_runtime_full) PROFILE="lemon_runtime_full" ;;
  min|lemon_runtime_min) PROFILE="lemon_runtime_min" ;;
  sim|sim_broadcast_platform) PROFILE="sim_broadcast_platform" ;;
  lemon_bot) PROFILE="lemon_bot" ;;
  *)
    die "unknown LEMON_PROFILE '$PROFILE_INPUT'.
  Use full, min, sim, lemon_bot, or a full runtime profile name."
    ;;
esac

if [ "$REQUIRE_BOT" = "1" ] && [ "$PROFILE" != "lemon_runtime_full" ] && [ "$PROFILE" != "lemon_runtime_min" ]; then
  die "--require-bot needs a bot-capable native runtime (full or min); the $PROFILE profile cannot host a Lemon Bot worker."
fi

if [ "$PROFILE" = "sim_broadcast_platform" ] && [ "$PLATFORM_OS" != "linux" ]; then
  die "the sim_broadcast_platform profile is built for Linux only; $PLATFORM has no such artifact."
fi

# --------------------------------------------------------------- manifest ----

BASE_URL="${BASE_URL%/}"
case "$BASE_URL" in
  https://*) INSECURE_BASE=0 ;;
  http://*)
    INSECURE_BASE=1
    warn "using a plain-HTTP base URL: $BASE_URL"
    ;;
  *) die "LEMON_INSTALL_BASE_URL must start with http:// or https://: $BASE_URL" ;;
esac

if [ -n "$PIN" ]; then
  MANIFEST_URL="$BASE_URL/releases/download/v$PIN/manifest.json"
  DOWNLOAD_BASE="$BASE_URL/releases/download/v$PIN"
elif [ "$CHANNEL" = "stable" ]; then
  MANIFEST_URL="$BASE_URL/releases/latest/download/manifest.json"
  DOWNLOAD_BASE="$BASE_URL/releases/latest/download"
else
  die "channel '$CHANNEL' needs an explicit version.
  Preview and nightly releases are not discoverable without the GitHub API, so
  set LEMON_VERSION to the exact version you want, e.g.
  LEMON_VERSION=2026.08.0 LEMON_CHANNEL=$CHANNEL sh install.sh"
fi

# An exact pin identifies the release; its manifest is the authority for that
# release's channel. Only an explicit LEMON_CHANNEL is enforced against it.
EXPECT_CHANNEL="$CHANNEL"
CHANNEL_LABEL="channel $CHANNEL"
if [ -n "$PIN" ] && [ "$CHANNEL_EXPLICIT" != "1" ]; then
  EXPECT_CHANNEL=""
  CHANNEL_LABEL="pinned $PIN"
fi

fetch() {
  # fetch <url> <destination> [progress]
  # Only release artifacts show curl's one-line progress bar, and only on a
  # terminal; everything else is silent apart from errors.
  curl_output="-sS"
  if [ "${3:-}" = "progress" ] && [ -t 2 ]; then
    curl_output="--progress-bar"
  fi
  if [ "$INSECURE_BASE" = "1" ]; then
    curl "$curl_output" -fL --retry 3 --connect-timeout 10 -o "$2" "$1"
  else
    curl "$curl_output" -fL --proto '=https' --retry 3 --connect-timeout 10 -o "$2" "$1"
  fi
}

select_artifact() {
  # select_artifact <manifest-path> <profile> [allow-missing]
  #
  # Prints "<file>\t<sha256>\t<size>\t<version>\t<channel>" for the artifact
  # matching this platform and the requested profile, selecting on structured
  # manifest fields rather than the filename. With allow-missing set to 1 a
  # manifest that publishes no such artifact prints nothing and succeeds, so
  # optional artifacts (the TUI) can be looked up in the same manifest.
  MANIFEST_PATH="$1" WANT_PROFILE="$2" ALLOW_MISSING="${3:-0}" \
    WANT_PLATFORM="$PLATFORM" WANT_CHANNEL="$EXPECT_CHANNEL" WANT_VERSION="$PIN" python3 - <<'PY'
import json
import os
import re
import sys

path = os.environ["MANIFEST_PATH"]
want_platform = os.environ["WANT_PLATFORM"]
want_profile = os.environ["WANT_PROFILE"]
want_channel = os.environ["WANT_CHANNEL"]
want_version = os.environ["WANT_VERSION"]
allow_missing = os.environ.get("ALLOW_MISSING") == "1"


def fail(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


try:
    with open(path, "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
except (OSError, ValueError) as error:
    fail(f"release manifest is not readable JSON: {error}")

if not isinstance(manifest, dict):
    fail("release manifest is not a JSON object")

schema = manifest.get("schema")
if schema != 2:
    fail(
        f"unsupported release manifest schema {schema!r}; this installer understands "
        "schema 2. Update install.sh from the repository."
    )

version = manifest.get("version")
channel = manifest.get("channel")
if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
    fail("release manifest has no safe version")
if not isinstance(channel, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", channel):
    fail("release manifest has no safe channel")

if want_version and want_version != version:
    fail(f"requested version {want_version} but the manifest publishes {version}")
if want_channel and want_channel != channel:
    fail(
        f"requested channel {want_channel} but the manifest publishes {channel}; "
        "set LEMON_CHANNEL to match or pin LEMON_VERSION"
    )

artifacts = manifest.get("artifacts")
if not isinstance(artifacts, list) or not artifacts:
    fail("release manifest has no artifacts")

matches = [
    artifact
    for artifact in artifacts
    if isinstance(artifact, dict)
    and artifact.get("platform") == want_platform
    and artifact.get("profile") == want_profile
]

if not matches and allow_missing:
    raise SystemExit(0)

if not matches:
    available = sorted(
        {
            f"{artifact.get('profile')}/{artifact.get('platform')}"
            for artifact in artifacts
            if isinstance(artifact, dict)
        }
    )
    fail(
        f"no {want_profile} artifact for {want_platform} in Lemon {version} ({channel}). "
        "Published: " + ", ".join(available)
    )

if len(matches) > 1:
    fail(f"release manifest has {len(matches)} entries for {want_profile}/{want_platform}")

artifact = matches[0]
filename = artifact.get("file")
sha256 = artifact.get("sha256")
size = artifact.get("size")

if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", filename):
    fail(f"artifact file must be a safe bare filename: {filename!r}")
if not isinstance(sha256, str) or not re.fullmatch(r"[0-9a-fA-F]{64}", sha256):
    fail(f"artifact {filename} has no hexadecimal sha256")
if type(size) is not int or size <= 0:
    fail(f"artifact {filename} has no positive size")
if want_profile == "lemon_bot":
    expected = f"lemon-{version}-{channel}-{want_platform}-lemon_bot.tar.gz"
    if filename != expected:
        fail(f"backend artifact must be named {expected}")
    os_name, arch = want_platform.split("-", 1)
    if artifact.get("os") != os_name or artifact.get("arch") != arch:
        fail("backend artifact OS/architecture does not match platform")

print("\t".join([filename, sha256.lower(), str(size), version, channel]))
PY
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    python3 -c 'import hashlib,sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())' "$1"
  fi
}

atomic_symlink() {
  # atomic_symlink <target> <link-path>
  #
  # rename(2) via python3 rather than `mv -f`: when the destination is an
  # existing symlink pointing at a directory, both GNU and BSD mv move the
  # source *into* that directory instead of replacing the link. os.replace
  # renames the link itself and is atomic.
  python3 -c 'import os, sys
target, link = sys.argv[1], sys.argv[2]
staging = link + ".tmp." + str(os.getpid())
try:
    os.remove(staging)
except FileNotFoundError:
    pass
os.symlink(target, staging)
os.replace(staging, link)' "$1" "$2"
}

validate_bot_archive() {
  python3 - "$1" <<'PY'
import posixpath
import sys
import tarfile

try:
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        members = archive.getmembers()
        seen = set()
        links = set()
        for member in members:
            name = member.name
            while name.startswith("./"):
                name = name[2:]
            name = name.rstrip("/")
            if name in ("", ".") and member.isdir():
                continue
            parts = name.split("/")
            if name.startswith("/") or any(p in ("", ".", "..") for p in parts):
                raise ValueError(f"unsafe archive path: {member.name}")
            if parts[0] != "bot" or name in seen:
                raise ValueError(f"unexpected or duplicate archive path: {name}")
            seen.add(name)
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError(f"unsupported archive member: {name}")
            if member.issym():
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
                if member.linkname.startswith("/") or not target.startswith("bot/"):
                    raise ValueError(f"escaping archive symlink: {name}")
                links.add(name)
        for name in seen:
            parts = name.split("/")
            if any("/".join(parts[:i]) in links for i in range(1, len(parts))):
                raise ValueError(f"archive member traverses a symlink: {name}")
        if "bot/bin/lemon-bot" in links:
            raise ValueError("backend binary must be a regular file")
except (OSError, tarfile.TarError, ValueError) as error:
    print(f"error: unsafe backend archive: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

verify_bot() {
  python3 - "$1" "$VERSION" "$VERIFY" "$PLATFORM" <<'PY'
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

root = Path(sys.argv[1]).resolve()
binary = root / "bot/bin/lemon-bot"
try:
    if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("backend has no regular executable bot/bin/lemon-bot")
    if not (root / "bot/web").is_dir() or not any((root / "bot/web").rglob("*")):
        raise ValueError("backend has no web assets")
    native_platform = {"linux-x86_64": "linux-x64", "linux-arm64": "linux-arm64", "darwin-arm64": "darwin-arm64"}[sys.argv[4]]
    native_root = root / f"bot/node_modules/@img/sharp-{native_platform}"
    libvips_root = root / f"bot/node_modules/@img/sharp-libvips-{native_platform}"
    if not (native_root / "package.json").is_file() or not (libvips_root / "package.json").is_file():
        raise ValueError("backend has no host-native image runtime dependencies")
    if not (native_root / f"lib/sharp-{native_platform}.node").is_file():
        raise ValueError("backend has no host-native image addon")
    with tempfile.TemporaryDirectory() as home, tempfile.TemporaryFile() as output:
        result = subprocess.run(
            [str(binary), "--version"], cwd=home,
            env={"HOME": home, "PATH": "/usr/bin:/bin"},
            stdout=output, stderr=subprocess.DEVNULL, timeout=15,
        )
        output.seek(0)
        reported = output.read(256)
    if result.returncode or reported != f"lemon-bot {sys.argv[2]}\n".encode():
        raise ValueError("backend --version did not report the manifest version")
    if sys.argv[3] == "1":
        def free_port():
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", 0))
                return sock.getsockname()[1]
        port, control_port = free_port(), free_port()
        with tempfile.TemporaryDirectory() as home:
            environment = {
                "HOME": home, "PATH": "/usr/bin:/bin",
                "LEMON_BOT_HOST": "127.0.0.1", "LEMON_BOT_PORT": str(port),
                "LEMON_BOT_DATA_DIR": f"{home}/.lemon/lemon_bot",
                "LEMON_BOT_CONTROL_URL": f"ws://127.0.0.1:{control_port}/ws",
                "LEMON_BOT_OPERATOR_TOKEN": secrets.token_hex(32),
                "LEMON_BOT_PUBLIC_URL": f"http://127.0.0.1:{port}",
            }
            process = subprocess.Popen([str(binary)], cwd=home, env=environment,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                deadline = time.monotonic() + 30
                ready = False
                while time.monotonic() < deadline and process.poll() is None:
                    try:
                        for route in ("/v1/setup", "/"):
                            with urllib.request.urlopen(
                                f"http://127.0.0.1:{port}{route}", timeout=1
                            ) as response:
                                if response.status != 200 or not response.read(1):
                                    raise ValueError(f"backend {route} is not ready")
                        ready = True
                        break
                    except (OSError, ValueError):
                        time.sleep(0.2)
                if not ready:
                    raise ValueError("backend did not serve /v1/setup and web assets")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
except (OSError, ValueError, subprocess.TimeoutExpired) as error:
    print(f"error: {error}; refusing to promote backend", file=sys.stderr)
    raise SystemExit(1)
PY
}

# ------------------------------------------------------------------ layout ---

LEMON_ROOT="$HOME/.lemon"
VERSIONS_DIR="$LEMON_ROOT/versions"
BIN_DIR="$LEMON_ROOT/bin"
TMP_DIR="$LEMON_ROOT/tmp"
CURRENT_LINK="$VERSIONS_DIR/current"
LAUNCHER="lemon"
LAUNCHER_TARGET="../versions/current/bin/lemon"
if [ "$PROFILE" = "lemon_bot" ]; then
  LEMON_ROOT="$HOME/.lemon/lemon_bot"
  VERSIONS_DIR="$LEMON_ROOT/versions"
  BIN_DIR="$HOME/.local/bin"
  TMP_DIR="$LEMON_ROOT/tmp"
  CURRENT_LINK="$LEMON_ROOT/current"
  LAUNCHER="lemon-bot"
  LAUNCHER_TARGET="$CURRENT_LINK/bot/bin/lemon-bot"
fi

mkdir -p "$VERSIONS_DIR" "$BIN_DIR" "$TMP_DIR"
if [ "$PROFILE" != "lemon_bot" ]; then
  mkdir -p "$LEMON_ROOT/run" "$LEMON_ROOT/store"
fi

# ----------------------------------------------------------------- cleanup ---
#
# Every path the install creates before it commits is registered here, so an
# error, a Ctrl-C, or a SIGTERM cannot leave downloads, a half-extracted
# staging directory, or an orphaned .previous copy behind. The last of those
# matters most: if the interrupt lands between moving the old version aside and
# moving the new one in, `versions/current` points at nothing, and only this
# handler can put it back.

INSTALL_COMMITTED=0
CLEANUP_TARBALL=""
CLEANUP_TUI_TARBALL=""
CLEANUP_PARTIAL=""
CLEANUP_PREVIOUS=""
CLEANUP_TARGET=""

cleanup() {
  if [ "$INSTALL_COMMITTED" = "1" ]; then
    return 0
  fi

  if [ -n "$CLEANUP_TARBALL" ]; then
    rm -f "$CLEANUP_TARBALL"
  fi

  if [ -n "$CLEANUP_TUI_TARBALL" ]; then
    rm -f "$CLEANUP_TUI_TARBALL"
  fi

  if [ -n "$CLEANUP_PARTIAL" ]; then
    rm -rf "$CLEANUP_PARTIAL"
  fi

  if [ -n "$CLEANUP_PREVIOUS" ] && [ -d "$CLEANUP_PREVIOUS" ]; then
    if [ -n "$CLEANUP_TARGET" ] && [ ! -d "$CLEANUP_TARGET" ]; then
      mv "$CLEANUP_PREVIOUS" "$CLEANUP_TARGET" || true
    else
      rm -rf "$CLEANUP_PREVIOUS"
    fi
  fi

  return 0
}

trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

ensure_links() {
  # ensure_links <version>
  atomic_symlink "$1" "$CURRENT_LINK"

  if [ ! -L "$BIN_DIR/$LAUNCHER" ] || [ "$(readlink "$BIN_DIR/$LAUNCHER")" != "$LAUNCHER_TARGET" ]; then
    atomic_symlink "$LAUNCHER_TARGET" "$BIN_DIR/$LAUNCHER"
  fi
}

# path_hint records, rather than prints, the PATH advice so the installer can
# end with it after setup.
PATH_NOTE=""
path_hint() {
  case ":${PATH:-}:" in
    *":$BIN_DIR:"*) return 0 ;;
  esac

  shell_name="$(basename "${SHELL:-sh}")"
  case "$shell_name" in
    fish)
      rc_file="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"
      path_line="fish_add_path $BIN_DIR"
      ;;
    zsh)
      rc_file="$HOME/.zshrc"
      path_line="export PATH=\"$BIN_DIR:\$PATH\""
      ;;
    bash)
      rc_file="$HOME/.bashrc"
      path_line="export PATH=\"$BIN_DIR:\$PATH\""
      ;;
    *)
      rc_file=""
      path_line="export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac

  if [ "$MODIFY_PATH" = "1" ] && [ -n "$rc_file" ]; then
    if [ ! -f "$rc_file" ] || ! grep -Fqx "$path_line" "$rc_file"; then
      mkdir -p "$(dirname "$rc_file")"
      {
        printf '\n# added by the lemon installer\n'
        printf '%s\n' "$path_line"
      } >>"$rc_file"
    fi
    PATH_NOTE="New shells will find lemon. To use it in this shell, run: $path_line"
    return 0
  fi

  PATH_NOTE="$BIN_DIR is not on your PATH. Add it with: $path_line"
}

free_port() {
  python3 -c 'import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()'
}

verify_boot() (
  if [ "$PROFILE" = "lemon_bot" ]; then
    return
  fi
  control_port="$(free_port)"
  web_port="$(free_port)"
  sim_port="$(free_port)"
  gateway_health_port="$(free_port)"
  router_health_port="$(free_port)"
  verify_node="lemon_install_verify_$$_$control_port"
  verify_home="$(mktemp -d "$TMP_DIR/verify.XXXXXX")"
  # A smoke boot must not share the operator's Store, agents, daemon identity,
  # process records, or release pipe/log directory.
  export HOME="$verify_home" LEMON_STORE_PATH="$verify_home/.lemon/store"
  export LEMON_AGENT_DIR="$verify_home/.lemon/agent" LEMON_DOTENV_DIR="$verify_home"
  export RELEASE_TMP="$verify_home/runtime" RELEASE_NODE="$verify_node"
  export LEMON_CONTROL_PLANE_PORT="$control_port"
  trap '"$BIN_DIR/lemon" stop >/dev/null 2>&1 || true; rm -rf "$verify_home"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cd "$verify_home"

  info "Verifying: booting the runtime on port $control_port ..."

  if ! LEMON_CONTROL_PLANE_PORT="$control_port" \
    LEMON_WEB_PORT="$web_port" \
    LEMON_SIM_UI_PORT="$sim_port" \
    LEMON_GATEWAY_HEALTH_PORT="$gateway_health_port" \
    LEMON_ROUTER_HEALTH_PORT="$router_health_port" \
    RELEASE_NODE="$verify_node" \
    "$BIN_DIR/lemon" daemon; then
    die "the installed runtime failed to start. Files are in $VERSIONS_DIR."
  fi

  healthy=0
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if curl -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$control_port/healthz" 2>/dev/null; then
      healthy=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 2
  done


  if [ "$healthy" != "1" ]; then

    die "the runtime started but /healthz never became ready on port $control_port."
  fi

  info "ok runtime booted and answered /healthz"
)

# verify_bot_runtime <release-dir>
#
# --require-bot asks the staged runtime itself, never the manifest, whether it
# can host a Lemon Bot worker: it must report the manifest's exact version and
# every required worker API. It runs in a throwaway HOME so a candidate that is
# not promoted yet cannot touch the operator's ~/.lemon state.
verify_bot_runtime() (
  [ -x "$1/bin/lemon" ] || return 1
  check_home="$(mktemp -d "$TMP_DIR/botcheck.XXXXXX")" || return 1
  check_errors="$check_home/errors"
  trap 'rm -rf "$check_home"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  unset RELEASE_ROOT RELEASE_VSN RELEASE_NAME RELEASE_PROG RELEASE_COMMAND RELEASE_MODE
  export HOME="$check_home" LEMON_STORE_PATH="$check_home/.lemon/store"
  export LEMON_AGENT_DIR="$check_home/.lemon/agent" LEMON_DOTENV_DIR="$check_home"
  export RELEASE_TMP="$check_home/runtime"
  cd "$check_home"
  if "$1/bin/lemon" node capabilities --json --require-bot --expected-version "$VERSION" \
    >/dev/null 2>"$check_errors"; then
    return 0
  fi
  cat "$check_errors" >&2
  return 1
)
setup_handoff() {
  if [ "$PROFILE" = "lemon_bot" ]; then
    info "Start lemon-bot with LEMON_BOT_CONTROL_URL and LEMON_BOT_OPERATOR_TOKEN configured."
    info "Backend state: $HOME/.lemon/lemon_bot (override with LEMON_BOT_DATA_DIR)."
  elif [ "$PROFILE" = "sim_broadcast_platform" ]; then
    info "Setup is not available for the sim profile."
  elif [ "$SKIP_SETUP" = "1" ]; then
    info "Setup skipped. Run this when you are ready to configure Lemon:"
    info "    $BIN_DIR/lemon setup"
  elif (exec </dev/tty) 2>/dev/null; then
    info ""
    if ! "$BIN_DIR/lemon" setup </dev/tty; then
      die "Lemon setup did not complete. The runtime remains installed at $TARGET_DIR. Re-run: $BIN_DIR/lemon setup"
    fi
  else
    info "No interactive terminal is available. Run this when you are ready to configure Lemon:"
    info "    $BIN_DIR/lemon setup"
  fi
}

finish() {
  info ""
  if [ "$PROFILE" = "lemon_bot" ]; then
    info "Run lemon-bot to start the standalone backend."
  elif [ -x "$CURRENT_LINK/tui/bin/lemon-tui" ]; then
    info "Run lemon to start."
  else
    info "Run lemon --help to see available commands."
  fi
  if [ -n "$PATH_NOTE" ]; then
    info "$PATH_NOTE"
  fi
}

# ----------------------------------------------------------------- install ---

manifest_file="$TMP_DIR/manifest.json"
if ! fetch "$MANIFEST_URL" "$manifest_file"; then
  rm -f "$manifest_file"
  die "could not download the release manifest: $MANIFEST_URL
  Check the version/channel, or install from source: $DOCS_URL"
fi

artifact_line=""
if ! artifact_line="$(select_artifact "$manifest_file" "$PROFILE")"; then
  rm -f "$manifest_file"
  exit 1
fi

if [ "$RESOLVE_VERSION" = "1" ]; then
  rm -f "$manifest_file"
  printf '%s\n' "$artifact_line" | cut -f4
  exit 0
fi

# The TUI is a second, optional artifact in the same manifest: a separate
# per-platform tarball that unpacks into tui/ next to the runtime's bin/.
# The sim profile has no terminal UI, LEMON_NO_TUI=1 opts out, and a bot worker
# host (--require-bot) is headless.
WANT_TUI=1
if [ "$PROFILE" = "lemon_bot" ] || [ "$PROFILE" = "sim_broadcast_platform" ] || [ "${LEMON_NO_TUI:-0}" = "1" ] || [ "$REQUIRE_BOT" = "1" ]; then
  WANT_TUI=0
fi

tui_line=""
if [ "$WANT_TUI" = "1" ]; then
  if ! tui_line="$(select_artifact "$manifest_file" "lemon_tui" 1)"; then
    rm -f "$manifest_file"
    exit 1
  fi
fi

rm -f "$manifest_file"

ARTIFACT_FILE="$(printf '%s\n' "$artifact_line" | cut -f1)"
ARTIFACT_SHA="$(printf '%s\n' "$artifact_line" | cut -f2)"
ARTIFACT_SIZE="$(printf '%s\n' "$artifact_line" | cut -f3)"
VERSION="$(printf '%s\n' "$artifact_line" | cut -f4)"
RESOLVED_CHANNEL="$(printf '%s\n' "$artifact_line" | cut -f5)"

TUI_FILE=""
TUI_SHA=""
TUI_SIZE=""
if [ -n "$tui_line" ]; then
  TUI_FILE="$(printf '%s\n' "$tui_line" | cut -f1)"
  TUI_SHA="$(printf '%s\n' "$tui_line" | cut -f2)"
  TUI_SIZE="$(printf '%s\n' "$tui_line" | cut -f3)"
elif [ "$WANT_TUI" = "1" ]; then
  warn "this release has no TUI artifact for $PLATFORM; installing runtime only"
fi

# Only non-default channels and profiles are worth naming in progress output.
INSTALL_LABEL="Lemon $VERSION"
install_qualifiers=""
if [ "$RESOLVED_CHANNEL" != "stable" ]; then
  install_qualifiers="$RESOLVED_CHANNEL"
fi
if [ "$PROFILE" != "lemon_runtime_full" ]; then
  install_qualifiers="${install_qualifiers:+$install_qualifiers, }$PROFILE"
fi
if [ -n "$install_qualifiers" ]; then
  INSTALL_LABEL="$INSTALL_LABEL ($install_qualifiers)"
fi

TARGET_DIR="$VERSIONS_DIR/$VERSION"
INSTALL_KEY="$VERSION"
if [ "$PROFILE" = "lemon_bot" ]; then
  INSTALL_KEY="$VERSION-$RESOLVED_CHANNEL-$PLATFORM"
  TARGET_DIR="$VERSIONS_DIR/$INSTALL_KEY"
fi

if [ -d "$TARGET_DIR" ] && [ "$FORCE" != "1" ]; then
  if [ "$REQUIRE_BOT" = "1" ] && ! verify_bot_runtime "$TARGET_DIR"; then
    die "the installed Lemon $VERSION at $TARGET_DIR does not report the required bot worker APIs.
  Re-run with --force to reinstall it from the release."
  fi
  if [ "$PROFILE" = "lemon_bot" ]; then
    verify_bot "$TARGET_DIR"
  fi
  if [ "$PROFILE" = "lemon_bot" ]; then
    ensure_links "versions/$INSTALL_KEY"
  else
    ensure_links "$INSTALL_KEY"
  fi
  if [ -n "$TUI_FILE" ] && [ ! -x "$TARGET_DIR/tui/bin/lemon-tui" ]; then
    info "$INSTALL_LABEL is already installed without the terminal UI, but $VERSION publishes one. Re-run with --force to reinstall it."
  else
    info "$INSTALL_LABEL is already installed. Re-run with --force to reinstall it."
  fi

  if [ "$VERIFY" = "1" ]; then
    verify_boot
  fi

  path_hint
  setup_handoff
  finish
  exit 0
fi

tarball="$TMP_DIR/$ARTIFACT_FILE"
CLEANUP_TARBALL="$tarball"
rm -f "$tarball"

info "Installing $INSTALL_LABEL ..."
if ! fetch "$DOWNLOAD_BASE/$ARTIFACT_FILE" "$tarball" progress; then
  rm -f "$tarball"
  die "could not download $DOWNLOAD_BASE/$ARTIFACT_FILE"
fi

actual_size="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$tarball")"
if [ "$actual_size" != "$ARTIFACT_SIZE" ]; then
  die "size mismatch for $ARTIFACT_FILE: expected $ARTIFACT_SIZE, actual $actual_size"
fi
actual_sha="$(sha256_of "$tarball")"
if [ "$actual_sha" != "$ARTIFACT_SHA" ]; then
  rm -f "$tarball"
  die "checksum mismatch for $ARTIFACT_FILE
  expected $ARTIFACT_SHA
  actual   $actual_sha
  Nothing was installed."
fi

# Both tarballs are downloaded and verified before either is extracted: a bad
# TUI download must not leave a half-installed version behind.
tui_tarball=""
if [ -n "$TUI_FILE" ]; then
  tui_tarball="$TMP_DIR/$TUI_FILE"
  CLEANUP_TUI_TARBALL="$tui_tarball"
  rm -f "$tui_tarball"

  if ! fetch "$DOWNLOAD_BASE/$TUI_FILE" "$tui_tarball" progress; then
    rm -f "$tarball" "$tui_tarball"
    die "could not download $DOWNLOAD_BASE/$TUI_FILE
  Nothing was installed. Set LEMON_NO_TUI=1 to install the runtime only."
  fi

  actual_sha="$(sha256_of "$tui_tarball")"
  if [ "$actual_sha" != "$TUI_SHA" ]; then
    rm -f "$tarball" "$tui_tarball"
    die "checksum mismatch for $TUI_FILE
  expected $TUI_SHA
  actual   $actual_sha
  Nothing was installed."
  fi
fi

partial_dir="$TARGET_DIR.partial"
CLEANUP_PARTIAL="$partial_dir"
rm -rf "$partial_dir"
mkdir -p "$partial_dir"

if [ "$PROFILE" = "lemon_bot" ]; then
  validate_bot_archive "$tarball"
fi
if ! tar -xzf "$tarball" -C "$partial_dir"; then
  rm -rf "$partial_dir"
  rm -f "$tarball"
  if [ -n "$tui_tarball" ]; then
    rm -f "$tui_tarball"
  fi
  die "could not extract $ARTIFACT_FILE"
fi

rm -f "$tarball"

# The runtime owns bin/ and lib/, the TUI owns tui/ — no collisions, so both
# unpack into the same staging directory and ride the one rename below.
if [ -n "$tui_tarball" ]; then
  if ! tar -xzf "$tui_tarball" -C "$partial_dir"; then
    rm -rf "$partial_dir"
    rm -f "$tui_tarball"
    die "could not extract $TUI_FILE"
  fi
  rm -f "$tui_tarball"
fi

if [ "$PROFILE" = "lemon_bot" ]; then
  verify_bot "$partial_dir"
elif [ ! -x "$partial_dir/bin/lemon" ]; then
  rm -rf "$partial_dir"
  die "the release tarball has no executable bin/lemon launcher; refusing to install it."
fi

if [ -n "$TUI_FILE" ] && [ ! -x "$partial_dir/tui/bin/lemon-tui" ]; then
  rm -rf "$partial_dir"
  die "the TUI tarball has no executable tui/bin/lemon-tui; refusing to install it.
  Set LEMON_NO_TUI=1 to install the runtime only."
fi

if [ "$REQUIRE_BOT" = "1" ] && ! verify_bot_runtime "$partial_dir"; then
  rm -rf "$partial_dir"
  die "Lemon $VERSION does not report the required bot worker APIs; refusing to install it.
  The previously installed runtime, if any, was left untouched."
fi

# A directory swap is two renames, and POSIX offers no way to make that one
# step. The old copy is therefore moved aside rather than deleted, restored if
# the second rename fails, and only discarded once versions/current has been
# flipped onto the new one.
previous_dir=""

if [ -d "$TARGET_DIR" ]; then
  previous_dir="$TARGET_DIR.previous.$$"
  rm -rf "$previous_dir"
  CLEANUP_PREVIOUS="$previous_dir"
  CLEANUP_TARGET="$TARGET_DIR"

  mv "$TARGET_DIR" "$previous_dir"

  if ! mv "$partial_dir" "$TARGET_DIR"; then
    mv "$previous_dir" "$TARGET_DIR"
    CLEANUP_PREVIOUS=""
    rm -rf "$partial_dir"
    CLEANUP_PARTIAL=""
    die "could not move the staged install into $TARGET_DIR; the previous version was restored."
  fi
else
  mv "$partial_dir" "$TARGET_DIR"
fi

CLEANUP_PARTIAL=""

if [ "$PLATFORM_OS" = "darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$TARGET_DIR" >/dev/null 2>&1 || true
fi

if [ "$PROFILE" = "lemon_bot" ]; then
  ensure_links "versions/$INSTALL_KEY"
else
  ensure_links "$INSTALL_KEY"
fi

# Past this point the install is live: versions/current resolves to the new
# tree, so the leftovers below are garbage rather than a rollback path.
INSTALL_COMMITTED=1

if [ -n "$previous_dir" ]; then
  rm -rf "$previous_dir"
  CLEANUP_PREVIOUS=""
fi

info "Installed $INSTALL_LABEL"
if [ "$PROFILE" = "lemon_bot" ]; then
  info "  state: $HOME/.lemon/lemon_bot"
elif ! "$BIN_DIR/lemon" version >/dev/null 2>&1; then
  warn "'$BIN_DIR/lemon version' did not succeed. Run it directly to see why."
fi

if [ "$VERIFY" = "1" ]; then
  verify_boot
fi

path_hint
setup_handoff
finish
