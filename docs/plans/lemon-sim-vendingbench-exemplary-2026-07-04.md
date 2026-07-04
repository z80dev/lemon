# VendingBench as an exemplary agent benchmark — 2026-07-04

Status: wave 1 complete (merged to main 2026-07-04); wave 2 pending
Owner: claude (orchestrator) + codex workers

## Wave 1 execution log (2026-07-04)

All six workstreams landed on main the same day. Each worker diff got a
dedicated code-review agent; every worker "green" was independently re-run.

- W-INTEG merged first (fixture regenerated post-merge for the new ruleset
  fingerprint). Review: no blocking bugs.
- W-REPRO merged; review caught two real items fixed by the orchestrator:
  arena.ex was fingerprinted into the PLAIN run ruleset_hash (now split:
  plain fingerprint excludes arena.ex; arena manifests carry
  arena_ruleset_hash), and arena bundles were not byte-reproducible
  (wall-clock ts_ms — now index-normalized in jsonl and pinned in embedded
  world copies under --deterministic-artifacts; CI gained an arena
  determinism gate; verified byte-identical).
- W-STATS merged; review clean except duplicated formatting between Suite and
  LeaderboardLive — Suite.format_metric_summary/1 is now public and shared.
- W-DOCS merged; review verified every command/number byte-for-byte; fixes:
  four docs/catalog.exs entries (+ this plan doc's), openai-codex credential
  wording corrected.
- W-DEMO merged; review fixes: realpath+descendant guard before rm -rf,
  run_mix trace to stderr (score JSON was being corrupted), orphaned legacy
  README dropped (the old "showcase" paper bundle turned out to be gitignored
  local state, never checked in — the generator replaces that story).
- W-EXT needed a second codex round for review findings (2 critical: unguarded
  Port.command crash path, {:noeol} fragmentation bricking runs; 2 high: no
  turn correlation → stale-reply desync, orphaned OS processes) — all fixed:
  guarded writes, line reassembly (70KB-line regression test), turn-echo
  correlation in protocol v0, SIGTERM/SIGKILL reaping. Merged after
  independent re-verification.

Post-merge on main: demo generator end-to-end green (90-day pressure
net_worth 3840.51 / baseline 4620.25; suite + BT ratings emitted), full
ci_sim_bench.sh green including both determinism gates, mix lemon.quality
green.
Predecessors: `lemon-sim-vendingbench-equivalent-goal-2026-05-16.md`, `lemon-sim-vendingbench-2-arena-goal-2026-05-27.md`, `lemon-exemplary-2026-07-04.md`

## Goal

Make VendingBench the exemplary public agent benchmark and the proof that LemonSim is
the best platform for running agent benchmarks. "Exemplary" is defined against the
public bar set by Andon Labs' Vending-Bench 2 (365-day horizon, money-balance metric,
5 runs per model averaged, adversarial "real-world messiness") plus the platform
properties VB2 does *not* have and LemonSim already does or can uniquely offer:

- byte-reproducible runs (seeded, event-sourced, hash-verified bundles)
- verifiable scoring (scorecard recompute from artifacts, tamper-evident leaderboards)
- first-class cost accounting (tokens + USD per competitor on every leaderboard)
- cross-suite Bradley-Terry ratings
- bring-your-own-agent (not just bring-your-own-model)
- live spectator UI + static replay bundles

## Where we are (audited 2026-07-04)

Strengths: event-sourced kernel with seeded determinism; VendingBench has v1/v2/arena
presets, adversarial suppliers, real nested physical-worker subagent, refunds/spoilage/
weather, checkpoints/resume/auto-wait for live runs, full artifact bundle incl.
`usage.json`, `manifest.json` (ruleset hash), `replay.html`; Suite → Ratings chain with
16 registered scorecards; ~55 scenario tests incl. byte-reproducibility.

Gaps found in audit:

1. Reproducibility is not CI-guarded — keyless suite/verify/score/ratings never run in CI.
2. Suite reports per-seed values but no variance statistics (VB2 averages 5 runs).
3. The published docs site (VitePress) has zero benchmark content; discovery is repo-README-only.
4. The only checked-in "showcase" run is a partial bundle (no usage/manifest/hashes) that
   ended at day 14 of 365.
5. Competitors can only be `provider:model` strings through the in-repo `ai` client —
   no external-agent protocol, so third parties cannot benchmark their own scaffolds.
6. Metric integrity nits: `stockouts` is a snapshot of currently-empty slots (not
   historical stockout-days); `arena_price_multiplier` is set but never consumed by the
   live demand path.
7. Arena is scripted-baseline only (no live multi-agent); public launcher is hardcoded to
   2 models / 30 days and disabled; usage panel exists only for replays, not live sims.
8. No live-model suite run has ever been recorded; nothing published to games.zeebot.xyz.

## Wave 1 — six parallel codex workers

