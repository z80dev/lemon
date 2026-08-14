# Publishing the hex packages

The umbrella ships two different things on two different clocks:

| | Artifact | Version scheme | Tag | Tooling |
|---|---|---|---|---|
| **Product** | Release tarballs of the whole umbrella | CalVer `YYYY.MM.PATCH` | `v2026.08.0` | `scripts/bump_version.sh` → `.github/workflows/release.yml` |
| **Platform** | Individual apps on hex.pm | semver, per package | `lemon_ai-v0.1.0` | `scripts/release_package` / `scripts/publish_train` → `.github/workflows/publish.yml` |

This page covers the second. Each published package starts at `0.1.0` and moves
independently (decision D10 in `docs/platform-split.md`); `1.0.0` waits until
the Phase 5 extraction has proven the APIs.

## The packages

`hex_package.exs` is the source of truth for which apps publish and under what
name. Since the 2026-08-10 rename (`ai`→`lemon_ai`, `agent_core`→`lemon_agent`)
every app name matches its hex name:

```
scripts/release_package --list
```

```
  APP                    HEX NAME               VERSION
  lemon_ai               lemon_ai               0.1.0
  lemon_core             lemon_core             0.1.0
  lemon_media            lemon_media            0.1.0
  lemon_agent            lemon_agent            0.1.0
  lemon_cli_runners      lemon_cli_runners      0.1.0
  lemon_memory           lemon_memory           0.1.0
  lemon_channels         lemon_channels         0.1.0
  lemon_router           lemon_router           0.1.0
  lemon_gateway          lemon_gateway          0.1.0
  lemon_platform_test    lemon_platform_test    0.1.0
```

`lemon_media` is a package because `lemon_channels` and `lemon_router` depend on
it (decision D13). It was not in the original list of eight, and leaving it out
would have blocked both of them — see the second failure mode below.
`lemon_cli_runners` joined with D15 (vendor CLI wrappers extracted from
`lemon_agent`).

Tags use the **app** name (`lemon_agent-v0.2.0`): the tag has to name a
directory the workflow can `cd` into.

> **0.1.0 provenance:** every package's first release was published to hex.pm
> on 2026-08-11 *without* going through the tag flow — a first publish needs no
> version bump, so a bare `mix hex.publish` leaves no release commit and no
> tag. There are no `*-v0.1.0` tags; the exact build commit is unrecorded.
> From `0.1.1` on, use the tooling below so every release is tagged.

## Publish order

Hex has no notion of "released together". A package's dependencies must already
exist on hex.pm at the moment it is published, so the first publish walks the
dependency graph bottom-up:

```
lemon_ai → lemon_core → lemon_media → lemon_agent → lemon_cli_runners → lemon_memory → lemon_channels → lemon_router → lemon_gateway → lemon_platform_test
```

`lemon_channels` precedes `lemon_router` because the router depends on it.

`scripts/release_package` enforces this. Before publishing it reads the target's
`in_umbrella` runtime deps and checks each one against hex.pm, refusing the
release when a dep is unpublished. `--force` overrides, which is only correct
when you are publishing that dep in the same session and know it lands first.

Two failure modes are worth recognising:

- **"dep X is not published on hex.pm"** — ordering. Publish X first.
- **"dep X is not in hex_package.exs @packages"** — X is not a package at all.
  This is not an ordering problem and `--force` will not save you: `mix
  hex.build` *drops* path dependencies rather than erroring, so forcing past it
  ships a tarball that claims the package has no such dependency and fails to
  compile for anyone outside this repo. Publish X too, make the dependency
  optional, or invert it. This is exactly what happened to `lemon_media`, and
  why D13 promoted it to a package rather than forcing past it.

## Releasing the whole train

