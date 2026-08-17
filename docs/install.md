# Install Lemon

Last reviewed: 2026-08-16

This page is the short install landing page for the public docs site. For the
full setup walkthrough, including provider details and Telegram configuration,
use the [Setup Guide](user-guide/setup.md).

## Install (prebuilt)

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer downloads the published release tarball for your platform,
verifies its SHA-256 against the release `manifest.json`, and installs it under
`~/.lemon`. It never calls the GitHub API, so it is not subject to API rate
limits.

Prerequisites:

- `curl`, `tar`, and `python3`. `python3` reads the release manifest and
  performs the atomic symlink flip; there is no `jq` dependency. On macOS,
  `xcode-select --install` provides it.
- Linux: glibc 2.39 or newer. Release tarballs are built on Ubuntu 24.04. The
  installer warns and continues on older or non-glibc systems; set
  `LEMON_INSTALL_IGNORE_GLIBC=1` to silence the warning.

Flags: `--force` reinstalls a version that is already present, `--verify` boots
the installed runtime on ephemeral ports and polls `/healthz` before finishing,
`--modify-path` appends the PATH line to your shell rc file, and `--help`
prints usage.

### Environment knobs

| Variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_VERSION` | *(latest stable)* | Pin an exact version, for example `2026.08.0`. Required for any channel other than `stable`. |
| `LEMON_CHANNEL` | `stable` | Release channel. `preview` and `nightly` are not discoverable without the GitHub API, so they must be combined with `LEMON_VERSION`. |
| `LEMON_PROFILE` | `lemon_runtime_full` | `full`, `min`, or `sim`, or the full profile name. `sim` (`sim_broadcast_platform`) is Linux-only. |
| `LEMON_INSTALL_IGNORE_GLIBC` | *(unset)* | Set to `1` to silence the Linux glibc baseline warning. |
| `LEMON_INSTALL_BASE_URL` | `https://github.com/z80dev/lemon` | Release base URL. Test seam used by `scripts/verify_install_script`. |

### What gets installed

```
~/.lemon/versions/<version>/   extracted release
~/.lemon/versions/current      symlink to the active version (atomic flip point)
~/.lemon/bin/lemon             -> ../versions/current/bin/lemon
~/.lemon/{cookie,env}          generated once by the launcher, mode 600
~/.lemon/run/                  pid and runtime-root records for daemon/stop
~/.lemon/store/                default store path for user installs
```

Only `versions/current` moves when you update. The `~/.lemon/bin/lemon`
launcher path, your config, secrets, and store stay where they are.

### PATH

Add `~/.lemon/bin` to your PATH if it is not already there:

```bash
export PATH="$HOME/.lemon/bin:$PATH"
```

The installer prints the correct line for your shell (including
`fish_add_path` for fish) and only edits an rc file when you pass
`--modify-path`.

### Verify

```bash
lemon version
lemon daemon
lemon status
lemon stop
```

`lemon doctor --bundle` generates the same redacted support bundle as the
source path. To have the installer prove the boot for you, run it with
`--verify`.

### Updating

```bash
lemon update            # download, verify, and stage the next release
lemon update --check    # report the latest published version only
lemon update --rollback # return to the previous installed version
```

Updates are a symlink flip plus a restart; Lemon does not hot-upgrade a running
node. Restart the runtime (`lemon stop && lemon daemon`) to pick up a staged
version. The two most recent previous versions are retained for rollback.

### Uninstall

```bash
lemon stop
rm -rf ~/.lemon/versions ~/.lemon/bin ~/.lemon/run ~/.lemon/tmp
```

That removes the runtime and leaves your configuration, secrets, and data in
place. To purge everything, including `~/.lemon/config.toml`, the secret store,
and `~/.lemon/store`, remove the whole directory:

```bash
rm -rf ~/.lemon
```

Also remove the PATH line from your shell rc file if you added one.

### Platform support

| Platform | Tag | Profiles |
| --- | --- | --- |
| Linux `x86_64` | `linux-x86_64` | `lemon_runtime_min`, `lemon_runtime_full`, `sim_broadcast_platform` |
| Linux `arm64` | `linux-arm64` | `lemon_runtime_min`, `lemon_runtime_full`, `sim_broadcast_platform` |
| macOS Apple Silicon | `darwin-arm64` | `lemon_runtime_min`, `lemon_runtime_full` |
| macOS Intel, Windows | *(none)* | Use a source install, WSL, or the container image |

macOS binaries are unsigned. The `curl` install path avoids Gatekeeper
quarantine, and the installer additionally clears the quarantine attribute
best-effort.

## Install from Source

The source install remains fully supported and is the path to use for
development, for unsupported platforms, and when you want to build release
tarballs yourself. It needs Elixir, Erlang/OTP, and a model provider key.

