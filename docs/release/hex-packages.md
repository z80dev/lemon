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
| `lemon_ai` | 0.3.0 | none |
| `lemon_core` | 0.3.0 | none |
| `lemon_agent` | 0.3.0 | `lemon_ai ~> 0.3.0`, `lemon_core ~> 0.3.0` |
| `lemon_memory` | 0.3.0 | `lemon_core ~> 0.3.0` |
| `lemon_platform_test` | 0.3.0 | `lemon_core`, `lemon_memory`, `lemon_ai`, `lemon_agent`, all `~> 0.3.0` and optional |

Every other app is in-repo only. `lemon_platform_test`'s `PluginCase` targets
`lemon_channels`, which is not published, so the Hex package excludes it; outside
this repository it comes from a path dependency on a checkout.

`0.2.0` is the first installable release line. The `0.1.0` releases published on
2026-08-11 cannot be installed (below).

The packages ship together on one 0.x release line, and every 0.x minor may break.
Each `mix.exs` therefore derives a single `@lemon_requirement` from its own
`@version` — `~> MAJOR.MINOR.0`, admitting patch releases of the same minor and
never the next one — and applies it to every sibling. A package's in-repo version
must stay on its siblings' minor: `PlatformPackagingContractTest` and
`scripts/verify_packages` (against the built `hex_metadata.config`) fail when a
requirement admits another minor or refuses a sibling's in-repo version.

### API migration for the 0.3 line (#559, #571, #592, #727)

These changes join the current unreleased package cycle; they do not imply that
new versions have been published. `lemon_core` stays on its already-unreleased
0.3.0 line rather than stacking another minor bump.