`scripts/publish_train` drives `release_package` across every package in
dependency order — for lockstep version bumps (D10: the packages "move
together for now"):

```bash
# Preflight: dry-run every package in order. Changes nothing, exits non-zero
# if any package would fail a real release.
scripts/publish_train 0.2.0

# Release + publish the train.
HEX_API_KEY=... scripts/publish_train 0.2.0 --publish [--push]
```

Properties worth knowing:

- **Sequential by design.** `--publish` requires a local `HEX_API_KEY` because
  pushing all tags and letting CI publish cannot work for a full train: the
  tag-triggered workflows run concurrently and the publish-order gate fails
  every package whose deps have not landed yet. CI publishing is for single
  releases.
- **Idempotent resume.** A package already on hex.pm at the target version is
  skipped; a package tagged locally but missing from hex.pm (a run that died
  between tag and publish) is finished with a bare `mix hex.publish`. Re-run
  the same command after a failure and the train continues where it stopped.
- **Quality runs once** for the whole train, not per package
  (`--skip-quality` skips it).
- Preflight passes `--force` to the per-package dry runs: before the train has
  run, in-train deps are necessarily absent from hex.pm. The real run keeps
  the order gate armed — by publish time each dep must actually be there.

## Releasing a package

```bash
# 1. See what would happen. Changes nothing.
scripts/release_package lemon_core 0.2.0 --dry-run

# 2. Do it: bumps mix.exs, rolls the changelog, commits, tags.
scripts/release_package lemon_core 0.2.0

# 3. Push the tag. CI publishes.
git push origin main && git push origin lemon_core-v0.2.0
```

The script refuses to run unless the working tree is clean, the version is
greater than the current one, the tag is free, `apps/<pkg>/CHANGELOG.md` has an
`## [Unreleased]` section with entries, `mix hex.build` succeeds, the publish
order holds, and `mix lemon.quality` is green.

On release it moves the `[Unreleased]` entries under `## [<version>] - <date>`,
leaves a fresh empty `[Unreleased]`, commits both files, and creates an
annotated tag. If `HEX_API_KEY` is set locally it publishes directly; otherwise
it stops and prints the command to run later — pushing the tag is the normal
path, since CI publishes from it.

### Options

| Flag | Effect |
|---|---|
| `--dry-run` | Run every check, change nothing. Reports and exits 0. |
| `--strict` | With `--dry-run`, exit non-zero if any check would fail. |
| `--verify` | Verify an already-tagged release. What CI runs. |
| `--skip-quality` | Skip `mix lemon.quality` (CI runs it as its own step). |
| `--force` | Bypass the publish-order gate. Read the warning above first. |
| `--yes` | Skip the interactive confirmation. |

## What CI does

`.github/workflows/publish.yml` fires on `*-v*` tags (and on manual dispatch,
which defaults to verify-only). It splits the tag into package and version, runs
`scripts/release_package --verify` — mix.exs matches the tag, the changelog has
that version's section, hex metadata builds, publish order holds — then runs the
quality lane, then publishes package and docs to hex.pm.

**Without the `HEX_API_KEY` secret the publish step no-ops with a notice rather
than failing.** Everything up to the actual upload still runs, so the pipeline
is exercisable before the key exists.

## LEMON_HEX_PUBLISH

Sibling packages depend on each other with `in_umbrella: true`, which hex
cannot express. `hex_package.exs` rewrites those into real hex requirements, but
only when `LEMON_HEX_PUBLISH=1` — so the umbrella's own compile, test and
`mix deps.get` never see the hex form.

Every hex command must therefore set it:

```bash
cd apps/lemon_core && LEMON_HEX_PUBLISH=1 mix hex.build
```

`scripts/release_package` and the workflow both set it for you. Running
`mix hex.build` without it produces a tarball whose dependencies have silently
vanished.

## Changelog discipline

Every published package has an `apps/<pkg>/CHANGELOG.md` in Keep a Changelog
format. A change to a published package's `lib/` should land with its changelog
entry in the same PR.

`.github/workflows/changelog-check.yml` checks this on every PR and annotates
when it is missed. It is **advisory** — it does not fail the build. Run it
locally with:

```bash
scripts/check_changelog_entries            # advisory, like CI
scripts/check_changelog_entries --strict   # exit non-zero on a miss
```

Once every published package has a changelog and the habit has stuck, add
`--strict` to the workflow.
