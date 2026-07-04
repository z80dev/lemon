# lemon 🍋

Lemon is a BEAM-native stack for LLM interactions: a layered set of Elixir/OTP
libraries with two products on top, a multi-channel personal assistant and
**LemonSim**, a deterministic model-vs-model simulation arena.

Named after a very good cat.

```
ai            — provider-agnostic LLM client (standalone; no umbrella deps)
agent_core    — agent loop, tools, CLI-runner protocol (depends on ai, lemon_core)
lemon_core    — true foundation only: config, store, secrets, bus/event, telemetry
──────────────────────────────────────────────────────────────────────────────
products:
  assistant   — channels, gateway, router, control plane, skills, coding agent
  LemonSim    — deterministic model-vs-model simulation arena
```

## Why BEAM

LLM products are already distributed systems: conversations run independently,
tool calls block, providers fail, users interrupt, and long-running sessions
need supervision. Lemon leans into that shape. It uses real OTP supervision
trees, per-conversation processes, message passing, and distributed-by-default
runtime primitives instead of wrapping a single process in queue glue.

## LemonSim

LemonSim is the arena side of the stack. It provides an event-sourced
simulation kernel, seeded deterministic runs, tool-constrained LLM decisions,
scored benchmark artifacts, replay verification with hash manifests, and a
LiveView spectator UI in `apps/lemon_sim_ui`.

What makes it different from an eval harness: results are **verifiable**.
Every run writes a hash-manifested artifact bundle, every scenario's scorecard
is a pure function of the final world state that the verifier recomputes and
diffs, and per-actor token/cost usage is recorded alongside. All 19 scenarios
are playable and all 16 scored scenarios are registry-verified: Werewolf,
Vending Bench, TCG Shop, Diplomacy, Poker, Tic Tac Toe, Skirmish, Survivor,
Pandemic, Auction, Courtroom, Space Station, Stock Market, Supply Chain,
Dungeon Crawl, Murder Mystery, Legislature, Intel Network, and Startup
Incubator.

On top of single runs sit benchmark **suites** (competitors × seeds matrices
with deterministic `suite.json` + `leaderboard.md` artifacts), cross-suite
**model ratings** (order-independent Bradley-Terry fit over pairwise
seed-level comparisons), and a public `/leaderboards` page in the spectator
UI.

Keyless quick start (no API keys required):

```bash
mix lemon.sim.tic_tac_toe --offline-strategy random --seed 42 --no-persist --max-turns 10
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci_baseline
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/vending_bench/vb_ci_baseline
mix lemon.sim.score apps/lemon_sim/priv/game_logs/vending_bench/vb_ci_baseline
mix lemon.sim.suite --scenario vending_bench --preset ci --seeds 7,8 --offline baseline,pressure --out /tmp/vb_suite
mix lemon.sim.ratings --suites /tmp/vb_suite --out /tmp/vb_ratings
```

With provider credentials configured, the same commands run live models
against each other:

```bash
mix lemon.sim.werewolf --player-count 6 --no-persist --max-turns 50
mix lemon.sim.werewolf --models "anthropic:claude-sonnet-4,openai:gpt-5,..." --sim-id ww_showdown
```

The TicTacToe offline and VendingBench offline commands are keyless
deterministic runs. Live `tic_tac_toe`, `werewolf`, and the Werewolf
compatibility scripts require configured model provider credentials. Werewolf
replay generation is available through:

```bash
mix lemon.sim.werewolf_replay apps/lemon_sim/priv/game_logs/werewolf_4model.jsonl
```

See [`apps/lemon_sim/README.md`](apps/lemon_sim/README.md) for the arena guide.

## Assistant

The assistant product is the same stack in a personal-agent shape: Telegram,
Discord, X/XMTP previews, local TUI, web UI, routing, gateway execution slots,
skills, coding tools, encrypted secrets, and persistent run history.

### 5-Minute Setup

#### Prerequisites

- Elixir 1.19.5+ and Erlang/OTP 28.5+
- A model provider API key (Anthropic, OpenAI, etc.)
- Node.js 24 LTS+ for TUI/Web clients

