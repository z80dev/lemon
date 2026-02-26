# Lemon Agent Guide

> **Effective agent context for the Lemon AI assistant platform.**  
> Lemon is a local-first assistant and coding agent system with a multi-engine architecture supporting Claude, Codex, OpenCode, Pi, and native Lemon engines.

---

## Quick Navigation

| If you want to... | Look in... |
|-------------------|------------|
| Add/modify AI provider support | `apps/ai/` |
| Work on coding tools or session management | `apps/coding_agent/` |
| Modify Telegram/Discord channel adapters | `apps/lemon_channels/` |
| Modify SMS/voice transports | `apps/lemon_gateway/` |
| Add new messaging channel adapters (X, XMTP, etc.) | `apps/lemon_channels/` |
| Work on agent routing or message flow | `apps/lemon_router/` |
| Build HTTP/WebSocket API features | `apps/lemon_control_plane/` |
| Manage configuration, secrets, or storage | `apps/lemon_core/` |
| Build game engines/match lifecycle services | `apps/lemon_games/` |
| Work with CLI runners/subagent spawning | `apps/agent_core/` |
| Create or modify skills | `apps/lemon_skills/` |
| Build cron jobs or automation | `apps/lemon_automation/` |
| Manage long-running external processes | `apps/lemon_services/` |
| Work on the web UI | `apps/lemon_web/` |
| Debug coding agent via RPC | `apps/coding_agent_ui/` |
| Market data ingestion | `apps/market_intel/` |
| Browser automation via CDP/Playwright | `clients/lemon-browser-node/` |

---

## Parallel Work & jj Workspaces

When working on multiple tasks in parallel (either as the same agent or multiple agents), **use jj workspaces to avoid file editing conflicts**.

### Workflow:

1. **Create a workspace for each parallel task:**
   ```bash
   jj workspace add --name=task-name ../lemon-task-name
   cd ../lemon-task-name
   ```

2. **Work in isolation** — Each workspace is an independent working directory backed by the same repo. Create a new change for your work:
   ```bash
   jj new main -m "Description of task"
   ```

3. **Clean up when complete** — After the change is merged/closed, remove the workspace:
   ```bash
   cd /path/to/main/lemon
   jj workspace forget task-name
   rm -rf ../lemon-task-name
   ```

### Why jj Workspaces?

- **No file lock conflicts** — Multiple agents can edit different files simultaneously without stepping on each other
- **Clean build contexts** — Each workspace maintains separate `_build/` and `deps/` (symlinked or independent)
- **Easy cleanup** — Remove workspaces when done without affecting the main repo
- **Native to this repo** — This repository uses Jujutsu (jj) for version control

### Golden Rule:

> **Never have multiple agents editing the same working directory simultaneously.** Always use jj workspaces for parallel tasks.

---

## Agent Team Composition

When spawning agents for parallel work, **match the agent tier to the task complexity**. Don't use Opus for investigation or Sonnet for architectural decisions.

### Role Model

| Role | Internal Model | External Model | Typical Tasks |
|------|---------------|----------------|---------------|
| Junior/Mid Dev | Sonnet | Kimi | Investigation, plan file creation, test running, config cleanup, doc updates, dependency audits, simple refactors |
| Senior Dev | Opus | — | Complex refactoring, architectural extraction, correctness-critical code, multi-module decomposition |
| Staff Engineer | Codex (MCP) | — | Plan ownership/review, architectural oversight, cross-cutting design decisions, final validation |

### Guidelines

- **Default to the lowest tier that can do the job** — Use Sonnet for exploration and investigation. Only escalate to Opus when the task involves complex logic, cross-module refactoring, or correctness-critical code.
- **Codex owns plans** — Matches the existing `owner: codex` / `reviewer: codex` convention in the planning system. Codex reviews architectural decisions and validates decomposition strategies.
- **Escalation pattern**: Sonnet investigates → Opus implements → Codex reviews. Not every task needs all three tiers.
- **Kimi for external/security**: Security audits, pre-push hooks, and external review tasks (already established in the pre-push hook workflow).
- **Planning metadata**: `owner:` and `reviewer:` fields in plan YAML front matter should reference these roles (e.g., `owner: codex`, `reviewer: codex`).

### Spawning Examples

