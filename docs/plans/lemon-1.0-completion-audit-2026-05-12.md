# Lemon 1.0 Completion Audit - 2026-05-12

Status: superseded by stricter Hermes parity audit

This audit maps the Lemon 1.0 mainstream-readiness objective to concrete repo
artifacts, commands, and remaining evidence gaps. It is intentionally stricter
than a test summary: a green test lane counts only when it covers the launch
requirement it is being used to prove.

Correction added 2026-05-12: this audit is no longer the controlling launch
verdict for Hermes parity. It treated the initial harness scorecard as enough
for the supported 1.0 scope. The active launch plan now requires the stricter
source-grounded feature comparison in
`docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md`, plus direct live
Telegram and Discord reliability proof before stable launch.

## Objective

Launch Lemon 1.0 as a mainstream-ready, self-hosted AI agent platform by
completing:

- truth audit and gap ledger
- installability and setup
- Hermes-class feature and reliability parity for the accepted stable scope
- packaging and release artifacts
- TUI, Web, Telegram, and bounded Discord interface readiness
- public website and docs
- deterministic and live-model testing
- supportability, diagnostics, and support policy

## Current Verdict

Lemon is not yet complete for stable public launch.

Earlier local release-candidate gates passed for release machinery and
deterministic harness coverage, but Lemon is not launch-complete. The active
blockers are Hermes parity and live channel reliability:

1. The Hermes feature parity matrix is now refreshed against current upstream
   Hermes `origin/main` at `4ad5fa702`, but the refreshed matrix adds or
   preserves launch-blocking scope decisions for live channels, browser/media,
   terminal backends, ACP/API server parity, automatic rollback, plugins,
   persistent goals, durable kanban boards, LSP semantic diagnostics, provider
   routing/fallback/credential pools, and supply-chain posture.
2. Direct Telegram live testing must pass for DM, group chat, forum topic,
   topic isolation, approvals, cancellation, restart/reconnect, duplicate
   avoidance, markdown/code rendering, long output, tool success/failure, and
   stable-boundary file/media behavior. Fresh live proof now covers DM recovery,
   forum-topic prompt/reply, topic isolation, topic-scoped cancellation,
   approval-button resolution in topic `35`, markdown/code rendering, and tool
   success/failure rendering, long-output chunking, and `/file get` document
   delivery, and restart/dedupe behavior. Telegram's text-first plus document
   delivery boundary is now live-proven.
3. Direct Discord live testing now passes for the supported text-first and
   file-delivery boundary. Bot credential/channel discovery, bot API smoke, and
   the second-bot manual matrix all pass through the established credentials
   file with `DISCORD_BOT_TOKEN` unset.
4. Browser/media/TTS/vision and multi-backend terminal parity must be either
   implemented and proven or explicitly kept out of stable launch claims.
5. Discord behavior outside the proven text-first and file-delivery boundary
   remains outside stable launch claims unless separately implemented and
   proven.

The remaining launch blockers are product and proof blockers, not publication
mechanics.

Toolchain status as of this audit:

- Official current stable releases checked on 2026-05-12: Elixir `1.19.5` and
  Erlang/OTP `28.5`.
- First-party CI and release workflow pins use Elixir `1.19.5` / OTP `28.5`,
  and `scripts/lint_ci_docs.sh` enforces those pins.
- The clean container source-install proof uses Elixir `1.19.5` on OTP `28.5`.
- This maintainer host now reports Elixir `1.19.5` on OTP `28.5` with ERTS
  `16.4`.
- The local release artifacts were rebuilt after that host upgrade, so the
  local tarball boot proof now covers the supported OTP patch level.

## Prompt-to-Artifact Checklist

