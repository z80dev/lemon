# Versioning and Release Channels

This document describes the versioning scheme and release-channel model for
Lemon, introduced in milestone M1-02.

## Version format

Lemon uses **CalVer** with a patch counter:

```
YYYY.MM.PATCH
```

Examples: `2026.03.0`, `2026.03.1`, `2026.04.0`.

The patch counter resets to `0` on each new month.  It increments for
hotfixes and out-of-cycle releases within the same month.

## Release channels

| Channel | Audience | Cadence | Stability |
|---|---|---|---|
| `stable` | General users | Monthly | Fully tested |
| `preview` | Early adopters | Weekly | Feature-complete, light testing |
| `nightly` | Contributors | Daily | Automated build, may be broken |

The channel is expressed in the artifact name and the release manifest.

## Platform tags

Artifact names carry a runner-agnostic platform tag derived from `uname`:

| Tag | `uname -s` | `uname -m` | Notes |
|---|---|---|---|
| `linux-x86_64` | `Linux` | `x86_64`, `amd64` | glibc 2.39 baseline (built on Ubuntu 24.04) |
| `linux-arm64` | `Linux` | `aarch64`, `arm64` | glibc 2.39 baseline |
| `darwin-arm64` | `Darwin` | `arm64` | Apple Silicon; binaries are unsigned |

The tag deliberately does not encode the build distribution, so the glibc
baseline can move without renaming artifacts.

## Artefacts

Release artifacts are named:

```
lemon-<version>-<channel>-<platform>-<profile>.tar.gz
```

Examples:

```
lemon-2026.08.0-stable-linux-x86_64-lemon_runtime_full.tar.gz
lemon-2026.08.0-stable-linux-arm64-lemon_runtime_min.tar.gz
lemon-2026.08.1-preview-darwin-arm64-lemon_runtime_full.tar.gz
```

Current release automation produces:

- Self-contained `.tar.gz` archives with the Erlang runtime baked in via
  `mix release`, one per profile and platform.
- A `manifest.json` describing every artifact in the release.

The published matrix is `lemon_runtime_min` and `lemon_runtime_full` on all
three platform tags, `sim_broadcast_platform` on the two Linux tags, and
`lemon_tui` on all three tags: 11 artifacts total. `lemon_tui` is a
pseudo-profile for a Bun-compiled client tarball containing
`tui/bin/lemon-tui`, not a BEAM release. The container image on
`ghcr.io/z80dev/lemon` is published as a multi-arch (`amd64`/`arm64`) manifest
and remains the portable Linux deployment contract.

macOS source installs are best effort. macOS `x86_64` and Windows have no
release artifacts; use a source install, WSL, or the container image.

## Release manifest (schema 2)

Consumers — `install.sh`, the self-updater, and the verifier scripts — match on
the structured fields, never on a filename regex:

```json
{
  "schema": 2,
  "version": "2026.08.0",
  "channel": "stable",
  "commit": "0123456789abcdef0123456789abcdef01234567",
  "built_at": "2026-08-16T00:00:00Z",
  "otp": "28.5",
  "elixir": "1.19.5",
  "artifacts": [
    {
      "file": "lemon-2026.08.0-stable-linux-x86_64-lemon_runtime_full.tar.gz",
      "profile": "lemon_runtime_full",
      "platform": "linux-x86_64",
      "os": "linux",
      "arch": "x86_64",
      "sha256": "…64 hex characters…",
      "size": 123456789,
      "glibc_min": "2.39"
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `schema` | Manifest schema version. Consumers reject anything they do not understand. |
| `version` / `channel` | CalVer version and release channel for the whole release. |
| `commit` | Source commit the artifacts were built from. |
| `built_at` | UTC build timestamp, RFC 3339. |
| `otp` / `elixir` | Toolchain versions baked into the release. |
| `artifacts[].file` | Bare filename of the asset, no path component. |
| `artifacts[].profile` | Release profile name. |
| `artifacts[].platform` | Platform tag; `os` and `arch` repeat its parts for convenience. |
| `artifacts[].sha256` / `size` | Mandatory integrity fields; every consumer verifies both. |
| `artifacts[].glibc_min` | Optional; present on Linux artifacts only. |

The manifest is published as a release asset, so it is reachable at
`releases/latest/download/manifest.json` for the latest stable release and at
`releases/download/v<version>/manifest.json` for a specific one. Neither URL
uses the GitHub API, so neither is rate limited. Preview and nightly releases
are not the "latest" release and therefore require an explicit version.

## Update flow

There are two update paths, and they do different jobs.

**Installed runtimes** (`~/.lemon`, from `install.sh` or a previous
`lemon update`) use the launcher's `lemon update`. It fetches the manifest for
the configured channel, compares versions with `LemonCore.Update.Version`,
downloads and SHA-256 verifies the matching runtime and, unless
`LEMON_NO_TUI=1` or the profile is `sim_broadcast_platform`, the matching
`lemon_tui` artifact. It stages both into the new version before flipping
`~/.lemon/versions/current`. Applying the new version requires a restart: Lemon
does not hot-upgrade a running node. The two previous versions are retained for
`lemon update --rollback`.

**Source checkouts** use `mix lemon.update` (or the source wrapper
`./bin/lemon update`), which remains a stage-1 local maintenance task and never
replaces binaries. The same source
wrapper family exposes `./bin/lemon setup ...` and `./bin/lemon doctor ...` as
delegates for the setup and diagnostics Mix tasks, plus
`./bin/lemon channels ...` for redacted Telegram/Discord launch readiness,
`./bin/lemon config ...` for config inspection and validation,
`./bin/lemon models ...` for model catalog discovery,
`./bin/lemon providers ...` for redacted provider readiness, and
`./bin/lemon policy ...` for route-specific model policy management. It also
exposes `./bin/lemon proofs ...` for redacted local proof artifact inventory,
`./bin/lemon media ...` for redacted generated-media job, artifact, and
provider-proof readiness,
`./bin/lemon readiness ...` for compact launch-gate readiness summaries and
`./bin/lemon readiness --strict` for scripts that should fail unless the
compact readiness status is fully ready,
`./bin/lemon secrets ...` as an allowlisted dispatcher for the existing
secret-store tasks, `./bin/lemon skill ...` for the existing skill lifecycle
task, and `./bin/lemon usage ...` for redacted usage/cost diagnostics.

It runs:

1. Version reporting.
2. Config migration for deprecated TOML sections.
3. Bundled-skill sync.

It does not:

- download release tarballs
- swap the active runtime binary

Those are the installed-runtime path above; a source checkout updates with
`git pull`.

## Runtime update settings

```toml
[runtime]
auto_update = false
channel = "stable"
pinned_version = "2026.03.0"
```

| Key | Effect |
|---|---|
| `auto_update` | Read and reported only. There is no background update timer; updates happen when an operator runs `lemon update`. |
| `channel` | Channel the updater checks. Defaults to `stable`. Non-stable channels also need `pinned_version`, because only the latest stable release is discoverable without the GitHub API. |
| `pinned_version` | Kill-switch: the updater stays on this exact version and reports newer releases without installing them. |

## See also

- `docs/install.md` — one-line installer, `~/.lemon` layout, and uninstall
- `docs/release/deployment_flows.md` — supported runtime/deployment modes
- `install.sh` / `scripts/verify_install_script` — installer and its fixture-server verifier
- `apps/lemon_core/lib/mix/tasks/lemon.update.ex` — stage-1 source-checkout update task
- `docs/plans/lemon-1.0-mainstream-readiness.md` — Hermes-on-BEAM readiness plan
