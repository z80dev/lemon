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

The channel is expressed in the binary name and the release manifest:

```
lemon-2026.03.0-stable-linux-x86_64.tar.gz
lemon-2026.03.1-preview-macos-aarch64.tar.gz
```

## Artefacts

Current release automation produces:

- Self-contained `.tar.gz` archives with the Erlang runtime baked in via
  `mix release`.
- A `manifest.json` with version, channel, file names, sizes, and SHA-256
  checksums.

As of the current workflow, public release artifacts are built for Linux
`x86_64` for these profiles:

- `lemon_runtime_min`
- `lemon_runtime_full`

The initial 1.0 stable support target is Linux `x86_64` release tarballs only.
macOS source installs are best effort, and macOS or other platform release
artifacts are future release-matrix work unless the release workflow is expanded.

## Update flow (`mix lemon.update`)

`mix lemon.update` is currently a stage-1 local maintenance task, not a remote
binary updater.

It runs:

1. Version reporting.
2. Config migration for deprecated TOML sections.
3. Bundled-skill sync.

It does not yet:

- fetch a remote release manifest
- compare local and remote channels
- download release tarballs
- verify downloaded artifact checksums
- swap the active runtime binary

Those remote update stages remain future release work.

## Kill-switch

The intended remote-update kill-switch shape is:

```toml
[runtime]
auto_update = false
pinned_version = "2026.03.0"
```

Treat this as forward-looking until remote update checks are implemented.

## See also

- `docs/release/deployment_flows.md` — supported runtime/deployment modes
- `apps/lemon_core/lib/mix/tasks/lemon.update.ex` — current stage-1 update task
- `docs/plans/lemon-1.0-mainstream-readiness.md` — launch readiness plan