| Requirement | Evidence | Verification | Status |
| --- | --- | --- | --- |
| Truth audit and gap ledger first | `docs/plans/lemon-1.0-mainstream-readiness.md` | Linked from README, docs index, VitePress navigation, and registered in `docs/catalog.exs` | Done |
| Product claims are honest | `README.md`, `docs/index.md`, `docs/compare.md`, `docs/demo.md`, readiness ledger | `scripts/lint_ci_docs.sh`, `scripts/verify_docs_site` | Done |
| Stable 1.0 support boundaries are explicit | `docs/support.md`, `docs/release/release_checklist_and_support_policy.md`, `docs/compare.md`, readiness ledger | Source install plus Linux tarballs; Telegram and Discord text-first/file boundaries stable; preview channels, cron, browser/media, install script, hosted service, and remote update boundaries documented | Done |
| Fresh source install works | `docs/plans/lemon-1.0-fresh-install-proof-2026-05-11.md` | Isolated `mix deps.get`, `mix compile`, `mix lemon.doctor --bundle` proof | Done |
| Setup path works | `mix lemon.setup`, `docs/user-guide/setup.md`, setup tests | Fresh setup proof and `scripts/test fast` | Done |
| Provider setup documented and tested | setup docs, config docs, fake-token Anthropic/OpenAI setup proof | Fresh install proof and setup task tests | Done |
| Supported toolchain is current | README, install docs, workflows, Dockerfile, lint script | Official sources checked on 2026-05-12; `scripts/lint_ci_docs.sh` enforces Elixir 1.19.5 / OTP 28.5 pins; clean container proof uses that pair | Done |
| Hermes-class parity is credible for 1.0 | `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md`, `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md` | The matrix is refreshed against Hermes `origin/main` at `4ad5fa702`; direct Telegram proof covers the text-first plus document-delivery boundary, Discord proof covers the text-first plus file-delivery boundary, and browser/media, terminal-backend, ACP/API server, rollback, plugin, persistent-goal, kanban, LSP, provider-routing, and supply-chain scope decisions remain outside stable claims unless promoted later | Partial / bounded for launch |
| Packaging builds local artifacts | `docs/plans/lemon-1.0-release-artifact-proof-2026-05-11.md` | Local `mix release` min/full, extracted boot, `/healthz`, support bundle | Done locally |
| Manifest verifies checksums | `scripts/verify_release_artifacts`, local artifact manifest | `scripts/verify_release_artifacts /tmp/lemon-release-artifact-proof-2026-05-0/artifacts` | Done locally |
| Release artifacts boot from tarballs | `scripts/verify_release_runtime_boot`, local artifact manifest | Extracts min/full tarballs, boots daemons, checks health, generates support bundles | Done locally |
| Release workflow publishes artifacts | `.github/workflows/release.yml` | Assembled artifacts are verified before publish; publishing is distribution work, not a readiness gate | Done for readiness |
| TUI happy path covered | `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md`, TUI tests | `scripts/test clients`, focused TUI proof entries | Done |
| Web UI happy path covered | Web ops routes, proof screenshots, interface proof pack | `scripts/test fast`, `scripts/test clients`, docs proof pack | Done |
| Telegram happy path covered | interface proof pack, Telegram adapter tests, support boundary docs, `scripts/live_telegram_matrix.py` | Fresh 2026-05-12 live proof covers DM recovery, forum-topic prompt/reply in topic `35`, topic isolation across topics `35` and `16456`, topic-scoped cancellation, topic approval-button resolution, markdown/code rendering, tool success/failure rendering, long-output chunking, `/file get` document delivery, and restart/dedupe behavior | Done for text-first + document-delivery boundary |
| Website exists and builds | `docs/index.md`, `docs/install.md`, `docs/compare.md`, `docs/support.md` | `scripts/verify_docs_site` | Done |
| Deterministic tests pass | canonical test lanes | `scripts/test fast`, `scripts/test quality`, `scripts/test eval-fast`, `scripts/test clients` | Done |
| Live-model evals run for release candidate | `scripts/test live-eval`, `.github/workflows/live-eval.yml` | Local provider-backed run passed on 2026-05-12 with Z.ai `glm-5-turbo`: 31 checks passed, 0 failed | Done |
| Support bundle exists and redacts secrets | `mix lemon.doctor --bundle`, support bundle modules/tests | `scripts/test fast`, support bundle tests, release artifact proof | Done |
| Issue/support flow is ready | `.github/ISSUE_TEMPLATE/bug_report.md`, `docs/support.md`, release support policy | `scripts/lint_ci_docs.sh`, docs-site verification | Done |
| Security model is public and current | `SECURITY.md`, `docs/security/safety.md`, `docs/security/agent-safety-contract.md` | `scripts/test fast`, `scripts/lint_ci_docs.sh`, safety tests | Done |

## Latest Evidence Snapshot

Commands run on 2026-05-12:

```bash
scripts/test fast
scripts/lint_ci_docs.sh
MIX_ENV=test mix lemon.quality
scripts/verify_docs_site
scripts/test_contract.sh
bash -n scripts/audit_1_0_readiness scripts/lint_ci_docs.sh scripts/verify_release_runtime_boot
git diff --check
scripts/verify_release_runtime_boot /tmp/lemon-release-artifact-proof-2026-05-0/artifacts
scripts/audit_1_0_readiness 2026.05.0 /tmp/lemon-release-artifact-proof-2026-05-0/artifacts
scripts/live_telegram_matrix.py --timeout 90
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 --topic-isolation --isolation-topic-id 35 --isolation-topic-id 16456 --timeout 180
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 --topic-cancel --cancel-topic-id 35 --timeout 95
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 --topic-tool-rendering --topic-markdown --timeout 160
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 --topic-approval --approval-topic-id 35 --timeout 180
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 --topic-long-output --long-output-topic-id 35 --timeout 120
scripts/live_telegram_matrix.py --skip-dm --skip-topic --topic-file-get --file-get-topic-id 35 --timeout 90
scripts/live_telegram_matrix.py --skip-dm --skip-topic --topic-restart-seed --restart-topic-id 35 --timeout 60
scripts/live_telegram_matrix.py --skip-dm --skip-topic --topic-restart-verify --restart-topic-id 35 --restart-nonce lemon-restart-seed-35-1778604398 --restart-reply-id 16685 --timeout 35
scripts/live_discord_matrix.py --list-channels
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-api-smoke
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --manual-matrix --reset-session-between-checks --timeout 300
LEMON_EVAL_API_KEY_SECRET={local-zai-secret} LEMON_EVAL_PROVIDER=zai LEMON_EVAL_MODEL=glm-5-turbo LEMON_EVAL_API_TYPE=openai_completions LEMON_EVAL_BASE_URL=https://api.z.ai/api/coding/paas/v4 scripts/test live-eval
```

