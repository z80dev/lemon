# Release Checklist and Support Policy

Last reviewed: 2026-10-15

This document defines the operational checklist for Lemon 1.0 release
candidates, rollback handling, and public support boundaries.

## Initial 1.0 Support Matrix

The initial stable 1.0 release artifact support target is:

| Area | Supported for 1.0 | Notes |
| --- | --- | --- |
| Release artifacts | `linux-x86_64`, `linux-arm64`, `darwin-arm64` tarballs | Built by `.github/workflows/release.yml` on pinned `ubuntu-24.04`, `ubuntu-24.04-arm`, and `macos-15` runners; Linux artifacts carry a glibc 2.39 baseline |
| Release profiles | `lemon_runtime_min`, `lemon_runtime_full`, `lemon_tui`, and the standalone `lemon_bot` backend on all platforms | 12 tarballs total. All BEAM runtime artifacts must boot from extracted tarballs; the three `lemon_tui` artifacts are Bun binaries verified on native runners; each `lemon_bot` artifact is a compiled Bun backend boot-verified on its native runner. `sim_broadcast_platform` is not published; it is built from source or `apps/lemon_sim_ui/Dockerfile` for sim deploys |
| Source install | Linux and macOS, best effort | Requires Elixir 1.19.5+ and Erlang/OTP 28.5+ |
| Windows and macOS `x86_64` | Not supported for 1.0 | Use WSL, the container image, or source-level experimentation |
| Install script | Supported with scope | `install.sh` on the `stable` channel for the three platform tags; `preview`/`nightly` require a pinned `LEMON_VERSION` |
| Update | Supported with scope | `lemon update` stages runtime plus TUI artifacts atomically for full/min installs, flips the `versions/current` symlink, and restarts an already-running verified managed daemon on the selected release (a stopped install stays stopped); `lemon update rollback --receipt ID --confirm DIGEST` does the same for the retained prior release. No hot upgrades, no background auto-update |
| Container image | `ghcr.io/z80dev/lemon` multi-arch | `amd64` and `arm64` under one tag |
| Hosted Lemon service | Not supported for 1.0 | Lemon is local-first/self-hosted |
| Stable remote channel | Telegram | Text-first support boundary; other channel adapters are preview unless promoted |

Expanding release artifacts to further platforms requires release-matrix work,
local artifact proof, and support-bundle verification for each target.

## Release Candidate Checklist

The Release workflow automates the repeatable candidate gates. Before it cuts
a version, it requires a green `ci.yml` run on the exact source commit (reused
through `scripts/ci_verified_commit`, otherwise by calling `ci.yml`, which runs
`scripts/test fast`, `quality`, `eval-fast` and `clients`,
`scripts/verify_source_install` and `scripts/verify_install_script`, the
Dialyzer gate, sim bench and the WASM runtime lane). It validates
version/changelog consistency and release notes, then builds and boot-verifies
the published artifacts on native runners and re-verifies the assembled
manifest. Do not repeat these manually for an ordinary release.

The remaining checks in this section are credentialed or human-observed
promotion evidence. Run only the checks relevant to a surface whose support
status is being promoted by that release; they are not routine publication
steps.

- [ ] Run `scripts/test live-eval` with release-candidate eval credentials, or
      dispatch `.github/workflows/live-eval.yml` with `LEMON_EVAL_API_KEY`
      configured as a repository secret. Local runs may use
      `LEMON_EVAL_API_KEY_SECRET` or `INTEGRATION_API_KEY_SECRET` to point at a
      Lemon secret.

      ```bash
      gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon

      mix lemon.secrets.set release_eval_api_key <token>
      LEMON_EVAL_API_KEY_SECRET=release_eval_api_key scripts/test live-eval

      gh workflow run live-eval.yml \
        --ref v2026.05.0 \
        -f iterations=3 \
        -f live_timeout_ms=90000
      gh run list --workflow live-eval.yml --limit 5
      gh run watch {run-id} --exit-status
      ```

      This is the minimum live-model eval matrix for stable 1.0: the full
      current `scripts/test live-eval` lane must pass at least once for the
      release candidate. It covers prior-work memory search, skill capture,
      skill curation, blocked cron tooling for scheduled runs, and parallel
      child delegation before answering.
