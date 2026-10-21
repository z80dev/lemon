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
- `LemonSim.Examples.*` owns the worlds. The examples are about three quarters
  of the Elixir source under `apps/lemon_sim/lib`, because the interesting work
  is in scenario rules, tools, projections, and scoring.

`ToolLoopDecider` is the fairness boundary for heterogeneous models. A scenario
offers a constrained tool/action surface, the model chooses through that
surface, and the updater turns accepted actions into authoritative events.

## Scenarios

There are four scenarios in this app:

- `TicTacToe` is the smallest self-play scenario and the tutorial example. It
  runs keyless with `--offline-strategy random`.
- `Werewolf` is the social-deduction showcase with hidden roles, transcripts,
  and video replay tooling. It is one of two scenarios in the persistent
  multi-game league system (`LemonSim.Bench.League` + per-scenario adapters,
  alongside `Poker`): randomized model-to-seat match planning, per-game
  records, and per-model/per-role standings with Bradley-Terry ratings. The
  `lemon_sim_ui` arenas run them around the clock when configured. Model play
  needs provider credentials; `mix lemon.sim.demo` (below) plays a keyless
  heuristic game in the spectator UI.
- `Poker` is a multi-hand no-limit hold'em session with per-seat model
  assignment; it is the second league/arena scenario (ranked mode on final
  chip stacks). It needs provider credentials to run.
- `VendingBench` is the operator/physical-worker vending business benchmark,
  with deterministic CI, paper, V2, offline Arena, and live multi-agent Arena
  modes. It is the only scenario with keyless suites and a CI byte-determinism
  gate.

## Run

Small local smoke run:

```bash
mix lemon.sim.tic_tac_toe --offline-strategy random --seed 42 --no-persist --max-turns 10
```

Deterministic benchmark run with artifacts, also keyless:

```bash
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci_baseline
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/vending_bench/vb_ci_baseline
mix lemon.sim.score apps/lemon_sim/priv/game_logs/vending_bench/vb_ci_baseline
```

### Keyless demo

One command boots the spectator UI and starts a live offline Werewolf game with
no provider API keys or model configuration:

```bash
mix lemon.sim.demo
mix lemon.sim.demo --seed 42 --player-count 7 --step-delay-ms 600
```

The task (in `apps/lemon_sim_ui`) starts `lemon_sim_ui` with its HTTP endpoint
unless it is already running in the same VM, starts the game through
`LemonSimUi.SimManager` with `offline_strategy: "heuristic"`, prints the
spectator URL (`http://localhost:4090/watch/<sim_id>` by default), and keeps
serving until interrupted. Every seat is played by the same heuristic as
`mix lemon.sim.werewolf --offline-strategy heuristic`
(`LemonSim.Examples.Werewolf.OfflineRunner.decide/2`): it picks a legal action
from `Werewolf.ActionSpace` with a `:rand` state seeded from the world seed, and
builds the event through `ActionSpace.execute_action/4`, so the same seed replays
the same game. `--step-delay-ms` (default 1200) paces turns for watching; the run
is persisted, resumable, and marked completed when the game ends. If another node
already serves the sim UI port, call `LemonSimUi.Demo.start_werewolf/1` from that
node's IEx shell or set `LEMON_SIM_UI_PORT`. Build browser assets once with
`mix sim_ui.assets.setup && mix sim_ui.assets.build`.

Live model runs require configured providers and credentials:

```bash
mix lemon.sim.tic_tac_toe --no-persist --max-turns 10
mix lemon.sim.werewolf --player-count 6 --no-persist --max-turns 50
mix lemon.sim.werewolf --player-count 5 --models anthropic:claude-sonnet-4-20250514,openai:gpt-4.1,google_gemini_cli:gemini-2.5-flash,openai-codex:gpt-6-luna,kimi:k2p5
mix run apps/lemon_sim/priv/scripts/werewolf_5model.exs
```

All live scenario facades resolve provider aliases, registered models, provider
base URLs, and API-key/OAuth secrets through
`LemonSim.LLM.GameHelpers.Config`. Unknown provider names fail without creating
new BEAM atoms; accepted names are bounded by `LemonAi.Models.get_providers/0`.

The `mix lemon.sim.*` wrappers share their runtime startup, optional keyword,
and simple provider/model parsing through `Mix.Tasks.Lemon.Sim.Common`.
The task helper delegates provider normalization to the same
`LemonSim.LLM.GameHelpers.Config` owner used by scenario facades while keeping
Mix-specific unknown-model errors.
Provider-qualified model specs accept registered provider names plus the
existing `gemini`, `gemini-cli`, `gemini_cli`, and `openai_codex` aliases;
unknown provider strings are rejected without creating atoms.

`mix lemon.sim.replay <scenario> <log>` renders Poker and Werewolf JSONL
transcripts to video. For example, a Werewolf transcript produced by
`mix lemon.sim.werewolf --models ... --transcript-path path.jsonl`:

Scenario log modules keep their domain-specific step and terminal metadata,
while `LemonSim.Examples.GameLog` provides the shared file lifecycle, JSONL
envelopes, event normalization, timestamps, and JSON-safe encoding.

```bash
mix lemon.sim.replay werewolf apps/lemon_sim/priv/game_logs/werewolf_4model.jsonl
mix lemon.sim.replay poker priv/game_logs/poker/abc123.jsonl --output replay.mp4 --fps 4
```

Both the scenario and the log path are required; run `mix lemon.sim.replay --help`
for options. The replay task requires `rsvg-convert` and `ffmpeg` on `PATH`.
(VendingBench uses `mix lemon.sim.vending_bench_replay`, which builds a static
HTML browser.)