Each worker runs in `.worktrees/wf-<name>`, leaves changes uncommitted in-tree, and
writes `/tmp/wf_<name>_report.md`. Orchestrator reviews, merges, and re-verifies
(`scripts/test path apps/lemon_sim/test/...`; never `mix test apps/X` at umbrella root).
Workstreams are file-disjoint by design; known seams are called out.

### W-REPRO — CI lane for reproducibility + bench smoke
New `.github/workflows/sim-bench.yml` (keyless, no API secrets):
- `mix lemon.sim.suite` for `vending_bench` (preset ci; competitors baseline+pressure;
  seeds 1,2), `vending_bench_arena` (preset ci), `tcg_shop` (preset ci).
- `mix lemon.sim.verify` + `mix lemon.sim.score` on each produced bundle.
- `mix lemon.sim.ratings` across the produced suites.
- Byte-determinism gate: run the vending_bench ci bundle twice with
  `--deterministic-artifacts` into two dirs; diff `hashes.json` (and full file hashes)
  — any drift fails the lane.
- Upload suite dirs as workflow artifacts. Target < 10 min wall clock.
Files: `.github/workflows/sim-bench.yml`, optional `scripts/ci_sim_bench.sh`.

### W-STATS — variance statistics in suites (VB2 parity: N runs averaged)
- `LemonSim.Bench.Suite`: per-competitor `stats` (additive to schema v1): `n`, `mean`,
  `std` (sample), `min`, `max` alongside existing `values_by_seed`. Ranking stays by
  mean (current behavior — verify; if ranking is by sum or single value, switch to mean).
- `leaderboard.md`: render `mean ± std (n)` per competitor.
- Preserve byte-determinism (stable key order, fixed float formatting).
- `LeaderboardLive` renders the new stats when present (guarded for old suite.json).
Files: `bench/suite.ex`, `bench/suite_test.exs`, `lemon_sim_ui .../leaderboard_live*`.

### W-DOCS — benchmark section on the docs site
VitePress (`docs/`): new "Benchmarks" nav section:
- Quickstart: keyless 5-minute path (ci preset, offline strategies, verify, score,
  suite, ratings) — must be copy-paste runnable with zero API keys.
- VendingBench page: what it simulates, presets (ci/paper/v2/arena), action space,
  scoring modes and `v1_net_worth` semantics, failure modes, comparison table vs
  Andon Labs Vending-Bench 1/2 (honest about differences: deterministic offline
  supplier/market corpora instead of live internet+email; that is the reproducibility
  trade).
- Platform page: artifact bundle contract, manifest/ruleset hash, verification, usage/
  cost accounting, suites, BT ratings, replay bundles, spectator UI.
- "Run your model" page: provider:model resolution, keys, presets, cost expectations.
Files: `docs/**` only (plus `.vitepress/config.js` nav).

### W-DEMO — exemplary demo bundles, generated not hand-checked-in
- `scripts/generate_sim_demo_bundles.sh` (or mix task): produces full deterministic
  bundles — vending_bench offline `pressure` (90-day, seed 42), offline `baseline`,
  and an arena baseline — plus a demo suite dir + `ratings.json`, all under a target dir.
- Test asserting the generated bundle verifies (`Bench.Artifacts.Verifier`) and the
  replay browser builds.
- Deal with the existing partial `vb_paper_live_20260527_161814` bundle: move it under
  `priv/fixtures/vending_bench/legacy_paper_live/` with a README noting it is a
  historical partial live run (or delete it if nothing references it) so no
  incomplete bundle poses as a showcase.
- Orchestrator will regenerate + check in the actual demo bundles after all wave-1
  merges (so they reflect final rulesets).
Files: `scripts/`, `apps/lemon_sim/test/...demo...`, fixture moves.

### W-EXT — bring-your-own-agent protocol (v0: single runs)
The strategic differentiator: benchmark *agents*, not just models.
- `LemonSim.LLM.Deciders.ExternalDecider`: JSON-lines over stdio to a competitor
  process. Per decision: write `{"type":"decision_request","sim_id":...,"turn":...,
  "observation":{...projector sections...},"tools":[...schemas...]}`; read
  `{"type":"tool_call","name":...,"arguments":{...}}` lines (support tools loop,
  terminal tool ends the decision, mirroring ToolLoopDecider + SingleTerminal policy).
  Timeouts, malformed lines, and process death map to the existing rejected-action /
  auto-wait recovery semantics. Tool *results* for support tools are written back as
  `{"type":"tool_result",...}` so the external agent can loop.
- `mix lemon.sim.vending_bench --external-cmd "python3 my_agent.py"` runs the live
  loop with ExternalDecider instead of a model.
- Reference client: `examples/external_agents/baseline_agent.py` (stdlib-only) that
  plays a simple restock loop; used by tests via a scripted stub.
- Usage tracking: external runs record zero tokens with `cost_known?: false`.
- Docs stub in apps/lemon_sim/README.md (W-DOCS covers the site separately).
Out of scope (wave 2): suite competitor spec `{"external": {...}}`, sandboxing.
Files: new decider module, mix task flag, `examples/external_agents/`, tests.

