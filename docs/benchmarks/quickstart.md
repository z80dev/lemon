# Benchmarks Quickstart

This is the keyless path: no provider account, no model API key, and no network
calls. It runs the deterministic VendingBench baseline, verifies the artifact
bundle, scores it, then runs a two-competitor suite.

The commands below write to `/tmp` so a source checkout stays clean.

## Run One Benchmark

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci_baseline_docs --artifact-dir /tmp/lemon-vb-ci-baseline-docs --deterministic-artifacts
```

Trimmed output from this run:

```text
Offline artifacts written to /tmp/lemon-vb-ci-baseline-docs
usage: 0 in / 0 out, $0.00 (0 actors)
```

The `ci` preset is a seven-day run with a 25-turn driver limit. The offline
strategies currently accepted by the task are `baseline` and `pressure`.

## Inspect The Bundle

```bash
find /tmp/lemon-vb-ci-baseline-docs -maxdepth 2 -type f | sort
```

Trimmed output:

```text
/tmp/lemon-vb-ci-baseline-docs/actions.jsonl
/tmp/lemon-vb-ci-baseline-docs/commands.jsonl
/tmp/lemon-vb-ci-baseline-docs/config.json
/tmp/lemon-vb-ci-baseline-docs/events.jsonl
/tmp/lemon-vb-ci-baseline-docs/facts.jsonl
/tmp/lemon-vb-ci-baseline-docs/final_world.json
/tmp/lemon-vb-ci-baseline-docs/hashes.json
/tmp/lemon-vb-ci-baseline-docs/manifest.json
/tmp/lemon-vb-ci-baseline-docs/replay.html
/tmp/lemon-vb-ci-baseline-docs/scorecard.json
/tmp/lemon-vb-ci-baseline-docs/usage.json
```

## Verify And Score

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.verify /tmp/lemon-vb-ci-baseline-docs
```

```text
Verified vending_bench run
Status: complete
```

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.score /tmp/lemon-vb-ci-baseline-docs
```

Trimmed output:

```json
{
  "status": "complete",
  "day_number": 7,
  "units_sold": 183,
  "cash_on_hand": 583.35,
  "cash_in_machine": 63.75,
  "inventory_value_wholesale": 127.95,
  "active_failure_mode_count": 0,
  "score_modes": {
    "lemon_operational_score": 376.4,
    "money_balance": 583.35,
    "v1_net_worth": 775.05
  }
}
```

`verify` checks the manifest, hashes, required files, and the registered
VendingBench scorecard recomputed from `final_world.json`. `score` runs verify
first, then prints `scorecard.json`.

## Run A Suite

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.suite --scenario vending_bench --preset ci --seeds 7,8 --offline baseline,pressure --out /tmp/lemon-vb-suite-docs
```

Output:

```text
# LemonSim Suite Leaderboard

Scenario: `vending_bench`
Preset: `ci`
Seeds: 2
Metric: `score_modes.v1_net_worth` (maximize)

All included runs are manifest hash and scorecard verified.

| Rank | Competitor | Mean score_modes.v1_net_worth (maximize) | Per-seed values | Tokens | Cost |
|---:|---|---:|---|---:|---:|
| 1 | baseline | 766.52 | 7: 782.4, 8: 750.65 | 0 | $0.0000 |
| 2 | pressure | 704.31 | 7: 709.26, 8: 699.36 | 0 | $0.0000 |
```

The suite writes `suite.json`, `leaderboard.md`, and one verified run bundle per
competitor and seed under `runs/`.

## Cross-Suite Ratings

```bash
LEMON_STORE_PATH=/tmp/lemon-docs-store mix lemon.sim.ratings --suites /tmp/lemon-vb-suite-docs --out /tmp/lemon-vb-ratings-docs
```

Output:

```text
# LemonSim Ratings Leaderboard

Suites: 1
Algorithm: Bradley-Terry MLE with one pseudo draw per active pair.

| Rank | Competitor | Rating | Comparisons | W-L-D | Suites |
|---:|---|---:|---:|---:|---:|
| 1 | baseline | 1639.79 | 2 | 2-0-0 | 1 |
| 2 | pressure | 1360.21 | 2 | 0-2-0 | 1 |
```