```bash
# Sonnet for investigation (junior/mid)
# Use model: "sonnet" in Task tool or --model sonnet in CLI

# Opus for complex implementation (senior)
# Use model: "opus" in Task tool or default CLI model

# Codex for plan review (staff)
# Use mcp__codex__codex tool with architectural review prompt

# Kimi for security audit (external)
# Use kimi CLI runner for pre-push or security review
```

---

## Documentation Contract ⚠️

> **Work is not complete until it is adequately documented.**

**Any code change must be accompanied by updates to all relevant documentation.** This is non-negotiable. Outdated documentation is technical debt that compounds and confuses future developers (including yourself).

### When You Modify Code, You MUST:

1. **Update `AGENTS.md` files** — If you change architecture, patterns, dependencies, or behaviors described in any `AGENTS.md`, update it immediately.
2. **Update `README.md` files** — If your change affects setup, usage, APIs, or public interfaces, update the relevant README.
3. **Update architecture docs in `docs/`** — If your change affects design decisions, addendums to existing docs, or new architectural patterns, update or add docs.
4. **Update inline comments** — Complex logic, public functions, and non-obvious behaviors must have accurate, up-to-date comments.
5. **Update configuration examples** — If you add/remove config options, update `.lemon/config.toml` examples and config documentation.

### Examples of Documentation Debt to Avoid:

- Changing a module's behavior without updating its `@moduledoc` or `AGENTS.md`
- Adding a new tool/config/API without documenting how to use it
- Refactoring architecture while leaving stale dependency diagrams
- Modifying environment variables without updating `.env.example` or docs
- Changing a behavior but leaving old instructions in guides

### The Golden Rule:

> If you changed how something works, you must change the documentation that describes how it works. **No exceptions.**

Future agents (and humans) depend on accurate documentation to be effective. Don't make their job harder by leaving stale docs.

---

## Project Structure

```
apps/
├── agent_core/          # Core agent runtime, CLI runners (claude, codex, pi, kimi, opencode), subagent management
├── ai/                  # AI provider abstraction (Anthropic, OpenAI, Google, Azure, Bedrock)
├── coding_agent/        # Main coding agent with 35+ tools, session management, budget enforcement
├── coding_agent_ui/     # Thin wrapper that exposes coding_agent via RPC (mostly empty, used for tooling)
├── lemon_automation/    # Cron jobs, heartbeat manager, run submitter
├── lemon_channels/      # Channel adapters for inbound/outbound delivery (Telegram, Discord, X API, XMTP)
├── lemon_control_plane/ # HTTP/WebSocket API server with 80+ JSON-RPC methods
├── lemon_core/          # Shared primitives: config, store (ETS/JSONL/SQLite), secrets, PubSub bus
├── lemon_games/         # Turn-based game domain engine, match lifecycle, event projections
├── lemon_gateway/       # Gateway engines (claude, codex, pi, lemon, echo), SMS/voice/email/webhook/farcaster transports
├── lemon_router/        # Message routing, agent directory, run orchestration
├── lemon_services/      # Long-running external process management (OTP-based, no umbrella deps)
├── lemon_skills/        # Skill registry, discovery, installation
├── lemon_web/           # Phoenix LiveView web interface
└── market_intel/        # Market data ingestion, analysis (Ecto/SQLite, GenStage)

clients/
├── lemon-browser-node/  # Browser automation node via CDP/Playwright (TypeScript)
├── lemon-tui/           # Terminal UI client (TypeScript)
└── lemon-web/           # Web workspace (shared, server, web packages)

docs/                    # Architecture docs, design decisions
config/                  # Umbrella configuration (config.exs, runtime.exs, dev.exs, prod.exs)
scripts/                 # Utility scripts
```

---

## Build, Test & Development

### Elixir Umbrella

```bash
# Install dependencies
mix deps.get

# Compile all apps
mix compile

# Run all tests
mix test

# Run tests for specific app
mix test apps/ai
mix test apps/coding_agent

# Run integration tests
mix test --include integration

# Format code
mix format

# Quality checks after docs/dependency changes
mix lemon.quality
```

### TUI Client (TypeScript)

```bash
cd clients/lemon-tui
npm install
npm run build
npm run dev      # Watch mode
```

### Web Client

```bash
cd clients/lemon-web
npm install
npm run dev      # Start web server + frontend
npm run build    # Build shared/server/web packages
```

### Browser Node Client (TypeScript)

```bash
cd clients/lemon-browser-node
npm install
npm run build
npm run dev      # Watch mode
```

### Quick Dev Bootstrap

