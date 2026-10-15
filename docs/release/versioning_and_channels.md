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

| Channel | Audience | Trigger | Stability |
|---|---|---|---|
| `stable` | General users | On demand | Fully tested |
| `preview` | Early adopters | On demand | Feature-complete, light testing |
| `nightly` | Contributors | On demand | May be broken |

The channel is expressed in the artifact name and release manifest. Channels
do not run on a schedule; an operator starts every release explicitly.

## One-click product releases

Keep the intended user-visible notes under `## [Unreleased]` in
`CHANGELOG.md`, then run the **Release** workflow from the `main` branch in
GitHub Actions. Leave `version` blank for the next CalVer, choose the channel,
and leave `draft` off for immediate publication. The same operation is
available through the CLI:

```bash
gh workflow run release.yml --ref main -f channel=stable -f draft=false
```

The workflow serializes release cuts and performs the complete operation:

1. The full `ci.yml` gate set (fast x4, quality, deterministic eval, install,
   clients, Dialyzer gate, sim bench, WASM) gates the dispatch's exact source
   commit **before** any version/changelog mutation, release commit, tag or
   push. A green `ci.yml` push run of that commit is reused through
   `scripts/ci_verified_commit`, which also waits up to 30 minutes for one that
   is still running; otherwise the release calls `ci.yml` as a reusable
   workflow, so the same parallel jobs run on that source commit.
   `skip_preflight=true` explicitly bypasses these lanes; artifact, manifest and
   container verification still run.
2. `scripts/prepare_product_release --auto` validates the Unreleased notes,
   chooses the next unused version, updates product version metadata, and moves
   the notes into the new version section. Automatic selection skips existing
   Git tags, including tags left behind by failed/unpublished cuts; explicit
   versions with existing tags are rejected without changing files.
3. GitHub Actions commits that cut to `main`, creates an annotated CalVer tag,
   and checks out the prepared tag (not the source commit) for every build.
4. Native runners build and verify all 14 tarballs (the existing 11 runtime/TUI
   artifacts plus three standalone `lemon_bot` backends). Container builds are
   smoke-tested and merged under the version-specific tag.
5. The workflow verifies the assembled manifest and artifacts, publishes the
   GitHub Release, then promotes the selected mutable container channel tag.
   `latest` moves with `stable` only.

The workflow refuses an empty Unreleased section, a non-increasing explicit
version, a non-default-branch dispatch, or a concurrent release cut. A draft
publishes the GitHub draft and version-specific container image, but
deliberately does not move mutable container channel tags.

If preflight fails, no release cut has been pushed: fix the source and dispatch
again. If a later job fails, use **Re-run failed jobs** on that workflow run.
A new workflow can also be dispatched with the existing tag as `--ref`; tag-ref
dispatches skip preparation and gate/rebuild the existing cut. Existing orphan
tags (including `v2026.10.10`, `v2026.10.11` and `v2026.10.13`) are left intact,
not reused or deleted. Direct tag pushes
remain supported for externally prepared releases. Ordinary releases should
use the `main` dispatch so version metadata, changelog, commit, tag, artifacts,
and container promotion stay one operation.

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

The original matrix remains `lemon_runtime_min` and `lemon_runtime_full` on all
three platform tags, `sim_broadcast_platform` on the two Linux tags, and
`lemon_tui` on all three tags: 11 artifacts. `lemon_tui` contains
`tui/bin/lemon-tui`, not a BEAM release. The standalone `lemon_bot` profile adds
one tarball on each platform, for **14 tarballs total**. It contains
`bot/bin/lemon-bot`, the complete built browser client in `bot/web`, and the
host-native Sharp addon and libvips dependencies under `bot/node_modules`.
It requires neither BEAM, the TUI, nor an installed Bun/Node runtime.

The release workflow calls the single canonical builder on each native host:

```sh
products/lemon_bot/scripts/build_release VERSION CHANNEL PLATFORM OUTPUT_DIR
```

The builder installs real dependencies, builds the web client, and compiles the
backend with Bun. `lemon-bot --version` prints `lemon-bot VERSION`. Native smoke
verification uses a clean HOME, a private temporary operator token and data
directory, checks `/v1/setup` and `/setup`, and fetches every packaged web asset.
No setup secret or first-run log is published.

Install only the standalone backend with:

```sh
LEMON_PROFILE=lemon_bot sh install.sh --skip-setup
```

This selects only `lemon_bot`, never a runtime or TUI artifact. Versions live in
`~/.lemon/lemon_bot/versions/<version>-<channel>-<platform>`, with the atomic
`~/.lemon/lemon_bot/current` pointer and `~/.local/bin/lemon-bot` executable.
Mutable product data stays outside version directories. Default full/min
runtime installation and its `~/.lemon/versions/current` pointer are unchanged.
Configure the backend's control URL, operator token, public URL and private data
directory before starting it; see the product's deployment instructions.

