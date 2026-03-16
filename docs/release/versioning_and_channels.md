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

Each release produces:

- A self-contained `.tar.gz` with the Erlang runtime baked in (via `mix release`).
- A `manifest.json` with version, channel, and SHA-256 checksums.

## Update flow (`mix lemon.update`)

1. Fetch the latest `manifest.json` from the configured release channel URL.
2. Compare the remote version against the running version.
3. Download the new tarball and verify the checksum.
4. Perform a staged swap: unpack to a side-by-side directory, then atomically
   replace the active binary on next start (or hot-swap via BEAM hot code loading
   when the `product_runtime` feature flag is `"default-on"`).

## Kill-switch

To pin a specific version and disable automatic update checks:

```toml
[runtime]
auto_update = false
pinned_version = "2026.03.0"
```

## See also

- `docs/product/runtime_plan.md` — overall M1 delivery plan
- `M1-02` — first-class Lemon runtime releases task
- `M1-05` — staged `mix lemon.update` task
