# Lemon 🍋 Agent Context

Lemon is a distributed AI coding assistant and agent platform built on the Erlang VM (BEAM). It features a multi-engine architecture (Claude, Codex, OpenCode, Pi, and native Lemon) and supports multiple interfaces including Telegram, Discord, a Terminal UI, and a Web UI.

## Project Overview

- **Architecture:** Elixir Umbrella project with specialized applications for AI providers, coding tools, message routing, and channel adapters.
- **Key Technologies:** Elixir/OTP, Phoenix (LiveView), TypeScript (TUI/Web clients), Node.js (Browser automation), SQLite/JSONL/ETS for storage.
- **Interfaces:**
    - **Telegram/Discord:** Primary interaction channels via `lemon_gateway` and `lemon_channels`.
    - **TUI:** Local developer interface (`clients/lemon-tui`).
    - **Web UI:** Collaborative workspace (`apps/lemon_web`, `clients/lemon-web`).
- **Engines:** Supports native execution and CLI-wrapped runners for various LLM-based engines.

## Directory Structure (Umbrella Apps)

- `apps/ai/`: Abstraction layer for LLM providers (Anthropic, OpenAI, etc.).
- `apps/agent_core/`: Core runtime, CLI runners, and subagent management.
- `apps/coding_agent/`: Main coding agent with 35+ tools and session management.
- `apps/lemon_router/`: Message routing and agent orchestration.
- `apps/lemon_core/`: Shared primitives: configuration, secrets, and storage.
- `apps/lemon_gateway/`: Inbound transport and engine selection.
- `apps/lemon_channels/`: Outbound delivery adapters (Telegram, Discord, etc.).
- `apps/lemon_skills/`: Reusable knowledge modules (skills).
- `apps/lemon_web/`: Phoenix-based web interface.
- `apps/lemon_control_plane/`: JSON-RPC API server.
- `clients/`: TypeScript-based clients for TUI, Web, and Browser automation.

## Building and Running

### Core System (Elixir)
- **Setup:** `mix deps.get && mix compile`
- **Initial Configuration:** `mix lemon.setup` (interactive) or `mix lemon.doctor` (verification).
- **Run Development TUI:** `./bin/lemon-dev /path/to/project`
- **Run Gateway:** `./bin/lemon-gateway`
- **Run Quality Checks:** `mix lemon.quality` (Enforces architecture boundaries and linting).
- **Run Tests:** `mix test` (or `mix test apps/name` for specific apps).

### Clients (TypeScript)
- **TUI:** `cd clients/lemon-tui && npm install && npm run dev`
- **Web:** `cd clients/lemon-web && npm install && npm run dev`

## Development Conventions

### Documentation Contract ⚠️
**Documentation is part of the code.** Any functional change MUST be accompanied by updates to:
- Relevant `AGENTS.md` files (found in the root and each app directory).
- Root `README.md` or app-specific READMEs.
- Architecture docs in `docs/`.
- Configuration examples in `.lemon/config.toml`.

### Parallel Work & Git Worktrees
To avoid conflicts when multiple agents (or tasks) are running, use **git worktrees** stored in `.worktrees/`:
```bash
git worktree add .worktrees/task-name -b task-name
```
**Never edit the same working directory with multiple parallel agents.**

### Agent Tiering
Match the model to the task complexity:
- **Sonnet:** Investigation, docs, simple refactors, test running.
- **Opus:** Complex refactoring, architectural changes, correctness-critical code.
- **Codex:** Architectural review, plan ownership, Staff-level oversight.

### Coding Standards
- **Elixir:** `snake_case` files, `CamelCase` modules, use `mix format`.
- **TypeScript:** Follow workspace ESLint/Prettier configs.
- **Secrets:** Never hardcode. Use `mix lemon.secrets set` and the `LemonCore.Secrets` module.

## Architecture & Flow

1. **Inbound:** User → `lemon_gateway` (Transport/Engine) → `lemon_router` (Routing).
2. **Execution:** `lemon_router` → `coding_agent` (Tools/Session) → `agent_core` (Runner).
3. **AI:** `agent_core` → `ai` (Provider) → LLM API.
4. **Outbound:** Agent → `lemon_channels` (Adapter) → User.

## Testing Strategy
- **Unit Tests:** Located in `test/` or `lib/**/test/` within each app.
- **Integration Tests:** Use `mix test --include integration`.
- **Quality Harness:** `mix lemon.quality` checks for cyclic dependencies and boundary violations defined in `docs/architecture_boundaries.md`.
