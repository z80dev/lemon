# Release Checklist and Support Policy

Last reviewed: 2026-05-12

This document defines the operational checklist for Lemon 1.0 release
candidates, rollback handling, and public support boundaries.

## Initial 1.0 Support Matrix

The initial stable 1.0 release artifact support target is:

| Area | Supported for 1.0 | Notes |
| --- | --- | --- |
| Release artifacts | Linux `x86_64` tarballs | Built by `.github/workflows/release.yml` on `ubuntu-latest` |
| Release profiles | `lemon_runtime_min`, `lemon_runtime_full` | Both must boot from extracted tarballs before stable 1.0 |
| Source install | Linux and macOS, best effort | Requires Elixir 1.19.5+ and Erlang/OTP 28.5+ |
| Windows | Not supported for 1.0 | Use WSL or source-level experimentation |
| Auto-update | Not supported for 1.0 | `mix lemon.update` remains a local maintenance task |
| Install script | Not supported for 1.0 | Source install and verified tarballs are the supported paths |
| Hosted Lemon service | Not supported for 1.0 | Lemon is local-first/self-hosted |
| Stable remote channel | Telegram | Text-first support boundary; other channel adapters are preview unless promoted |

Expanding release artifacts to macOS or other platforms requires release-matrix
work, artifact proof, and support-bundle verification for each target.

## Release Candidate Checklist

Before cutting a stable release:

- [ ] Confirm `mix.exs` version matches the intended tag.
- [ ] Confirm `CHANGELOG.md` has a section for the release.
- [ ] Run `scripts/prepare_release_notes {version}` and confirm the output is
      useful for the GitHub Release body.
- [ ] Run `scripts/lint_ci_docs.sh` and confirm the first-party version metadata
      and BEAM toolchain pin checks pass.
- [ ] Run `scripts/test fast`.
- [ ] Run `scripts/test quality`.
- [ ] Run `scripts/test eval-fast`.
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
- [ ] Rerun the Telegram live matrix for the stable text-first plus
      document-delivery boundary using the established Telethon credentials and
      Lemonade Stand group/topics.

      ```bash
      scripts/live_telegram_matrix.py --timeout 90
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-isolation \
        --isolation-topic-id 35 \
        --isolation-topic-id 16456 \
        --timeout 180
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-cancel \
        --cancel-topic-id 35 \
        --timeout 95
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-tool-rendering \
        --topic-markdown \
        --timeout 160
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-approval \
        --approval-topic-id 35 \
        --timeout 180
      scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
        --topic-long-output \
        --long-output-topic-id 35 \
        --timeout 120
      scripts/live_telegram_matrix.py --skip-dm --skip-topic \
        --topic-file-get \
        --file-get-topic-id 35 \
        --timeout 90
      ```

      Also run the two-step topic restart/dedupe proof after restarting
      `./bin/lemon`. The proof must cover DM, group forum-topic routing, topic
      isolation, cancellation, approval buttons, tool success/failure status,
      markdown/code rendering, long output, document delivery, and duplicate
      avoidance after restart.
- [ ] For Hermes-parity readiness, run the non-bot manual Discord matrix and
      keep the result JSON for the final audit.

      ```bash
      scripts/live_discord_matrix.py --channel-id 1475727417372049419 \
        --manual-matrix \
        --timeout 180 \
        --result-path tmp/discord-live-proof.json
      ```

      The prompts must be sent by a real non-bot Discord user. Bot API smoke,
      bot-authored messages, and webhooks do not count as Lemon inbound proof.
- [ ] Run `scripts/test clients`.
- [ ] Build `lemon_runtime_min` with `MIX_ENV=prod mix release lemon_runtime_min --overwrite`.
- [ ] Build `lemon_runtime_full` with `MIX_ENV=prod mix release lemon_runtime_full --overwrite`.
- [ ] Package both release directories as Linux `x86_64` tarballs.
- [ ] Verify SHA-256 for each tarball and include both in `manifest.json`.
- [ ] Run `scripts/verify_release_artifacts {artifact-directory}` against the
      assembled artifact directory. The verifier must see both
      `lemon_runtime_min` and `lemon_runtime_full` Linux `x86_64` tarballs.
- [ ] Run `scripts/verify_release_runtime_boot {artifact-directory}` against
      the assembled artifact directory. The verifier must extract both
      tarballs, boot each runtime, check `/healthz`, and generate a support
      bundle through release `eval`.
- [ ] Run product smoke against the release candidate.
- [ ] Run `scripts/verify_docs_site`. It installs docs dependencies in a temp
      copy, runs `npm audit --audit-level=high`, builds the VitePress site, and
      checks markdown links without leaving generated artifacts in the repo.
- [ ] Confirm docs generated artifacts are not left in the repository.
- [ ] Confirm issue templates and support-bundle docs reference the current artifact names.
- [ ] Confirm known dependency audit findings are recorded and accepted or fixed.
- [ ] Run `LEMON_DISCORD_LIVE_PROOF_JSON=tmp/discord-live-proof.json
      scripts/audit_1_0_readiness {version} {artifact-directory}` and treat any
      failure or blocker as release-blocking. The audit also prints
      remote preflight evidence for the release tag, release workflow, live-eval
      workflow, and release-eval repository secret state so the final handoff
      does not depend on manual GitHub inspection.

## Dependency Audit Policy

Runtime dependencies and docs-site tooling are handled differently for 1.0.