```bash
./bin/lemon-dev    # Installs deps, builds, launches TUI
./bin/lemon        # Unified runtime (gateway + control plane + router + channels + web)
./bin/lemon-tui    # TUI attached to unified runtime; auto-starts runtime if needed
```

---

## Architecture Overview

### Message Flow

```
[User via Telegram / SMS (Twilio) / Discord / XMTP / X]
    ↓
[lemon_gateway] - Transport layer, engine selection
    ↓
[lemon_router] - Route to appropriate agent, run orchestration
    ↓
[coding_agent] - Execute tools, manage sessions, budget enforcement
    ↓
[agent_core] - CLI runners (claude/codex/pi/kimi/opencode), subagent spawning
    ↓
[ai] - LLM provider calls (Anthropic, OpenAI, Google, Azure, Bedrock)
```

Outbound message delivery goes through `lemon_channels` (Telegram, X API, XMTP adapters).
The control plane (`lemon_control_plane`) provides the JSON-RPC API used by TUI/web clients.

### Key Dependencies Between Apps

Derived from mix.exs files and enforced by `mix lemon.quality` (architecture boundary check):

```
lemon_control_plane ──→ lemon_core, lemon_router, lemon_channels, lemon_skills, lemon_automation, lemon_gateway, ai, coding_agent*
lemon_router ─────────→ lemon_core, lemon_gateway, lemon_channels, coding_agent, agent_core
lemon_gateway ────────→ lemon_core, agent_core, ai, coding_agent, lemon_channels*
lemon_automation ─────→ lemon_core, lemon_router
lemon_channels ───────→ lemon_core
coding_agent ─────────→ lemon_core, agent_core, ai, lemon_skills
agent_core ───────────→ lemon_core, ai
lemon_skills ─────────→ lemon_core, agent_core, ai, lemon_channels
lemon_web ────────────→ lemon_core, lemon_router
market_intel ─────────→ lemon_core, agent_core, lemon_channels*
lemon_services ───────→ (no umbrella deps - standalone OTP service manager)
coding_agent_ui ──────→ coding_agent
ai ───────────────────→ lemon_core
```

`*` = runtime: false (compile-time only dependency)

---

## Configuration

- **User config**: `~/.lemon/config.toml`
- **Project config**: `.lemon/config.toml` (in repo root)
- **Secrets**: Managed via `mix lemon.secrets.*` tasks (`set`, `list`, `delete`, `status`, `init`)
- **Config inspection**: `mix lemon.config` - show resolved runtime config
- **Store migration**: `mix lemon.store.migrate_jsonl_to_sqlite`

Key env vars:
- `ANTHROPIC_API_KEY` - Claude provider
- `OPENAI_API_KEY` - OpenAI provider
- `LEMON_LOG_LEVEL` - Log level (debug/info/warning/error)
- `LEMON_STORE_PATH` - Persistent store path
- `LEMON_WEB_ACCESS_TOKEN` - Web UI auth token
- `LEMON_WEB_HOST` / `LEMON_WEB_PORT` - Web server binding (prod)
- `LEMON_WEB_SECRET_KEY_BASE` - Required in prod
- `DEEPGRAM_API_KEY` - Speech-to-text
- `ELEVENLABS_API_KEY` / `ELEVENLABS_VOICE_ID` - TTS
- `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_PHONE_NUMBER` - SMS

---

## Key Patterns

### Adding a New Tool

1. Create module in `apps/coding_agent/lib/coding_agent/tools/`
2. Implement `CodingAgent.Tool` behaviour
3. Add to `CodingAgent.Tools` registry
4. Update tool policy if needed

### Adding an AI Provider

1. Create provider module in `apps/ai/lib/ai/providers/`
2. Implement `Ai.Provider` behaviour
3. Register in `Ai.ProviderRegistry`

### Adding a Gateway Transport

External channel adapters live in `apps/lemon_channels/`. Current adapters include Telegram and Discord.
Gateway-native transports remain in `apps/lemon_gateway/` (SMS/Twilio, voice, email/webhook/farcaster glue).

1. Create transport module in `apps/lemon_gateway/lib/lemon_gateway/`
2. Implement appropriate behaviour (see existing transports for patterns)
3. Wire up in `LemonGateway.Application`

### Adding a Gateway Engine

Engines are in `apps/lemon_gateway/lib/lemon_gateway/engines/`. Current: `claude.ex`, `codex.ex`, `pi.ex`, `lemon.ex`, `opencode.ex`, `echo.ex`.

