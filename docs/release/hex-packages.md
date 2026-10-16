# Publishing the Hex packages

The umbrella ships two different things on two different clocks:

| | Artifact | Version scheme | Tag | Tooling |
|---|---|---|---|---|
| **Product** | Release tarballs of the whole umbrella | CalVer `YYYY.MM.PATCH` | `v2026.08.0` | `scripts/prepare_product_release` (calls `scripts/bump_version.sh`) → `.github/workflows/release.yml` |
| **Packages** | Five apps on hex.pm | semver, per package | `lemon_ai-v0.2.0` | `scripts/release_package` → `.github/workflows/publish.yml` |

This page covers the second. Status and the decisions behind it are in
[`docs/platform-split.md`](../platform-split.md).

## The packages

Exactly five apps publish, in this dependency order (`scripts/verify_packages
--list` is the source of truth):

```
lemon_ai → lemon_core → lemon_agent → lemon_memory → lemon_platform_test
```

| Package | In-repo version | Sibling deps |
|---|---|---|
| `lemon_ai` | 0.2.0 | none |
| `lemon_core` | 0.2.0 | none |
| `lemon_agent` | 0.2.0 | `lemon_ai`, `lemon_core` |
| `lemon_memory` | 0.2.0 | `lemon_core` |
| `lemon_platform_test` | 0.2.0 | `lemon_core`, `lemon_memory`, `lemon_ai`, `lemon_agent` (all optional) |

Every other app is in-repo only. `lemon_platform_test`'s `PluginCase` targets
`lemon_channels`, which is not published, so outside this repository it needs a
path dependency on a checkout.

`0.2.0` is the first installable release line. The `0.1.0` releases published on
2026-08-11 cannot be installed (below); sibling requirements are `~> 0.2` so no
resolver ever picks them.

## The generator (`lemon_new`)

`installer/` builds `mix lemon.new`. It is not one of the five and `release_package`
does not handle it, but its `mix.exs` is self-contained the same way (package
metadata, MIT license, links, files `lib templates mix.exs README.md CHANGELOG.md
LICENSE`, nothing read from outside `installer/`), so `mix hex.build` works in
that directory and `mix archive.install hex lemon_new` will work once an owner
publishes it. It has no dependencies. A first publish of a new package needs a
key with API write; the package-scoped keys below cannot create packages.

## Retired 0.1.0 releases

Every `0.1.0` tarball shipped a `mix.exs` whose first line was
`Code.require_file("../../hex_package.exs", __DIR__)`, a file that is not in the
tarball, so `mix compile` fails with `Code.LoadError` for any consumer. Ten
packages were published that way; `lemon_skills` and `lemon_browser` never were.
Retiring keeps the releases resolvable for anyone who locked them but warns on
every `mix deps.get`. All ten were retired on 2026-10-13 with:

```bash
# The five that continue from 0.2.0.
for pkg in lemon_ai lemon_core lemon_agent lemon_memory lemon_platform_test; do
  mix hex.retire "$pkg" 0.1.0 invalid \
    --message "uninstallable: mix.exs requires a file missing from the package; use ~> 0.2"
done

# The five that are no longer published at all.
for pkg in lemon_media lemon_router lemon_gateway lemon_channels; do
  mix hex.retire "$pkg" 0.1.0 invalid \
    --message "uninstallable, and no longer published; the app lives in github.com/z80dev/lemon"
done
mix hex.retire lemon_cli_runners 0.1.0 invalid \
  --message "uninstallable, and removed: subagents are native-only"
```

Check with `curl -s https://hex.pm/api/packages/<pkg> | jq .retirements`.

## Hex credentials

Hex 2FA applies to interactive logins. API keys sent as `HEX_API_KEY` do not
prompt, so automation uses keys scoped to the `lemon_*` packages, created on the
hex.pm dashboard (Settings → Keys) with an expiry:

- CI: the `HEX_API_KEY` repository secret, used by `publish.yml`.
- Local owner commands: a key kept in the macOS login Keychain, never in the repo:

  ```bash
  security add-generic-password -U -s hex-api-key -a <hex-user> -w   # prompts for the key
  HEX_API_KEY="$(security find-generic-password -s hex-api-key -a <hex-user> -w)" \
    mix hex.retire <pkg> <version> <reason> --message "..."
  ```