#### 1. Clone and build

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix deps.get
mix compile
```

#### 2. Configure

Create `~/.lemon/config.toml`:

```toml
[providers.anthropic]
api_key_secret = "llm_anthropic_api_key_raw"

[defaults]
provider = "anthropic"
model    = "anthropic:claude-sonnet-4-20250514"
engine   = "lemon"
```

Store your API key:

```bash
mix lemon.secrets.set llm_anthropic_api_key_raw "sk-ant-..."
```

On Linux and other non-keychain environments, keep
`~/.lemon/secrets_master_key` as the canonical local master key file. The
`./bin/lemon` wrapper normalizes `LEMON_SECRETS_MASTER_KEY` from that file at
startup.

#### 3. Run the setup checks

```bash
./bin/lemon setup
./bin/lemon channels
./bin/lemon config validate
./bin/lemon doctor
./bin/lemon secrets status
./bin/lemon skill list
```

The source wrapper commands delegate to Mix tasks, for example
`./bin/lemon setup` -> `mix lemon.setup`, `./bin/lemon config` ->
`mix lemon.config`, `./bin/lemon doctor` -> `mix lemon.doctor`, and
`./bin/lemon skill` -> `mix lemon.skill`. Use `./bin/lemon --help` and
subcommand `--help` output for the full command list.

For source-checkout maintenance, `./bin/lemon update --check` delegates to the
stage-1 local `mix lemon.update` task. It reports the current version, checks
config migration state, and can sync bundled skills when run without
`--no-skill-sync`; it does not download or swap remote release binaries.

#### 4. Start Lemon

TUI:

```bash
./bin/lemon-dev /path/to/your/project
```

Telegram gateway:

```bash
./bin/lemon-gateway
```

Web UI / operations dashboard:

```bash
./bin/lemon
# session console: http://localhost:4080/
# ops dashboard:   http://localhost:4080/ops
```

Script notifications:

```bash
./bin/lemon send --to telegram:<chat_id> "deploy finished"
echo "RAM 92%" | ./bin/lemon send --to discord:<channel_id>
./bin/lemon send --to discord:#ops --attach report.txt --attach trace.log "deploy report"
```

`./bin/lemon send` supports Telegram and Discord targets, optional `:thread_id`,
`--thread`, `--topic`, `--account`, `--reply-to`, `--subject`, `--file`,
`--file -`, repeated `--attach` uploads up to 10 files, `--dry-run`, `--json`,
`--quiet`, `--help`, and filtered `--list`. Platform-only targets use env
defaults first, then `[gateway.telegram] default_chat_id` /
`default_thread_id` / `default_topic_id` or `[gateway.discord]
default_channel_id` / `default_thread_id`. Default account ids use
`LEMON_TELEGRAM_DEFAULT_ACCOUNT_ID` / `LEMON_DISCORD_DEFAULT_ACCOUNT_ID`, then
`[gateway.telegram] default_account_id` / `[gateway.discord]
default_account_id`. Dry-run validates targets, body/caption resolution, and
attachment metadata without platform credentials or delivery. List mode reports
env/config defaults plus bounded recent Telegram/Discord known-target windows
with exact reusable aliases when the BEAM store has seen chats, channels, or
threads. `--account <id>` selects the channel account for delivery and scopes
known-target listing/name resolution. `--thread <id-or-name>` and
Telegram-friendly `--topic <id-or-name>` set the thread/topic separately from
`--to` and fail if the target already embeds a thread.
`--reply-to <message-id>` replies under an existing platform message when the
channel adapter supports it. Unique known names work for Telegram and Discord,
such as `telegram:#lemon-ops`, `telegram:@lemon_ops`,
`telegram:#lemon-ops:deploys`, `discord:#ops`, or `discord:#ops:deploys`.

#### 5. Telegram quickstart

1. Create a bot via `@BotFather` with `/newbot`, then copy the token.
2. Add `gateway.telegram.bot_token = "..."` and
   `allowed_chat_ids = [your_id]` to config.
3. Restart the gateway, then message your bot.