Runtime release artifacts must not ship known high or critical dependency
advisories without a release-blocking issue, an explicit mitigation, and a
maintainer decision recorded in the launch ledger.

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
- generated docs artifacts such as `docs/node_modules`,
  `docs/package-lock.json`, and `docs/.vitepress/dist` must not remain in the
  repository after local verification

As of 2026-05-11, the accepted docs-tooling findings are three moderate
advisories in the VitePress dependency chain:

- `vitepress <= 1.6.4` via `vite`
- `vite <= 6.4.1`
- `esbuild <= 0.24.2`

`npm audit --json` reports no high or critical advisories and no available fix
for that chain. These findings do not block the runtime release while the docs
site is served as static output only.

## Tag and Publish Checklist

- [ ] Commit and push the release-readiness changes to the default branch before
      creating or dispatching the release tag. The release workflow,
      live-eval workflow, verifier scripts, and support docs must exist on
      GitHub before the tag is pushed or manually dispatched.
- [ ] Review the full unpushed local range before pushing `main`; on the current
      launch branch, `main` may be ahead of `origin/main` by more than the
      final release-readiness commit.
- [ ] Create or verify the CalVer tag, for example `v2026.05.0`.
- [ ] Trigger `.github/workflows/release.yml` from the tag push, or manually
      dispatch it with explicit inputs. Do not use both paths unless
      intentionally rerunning the release workflow:

      ```bash
      # First publish the release-readiness changes to the default branch.
      git status --short --branch
      git rev-list --count origin/main..HEAD
      git log --oneline origin/main..HEAD
      test -z "$(git status --short)" || { echo "refusing to publish with a dirty tree" >&2; exit 1; }
      git log -1 --oneline
      git push origin main

      # Option A: push the tag and let the tag-push workflow create the release.
      git tag v2026.05.0
      git push origin v2026.05.0

      # Option B: if the tag already exists or the tag-push workflow did not run.
      gh workflow run release.yml \
        --ref v2026.05.0 \
        -f tag=v2026.05.0 \
        -f channel=stable
      ```

- [ ] Watch the intended release workflow run and require a successful exit:

      ```bash
      gh run list --workflow release.yml --limit 5
      gh run watch {run-id} --exit-status
      ```

- [ ] Confirm the workflow used the version-specific `CHANGELOG.md` section for
      the GitHub Release body.
- [ ] Confirm the workflow uploads:
  - `lemon-{version}-{channel}-linux-x86_64-lemon_runtime_min.tar.gz`
  - `lemon-{version}-{channel}-linux-x86_64-lemon_runtime_full.tar.gz`
  - `manifest.json`
- [ ] Confirm the workflow's `verify-published-artifacts` job downloaded the
      published GitHub Release assets and ran
      `scripts/verify_github_release_artifacts {tag-or-version}`. The verifier
      retries release lookup and asset download to tolerate GitHub asset
      propagation delays, then verifies checksums, boots the downloaded
      runtimes, checks health, and generates support bundles.
- [ ] Download the published artifacts from GitHub Release.
- [ ] Verify and boot downloaded artifacts with
      `scripts/verify_github_release_artifacts {tag-or-version}`.
- [ ] Mark the release as stable only after downloaded artifacts pass.

## Rollback Checklist

Rollback means recommending or restoring a previous known-good release artifact.
Lemon 1.0 does not have a remote binary auto-updater, so rollback is an operator
procedure.

- [ ] Identify the previous known-good GitHub Release and artifact profile.
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
- TUI, web, Telegram, and control-plane issues that can be reproduced on a
  supported source install or Linux release artifact.
- Discord, X/Twitter, XMTP, SMS, voice, and other channel adapters only as
  preview surfaces unless promoted by release notes.
- First-party text web search/fetch issues that can be reproduced in a
  supported agent run.
- Operator-controlled cron and scheduled automation as preview surfaces when
  failures are reproducible through first-party runtime or Web operations paths.
- Bugs accompanied by a redacted support bundle when diagnostics are needed.

Not supported for stable 1.0:

- Windows-native release artifacts.
- Unverified platform-specific packaging.
- Remote auto-update.
- Remote one-line install scripts.
- Hosted multi-tenant operation.
- Stable support guarantees for preview channel adapters.
- Production-grade scheduling guarantees, external scheduler integrations, or
  unrestricted model-facing cron management.
- First-class browser automation, generated media, image analysis, or TTS/voice
  behavior unless a release note explicitly promotes a narrower path.
- Production support for third-party plugins, unofficial MCP servers, or local
  model endpoints beyond documented OpenAI-compatible configuration.

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

Keep these files current during the 1.0 launch process:

- `docs/plans/lemon-1.0-mainstream-readiness.md`
- `docs/plans/lemon-1.0-fresh-install-proof-2026-05-11.md`
- `docs/plans/lemon-1.0-release-artifact-proof-2026-05-11.md`
- `docs/release/versioning_and_channels.md`
- `docs/release/deployment_flows.md`
- `.github/workflows/release.yml`
- `.github/workflows/product-smoke.yml`
- `.github/workflows/docs-site.yml`
- `.github/workflows/live-eval.yml`
- `scripts/bump_version.sh`
- `scripts/lint_ci_docs.sh`
- `scripts/audit_1_0_readiness`
- `scripts/prepare_release_notes`
- `scripts/verify_release_artifacts`
- `scripts/verify_release_runtime_boot`
- `scripts/verify_github_release_artifacts`
