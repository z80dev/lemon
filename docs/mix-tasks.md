# Mix task reference

Lemon ships 54 `mix lemon.*` tasks across the umbrella (plus `mix lemon.new` from the installer archive). `mix help | grep lemon`
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
| `mix lemon.new NAME` | Scaffold a new Lemon agent project. Ships in the `installer/` archive, **not** the umbrella — install it with `mix archive.install` before use. Flags: `--hex` (Hex requirements, no checkout; not with `--channel`), `--channel`, `--memory`, `--lemon-path`, `--packages-path`, `--install`. |
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
| Hermes migration Mix tasks | Deleted; use `lemon migrate hermes` from a release or `./bin/lemon migrate hermes` from a source checkout. |

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
| `mix lemon.secrets.rotate_key` | Rotate the secrets master key and re-encrypt stored secrets. |
| `mix lemon.voice.secrets` | Interactively set voice API secrets. |

## Diagnostics

Read-only, redacted health and configuration reports. Safe to run anywhere.

| Task | Purpose |
| --- | --- |
| `mix lemon.doctor` | Run Lemon diagnostics and report health. |
| `mix lemon.config` | Validate and inspect Lemon configuration (`--validate`, etc.). |
| `mix lemon.channels` | Inspect channel configuration. |
| `mix lemon.usage` | Show redacted usage, cost, token, and quota diagnostics. |
| `mix lemon.media` | Show redacted generated-media job status. |
| `mix lemon.models` | List known Lemon AI models (`--provider`, `--vision`, `--thinking`, `--json`). |
| `mix lemon.introspection` | Query agent introspection events. |
| `mix lemon.feedback` | Inspect historical routing feedback stats. |

## Quality & CI

`mix lemon.quality` runs in CI (`scripts/test quality`) on every PR and push to main; the rest are adjacent guards.

| Task | Purpose |
| --- | --- |
| `mix lemon.quality` | Run the docs link, architecture docs, `deps/0` policy, and duplicate test module checks (`--root`, `--validate-config`). |
| `mix lemon.architecture.docs` | Generate architecture boundary docs from policy. |
| `mix lemon.check_duplicate_tests` | Check for duplicate test module names. |
| `mix lemon.extension.validate` | Validate Lemon extension package manifests. |
| `mix lemon.eval` | Run the coding-quality eval harness. |
| `mix lemon.eval.coding` | Run the opt-in live production-CLI coding benchmark. |

## Data, stores & messaging

Durable state and outbound notifications.

| Task | Purpose |
| --- | --- |
| `mix lemon.store.migrate_jsonl_to_sqlite` | Migrate Lemon store data from JSONL files to SQLite. |
| `mix lemon.honcho` | Inspect the Honcho memory satellite (`status` / `sessions` / `ping` / `context`). |
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

`lemon_sim` contributes **11** tasks, and `lemon_sim_ui` adds `mix lemon.sim.demo`. They fall into five sub-groups.

### Scenario runners (self-play)

Each runs one scenario's self-play example. All share the common flags
`--seed`, `--max-turns`, `--offline-strategy`, `--no-persist`, and `--sim-id`
(run `mix help lemon.sim.<scenario>` for scenario-specific options).

`poker`, `tic_tac_toe`, `vending_bench`, `werewolf` (4).

```bash
mix lemon.sim.tic_tac_toe --offline-strategy random --seed 42 --no-persist --max-turns 10
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci
```

### Demo

| Task | Purpose |
| --- | --- |
| `mix lemon.sim.demo` | Boot the sim UI and watch a keyless offline Werewolf game. |

### Replay renderers

| Task | Purpose |
| --- | --- |
| `mix lemon.sim.replay <scenario> <log>` | Render any scenario's JSONL game log into a video. |
| `mix lemon.sim.vending_bench_replay DIR` | Build a static HTML replay browser from a VendingBench artifact directory (not a video). |

`mix lemon.sim.replay` handles every video scenario through one task, backed by
each scenario's shared `VideoGenerator`. Scenarios: `poker`, `werewolf`. Both
the scenario and the log path are required.

```bash
mix lemon.sim.replay poker apps/lemon_sim/priv/game_logs/poker/abc.jsonl
mix lemon.sim.replay werewolf werewolf.jsonl --fps 3 --output werewolf.mp4
```

VendingBench keeps a separate task because its replay is a static HTML browser,
not a video. `tic_tac_toe` has no replay renderer.

### Scoring & verification

| Task | Purpose |
| --- | --- |
| `mix lemon.sim.score PATH` | Print the scorecard for a run artifact bundle. |
| `mix lemon.sim.verify PATH` | Verify a run artifact bundle: hashes, event replay (VendingBench, Werewolf, Poker), and scorecard recompute. Exits non-zero on failure. |

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

`scripts/release_package` and `scripts/verify_packages` are shell **scripts**,
not Mix tasks. Invoke `scripts/release_package PACKAGE VERSION` directly; see
[standalone packages](release/hex-packages.md). They are not listed by
`mix lemon.help`.

`./bin/lemon node join` is also a source wrapper, not a Mix task. It starts a
long-lived native coding execution worker and has no corresponding Mix task.

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

**Scenario runners remain separate.** The four retained runners have distinct
switch sets and example entrypoints: `werewolf` supports per-seat models,
`vending_bench` has benchmark presets, and `tic_tac_toe` exposes kernel-level
offline strategies. A shared dispatcher would not remove those differences.
VendingBench is also called directly by `scripts/sim_bench.sh` and
`scripts/generate_sim_demo_bundles.sh`.
