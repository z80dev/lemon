# lemon 🍋

Lemon is an AI coding assistant that runs on your own machine, built as a distributed
system of concurrent processes on the BEAM (Erlang VM). You talk to it via Telegram
while it runs locally — or use the terminal UI or web UI directly.

Named after a very good cat.

---

## 5-Minute Setup

### Prerequisites

- Elixir 1.19+ and Erlang/OTP 27+
- A model provider API key (Anthropic, OpenAI, etc.)
- Node.js 20+ (TUI/Web clients only)

### 1. Clone and build

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix deps.get
mix compile
```

### 2. Configure

Create `~/.lemon/config.toml`:

```toml
[providers.anthropic]
api_key_secret = "llm_anthropic_api_key"

[defaults]
provider = "anthropic"
model    = "anthropic:claude-sonnet-4-20250514"
engine   = "lemon"
```

Store your API key:

```bash
mix lemon.setup secrets set llm_anthropic_api_key "sk-ant-..."
```

### 3. Run the automated setup (optional)

```bash
mix lemon.setup        # interactive walkthrough
mix lemon.doctor       # verify everything is working
```

### 4. Start Lemon

**TUI (development/local):**
```bash
./bin/lemon-dev /path/to/your/project
```

**Telegram gateway:**
```bash
./bin/lemon-gateway
```

### 5. Telegram quickstart

1. Create a bot via `@BotFather` — run `/newbot`, copy the token
2. Add to config: `gateway.telegram.bot_token = "..."` and `allowed_chat_ids = [your_id]`
3. Restart the gateway, then message your bot

Full Telegram setup details: [`docs/user-guide/setup.md`](docs/user-guide/setup.md)

---

## What You Can Do

| Feature | How |
|---|---|
| Chat with an AI coding assistant | Telegram, TUI, or Web UI |
| Run tasks in a specific repo | `/new /path/to/repo` or bind a project in config |
| Use skills (reusable knowledge modules) | `mix lemon.skill list` / `install` / `inspect` |
| Search past runs by content | `search_memory` tool (enable `session_search` flag) |
| Generate skill drafts from memory | `mix lemon.skill draft generate` |
| Schedule recurring tasks | Cron configuration in `~/.lemon/config.toml` |
| Use multiple LLM providers | 26 providers supported; configure in `[providers]` |

---

## Telegram Commands

| Command | What it does |
|---|---|
| `/new` | Start a new session |
| `/new /path/to/repo` | Start session bound to a repo |
| `/cwd [path\|clear]` | Set working directory for this chat |
| `/resume` | List previous sessions |
| `/cancel` | Cancel a running run |
| `/lemon`, `/claude`, `/codex` | Switch engine for one message |
| `/steer`, `/followup`, `/interrupt` | Queue mode overrides |

---

## Key Capabilities

**Agent:**
- 20 built-in tools: `bash`, `read`, `write`, `edit`, `grep`, `websearch`, `webfetch`, `task`, `agent`, and more
- Real-time streaming with live steering (inject messages mid-run)
- Session persistence via JSONL with tree-structured history
- Context compaction and branch summarization

**Routing & Execution:**
- Lane-aware scheduling: main (4), subagent (8), background (2)
- 26 LLM providers with automatic model selection
- Multi-engine: native Lemon + Codex CLI, Claude CLI, OpenCode CLI, Pi CLI
- Adaptive routing: learns from past run outcomes (enable `routing_feedback`)

**Skills:**
- Reusable knowledge modules loaded by the agent when relevant
- Manifest v2 format with category, required tools, and structured body
- Automatic draft synthesis from successful runs (enable `skill_synthesis_drafts`)

**Infrastructure:**
- Telegram, Discord, X/Twitter channel adapters
- Cron scheduling with heartbeats
- Event-driven architecture with pub/sub across all components
- Encrypted secrets keychain

---

## Documentation

| Audience | Start here |
|---|---|
| New users | [`docs/user-guide/setup.md`](docs/user-guide/setup.md) — full setup walkthrough |
| Skills | [`docs/user-guide/skills.md`](docs/user-guide/skills.md) — listing, installing, synthesizing |
| Memory & search | [`docs/user-guide/memory.md`](docs/user-guide/memory.md) — session search, retention |
| Adaptive features | [`docs/user-guide/adaptive.md`](docs/user-guide/adaptive.md) — routing feedback, synthesis |
| Architecture | [`docs/architecture/overview.md`](docs/architecture/overview.md) — system design |
| Config reference | [`docs/config.md`](docs/config.md) — full TOML reference |
| Non-Elixir users | [`docs/for-dummies/README.md`](docs/for-dummies/README.md) — plain-English tour |
| Contributors | [`AGENTS.md`](AGENTS.md) — project navigation and conventions |
| Full docs index | [`docs/README.md`](docs/README.md) — complete documentation map |

---

## Development

```bash
mix test                          # all tests
mix test apps/lemon_skills        # one app
mix lemon.quality                 # lint + doc freshness + architecture boundaries
```

**Release profiles:**

| Profile | Use case |
|---|---|
| `lemon_runtime_min` | Headless / CI / embedded |
| `lemon_runtime_full` | Local development |

```bash
MIX_ENV=prod mix release lemon_runtime_full
```

See [`ROADMAP.md`](ROADMAP.md) for what's planned.

---

## License

MIT — see LICENSE file.

---

## Acknowledgments

Lemon is heavily inspired by [pi](https://github.com/badlogic/pi-mono) (Mario Zechner),
draws architectural ideas from [Oh-My-Pi](https://github.com/can1357/oh-my-pi) (can1357),
[takopi](https://github.com/banteg/takopi) (banteg), OpenClaw, and Ironclaw.

Built with [Elixir](https://elixir-lang.org/) and the BEAM.
TUI powered by [@mariozechner/pi-tui](https://www.npmjs.com/package/@mariozechner/pi-tui).
