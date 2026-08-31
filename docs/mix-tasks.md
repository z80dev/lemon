# Mix task reference

Lemon ships ~70 `mix lemon.*` tasks across the umbrella. `mix help | grep lemon`
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

> **Packaged and source users:** use the release CLI (`lemon …`) or the
> matching source wrapper (`./bin/lemon …`) for normal setup and diagnostics.
> The Mix commands on this page are the direct contributor interfaces behind
> those user-facing verbs.

```bash
# Installed release
lemon setup
lemon model --provider anthropic
lemon gateway setup
lemon config validate
lemon secrets status
lemon channels
lemon providers status
lemon doctor

# Source checkout
./bin/lemon setup
./bin/lemon model --provider anthropic
./bin/lemon gateway setup
./bin/lemon config validate
./bin/lemon secrets status
./bin/lemon channels
./bin/lemon providers status
./bin/lemon doctor
./bin/lemon node join --name worker-1 --controller ws://controller:4040/ws --pair --cwd /srv/project
```

The installed `lemon` runtime CLI is included in the minimal and full release
profiles. It returns `0` for success, `1` for command failures, and `2` for
usage errors; command-specific help returns `0` without running the command.
The simulation release does not include this runtime CLI.

---

## Onboarding & setup

Getting a fresh checkout or a fresh machine to a working agent.

| Task | Purpose |
| --- | --- |
| `mix lemon.new NAME` | Scaffold a new Lemon agent project. Ships in the `installer/` archive, **not** the umbrella — install it with `mix archive.install` before use. Flags: `--channel`, `--memory`, `--install`. |
| `mix lemon.setup` | Idempotent first-run setup: derives config/secrets/provider state, creates only missing config and secrets state, skips an already usable provider, and verifies a newly configured provider unless `--skip-verify` defers its live check. This is the contributor alternative to `lemon setup` / `./bin/lemon setup`. |
| `mix lemon.onboard` | Top-level interactive provider onboarding. Contributor alternative to `lemon model` / `./bin/lemon model`. |
| `mix lemon.onboard.anthropic` | Interactive onboarding for the Anthropic provider. |
| `mix lemon.onboard.codex` | Interactive onboarding for the OpenAI Codex provider. |
| `mix lemon.onboard.copilot` | Interactive onboarding for the GitHub Copilot provider. |
| `mix lemon.onboard.gemini` | Interactive onboarding for the Google Gemini CLI provider. |
| `mix lemon.onboard.antigravity` | Interactive onboarding for the Google Antigravity provider. |
| `mix lemon.providers` | Show redacted provider readiness. This contributor task remains read-only; use `lemon providers` / `./bin/lemon providers` for fallback and credential-pool reference edits. |
| `mix lemon.workspace` | Initialize `~/.lemon/agent/workspace` bootstrap files. |
| `mix lemon.update` | Update Lemon: config migration and bundled-skill sync. |
| `mix lemon.hermes.audit` | Audit Hermes data compatibility without writing files. |
| `mix lemon.hermes.migrate` | Migrate compatible Hermes data into Lemon. |

## Secrets

Encrypted secret store plus the voice-specific helper. When running the
individual secrets tasks directly, `mix lemon.secrets.init` must run once to
create the master key. The full `mix lemon.setup` / `lemon setup` journey
initializes a missing master key itself and does not replace an existing one.

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

`lemon_sim` contributes **26** tasks. They fall into four sub-groups.

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

| Task | Purpose |
| --- | --- |
| `mix lemon.sim.replay <scenario> <log>` | Render any scenario's JSONL game log into a video. |
| `mix lemon.sim.vending_bench_replay DIR` | Build a static HTML replay browser from a VendingBench artifact directory (not a video). |

`mix lemon.sim.replay` handles every video scenario through one task, backed by
each scenario's shared `VideoGenerator`. Scenarios: `skirmish`, `auction`,
`courtroom`, `diplomacy`, `dungeon_crawl`, `intel_network`, `legislature`,
`murder_mystery`, `pandemic`, `poker`, `space_station`, `startup_incubator`,
`stock_market`, `supply_chain`, `survivor`, `werewolf`. A single positional
argument is treated as a `skirmish` log for backwards compatibility.

```bash
mix lemon.sim.replay poker apps/lemon_sim/priv/game_logs/poker/abc.jsonl
mix lemon.sim.replay werewolf werewolf.jsonl --fps 3 --output werewolf.mp4
```

VendingBench keeps a separate task because its replay is a static HTML browser,
not a video. `tic_tac_toe` and `tcg_shop` have no replay renderer.

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

`./bin/lemon node join` is also a source wrapper, not a Mix task. It starts a
long-lived native coding execution worker and therefore has no `mix
lemon.node.*` entry:

```bash
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join \
  --name worker-1 \
  --controller wss://controller.example/ws \
  --pair \
  --cwd /srv/project
```

Use `--pair` when creating the controller identity. Later starts reuse the
private, controller-bound token stored by durable node ID on the destination.
Re-run with `--pair` after the controller's seven-day session-token expiry to
recover the same durable node and revoke older sessions. Use the explicit
operator-authorized `--pair --repair --node-id ID` path only for a legacy record
without a recovery credential.
Prefer `LEMON_NODE_OPERATOR_TOKEN` / `LEMON_NODE_TOKEN` over token flags; node
names must be unique on the controller, and the destination cwd must already
exist.

Non-loopback controllers require `wss://` by default. Plaintext `ws://` needs
`--allow-insecure-controller` and is acceptable only for development or across
a verified encrypted overlay such as Tailscale.

---

## Sim task consolidation notes

**Done — replay renderers.** The 15 per-scenario `*_replay` tasks were folded
into the single parameterized `mix lemon.sim.replay <scenario> <log>`. They were
near-identical thin wrappers over each scenario's shared `VideoGenerator`
(`LemonSim.Examples.Rendering.DomainVideoGenerator`), so one registry-backed task
covers them all. `vending_bench_replay` stayed separate (it builds a static HTML
browser, not a video). Net: 15 tasks removed with no loss of capability.

**Deliberately not done — scenario runners.** The 19 `mix lemon.sim.<scenario>`
runners look consolidatable but are not: each has a distinct switch set and calls
distinct example-module entrypoints (e.g. `werewolf` does multi-model per-seat
assignment via `--models`/`--player-count`; `vending_bench` has `--preset` and
offline strategies; `tic_tac_toe` has `--offline-strategy`). A single
`mix lemon.sim <scenario>` would either be a leaky mega-task branching on
scenario, or a dispatcher that still keeps all 19 modules — both worse than 19
focused tasks. `vending_bench` is also called directly by CI
(`scripts/ci_sim_bench.sh`, `scripts/generate_sim_demo_bundles.sh`). Left as-is.