## How a package's mix.exs stays self-contained

The tarball ships `apps/<pkg>/mix.exs` verbatim, so it may not read anything
outside its own directory. Each of the five decides at load time which form it
is in:

- **Umbrella** — it sits at `apps/<pkg>/mix.exs` under the umbrella's `mix.exs`:
  it shares the umbrella's `_build`, `deps`, `mix.lock` and config, and sibling
  packages are `in_umbrella: true`.
- **Package** — anywhere else (`deps/<pkg>/` in a consumer, an unpacked
  tarball): no umbrella paths, and a private `lemon_deps/1` rewrites each
  `in_umbrella` sibling into a `~> 0.2` Hex requirement, keeping `optional: true`.

`LEMON_HEX_PUBLISH=1` forces the package form inside the repo. `mix hex.build`
needs it: run without it, the deps are still `in_umbrella` and hex refuses to
build ("Dependencies excluded from the package"). `scripts/verify_packages` and
`scripts/release_package` set it for you.

`lemon_core`'s package `exclude_patterns` leave this repository's tooling out of
the tarball: `LemonCore.Quality.*`, `LemonCore.Update.*`, and the `lemon.quality`,
`lemon.architecture.docs`, `lemon.check_duplicate_tests`, `lemon.update`,
`lemon.bench` and `lemon.help` tasks.

## Proving the tarballs work

```bash
scripts/verify_packages [--keep] [--no-generator]
```

It builds each package with `mix hex.build --unpack`, compiles a scratch
consumer project that depends on nothing but the unpacked directories, boots
`:lemon_agent`, checks the repo-only modules are absent, then runs
`mix lemon.new --packages-path` for the base and `--memory` shapes against the
same tarballs and runs their tests. It needs Hex and network access to hex.pm.
`.github/workflows/packaging.yml` runs it on pull requests that touch the
packages and nightly, plus an advisory Elixir 1.15 leg for the declared floor.

## Releasing a package

```bash
# 1. Every check, no changes. Includes scripts/verify_packages.
scripts/release_package lemon_core 0.2.0 --dry-run

# 2. Release: sets @version, rolls the changelog, commits, tags lemon_core-v0.2.0.
scripts/release_package lemon_core 0.2.0

# 3. Push. publish.yml verifies the tag and publishes it.
git push origin main && git push origin lemon_core-v0.2.0
```

The script refuses unless the package is one of the five, the version is not
behind `@version` in `mix.exs`, the tag is free, the tree is clean,
`apps/<pkg>/CHANGELOG.md` has entries under `## [Unreleased]`, every sibling it
depends on is on hex.pm at its in-repo version, and `scripts/verify_packages`
passes. It publishes from the unpacked tarball, so the release (docs included)
is exactly what was verified.

Hex has no multi-package release. Release in dependency order and let each
publish land before the next; a package whose siblings are not on hex.pm yet is
refused. A lockstep release of all five is the same command five times:

```bash
for pkg in $(scripts/verify_packages --list); do
  HEX_API_KEY=... scripts/release_package "$pkg" 0.2.0 --yes
done
```

| Flag | Effect |
|---|---|
| `--dry-run` | Run every check, change nothing. |
| `--verify` | Check an already-tagged release (what CI runs on the tag). |
| `--publish-tagged` | Publish an already-tagged release from its tarball (CI's publish job). |
| `--yes` | Skip the confirmation. |

## What CI does

`.github/workflows/publish.yml` fires on `*-v*` tags (and on manual dispatch,
which defaults to verify-only). It splits the tag into package and version, runs
`scripts/release_package --verify`, then `--publish-tagged`. Without the
`HEX_API_KEY` secret the publish step exits with a notice instead of failing.

Create that key on the hex.pm dashboard (Settings → Keys → Generate New Key);
Hex 2.5 removed `mix hex.user key`. Scope it to the `lemon_*` packages rather
than API write, give it an expiry, and store it with `gh secret set HEX_API_KEY`.
The key is shown once; rotate it by generating a new one and re-setting the
secret.

## Changelogs

Each of the five keeps `apps/<pkg>/CHANGELOG.md` in Keep a Changelog format;
`release_package` rolls `[Unreleased]` into the released version. Apps that are
not published have no package changelog; the root `CHANGELOG.md` covers them.