### W-INTEG — metric integrity fixes
- Historical stockout tracking: accumulate `stockout_days` (slot-days empty at
  rollover) in world state; `Performance` reports both snapshot and historical;
  `lemon_operational_score` penalty switches to the historical figure.
- `arena_price_multiplier`: wire it into the live demand path the way
  `arena_demand_multiplier` is consumed, or remove the dead field — pick one, justify
  in the report (leaning: consume it in `DemandModel.daily_sales` for arena worlds).
- Regenerate any checked-in fixtures whose scorecards/hashes shift
  (`priv/fixtures/vending_bench/ci_replay`), and update tests.
Files: `world.ex`, `updater.ex`, `performance.ex`, `demand_model.ex`, fixtures, tests.
Seam warning: W-DEMO generates bundles — resolved by W-DEMO shipping a *generator*,
with real bundles regenerated post-merge.

## Wave 2 (after wave-1 review/merge; some need my design first)

- **Live multi-agent Arena** (headline differentiator over VB2, which is single-agent):
  concurrent live operator loops in a shared arena world — needs an orchestration
  design (turn barriers per sim-day, shared-world event merge, per-agent usage) before
  delegation.
- Suite support for external competitors (`{"id":..., "external": {"cmd": [...]}}`).
- UI: configurable launcher (models/days from config), live usage panel in spectator.
- Live-model suite run (real keys, ≥2 models, ≥5 seeds, v2 preset scaled) + publish
  leaderboard/ratings to games.zeebot.xyz — requires user-provided keys/budget.
- Coverage floor raise for lemon_sim/lemon_sim_ui after new tests land.

## Wave 2 design sketch — live multi-agent Arena

Current Arena is N independent per-agent worlds stepped by a deterministic script,
with cross-world competition pressure applied between days and PvP interactions
injected on fixed days. The live version keeps the per-agent world/event-log model
and adds an orchestrator:

- `Arena.LiveRunner` (GenServer): owns N agent slots, each slot = kernel `State` +
  decider (LLM via ToolLoopDecider, or ExternalDecider once W-EXT lands) + its own
  `Usage` collector.
- **Day-barrier turn model**: within sim day D, each agent's decision loop runs in
  its own Task (agents only mutate their own world). The barrier: all agents must
  reach end-of-day (terminal `wait_for_next_day` or time exhaustion / auto-wait
  recovery) before the orchestrator (1) routes queued cross-agent events, (2)
  recomputes `apply_competition_pressure` from all agents' prices, (3) rolls every
  world to day D+1. A per-agent wall-clock budget per day prevents one stalled model
  from blocking the arena (budget exhaustion → auto-wait, same as single-agent
  recovery).
- **Cross-agent interactions**: `send_arena_message` / `send_arena_money` /
  `trade_with_agent` emit into the sender's log as today; the orchestrator assigns a
  monotonic arena sequence number and delivers to the recipient's inbox at the day
  barrier. Authoritative accounting stays in the updater (already tested:
  "arena worlds expose competitor tools and authoritative payment and trade
  accounting"). Barrier delivery keeps replay deterministic without cross-task
  ordering races.
- **Artifacts**: per-agent full standard bundles + arena-level bundle
  (`arena_events.jsonl` merged by sequence number, `arena_scorecard.json`
  leaderboard by `money_balance`, per-agent usage). Replay of the arena = replay of
  N per-agent logs + the sequenced cross-agent stream.
- **Failure containment**: bankrupt agents stop taking turns but their world stays
  in the arena (competitors can still see the machine); a crash-looping agent
  auto-waits days exactly like single-agent recovery.

## Acceptance (wave 1)

- CI: sim-bench lane green on a keyless runner; deliberate ruleset edit flips the
  byte-determinism gate red (verified once locally, not committed).
- `suite.json` carries stats; leaderboard.md shows `mean ± std (n)`; old suites still
  render.
- Docs site builds with the Benchmarks section; quickstart commands verified verbatim.
- Demo generator produces bundles that pass `verify` + `score`; partial legacy bundle
  no longer masquerades as a showcase.
- An external stdlib-Python agent completes a ci-preset run end-to-end via
  `--external-cmd`, producing a verifiable bundle.
- Historical stockout metric + arena multiplier resolution covered by tests; fixture
  regeneration keeps `verify` green; full fast suite green.

## Verification discipline (carried from lemon-exemplary-2026-07-04)

- Workers cannot commit (worktree .git metadata is read-only in their sandbox) and
  cannot write `$CLAUDE_JOB_DIR` — reports go to `/tmp/wf_<name>_report.md`.
- Copy `deps/` + `_build/` into each worktree (`cp -a`) to skip cold compiles.
- Re-verify every worker's "green" with `scripts/test path <test files>`.
- Code-review agent pass on each diff before merge; full fast suite + quality lane
  after each merge wave.