Host toolchain for the latest broad local audit:

```text
Elixir 1.19.5 compiled with Erlang/OTP 28
Erlang/OTP: 28.5
ERTS: 16.4
```

The supported 1.0 toolchain remains Elixir `1.19.5` / OTP `28.5`; CI, the clean
Docker proof, and the refreshed local release artifact proof now align on that
patch level.

Current result:

- `scripts/test fast`: passed
- `scripts/lint_ci_docs.sh`: passed
- `scripts/verify_docs_site`: passed
- `scripts/test_contract.sh`: passed
- shell syntax check for release/audit verifier scripts: passed
- `git diff --check`: passed
- `scripts/verify_release_runtime_boot`: passed against refreshed local release
  artifacts built under OTP 28.5
- readiness audit: exit `66`, with all local gates passing and remaining live
  evidence blockers still open
- latest readiness audit rerun after test-stability fixes: exit `66`, with
  `fast`, `quality`, `eval-fast`, `clients`, docs, and local artifact boot gates
  passing; provider-backed live eval remained blocked at that point
- provider-backed live eval now passes locally: `scripts/test live-eval`
  reported 31 checks passing and 0 failing against Z.ai `glm-5-turbo`
- latest readiness audit rerun with `LEMON_EVAL_API_KEY_SECRET=llm_zai_api_key`:
  passed the local gates, provider-backed live eval, and Discord
  external-sender manual proof

The readiness audit confirmed:

- version metadata matches `2026.05.0`
- release notes are valid
- CI/docs policy lint passes
- fast, quality, eval-fast, and client lanes pass
- docs site verifies
- local artifacts verify and boot
- provider-backed live eval passes
- Discord external-sender manual live proof is present
- remote preflight evidence is printed directly by the audit script

## Remote Publish Preflight

Checked on 2026-05-12:

- Repository: `z80dev/lemon`
- Remote: `git@github.com:z80dev/lemon.git`
- Default branch: `main`
- Current local branch: `main`
- Current local branch divergence: `git rev-list --count origin/main..HEAD`
  returned `90`; pushing `main` will publish the full unpushed local range, not
  just the release-readiness commit.
- Current local HEAD: release-readiness commit
  `chore(release): prepare lemon 1.0 readiness`; run `git log -1 --oneline`
  immediately before pushing for the exact hash
- GitHub CLI: authenticated as `z80dev` with `repo` scope
- Non-mutating push preflight:
  - `git push --dry-run origin main` succeeded and would update `main` from
    `2f1aee5e` to the then-current local `HEAD`
  - `git push --dry-run origin HEAD:refs/tags/v2026.05.0` succeeded and would
    create the remote release tag
- Remote tag lookup: `git ls-remote --tags origin 'v2026.05.0*'` returned no
  tags.
- Release workflow lookup:
  `gh run list --workflow release.yml --limit 5` returned no runs.
- Live-eval workflow lookup:
  `gh run list --workflow live-eval.yml --limit 5` returned a GitHub API 404
  because the workflow exists only in the current local branch until these
  release-readiness changes are pushed.
- Release-eval secret lookup:
  `gh secret list` found none of `LEMON_EVAL_API_KEY`, `INTEGRATION_API_KEY`,
  or `ANTHROPIC_API_KEY`.

Remote publication is operationally possible from this checkout, but publication
is not a readiness gate. Publishing still requires explicit maintainer approval.

Provider-backed live eval already passed locally for this audit. Rerun it for
the final release candidate if code, prompts, tools, or provider configuration
change:

```bash
scripts/test live-eval
```

or dispatch the manual workflow:

```bash
gh secret set LEMON_EVAL_API_KEY --repo z80dev/lemon
gh workflow run live-eval.yml --ref v2026.05.0 -f iterations=3 -f live_timeout_ms=90000
gh run list --workflow live-eval.yml --limit 5
gh run watch {run-id} --exit-status
```

Final stable readiness should be accepted after the final readiness audit and
the live proof lanes pass.

## Goal Completion Gate

Do not mark the Lemon 1.0 mainstream-readiness goal complete while this audit
still exits `66` or while external evidence is missing. Completion
requires all of:

- the release-readiness changes are committed and pushed to `main`
- `scripts/test live-eval` passes locally with a real credential, or
  `.github/workflows/live-eval.yml` passes on GitHub with the intended release
  candidate ref
- Discord external-sender manual live proof JSON passes and is supplied to the final
  readiness audit
- `scripts/audit_1_0_readiness 2026.05.0 {local-artifact-dir}`
  exits `0`