1. Create engine module implementing `LemonGateway.Engine` behaviour
2. Register in engine registry

---

## Testing & Debugging

### Gateway Debugging (Telegram)

```bash
# Terminal 1: Start gateway with debug logs
LOG_LEVEL=debug ./bin/lemon-gateway --debug --sname lemon_gateway_debug

# Terminal 2: Attach to BEAM node
iex --sname lemon_attach --cookie lemon_gateway_dev_cookie \
    --remsh lemon_gateway_debug@$(hostname -s)
```

Useful runtime checks:
```elixir
# Scheduler state
:sys.get_state(LemonGateway.Scheduler)

# Engine lock waiters
:sys.get_state(LemonGateway.EngineLock)

# Thread workers
DynamicSupervisor.which_children(LemonGateway.ThreadWorkerSupervisor)

# Session history
LemonCore.Store.get_run_history(session_key, limit: 10)
```

### Telethon Debug Loop

See `.claude/skills/telegram-gateway-debug-loop/SKILL.md` for detailed instructions on using Telethon with real Telegram credentials for testing.

---

## Security

### Pre-Push Security Hook

This repository includes an optional pre-push hook that uses **kimi** to review commits for sensitive information before pushing.

**What it checks for:**
- API keys (OpenAI, Anthropic, AWS, etc.)
- Passwords and authentication tokens
- Private keys (SSH, SSL, JWT secrets)
- Database connection strings with credentials
- Environment files (.env) containing secrets
- Hardcoded secrets in configuration files

**Installation:**
```bash
./bin/install-security-hook
```

**Usage:**
- The hook runs automatically on `git push`
- If sensitive data is detected, the push is blocked
- To bypass in emergencies: `git push --no-verify`
- To uninstall: `rm .git/hooks/pre-push`

**Note:** The hook is not installed by default. Each developer must opt-in by running the install script.

---

## Documentation Index

- `docs/architecture_boundaries.md` - Dependency boundaries and allowed cross-app references
- `docs/config.md` - Runtime configuration reference
- `docs/skills.md` - Skill system documentation
- `docs/quality_harness.md` - Quality checks and cleanup (`mix lemon.quality`, `mix lemon.cleanup`)
- `docs/assistant_bootstrap_contract.md` - Bootstrap contract
- `docs/context.md` - Context management
- `docs/telemetry.md` - Telemetry and observability
- `docs/extensions.md` - Extension system
- `docs/beam_agents.md` - BEAM agent architecture
- `docs/benchmarks.md` - Performance benchmarks
- `docs/model-selection-decoupling.md` - Model selection design
- `docs/agent-loop/` - Agent loop design docs
- `docs/testing/` - Testing guides
- `docs/tools/` - Tool documentation

---

## Coding Conventions

- **Elixir**: snake_case files, CamelCase modules
- **TypeScript**: Follow workspace ESLint config
- **Format**: Run `mix format` before committing
- **Tests**: `*_test.exs` for Elixir, `*.test.ts` for TypeScript
- **Commits**: Short, imperative style (`Fix gateway timeout`, `chore: update docs`)
- **Documentation**: See [Documentation Contract](#documentation-contract-) above — code changes require doc updates

---

## App-Specific Guides

Each app has its own `AGENTS.md` with detailed context:

| App | Location |
|-----|----------|
| agent_core | `apps/agent_core/AGENTS.md` |
| ai | `apps/ai/AGENTS.md` |
| coding_agent | `apps/coding_agent/AGENTS.md` |
| lemon_core | `apps/lemon_core/AGENTS.md` |
| lemon_gateway | `apps/lemon_gateway/AGENTS.md` |
| lemon_channels | `apps/lemon_channels/AGENTS.md` |
| lemon_router | `apps/lemon_router/AGENTS.md` |
| lemon_control_plane | `apps/lemon_control_plane/AGENTS.md` |
| lemon_skills | `apps/lemon_skills/AGENTS.md` |
| lemon_automation | `apps/lemon_automation/AGENTS.md` |
| lemon_services | `apps/lemon_services/AGENTS.md` |
| lemon_web | `apps/lemon_web/AGENTS.md` |
| market_intel | `apps/market_intel/AGENTS.md` |
| coding_agent_ui | `apps/coding_agent_ui/AGENTS.md` |

---

*Last updated: 2026-02-22* (added jj workspaces section)