- [ ] Run `scripts/test clients`.
- [ ] Build `lemon_runtime_min` with `MIX_ENV=prod mix release lemon_runtime_min --overwrite`.
- [ ] Build `lemon_runtime_full` with `MIX_ENV=prod mix release lemon_runtime_full --overwrite`.
- [ ] Confirm `release-smoke.yml` builds both runtime profiles and evaluates the
      packaged releases directly, while `scripts/verify_release_runtime_boot`
      repeats the same check on each min/full release tarball. Each release must
      load `LemonMCP.Client`, report `LemonSkills.McpSource.mcp_enabled?/0`, keep
      `:lemon_mcp` loaded but not started, expose no application callback, and
      contain no `LemonMCP.Application` module.
- [ ] Build and package the `clients/tui` Bun binary for
      `linux-x86_64`, `linux-arm64`, and `darwin-arm64` as the `lemon_tui`
      artifacts.
- [ ] Verify SHA-256 for all 12 tarballs and include all 12 in `manifest.json`.
- [ ] Run `scripts/verify_release_artifacts {artifact-directory}` against the
      assembled artifact directory. The verifier must see the full profile x
      platform matrix: the min/full runtime tarballs, the three `lemon_tui`
      tarballs and the three `lemon_bot` tarballs (12 total).
- [ ] Run `scripts/verify_release_runtime_boot {artifact-directory}` against
      the assembled artifact directory (`--platform TAG` to pick another
      platform; default is the host's). The verifier boots every BEAM tarball
      and each `lemon_bot` tarball for that platform and skips the `lemon_tui`
      pseudo-profile. Min/full check
      `/healthz` and generate support bundles through release `eval`;
      `lemon_bot` checks the packaged web build and `/v1/setup`.
- [ ] Run product smoke against the release candidate
      (`scripts/product_smoke_local --release`, or dispatch
      `product-smoke.yml`).
- [ ] When the release touches a real external integration, run the matching
      manual smoke: `scripts/live_telegram_matrix.py`,
      `scripts/live_discord_matrix.py`, `scripts/live_provider_fallback_smoke.exs`,
      `scripts/live_provider_ownership_smoke.exs`, or
      `scripts/live_cron_runtime_restart_smoke.exs`. MCP has no live smoke
      script; its client and transports are covered by `apps/lemon_mcp/test`.
- [ ] Run `scripts/verify_docs_site`. It installs docs dependencies in a temp
      copy, builds the VitePress site, and
      checks markdown links without leaving generated artifacts in the repo.
- [ ] Confirm docs generated artifacts are not left in the repository.
- [ ] Confirm issue templates and support-bundle docs reference the current artifact names.
- [ ] Confirm known dependency audit findings are recorded and accepted or fixed.
- [ ] Confirm the OSV Scanner workflow is present and scoped to the first-party
      Mix, npm, and Bun lockfiles before publishing a release candidate.
- [ ] Confirm the `history` job in `.github/workflows/ci.yml` blocks
      unrelated-history PRs before merge.
- [ ] Confirm the Bun TUI package and release lanes validate `clients/tui` and
      publish all three `lemon_tui` platform artifacts without publishing a
      separate package.
- [ ] Run `scripts/test all` from the tagged commit.

## Dependency Audit Policy

Runtime dependencies and docs-site tooling are handled differently for 1.0.

Runtime release artifacts must not ship known high or critical dependency
advisories without a release-blocking issue, an explicit mitigation, and a
maintainer decision recorded in the launch ledger.

`.github/workflows/osv-scanner.yml` scans the first-party lockfiles on pull
requests and pushes that touch dependency manifests, on a weekly `main`
schedule, and through manual dispatch. It uses Google's pinned reusable OSV
scanner workflow, grants `security-events: write` for SARIF upload, and scans
      `mix.lock`, the Lemon web/browser npm lockfiles, `clients/tui/bun.lock`,
      the gateway private npm lockfile, and the diagrams npm lockfile. The workflow is
configured with `fail-on-vuln: false` so findings are detection signals, not
automatic release decisions; release candidates still require maintainer triage
for high or critical runtime findings.

## Repository History Integrity

The `history` job in `.github/workflows/ci.yml` protects `main` from unrelated-history
pull requests. It checks out the PR head with full history, fetches the target
base branch, and requires `git merge-base "origin/${GITHUB_BASE_REF}" HEAD` to
return a non-empty common ancestor.

This keeps accidental orphan branches, reinitialized `.git/` directories, or
force-pushes from another repository from grafting a second root into Lemon's
history and collapsing blame across a large umbrella snapshot. Failed PRs
should be recreated from the current target branch, then the intended changes
should be cherry-picked or re-applied.

## Bun TUI Package Check

The client-quality lane validates `clients/tui` with the pinned Bun toolchain,
`bun install --frozen-lockfile`, `bun run check`, `bun run lint`, and `bun test`.
The release lane additionally compiles the `lemon_tui` pseudo-profile for each
supported platform. It is a client binary packaged alongside the BEAM runtime,
not a separately published package.

The docs site is static output. VitePress, Vite, esbuild, and
`markdown-link-check` are development/build-time tooling for `docs/`; they are
not included in `lemon_runtime_min` or `lemon_runtime_full` release tarballs.
For the docs package:

- high and critical advisories block release candidates
- moderate advisories are allowed only when all of these are true:
  - the advisory affects docs build/dev tooling, not runtime tarballs
  - the static docs build succeeds
  - markdown link checking succeeds
  - `npm audit` reports `fixAvailable: false` or the available fix would require
    an unsafe/manual major upgrade
  - the finding is recorded in the launch ledger
- generated docs artifacts such as `docs/node_modules` and
  `docs/.vitepress/dist` must not remain in the repository after local
  verification; `docs/package-lock.json` is tracked for `npm ci` parity

As of 2026-05-11, the accepted docs-tooling findings are three moderate
advisories in the VitePress dependency chain:

- `vitepress <= 1.6.4` via `vite`
- `vite <= 6.4.1`
- `esbuild <= 0.24.2`

`npm audit --json` reports no high or critical advisories and no available fix
for that chain. These findings do not block the runtime release while the docs
site is served as static output only.

## Publish Checklist

Publishing is one manually triggered workflow after the release-readiness
gates above pass. Before starting it, ensure the intended release notes are
under `## [Unreleased]` in `CHANGELOG.md` and the readiness changes are already
on `main`.

```bash
gh workflow run release.yml --ref main -f channel=stable -f draft=false
gh run list --workflow release.yml --limit 5
gh run watch {run-id} --exit-status
```

The `version` input is optional. Blank derives the next CalVer from the current
UTC month and `mix.exs`; `-f version=2026.08.2` requests an explicit,
strictly-increasing version. The workflow then:

1. gates the dispatch's exact source commit with `ci.yml` (a green `main` push
   run is reused; otherwise `ci.yml` is called), before any file or tag changes
