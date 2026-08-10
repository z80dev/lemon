# Mix task reference

Lemon ships ~85 `mix lemon.*` tasks across the umbrella. `mix help | grep lemon`
lists them alphabetically with no grouping, which makes the tooling hard to
discover. This page groups every task by purpose. For a live, grouped listing
from the CLI, run:

```bash
mix lemon.help
```

`mix lemon.help` reads each task's `@shortdoc` at runtime, so it never drifts
from the code; this document adds the flags, examples, and follow-up notes that
the one-liner can't.

Each task's own docs are always available with `mix help lemon.<task>`.

---

## Onboarding & setup

Getting a fresh checkout or a fresh machine to a working agent.

| Task | Purpose |
| --- | --- |
| `mix lemon.new NAME` | Scaffold a new Lemon agent project. Ships in the `installer/` archive, **not** the umbrella — install it with `mix archive.install` before use. Flags: `--channel`, `--memory`, `--install`. |
| `mix lemon.setup` | First-time setup and configuration. |
| `mix lemon.onboard` | Top-level interactive provider onboarding (delegates to the per-provider tasks below). |
| `mix lemon.onboard.anthropic` | Interactive onboarding for the Anthropic provider. |
| `mix lemon.onboard.codex` | Interactive onboarding for the OpenAI Codex provider. |
| `mix lemon.onboard.copilot` | Interactive onboarding for the GitHub Copilot provider. |
| `mix lemon.onboard.gemini` | Interactive onboarding for the Google Gemini CLI provider. |
| `mix lemon.onboard.antigravity` | Interactive onboarding for the Google Antigravity provider. |
| `mix lemon.providers` | Show redacted provider readiness. |
| `mix lemon.workspace` | Initialize `~/.lemon/agent/workspace` bootstrap files. |
| `mix lemon.update` | Update Lemon: config migration and bundled-skill sync. |
| `mix lemon.hermes.audit` | Audit Hermes data compatibility without writing files. |
| `mix lemon.hermes.migrate` | Migrate compatible Hermes data into Lemon. |

## Secrets

Encrypted secret store plus the voice-specific helper. `mix lemon.secrets.init`
must run once to create the master key before the others resolve.

| Task | Purpose |
| --- | --- |
| `mix lemon.secrets.init` | Initialize the Lemon secrets master key. |
| `mix lemon.secrets.set KEY VALUE` | Store an encrypted secret. |
| `mix lemon.secrets.list` | List stored secret metadata (no values). |
| `mix lemon.secrets.status` | Show encrypted secrets status. |
| `mix lemon.secrets.check` | Check secret resolution sources (env vs. store). |
| `mix lemon.secrets.delete KEY` | Delete a stored secret. |
| `mix lemon.secrets.import_env` | Import env-based secrets into the encrypted store. |
| `mix lemon.voice.secrets` | Interactively set voice API secrets. |

## Diagnostics & readiness

Read-only, redacted health and configuration reports. Safe to run anywhere.

| Task | Purpose |
| --- | --- |
| `mix lemon.doctor` | Run Lemon diagnostics and report health. |
| `mix lemon.readiness` | Compact redacted launch-readiness summary. |
| `mix lemon.config` | Validate and inspect Lemon configuration (`--validate`, etc.). |
| `mix lemon.channels` | Show redacted Telegram and Discord launch readiness. |
| `mix lemon.usage` | Show redacted usage, cost, token, and quota diagnostics. |
| `mix lemon.proofs` | Show redacted local proof artifact status. |
| `mix lemon.media` | Show redacted generated-media and provider-proof readiness. |
| `mix lemon.models` | List known Lemon AI models (`--provider`, `--vision`, `--thinking`, `--json`). |
| `mix lemon.introspection` | Query agent introspection events. |
| `mix lemon.feedback` | Inspect historical routing feedback stats. |

## Quality & CI

The checks that run in `mix lemon.quality` on every push, plus adjacent guards.

| Task | Purpose |
| --- | --- |
| `mix lemon.quality` | Run docs and architecture quality checks (`--root`, `--validate-config`). |
| `mix lemon.architecture.docs` | Generate architecture boundary docs from policy. |
| `mix lemon.check_duplicate_tests` | Check for duplicate test module names. |
| `mix lemon.extension.validate` | Validate Lemon extension package manifests. |
| `mix lemon.cleanup` | Scan or prune stale docs/agent-loop run artifacts. |
| `mix lemon.eval` | Run the coding-quality eval harness. |