Each release also publishes version-scoped `join-node.sh` and `install.sh`
assets. The join command downloads from `releases/download/v<VERSION>/`, not a
mutable source branch. The manifest's top-level `scripts` array records each
asset's `kind` (`node_join` or `installer`), `filename`, `sha256` and `size_bytes`.
Verifiers download and validate both scripts alongside the tarballs.

The container image on `ghcr.io/z80dev/lemon` remains a multi-arch
(`amd64`/`arm64`) BEAM runtime deployment contract.

### Apple application prerequisites

The standalone macOS backend tarball is not a signed desktop application.
Apple application packaging uses `products/lemon_bot/apple/release.py`, whose
schema-version-1 receipt identifies product/version/channel, Apple marketing
and build numbers, distribution, and artifact filename/format/platform/checksum/
size. A receipt's `uploadAccepted` means transport acceptance only, not App
Store review or public availability.

Normal desktop application assets must be Developer ID signed and notarized
(`developer-id-notarized`); App Store delivery requires the actual signing and
App Store Connect credentials (`app-store`). `local-preview` artifacts must
never enter normal publication. The tarball workflow does not fabricate or
publish signed `.dmg`, application `.zip`, or `.ipa` assets. Wiring those assets
into normal publication requires the real signing credentials and an
authenticated receipt/artifact handoff from the Apple builder first.

macOS source installs are best effort. macOS `x86_64` and Windows have no
release artifacts; use a source install, WSL, or the container image.

## Release manifest (schema 2)

Consumers select artifacts by structured profile/platform fields; verification
also checks that the filename agrees with those fields:

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
| `otp` / `elixir` | Toolchain versions for the BEAM artifacts, not a standalone backend requirement. |
| `artifacts[].file` | Bare filename of the asset, no path component. |
| `artifacts[].profile` | Release profile name. |
| `artifacts[].platform` | Platform tag; `os` and `arch` repeat its parts for convenience. |
| `artifacts[].sha256` / `size` | Mandatory integrity fields; every consumer verifies both. |
| `artifacts[].glibc_min` | Optional; present on Linux artifacts only. |
| `scripts` | Version-scoped join/installer assets with `kind`, `filename`, `sha256`, and `size_bytes`. |

The manifest is published as a release asset, so it is reachable at
`releases/latest/download/manifest.json` for the latest stable release and at
`releases/download/v<version>/manifest.json` for a specific one. Neither URL
uses the GitHub API, so neither is rate limited. Preview and nightly releases
are not the "latest" release and therefore require an explicit version.

## Update flow

There are two update paths, and they do different jobs.

**Installed runtimes** (`~/.lemon`, from `install.sh` or a previous
`lemon update`) use the launcher's preview-confirm lifecycle:

```bash
lemon update check
lemon update plan
lemon update apply --confirm <exact-plan-digest>
lemon update history
lemon update rollback --receipt <exact-apply-receipt> \
  --confirm <exact-rollback-digest>
```

The non-mutating plan binds the exact running/current versions, raw manifest
SHA-256 and commit, channel/target/profile/platform, artifact names, declared
sizes, and checksums. Apply re-plans under an exclusive lock, records a verified
private checkpoint first, downloads and exact-size/SHA-256 verifies the runtime
and optional TUI, rejects unconfined or special archive entries before
extraction, validates the staged launcher version, then atomically flips
`~/.lemon/versions/current`. A post-flip failure restores the prior pointer.
Successful apply writes a content-free receipt; rollback accepts no path and
requires that exact receipt/digest plus an unchanged current pointer and
checkpoint checksum. Both operations require a restart; Lemon does not
hot-upgrade a running node.

Schema 2 authenticates the artifact against the manifest's checksum and size.
It is **not publisher-signed**: no detached manifest proof or trusted publisher
key is currently published. Artifact requests are time-bounded and
streamed to disk with a declared/post-download hard size check; the current
`:httpc` boundary cannot cancel at the exact in-flight byte where an overlong
body crosses its declaration, so the refused file is deleted after the bounded
response completes. See [the update guide](../user-guide/updates.md).

**Source checkouts** use `mix lemon.update` (or the no-subcommand source wrapper
`./bin/lemon update`), which remains a stage-1 local maintenance task and never
replaces binaries. `./bin/lemon update check|history` expose read-only release
visibility and receipts; packaged `plan`, `apply`, and `rollback` fail closed
with Git workflow guidance. The same source
wrapper family exposes `./bin/lemon setup ...` and `./bin/lemon doctor ...` as
delegates for the setup and diagnostics Mix tasks, plus
`./bin/lemon channels ...` to inspect redacted Telegram and Discord
configuration, `./bin/lemon config ...` for config inspection and validation,
`./bin/lemon models ...` for model catalog discovery,
`./bin/lemon providers ...` for redacted provider configuration, and
`./bin/lemon policy ...` for route-specific model policy management. It also
exposes `./bin/lemon media ...` for generated-media job status,
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
