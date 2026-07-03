# LemonSim

LemonSim is the deterministic simulation arena in the Lemon stack. It runs LLMs
inside explicit game and benchmark worlds, records what happened, and produces
artifacts that can be replayed, scored, and verified.

## Shape

- `LemonSim.Kernel` owns the event-sourced core: state, events, runner flow,
  updater/action/projector behaviours, decision adaptation, persistence, and
  pubsub helpers.
- `LemonSim.LLM` owns model-facing execution: `ToolLoopDecider`, tool policies,
  provider/model setup, throttling, live-run helpers, and transcripts.
- `LemonSim.Bench` owns benchmark artifacts: manifests, scorecard behaviours,
  registry-driven scorecard recompute verification, hash verification, and
  shared run-bundle helpers.
- `LemonSim.Examples.*` owns the worlds. The examples are 92.3% of the current
  Elixir source under `apps/lemon_sim/lib`, because the interesting work is in
  scenario rules, tools, projections, and scoring.

`ToolLoopDecider` is the fairness boundary for heterogeneous models. A scenario
offers a constrained tool/action surface, the model chooses through that
surface, and the updater turns accepted actions into authoritative events.

## Scenarios

There are 19 examples in this app:

- `TicTacToe` is the smallest self-play scenario.
- `Werewolf` is the social-deduction showcase with hidden roles, transcripts,
  and video replay tooling.
- `VendingBench` is the operator/physical-worker vending business benchmark,
  with deterministic CI, paper, V2, and Arena modes.
- `TcgShop` is a single-operator local game store benchmark with inventory,
  suppliers, customers, events, online orders, accounting, and scorecards.
- `Diplomacy`, `Poker`, `Skirmish`, `Survivor`, `Pandemic`, `Auction`,
  `Courtroom`, `SpaceStation`, `StockMarket`, `SupplyChain`, `DungeonCrawl`,
  `MurderMystery`, `Legislature`, `IntelNetwork`, and `StartupIncubator` cover
  other state machines and decision surfaces.

## Run

Small local smoke run:

```bash
mix lemon.sim.tic_tac_toe --no-persist --max-turns 10
```

Deterministic benchmark run with artifacts:

```bash
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci_baseline
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/vending_bench/vb_ci_baseline
mix lemon.sim.score apps/lemon_sim/priv/game_logs/vending_bench/vb_ci_baseline
```

TCG Shop deterministic lanes:

```bash
mix lemon.sim.tcg_shop --preset ci --offline-strategy baseline --sim-id tcg_ci_baseline
mix lemon.sim.tcg_shop --preset ci --offline-strategy pressure --sim-id tcg_ci_pressure
mix lemon.sim.tcg_shop --preset stress --offline-strategy overextended --sim-id tcg_stress_bad_operator
```

Werewolf multi-model script, with providers and credentials configured:

```bash
mix run apps/lemon_sim/priv/scripts/werewolf_5model.exs
```

Werewolf has replay tooling but no `mix lemon.sim.werewolf` run task in this
checkout:

```bash
mix lemon.sim.werewolf_replay apps/lemon_sim/priv/game_logs/werewolf_4model.jsonl
```

Generic skirmish replay video generation:

```bash
mix lemon.sim.replay priv/game_logs/abc123.jsonl --output replay.mp4 --fps 4
```

Replay video tasks require `rsvg-convert` and `ffmpeg` on `PATH`.

## Artifacts

Benchmark runs write bundles under `apps/lemon_sim/priv/game_logs/...` unless
`--artifact-dir` is provided. Vending Bench and TCG Shop write rich bundles with
scenario-specific replay/transcript files. Poker, Stock Market, and Pandemic
write verified scorecard bundles with `manifest.json`, `hashes.json`,
`final_world.json`, `events.jsonl`, `actions.jsonl`, `scorecard.json`, and
`usage.json`.

Use:

```bash
mix lemon.sim.verify path/to/run
mix lemon.sim.score path/to/run
```

`verify` checks the manifest, hash schema, required benchmark files, manifest
integrity hashes, and hashed file contents. For scenarios registered in
`LemonSim.Bench.Scorecard.Registry`, it also recomputes `scorecard.json` from
`final_world.json` and compares canonical JSON. Registered verified scenarios:
`vending_bench`, `vending_bench_arena`, `tcg_shop`, `poker`, `stock_market`,
and `pandemic`. Unregistered scenarios still get manifest/hash verification and
skip scorecard recompute. `score` verifies first, then prints the scorecard.

## Suites and Leaderboards

Suites run one scenario across competitors and seeds, verify each run bundle,
aggregate the registered primary metric, and rank competitors with tokens and
cost alongside score. Keyless deterministic suites use offline strategies:

```bash
mix lemon.sim.suite --scenario vending_bench --preset ci --seeds 11,22,33 --offline baseline,pressure --out /tmp/vending-suite
```

That writes `/tmp/vending-suite/suite.json`, one verified bundle per
competitor/seed under `/tmp/vending-suite/runs/`, and
`/tmp/vending-suite/leaderboard.md`. The leaderboard shape is:

```markdown
# LemonSim Suite Leaderboard

Scenario: `vending_bench`
Preset: `ci`
Seeds: 3
Metric: `score_modes.v1_net_worth` (maximize)

All included runs are manifest hash and scorecard verified.

| Rank | Competitor | Mean score_modes.v1_net_worth (maximize) | Per-seed values | Tokens | Cost |
|---:|---|---:|---|---:|---:|
| 1 | baseline | ... | 11: ..., 22: ..., 33: ... | 0 | $0.0000 |
| 2 | pressure | ... | 11: ..., 22: ..., 33: ... | 0 | $0.0000 |
```

Live competitors can be added with repeatable `--model MODEL_ID` options when
provider credentials are configured. Re-render an existing suite without
rerunning scenarios:

```bash
mix lemon.sim.leaderboard /tmp/vending-suite
mix lemon.sim.leaderboard /tmp/vending-suite --recompute
```

`--recompute` re-verifies the run bundles and rebuilds rankings. Any failed or
tampered run stays visible in `suite.json` and the failure section of
`leaderboard.md`, but it is excluded from rankings.

## Write A Scenario

Start with `LemonSim.Examples.TicTacToe`; it is the smallest complete example.
The standard anatomy is:

- top-level scenario module, such as
  `apps/lemon_sim/lib/lemon_sim/examples/tic_tac_toe.ex`
- `action_space.ex` for legal model/user actions
- `updater.ex` for authoritative state transitions
- `events.ex` for emitted facts
- optional `performance.ex`, `game_log.ex`, `frame_renderer.ex`, or
  `video_generator.ex` when the scenario needs scoring or replay media

Keep scenario-specific rules in `LemonSim.Examples.*`. Shared runner,
model-loop, artifact, and verification logic belongs in `Kernel`, `LLM`, or
`Bench`.

## Spectator UI

`apps/lemon_sim_ui` is the LiveView spectator surface. It can watch registered
simulation runs, render scenario-specific boards, and serve replay-oriented
views for long or public runs.