## Data, stores & messaging

Durable state and outbound notifications.

| Task | Purpose |
| --- | --- |
| `mix lemon.store.migrate_jsonl_to_sqlite` | Migrate Lemon store data from JSONL files to SQLite. |
| `mix lemon.memory` | Manage the durable memory store (`stats` / `prune` / `erase`). |
| `mix lemon.policy` | Manage per-route model policies (channel / account / peer / thread). |
| `mix lemon.send` | Send a Telegram or Discord notification from a script. |

## Skills

| Task | Purpose |
| --- | --- |
| `mix lemon.skill` | Manage Lemon skills (discover / install / update / remove). |
| `mix lemon.skill.lint` | Lint skill bundles for manifest compliance and audit cleanliness. |

## Benchmarks (platform)

| Task | Purpose |
| --- | --- |
| `mix lemon.bench` | Run the platform microbenchmark suites. See [`benchmarks/quickstart.md`](benchmarks/quickstart.md). |

## Sim & arena

`lemon_sim` contributes **41** tasks — roughly half of all `lemon.*` tasks. They
fall into four sub-groups.

### Scenario runners (self-play)

Each runs one scenario's self-play example. All share the common flags
`--seed`, `--max-turns`, `--offline-strategy`, `--no-persist`, and `--sim-id`
(run `mix help lemon.sim.<scenario>` for scenario-specific options).

`auction`, `courtroom`, `diplomacy`, `dungeon_crawl`, `intel_network`,
`legislature`, `murder_mystery`, `pandemic`, `poker`, `skirmish`,
`space_station`, `startup_incubator`, `stock_market`, `supply_chain`,
`survivor`, `tcg_shop`, `tic_tac_toe`, `vending_bench`, `werewolf` (19).

```bash
mix lemon.sim.tic_tac_toe --offline-strategy random --seed 42 --no-persist --max-turns 10
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci
```

### Replay renderers

Render a scenario's JSONL game log into a video/replay. One `*_replay` task
exists per scenario except `tic_tac_toe` and `tcg_shop`; `skirmish` uses the
generic `mix lemon.sim.replay`.

`auction_replay`, `courtroom_replay`, `diplomacy_replay`,
`dungeon_crawl_replay`, `intel_network_replay`, `legislature_replay`,
`murder_mystery_replay`, `pandemic_replay`, `poker_replay`,
`space_station_replay`, `startup_incubator_replay`, `stock_market_replay`,
`supply_chain_replay`, `survivor_replay`, `vending_bench_replay`,
`werewolf_replay` (16), plus the generic `mix lemon.sim.replay` (1).

### Scoring & verification

| Task | Purpose |
| --- | --- |
| `mix lemon.sim.score PATH` | Print the scorecard for a run artifact bundle. |
| `mix lemon.sim.verify PATH` | Verify a run artifact bundle. |

```bash
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/vending_bench/vb_ci
mix lemon.sim.score  apps/lemon_sim/priv/game_logs/vending_bench/vb_ci
```

### Suites, leaderboards & ratings

| Task | Purpose |
| --- | --- |
| `mix lemon.sim.suite` | Run a benchmark suite and write a leaderboard (`--scenario`, `--preset`, `--seeds`, `--offline`, `--external-cmd`, `--out`). |
| `mix lemon.sim.leaderboard PATH` | Print and rewrite a suite leaderboard (`--recompute`). |
| `mix lemon.sim.ratings` | Aggregate suite leaderboards into cross-suite model ratings (`--root`/`--suites`, `--out`). |

## Not a mix task

`scripts/release_package` is a shell **script**, not a `mix` task — invoke it
directly (`scripts/release_package <package>`). It is not listed by
`mix lemon.help`.

---

## Follow-up: sim task consolidation

The 19 scenario runners and 16 named replay renderers are near-identical
thin wrappers that differ only by scenario name. They could collapse into two
parameterized tasks:

- `mix lemon.sim <scenario>` — replacing the 19 runners.
- `mix lemon.sim.replay <scenario> <log>` — generalizing the already-existing
  generic `lemon.sim.replay` to replace the 16 named `*_replay` tasks.

That would remove **35 tasks** (of the 41 in `lemon_sim`), leaving
`score`, `verify`, `suite`, `leaderboard`, `ratings`, and the one generic
`replay`. This is a deliberately deferred refactor — larger and lower priority
than this index — tracked here as a follow-up, not done.
