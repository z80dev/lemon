# Lemon Agent Guide

> **Effective agent context for the Lemon AI assistant platform.**  
> Lemon is a local-first assistant and coding agent system with a multi-engine architecture supporting Claude, Codex, OpenCode, Pi, and native Lemon engines.

---

## Quick Navigation

| If you want to... | Look in... |
|-------------------|------------|
| Add/modify AI provider support | `apps/ai/` |
| Work on coding tools or session management | `apps/coding_agent/` |
| Modify Telegram/Discord/voice transports | `apps/lemon_gateway/` |
| Add new messaging channels (X, XMTP, etc.) | `apps/lemon_channels/` |
| Work on agent routing or message flow | `apps/lemon_router/` |
| Build HTTP/WebSocket API features | `apps/lemon_control_plane/` |
| Manage configuration, secrets, or storage | `apps/lemon_core/` |
| Work with CLI runners/subagent spawning | `apps/agent_core/` |
| Create or modify skills | `apps/lemon_skills/` |
| Build cron jobs or automation | `apps/lemon_automation/` |
| Work on the web UI | `apps/lemon_web/` |
| Debug coding agent via RPC | `apps/coding_agent_ui/` |
| Market data ingestion | `apps/market_intel/` |

---

## Project Structure

```
apps/
├── agent_core/          # Core agent runtime, CLI runners, subagent management
├── ai/                  # AI provider abstraction (Anthropic, OpenAI, etc.)
├── coding_agent/        # Main coding agent with 30+ tools
├── coding_agent_ui/     # Debug RPC interface for coding agent
├── lemon_automation/    # Cron jobs, heartbeats, automation
├── lemon_channels/      # Channel adapters (Telegram, X API, XMTP)
├── lemon_control_plane/ # HTTP/WebSocket API, JSON-RPC methods
├── lemon_core/          # Shared primitives, config, store, secrets
├── lemon_gateway/       # Gateway transports, engines, message handling
├── lemon_router/        # Message routing, agent directory
├── lemon_services/      # External service management
├── lemon_skills/        # Skill registry, installation
├── lemon_web/           # Phoenix web interface
└── market_intel/        # Market data ingestion, analysis

clients/
├── lemon-tui/           # Terminal UI client (TypeScript)
└── lemon-web/           # Web workspace (shared, server, web)

docs/                    # Architecture docs, design decisions
config/                  # Umbrella configuration
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

### Quick Dev Bootstrap

```bash
./bin/lemon-dev    # Installs deps, builds, launches TUI
```

---

## Architecture Overview

### Message Flow

```
[User via Telegram/Discord/Email/SMS] 
    ↓
[lemon_gateway] - Transport layer, engines
    ↓
[lemon_router] - Route to appropriate agent
    ↓
[coding_agent] - Execute tools, manage sessions
    ↓
[agent_core] - CLI runners, subagent spawning
    ↓
[ai] - LLM provider calls
```

### Key Dependencies Between Apps

```
lemon_control_plane ──→ lemon_router, lemon_channels, lemon_skills, coding_agent
lemon_router ─────────→ lemon_gateway, lemon_channels, coding_agent, agent_core
lemon_gateway ────────→ agent_core, coding_agent, lemon_channels, lemon_core
lemon_channels ───────→ lemon_core
coding_agent ─────────→ agent_core, ai, lemon_skills, lemon_core
agent_core ───────────→ ai, lemon_core
lemon_skills ─────────→ agent_core, ai, lemon_channels
market_intel ─────────→ lemon_core, agent_core, lemon_channels
```

---

## Configuration

- **User config**: `~/.lemon/config.toml`
- **Project config**: `.lemon/config.toml` (in repo root)
- **Secrets**: Managed via `mix lemon.secrets.*` tasks

Key env vars:
- `ANTHROPIC_API_KEY` - Claude provider
- `OPENAI_API_KEY` - OpenAI provider
- `LEMON_TELEGRAM_BOT_TOKEN` - Telegram transport

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

### Adding a Transport

1. Create transport module in `apps/lemon_gateway/lib/lemon_gateway/transports/`
2. Implement transport behaviour
3. Register in `LemonGateway.TransportRegistry`

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

- `docs/architecture_boundaries.md` - Dependency boundaries
- `docs/config.md` - Runtime configuration reference
- `docs/skills.md` - Skill system documentation
- `docs/quality_harness.md` - Quality checks and cleanup
- `docs/assistant_bootstrap_contract.md` - Bootstrap contract
- `docs/context.md` - Context management
- `docs/telemetry.md` - Telemetry and observability

---

## Coding Conventions

- **Elixir**: snake_case files, CamelCase modules
- **TypeScript**: Follow workspace ESLint config
- **Format**: Run `mix format` before committing
- **Tests**: `*_test.exs` for Elixir, `*.test.ts` for TypeScript
- **Commits**: Short, imperative style (`Fix gateway timeout`, `chore: update docs`)

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

*Last updated: 2026-02-22*
