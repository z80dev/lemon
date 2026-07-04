# Lemon Exemplary-Repo Plan — 2026-07-04

Owner: @z80. Status: in execution.

Follow-up to `lemon-stack-reshape-2026-07-02.md` (executed). The reshape fixed
layering; this plan closes the remaining gap between "well-shaped repo" and
"exemplary public Elixir codebase that showcases the stack".

## Thesis (unchanged)

BEAM-native LLM interaction stack: `ai` → `agent_core` → two products.
The assistant is feature-comparable to Hermes Agent (Nous Research); the
**sim arena is the differentiator** — deterministic, replay-verified,
model-vs-model benchmarks with cost accounting. Nothing in the competitor
landscape has recompute-verified scorecards. Lead with that.

## Verified weaknesses (2026-07-04 audit)

1. **Missing table-stakes Elixir signals**: no `mix format --check-formatted`
   in CI, no Credo, no Dialyzer, no ExDoc. Home-grown quality gates
   (architecture boundaries, docs freshness, per-app coverage) are unusual and
   good — but a hiring reviewer looks for the standard tools first.
2. **Sim product layer unfinished**: 10 of 16 performance modules not onboarded
   to the verified `Scorecard` behaviour/registry; `Bench.Suite` hardcodes
   vending_bench/tcg_shop; no leaderboard or usage surface in `lemon_sim_ui`;
   no cross-suite/Elo ratings.
3. **Rendering boilerplate**: 15 near-identical `video_generator.ex` copies
   (~2,800 dup lines) and 15 `frame_renderer.ex` copies sharing SVG chrome
   (12.5k lines total, 40–60% reducible).
4. **Residual infra duplication**: token estimation (`chars ÷ 4`) ×5 across
   ai/agent_core/coding_agent/router; generic truncation primitives ×6;
   one backoff straggler (`CodingAgent.RateLimitHealer`). Canonical home is
   `ai` (only bottom node reachable by every consumer; `lemon_core` is
   invisible to `ai`).
5. **Docs drift + cruft**: architecture overview listed 15/21 apps and called
   the repo "an AI coding assistant"; dead `games-platform.yml` CI job for a
   nonexistent app; tracked `test.log`.
6. **Coverage floors near-cosmetic in places**: lemon_sim 33 (flagship!),
   lemon_web 5, x_api 35, sim_ui 37. 10 performance modules have no tests.

## Verified strengths (lean into)

- Deterministic event-sourced kernel + hash/scorecard recompute verification.
- Enforced layering (`mix lemon.quality` architecture checks in CI),
  warnings-as-errors, per-app coverage gates, OSV scan, deterministic
  regression loop, deployed VitePress docs site.
- Zero TODO/FIXME debt in lib code across 21 apps.
- `ai` is a genuinely standalone 26-provider LLM client — a library-quality
  showcase on its own.

## Phases

- **P0 — Land + hygiene** (done in this plan's first commits): merge
  `sim/flagship-2026-07`; delete dead CI job + tracked log; `mix format`
  everywhere + CI check; refresh architecture overview.
- **P1 — Sim flagship completion** (codex workers, parallel worktrees):
  - W-A: onboard the 10 remaining scenarios to `Scorecard` behaviour +
    registry + performance tests; generalize `Bench.Suite` run adapters.
  - W-B: extract shared `Examples.Rendering.VideoGenerator` +
    `FrameRenderer` chrome; scenarios keep only board-specific rendering.
  - W-C: `lemon_sim_ui` leaderboard LiveView reading `suite.json` bundles +
    per-run usage/cost in spectator.
  - W-D (after W-A): cross-suite Elo-style model ratings
    (`mix lemon.sim.ratings`), new aggregate artifact.
- **P2 — Stack dedup** (codex worker): `Ai.Tokens.estimate/1`, `Ai.Text`
  truncation primitives; delegate the 5 token-estimate and generic truncation
  copies; point `RateLimitHealer` at `LemonCore.Retry`. Keep
  `LemonCore.Retry` and `Ai.Providers.RetryHelper` as the two sanctioned
  backoff homes (two independent roots), documented.
- **P3 — Standard-tooling credibility**: Credo (curated config, zero
  violations at adoption), ExDoc for `ai`/`agent_core`/`lemon_sim`,
  `mix format --check-formatted` in CI (P0), Dialyzer evaluated for `ai`
  only (PLT cost vs. signal — decide, don't drift).
- **P4 — Polish**: raise coverage floors to new measured levels, README
  feature refresh (leaderboards, ratings, UI), memory/docs updates.

## Closed decisions

- Backoff math stays duplicated between `ai` and `lemon_core` (two roots that
  cannot see each other); classification stays in `Ai.Providers.RetryHelper`.
- `docs/plans/` stays in-tree as the decision log (catalog-stamped), not
  deleted; completed plans get `max_age_days: 365`.