2. consumes and validates the Unreleased changelog notes, then updates every
   first-party product version
3. commits the release cut to `main` and creates its annotated tag
4. builds every native artifact from the tag, boot-verifying each on its
   native runner, and builds and smoke-tests the multi-arch container
5. verifies the assembled manifest and artifacts
6. publishes the GitHub Release, `manifest.json`, `install.sh`, `join-node.sh`,
   and all 12 tarballs
7. promotes the selected container channel; stable also promotes `latest`

Release runs are serialized. A failed preparation creates neither a commit nor
a tag. If a later job fails, use **Re-run failed jobs** on the same workflow
run; the successful preparation job and its exact tag are retained. If a new
workflow run is required, dispatch from the existing tag:

```bash
gh workflow run release.yml --ref v2026.08.2 -f channel=stable -f draft=false
```

Tag-ref dispatches skip release preparation and rebuild the existing release
cut. Mutable container channel tags do not move until the complete GitHub
Release exists.

The expected assets are:

- three `lemon_runtime_min` tarballs
- three `lemon_runtime_full` tarballs
- three `lemon_tui` tarballs
- three `lemon_bot` tarballs
- `manifest.json` schema 2
- `install.sh` and `join-node.sh`

For an intentionally prepared new external tag, direct tag push remains
supported:

```bash
git push origin v2026.08.2
```

Do not combine a `main` dispatch with a separate tag push for the same version.

## Rollback Checklist

Rollback means recommending or restoring a previous known-good release artifact.
Rollback is always an operator action; nothing rolls back on its own.

For runtimes installed by `install.sh` into `~/.lemon`, the two most recent
previous versions are retained on disk. `lemon update rollback` restarts a
running managed daemon onto the prior release itself; a stopped install stays
stopped, so there is no separate stop/start step:

```bash
lemon update history
lemon update rollback --receipt <apply-receipt-id> --confirm <rollback-digest>
lemon status
```

If the command exits `1` with `daemon_restart_failed`, the rollback is already
committed but the daemon did not restart: fix the startup problem, then run
`lemon daemon`. See [Update, roll back, and uninstall](../user-guide/updates.md).

For manual tarball and container installs, use the full procedure:

