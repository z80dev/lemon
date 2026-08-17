#!/bin/sh
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
# POSIX sh: no bashisms, no arrays, no [[ ]], no local.
set -eu

DEFAULT_BASE_URL="https://github.com/z80dev/lemon"
DOCS_URL="https://github.com/z80dev/lemon/blob/main/docs/install.md"
SOURCE_URL="https://github.com/z80dev/lemon"
GLIBC_MIN_MAJOR=2
GLIBC_MIN_MINOR=39

FORCE=0
VERIFY=0
MODIFY_PATH=0

BASE_URL="${LEMON_INSTALL_BASE_URL:-$DEFAULT_BASE_URL}"
CHANNEL="${LEMON_CHANNEL:-stable}"
PIN="${LEMON_VERSION:-}"
PROFILE_INPUT="${LEMON_PROFILE:-lemon_runtime_full}"

usage() {
  cat <<EOF
Lemon installer

Usage:
  curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
  sh install.sh [--force] [--verify] [--modify-path] [--help]

Options:
  --force         Reinstall even if the target version is already present.
  --verify        Boot the installed runtime on ephemeral ports, poll /healthz,
                  then stop it. Fails the install if the smoke check fails.
  --modify-path   Append the PATH export to your shell rc file. Without it the
                  installer only prints the line for you to add.
  --help          Show this help.

Prerequisites:
  curl, tar, and python3. python3 parses the release manifest and performs the
  atomic symlink flip; there is no jq dependency. Install it with
  \`xcode-select --install\` on macOS or your distribution's python3 package.

Environment:
  LEMON_VERSION               Pin an exact version, e.g. 2026.08.0. Required for
                              any channel other than stable.
  LEMON_CHANNEL               Release channel (default: stable).
  LEMON_PROFILE               full | min | sim, or a full profile name
                              (lemon_runtime_full, lemon_runtime_min,
                              sim_broadcast_platform). Default: lemon_runtime_full.
  LEMON_NO_TUI                Set to 1 to install the runtime only, skipping the
                              terminal UI (\`lemon-tui\`). Roughly halves the
                              download. The sim profile never ships a TUI.
  LEMON_INSTALL_IGNORE_GLIBC  Set to 1 to silence the Linux glibc baseline check.
  LEMON_INSTALL_BASE_URL      Override the GitHub release base URL (test seam).

Installs into \$HOME/.lemon. Docs: $DOCS_URL
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
  *)
    die "unknown LEMON_PROFILE '$PROFILE_INPUT'.
  Use full, min, sim, or a profile name (lemon_runtime_full, lemon_runtime_min, sim_broadcast_platform)."
    ;;
esac

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

fetch() {
  # fetch <url> <destination>
  if [ "$INSECURE_BASE" = "1" ]; then
    curl -fL --retry 3 --connect-timeout 10 -o "$2" "$1"
  else
    curl -fL --proto '=https' --retry 3 --connect-timeout 10 -o "$2" "$1"
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
    WANT_PLATFORM="$PLATFORM" WANT_CHANNEL="$CHANNEL" WANT_VERSION="$PIN" python3 - <<'PY'
import json
import os
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
if not isinstance(version, str) or not version:
    fail("release manifest has no version")
if not isinstance(channel, str) or not channel:
    fail("release manifest has no channel")

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

if not isinstance(filename, str) or not filename or "/" in filename:
    fail(f"artifact file must be a bare filename: {filename!r}")
if not isinstance(sha256, str) or len(sha256) != 64:
    fail(f"artifact {filename} has no 64-character sha256")
if not isinstance(size, int) or size <= 0:
    fail(f"artifact {filename} has no positive size")

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

# ------------------------------------------------------------------ layout ---

LEMON_ROOT="$HOME/.lemon"
VERSIONS_DIR="$LEMON_ROOT/versions"
BIN_DIR="$LEMON_ROOT/bin"
TMP_DIR="$LEMON_ROOT/tmp"

mkdir -p "$VERSIONS_DIR" "$BIN_DIR" "$TMP_DIR" "$LEMON_ROOT/run" "$LEMON_ROOT/store"

ensure_links() {
  # ensure_links <version>
  atomic_symlink "$1" "$VERSIONS_DIR/current"

  if [ ! -L "$BIN_DIR/lemon" ] || [ "$(readlink "$BIN_DIR/lemon")" != "../versions/current/bin/lemon" ]; then
    atomic_symlink "../versions/current/bin/lemon" "$BIN_DIR/lemon"
  fi
}

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
    if [ -f "$rc_file" ] && grep -q '# added by the lemon installer' "$rc_file"; then
      info "PATH entry already present in $rc_file"
    else
      mkdir -p "$(dirname "$rc_file")"
      {
        printf '\n# added by the lemon installer\n'
        printf '%s\n' "$path_line"
      } >>"$rc_file"
      info "Added $BIN_DIR to PATH in $rc_file (open a new shell to pick it up)."
    fi
    return 0
  fi

  info ""
  info "$BIN_DIR is not on your PATH. Add it with:"
  info ""
  info "    $path_line"
  info ""
  if [ -n "$rc_file" ]; then
    info "Re-run with --modify-path to append that line to $rc_file automatically."
  fi
}

free_port() {
  python3 -c 'import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()'
}

verify_boot() {
  control_port="$(free_port)"
  web_port="$(free_port)"
  sim_port="$(free_port)"

  info "Verifying: booting the runtime on port $control_port ..."

  if ! LEMON_CONTROL_PLANE_PORT="$control_port" \
    LEMON_WEB_PORT="$web_port" \
    LEMON_SIM_UI_PORT="$sim_port" \
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

  LEMON_CONTROL_PLANE_PORT="$control_port" "$BIN_DIR/lemon" stop >/dev/null 2>&1 || true

  if [ "$healthy" != "1" ]; then
    die "the runtime started but /healthz never became ready on port $control_port."
  fi

  info "ok runtime booted and answered /healthz"
}

# ----------------------------------------------------------------- install ---

info "Installing Lemon ($PROFILE, $PLATFORM, channel $CHANNEL)"

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

# The TUI is a second, optional artifact in the same manifest: a separate
# per-platform tarball that unpacks into tui/ next to the runtime's bin/.
# The sim profile has no terminal UI, and LEMON_NO_TUI=1 opts out.
WANT_TUI=1
if [ "$PROFILE" = "sim_broadcast_platform" ] || [ "${LEMON_NO_TUI:-0}" = "1" ]; then
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

TARGET_DIR="$VERSIONS_DIR/$VERSION"

if [ -d "$TARGET_DIR" ] && [ "$FORCE" != "1" ]; then
  ensure_links "$VERSION"
  info "Lemon $VERSION ($RESOLVED_CHANNEL) is already installed at $TARGET_DIR."
  if [ -n "$TUI_FILE" ] && [ ! -x "$TARGET_DIR/tui/bin/lemon-tui" ]; then
    info "This install has no terminal UI, but $VERSION publishes one."
  fi
  info "Re-run with --force to reinstall it."

  if [ "$VERIFY" = "1" ]; then
    verify_boot
  fi

  path_hint
  exit 0
fi

tarball="$TMP_DIR/$ARTIFACT_FILE"
rm -f "$tarball"

info "Downloading $ARTIFACT_FILE ($ARTIFACT_SIZE bytes) ..."
if ! fetch "$DOWNLOAD_BASE/$ARTIFACT_FILE" "$tarball"; then
  rm -f "$tarball"
  die "could not download $DOWNLOAD_BASE/$ARTIFACT_FILE"
fi

actual_sha="$(sha256_of "$tarball")"
if [ "$actual_sha" != "$ARTIFACT_SHA" ]; then
  rm -f "$tarball"
  die "checksum mismatch for $ARTIFACT_FILE
  expected $ARTIFACT_SHA
  actual   $actual_sha
  Nothing was installed."
fi
info "ok sha256 $actual_sha"

# Both tarballs are downloaded and verified before either is extracted: a bad
# TUI download must not leave a half-installed version behind.
tui_tarball=""
if [ -n "$TUI_FILE" ]; then
  tui_tarball="$TMP_DIR/$TUI_FILE"
  rm -f "$tui_tarball"

  info "Downloading $TUI_FILE ($TUI_SIZE bytes) ..."
  if ! fetch "$DOWNLOAD_BASE/$TUI_FILE" "$tui_tarball"; then
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
  info "ok sha256 $actual_sha"
fi

partial_dir="$TARGET_DIR.partial"
rm -rf "$partial_dir"
mkdir -p "$partial_dir"

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

if [ ! -x "$partial_dir/bin/lemon" ]; then
  rm -rf "$partial_dir"
  die "the release tarball has no executable bin/lemon launcher; refusing to install it."
fi

if [ -n "$TUI_FILE" ] && [ ! -x "$partial_dir/tui/bin/lemon-tui" ]; then
  rm -rf "$partial_dir"
  die "the TUI tarball has no executable tui/bin/lemon-tui; refusing to install it.
  Set LEMON_NO_TUI=1 to install the runtime only."
fi

if [ -d "$TARGET_DIR" ]; then
  previous_dir="$TARGET_DIR.previous.$$"
  mv "$TARGET_DIR" "$previous_dir"
  mv "$partial_dir" "$TARGET_DIR"
  rm -rf "$previous_dir"
else
  mv "$partial_dir" "$TARGET_DIR"
fi

if [ "$PLATFORM_OS" = "darwin" ] && command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$TARGET_DIR" >/dev/null 2>&1 || true
fi

ensure_links "$VERSION"

info ""
info "Installed Lemon $VERSION ($RESOLVED_CHANNEL, $PROFILE) to $TARGET_DIR"
info "  launcher: $BIN_DIR/lemon -> ../versions/current/bin/lemon"
if [ -n "$TUI_FILE" ]; then
  info "  tui:      $TARGET_DIR/tui/bin/lemon-tui"
fi
info "  state:    $LEMON_ROOT/store"

if ! "$BIN_DIR/lemon" version; then
  warn "'$BIN_DIR/lemon version' did not succeed. Run it directly to see why."
fi

if [ "$VERIFY" = "1" ]; then
  verify_boot
fi

path_hint

info ""
info "Next steps:"
if [ -n "$TUI_FILE" ]; then
  info "    lemon              # launch the terminal UI (starts the daemon for you)"
fi
info "    lemon --help       # available commands"
info "    lemon daemon       # start the runtime in the background"
info "    lemon status       # check it is healthy"
info "    lemon update       # install the next release"
info ""
info "Docs: $DOCS_URL"
