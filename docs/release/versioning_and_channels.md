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

`mix lemon.update` and the source wrapper `./bin/lemon update` are currently
stage-1 local maintenance tasks, not remote binary updaters. The same source
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
- `docs/plans/lemon-1.0-mainstream-readiness.md` — Hermes-on-BEAM readiness plan