- [ ] Identify the previous known-good artifact profile.
- [ ] Download the previous artifact and `manifest.json`.
- [ ] Verify the artifact checksum.
- [ ] Stop the current release runtime.
- [ ] Preserve `~/.lemon/config.toml`, secrets, and store paths before replacing runtime files.
- [ ] Extract the previous artifact into a clean runtime directory.
- [ ] Start the previous runtime with the same environment variables.
- [ ] Check `/healthz`.
- [ ] Generate a release-runtime support bundle if rollback was caused by a defect.
- [ ] Open or update the tracking issue with the failing version, rollback target, support bundle, and reproduction steps.

## Support Policy

Supported for stable 1.0:

- Installation from source on machines with supported Elixir/Erlang versions.
- Linux `x86_64` release tarballs for `lemon_runtime_min` and `lemon_runtime_full`.
- Provider configuration through documented secrets and setup paths.
- TUI, web, Telegram, Discord, and control-plane issues that can be reproduced on a
  supported source install or Linux release artifact.
- XMTP, SMS, voice, and other channel adapters only as
  preview surfaces unless promoted by release notes.
- First-party text web search/fetch issues that can be reproduced in a
  supported agent run.
- Operator-controlled cron and scheduled automation as preview surfaces when
  failures are reproducible through first-party runtime or Web operations paths.
- Bugs accompanied by a redacted support bundle when diagnostics are needed.

Supported with scope:

- The one-line install script (`install.sh`) on the `stable` channel for
  `linux-x86_64`, `linux-arm64`, and `darwin-arm64`. It requires `curl`, `tar`,
  and `python3`, verifies every artifact's SHA-256 against the release manifest,
  and installs into the `~/.lemon` layout. Installing a `preview` or `nightly`
  release requires an explicit `LEMON_VERSION` pin.
- Remote update through `lemon update` for runtimes installed in that layout.
  Update is a non-mutating plan followed by exact-confirm, checksum/size
  verification, archive confinement, atomic symlink flip, private content-free
  receipt, and a restart of an already-running verified managed daemon onto
  the selected release (a stopped install stays stopped). Rollback requires the exact apply
  receipt/digest and verified retained checkpoint. Manual tarball and container
  installs are not managed by the updater. Schema-2 manifests are
  checksum-authenticated but not publisher-signed.
- Multi-arch container images on `ghcr.io/z80dev/lemon` (`amd64`, `arm64`).

Not supported for stable 1.0:

- Windows-native release artifacts.
- macOS `x86_64` release artifacts.
- Unverified platform-specific packaging, including OS package managers
  (Homebrew, apt, AUR) and desktop bundles.
- Hot code upgrades. An applied update always restarts the node (`lemon update` restarts a running managed daemon for you).
- Background or unattended auto-update. `[runtime] auto_update` is read and
  reported only; there is no update timer.
- Signed or notarized macOS binaries.
- Hosted multi-tenant operation.
- Stable support guarantees for preview channel adapters.
- Production-grade scheduling guarantees, external scheduler integrations, or
  unrestricted model-facing cron management.
- First-class browser automation, generated media, image analysis, or TTS/voice
  behavior unless a release note explicitly promotes a narrower path.
- Production support for third-party plugins, public plugin registries,
  sandboxed non-BEAM plugin hosts, unofficial MCP servers, or local model
  endpoints beyond documented OpenAI-compatible configuration. The local BEAM
  extension-host proof only covers explicitly trusted extension paths, tool
  execution through the registry, and built-in conflict precedence.

Security issues should use `SECURITY.md`. General defects should use the bug
report template and include:

- source-dev commit or release artifact version
- operating system and CPU architecture
- install path: source-dev or release-runtime
- support bundle command output or attached reviewed bundle
- expected behavior and actual behavior

Support bundle manifests include the Lemon app version, release name/version,
release channel when available, source/release runtime mode, git commit/branch
state, Elixir/OTP versions, OS, and CPU architecture.

## Required Evidence Files

Keep these release contracts current:

- `docs/release/versioning_and_channels.md`
- `docs/release/deployment_flows.md`
- `.github/workflows/release.yml`
- `.github/workflows/product-smoke.yml`
- `.github/workflows/docs-site.yml`
- `.github/workflows/live-eval.yml`
- `.github/workflows/ci.yml`
- `.github/workflows/osv-scanner.yml`
- `.github/workflows/release-smoke.yml`
- `scripts/bump_version.sh`
- `scripts/prepare_release_notes`
- `scripts/prepare_product_release`
- `scripts/verify_release_artifacts`
- `scripts/verify_release_runtime_boot`
- `install.sh`
- `scripts/verify_install_script`