## Artifacts

Benchmark runs write bundles under `apps/lemon_sim/priv/game_logs/...` unless
`--artifact-dir` is provided. VendingBench writes a rich bundle with replay and
transcript files. Poker writes a scorecard bundle with `manifest.json`,
`hashes.json`, `final_world.json`, `events.jsonl`, `actions.jsonl`,
`scorecard.json`, and `usage.json`. Werewolf does not write a bundle; its
`--artifact-dir` holds a JSONL transcript.

Usage counters and cost components are nullable: an unreported measurement stays
`null` in `usage.json`, including after a run resumes. Aggregates stay unknown if
any response or included run is unknown; known output or cache counts are still
retained independently. Catalog pricing alone does not make a partially measured
response's cost known. CLI summaries, VendingBench reports, and suite leaderboards
display these missing measurements as `unknown`, never as measured zeros. A
keyless offline run with no model calls still has zero usage and zero cost.

Use:

```bash
mix lemon.sim.verify path/to/run
mix lemon.sim.score path/to/run
```

### Determinism

[`test/lemon_sim/determinism_test.exs`](test/lemon_sim/determinism_test.exs)
runs the offline VendingBench strategy (a scripted decider, no LLM) twice with
one seed and asserts both the in-memory final world state and every artifact's
sha256 in `hashes.json` are identical. It is fast (~0.2s) and fully offline, so
it belongs in the CI lane, and `scripts/ci_sim_bench.sh` repeats the check on
the CLI with a double-run `diff -r`. The `deterministic_artifacts?: true` option
pins the two knobs that are nondeterministic by design (a unique run id and the
wall-clock timestamp).

`verify` checks the manifest, hash schema, required benchmark files, manifest
integrity hashes, and hashed file contents. For scenarios registered in
`LemonSim.Bench.Scorecard.Registry` (`poker`, `vending_bench`,
`vending_bench_arena`, and `werewolf`), it also recomputes `scorecard.json` from
`final_world.json` and compares canonical JSON. It does not re-fold
`events.jsonl` to rebuild `final_world.json`, so it proves the bundle is
internally consistent with its own hashes and scorecard, not that the recorded
run was replayed. Unregistered scenarios still get manifest/hash verification
and skip scorecard recompute. `score` verifies first, then prints the scorecard.

Regenerate local demo bundles with:

```bash
scripts/generate_sim_demo_bundles.sh [out_dir]
```

The generator writes deterministic VendingBench baseline and pressure bundles,
a CI-scale VendingBench Arena bundle, a small VendingBench suite, and ratings
output. It runs `mix lemon.sim.verify` and `mix lemon.sim.score` over every
bundle and prints a final metric summary. The default output directory is
`tmp/sim_demo_bundles`.

## Suites and Leaderboards

Suites run one scenario across competitors and seeds, verify each run bundle,
aggregate the registered primary metric, and rank competitors with tokens and
cost alongside score. Keyless deterministic suites use offline strategies:

```bash
mix lemon.sim.suite --scenario vending_bench --preset ci --seeds 11,22,33 --offline baseline,pressure --out /tmp/vending-suite
```

Competitor specs accept exactly one execution mode:

| Shape | Scenario support | Cost behavior |
| --- | --- | --- |
| `{"id":"baseline","offline_strategy":"baseline"}` | Deterministic adapters | `$0.0000` |
| `{"id":"model","model":"provider:model-id"}` | Live adapters | Provider pricing or unknown |
| `{"id":"my-agent","external_cmd":"python3 my_agent.py"}` | `vending_bench` | Unknown |

Suite run adapters are currently available for `vending_bench` and
`vending_bench_arena`. Other registered scorecards can be recompute-verified
from artifact bundles but do not yet have suite runners.

The keyless CI smoke lane is:

```bash
scripts/ci_sim_bench.sh
```

It runs deterministic offline suites for VendingBench and VendingBench Arena
under `$RUNNER_TEMP` or `tmp/`, verifies and scores every produced run bundle,
writes cross-suite ratings, and checks VendingBench byte-reproducible artifact
output with a double-run `diff -r` gate.

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
| 1 | baseline | ... ± ... (n=3) | 11: ..., 22: ..., 33: ... | 0 | $0.0000 |
| 2 | my-agent | ... ± ... (n=3) | 11: ..., 22: ..., 33: ... | 0 | unknown |
```

Each ranking entry in `suite.json` includes additive `stats` with `n`, `mean`,
sample `std`, `min`, and `max` for the primary metric across included seeds.

Live competitors can be added with repeatable `--model MODEL_ID` options when
provider credentials are configured. VendingBench external agents can be added
with repeatable `--external-cmd COMMAND` options. Re-render an existing suite
without rerunning scenarios:

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

Keep scenario-specific rules in `LemonSim.Examples.*`. Each scenario declares
the world `:status` values that end it via `terminal_statuses/0` and is listed
in `LemonSim.Examples`; runners, arenas, and UIs decide "finished" only through
`LemonSim.Examples.terminal?/1` (Tic Tac Toe ends `won`/`draw`, VendingBench
`complete`/`bankrupt`, Werewolf and Poker `game_over`). Shared runner,
model-loop, artifact, and verification logic belongs in `Kernel`, `LLM`, or
`Bench`. Mix-task-only startup and option plumbing belongs in the ordinary
functions in `Mix.Tasks.Lemon.Sim.Common`, not in scenario modules or task
macros.

## Spectator UI

`apps/lemon_sim_ui` is the LiveView spectator surface. It can watch registered
simulation runs, render scenario-specific boards, and serve replay-oriented
views for long or public runs.