Requirements:

- Elixir 1.19.5+
- Erlang/OTP 28.5+
- Node.js 24 LTS+ if you want TUI or web client work
- An Anthropic, OpenAI, or compatible provider credential

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix local.hex --force
mix deps.get
mix compile
./bin/lemon setup
./bin/lemon channels
./bin/lemon config validate
./bin/lemon doctor
./bin/lemon media --limit 5
./bin/lemon models --provider anthropic
./bin/lemon providers --provider openai
./bin/lemon policy list
./bin/lemon proofs --limit 5
./bin/lemon readiness --limit 5
./bin/lemon secrets status
./bin/lemon skill list
./bin/lemon usage
```

Start Lemon locally:

```bash
./bin/lemon-dev /path/to/your/project
```

If you want a repeatable local proof of the source path after building, run:

```bash
scripts/verify_source_install --skip-compile
```

Without `--skip-compile`, the verifier also runs `MIX_ENV=test mix compile --warnings-as-errors`.
It checks the BEAM toolchain, locked dependency resolution, non-interactive
setup dispatch, promoted Telegram/Discord channel readiness, stage-1 local
update dry-run dispatch, doctor JSON diagnostics, model catalog listing,
provider readiness listing, model policy listing, redacted proof artifact
listing, media diagnostics, readiness summary, secrets status, skill listing,
usage diagnostics, plus redacted support-bundle generation.

For source-checkout maintenance outside the verifier:

```bash
./bin/lemon update --check
```

This delegates to `mix lemon.update --check` and is a local maintenance check
for a source checkout: it reports the version and syncs bundled skills. Binary
updates belong to installed runtimes, where `lemon update` flips
`~/.lemon/versions/current` to a newly downloaded release.

For route-specific model defaults, use the source wrapper:

```bash
./bin/lemon models --provider anthropic
./bin/lemon providers --provider openai
./bin/lemon policy list
./bin/lemon proofs --limit 5
./bin/lemon media --limit 5
./bin/lemon readiness --limit 5
./bin/lemon channels
./bin/lemon secrets status
./bin/lemon skill list
./bin/lemon usage
./bin/lemon policy set telegram --account default --model anthropic:claude-sonnet-4-20250514
```

Use `./bin/lemon readiness --strict` when a script should fail unless all compact
launch-readiness gates are ready.

## Configure One Provider

Use the setup wizard when possible:

```bash
./bin/lemon setup provider
```

For manual setup, create `~/.lemon/config.toml` and reference secrets by name:

```toml
[providers.anthropic]
api_key_secret = "llm_anthropic_api_key_raw"

[defaults]
provider = "anthropic"
model    = "anthropic:claude-sonnet-4-20250514"
engine   = "lemon"
```

Store the secret:

```bash
./bin/lemon secrets set llm_anthropic_api_key_raw "sk-ant-..."
```

## Verify the Install

Run doctor after setup:

```bash
./bin/lemon doctor
```

Generate a redacted support bundle if you need help:

```bash
./bin/lemon doctor --bundle
```

The bundle is designed to exclude provider keys, tokens, passwords, private
prompts, memory contents, and tool outputs. Review it before sharing.

For release-candidate source installs, use the full source verifier:

```bash
scripts/verify_source_install
```

To prove the prebuilt path without a published release, run the installer
verifier. It builds a fixture release, serves it from localhost, and asserts the
install layout, checksum rejection, idempotency, version retention, and the
symlink flip:

```bash
scripts/verify_install_script
```

## Release Artifacts

Releases publish `mix release` tarballs named
`lemon-<version>-<channel>-<platform>-<profile>.tar.gz` together with a
`manifest.json` that records each artifact's platform, profile, SHA-256, size,
and glibc baseline. See
[Versioning and Channels](release/versioning_and_channels.md) for the manifest
schema and [Deployment Flows](release/deployment_flows.md) for the manual
server install, which stays supported alongside the installer.

Supported install paths: the one-line installer, manual tarball installs, the
container image, and source installs. The product ledger tracks artifact and
setup proof under [Hermes-on-BEAM Readiness](plans/lemon-1.0-mainstream-readiness.md).

Current release profiles:

- `lemon_runtime_min`
- `lemon_runtime_full`
- `sim_broadcast_platform` (Linux only)

Build locally:

```bash
MIX_ENV=prod mix release lemon_runtime_full
```

## Next Pages

| Next step | Page |
| --- | --- |
| Full setup details | [Setup Guide](user-guide/setup.md) |
| Configuration reference | [Config Reference](config.md) |
| Runtime and release behavior | [Versioning and Channels](release/versioning_and_channels.md) |
| Troubleshooting and quality gates | [Testing](testing.md) |