- **`lemon_ai` 0.3.0 (breaking):** provider content events are delta-only
  (#571): starts, deltas and block ends no longer carry an `AssistantMessage`
  snapshot (see the `lemon_ai` README). Remove `LemonAi.Providers.RetryHelper` and
  `LemonAi.OneshotRetry`. Use `LemonAi.Retry` and `%LemonAi.Retry.Policy{}`.
  Retryability classification belongs to `LemonAi.Error`; provider HTTP retry
  timing, one-shot attempts and cancellation-aware waiting belong to
  `LemonAi.Retry`. Provider configuration is converted with
  `LemonAi.Provider.retry_policy/0,1`; injected sleep remains configurable via
  `retry_sleep/1,2`. Provider-only `LemonAi.RateLimiter` is unchanged.
- **`lemon_core` 0.3.0:** add `%LemonCore.Retry.Policy{}` and policy-based
  `LemonCore.Retry.policy/1`, `retry_allowed?/2`, `backoff_delay_ms/2` and
  `delay/2,3`. Existing core backoff/Retry-After APIs remain available and use
  that policy implementation. Add `LemonCore.RateLimiter` for platform
  consumers and `LemonCore.RuntimeSeam` for optional-consumer registration and
  protected dispatch. Existing domain bridge APIs and behaviour contracts remain
  public; the duplicated registry implementations are removed, not the domain
  acknowledgement/failure policies. `LemonCore.Dedupe.Ets.check_and_mark/3`
  now atomically claims and fails closed when its table is unavailable; new
  `retain/4`, `forget/2` and `:infinity` retention support confirmed receipts and
  caller-owned bounded histories. Durable inbox uniqueness continues to use
  Store CAS. Platform callers migrate from the removed
  `LemonChannels.Outbox.RateLimiter`, `LemonControlPlane.A2A.RateLimiter` and
  `LemonWeb.LoginThrottle` implementations to `LemonCore.RateLimiter`; their
  application-owned registered process/table identities remain unchanged.
- **`lemon_core` 0.3.0 (breaking):** product runtime modules move out of the
  foundation. Source and packaged Lemon commands keep their names; foundation
  consumers must migrate imports and registrations listed in the
  [core changelog](../../apps/lemon_core/CHANGELOG.md#unreleased). CLI,
  browser and control-plane implementations ship with the product, not on Hex.
- **`lemon_agent` 0.3.0 (breaking):** `{:message_update, event}` carries only
  the delta-only provider event, not a growing partial `AssistantMessage` (#571).
  Queue transport lives in `AgentLoopConfig.hooks` (`queue_owner`, `queue_ref`,
  `queue_timeout`) beside `emit_system_prompt`, `stream_rules` and
  `on_stream_rule` (#559).
  The loop uses `LemonAi.Retry` while preserving one transient retry budget per
  response and provider `max_attempts: 1`. Package dependencies require
  `lemon_ai ~> 0.3.0` and `lemon_core ~> 0.3.0`, rather than resolving older
  or newer-minor packages that lack or change the consolidated APIs.

Both policy structs count `max_attempts` as **total attempts including the
initial attempt**. Their shared fields are `base_delay_ms`, `max_delay_ms`,
`max_retry_after_ms`, `factor`, `jitter`, `jitter_fraction`, `jitter_fun`,
`sleep_fun`, `alternate_available` and `classify`; AI also accepts
`error_retry_after_ms`. A delay calculation does not create another retry
budget. Unknown mutation outcomes remain non-retryable except for the
documented, fixed-idempotency-key channel outbox delivery policy.

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
  `in_umbrella` sibling into its declared Hex requirement, keeping `optional: true`.

`LEMON_HEX_PUBLISH=1` forces the package form inside the repo. `mix hex.build`
needs it: run without it, the deps are still `in_umbrella` and hex refuses to
build ("Dependencies excluded from the package"). `scripts/verify_packages` and
`scripts/release_package` set it for you.

`lemon_core`'s package `exclude_patterns` leave this repository's tooling
out of the tarball: `LemonCore.Quality.*` and the `lemon.quality`,
`lemon.architecture.docs`, `lemon.check_duplicate_tests`, `lemon.bench`
and `lemon.help` tasks. The managed updater and `mix lemon.update` source task
live in `lemon_cli`.
The build identity the doctor reports (`LemonCore.BuildInfo.version/0`,
`identity/0`, `describe/0`) ships; the Lemon application's Elixir floor is a
`lemon doctor` check in `lemon_cli` (`LemonCli.Doctor.Toolchain`), so the packaged
runtime check passes on every Elixir the packages admit.
`lemon_platform_test` excludes `PluginCase`, whose target is unpublished.
It ships `LemonPlatformTest.Testing`, the shared ExUnit helpers formerly in core.

## Proving the tarballs work

```bash
scripts/verify_packages [--keep] [--no-generator]
```

It builds each package with `mix hex.build --unpack` and inspects the tarballs:
no packaged source names a module a tarball excludes, `lemon_platform_test`
never names `LemonChannels`, and each sibling requirement in `hex_metadata.config`
admits its sibling's 0.x minor and no other. It then compiles a scratch consumer
project that depends on nothing but the unpacked directories (failing when any
dependency requires a newer Elixir than the running one), boots `:lemon_agent`,
checks the repo-only modules are absent, fails if xref finds a packaged call into
a published namespace the packages do not define or a function the running
Elixir/OTP lacks, and runs the packaged doctor: `LemonCore.Doctor.Checks.Runtime`
must report the build identity with no failure on the running toolchain, and no
doctor check may crash. The scratch consumer also runs an ExUnit suite against
the packaged test harness. Finally the script builds the installer in the scratch
directory, so the checkout can be read-only. It runs `mix lemon.new --packages-path`
for the base and `--memory` shapes against the same tarballs and runs their tests.
It needs Hex and network access to hex.pm. `.github/workflows/packaging.yml` runs
it on pull requests that touch the packages and nightly, on Elixir 1.20.5 / OTP
29.1.2 and on the declared floor, Elixir 1.17.3 / OTP 26.2; both legs are required.

The packages declare `elixir: "~> 1.17"`. That is the honest floor: exqlite 0.43
(required by `lemon_memory`, optional for `lemon_core`) requires Elixir 1.17, and
the packages call `String.replace_invalid/2` (Elixir 1.16). Elixir 1.15.8 / OTP
26.2 fails both checks above. `PlatformPackagingContractTest` keeps every package
on one floor and requires a packaging leg on it.

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