Full Telegram setup details: [`docs/user-guide/setup.md`](docs/user-guide/setup.md)

## Assistant Capabilities

| Feature | How |
|---|---|
| Chat with an AI coding assistant | Telegram, TUI, or Web UI |
| Run tasks in a specific repo | `/new /path/to/repo` or bind a project in config |
| Switch engines | `/lemon`, `/claude`, `/codex`, `/opencode`, or `/pi` |
| Use skills | `./bin/lemon skill list`, `install`, `inspect` |
| Search past runs | `search_memory` tool with the `session_search` flag |
| Generate skill drafts | `mix lemon.skill draft generate` |
| Schedule recurring tasks | Cron configuration in `~/.lemon/config.toml` |
| Send shell/CI notifications | `./bin/lemon send --to telegram:<chat_id> "done"` |
| Check channel readiness | `./bin/lemon channels` |
| Check provider readiness | `./bin/lemon providers --provider openai` |
| Inspect redacted proof artifacts | `./bin/lemon proofs --limit 5` |
| Check usage/cost totals | `./bin/lemon usage` |

Telegram commands include `/new`, `/cwd`, `/resume`, `/cancel`, `/lemon`,
`/claude`, `/codex`, `/steer`, `/followup`, and `/interrupt`.

## Documentation

| Audience | Start here |
|---|---|
| LemonSim | [`apps/lemon_sim/README.md`](apps/lemon_sim/README.md) |
| Public docs site | [`docs/index.md`](docs/index.md) |
| Install landing page | [`docs/install.md`](docs/install.md) |
| New users | [`docs/user-guide/setup.md`](docs/user-guide/setup.md) |
| Skills | [`docs/user-guide/skills.md`](docs/user-guide/skills.md) |
| Memory & search | [`docs/user-guide/memory.md`](docs/user-guide/memory.md) |
| Adaptive features | [`docs/user-guide/adaptive.md`](docs/user-guide/adaptive.md) |
| Architecture | [`docs/architecture/overview.md`](docs/architecture/overview.md) |
| Config reference | [`docs/config.md`](docs/config.md) |
| Non-Elixir users | [`docs/for-dummies/README.md`](docs/for-dummies/README.md) |
| Contributors | [`AGENTS.md`](AGENTS.md) |
| Full docs index | [`docs/README.md`](docs/README.md) |

## Development

```bash
scripts/test fast                 # compile with warnings as errors + ExUnit excluding integration
scripts/test path apps/lemon_skills/test
scripts/test quality              # lint + doc freshness + architecture boundaries
scripts/test clients              # Python CLI package check + Node client CI parity
```

See [`docs/testing.md`](docs/testing.md) for the canonical local test lanes and
how they map to CI.

GitHub Copilot coding-agent runs use
[`/.github/workflows/copilot-setup-steps.yml`](.github/workflows/copilot-setup-steps.yml)
to preinstall BEAM/Rust toolchains plus Hex dependencies before the agent
firewall is enabled. Keep it aligned with the versions and dependency bootstrap
steps in [`/.github/workflows/quality.yml`](.github/workflows/quality.yml).

Release profiles:

| Profile | Use case |
|---|---|
| `lemon_runtime_min` | Headless/API runtime with gateway, router, channels, and control plane |
| `lemon_runtime_full` | Full local runtime with automation, skills, web UI, and sim UI |
| `sim_broadcast_platform` | Public sim broadcast and replay deployment (`lemon_sim_ui`) |

```bash
MIX_ENV=prod mix release lemon_runtime_full
```

## License

MIT — see LICENSE file.

## Acknowledgments

Lemon is heavily inspired by [pi](https://github.com/badlogic/pi-mono) (Mario Zechner),
draws architectural ideas from [Oh-My-Pi](https://github.com/can1357/oh-my-pi) (can1357),
[takopi](https://github.com/banteg/takopi) (banteg), OpenClaw, and Ironclaw.
Skill library bootstrapped from [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research).

Built with [Elixir](https://elixir-lang.org/) and the BEAM.
TUI powered by [@mariozechner/pi-tui](https://www.npmjs.com/package/@mariozechner/pi-tui).
