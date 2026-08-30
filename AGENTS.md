# Lemon Agent Guide

> **Effective agent context for the Lemon LLM interaction stack.**
> Lemon is a BEAM-native stack of Elixir/OTP libraries for LLM interactions, with two flagship products on top: a multi-channel personal assistant and LemonSim, a deterministic model-vs-model simulation arena. The assistant uses the stack for local-first agent work across channels; LemonSim uses it for event-sourced, replay-verified benchmark worlds.

---

## Quick Navigation

| If you want to... | Look in... |
|-------------------|------------|
| Add/modify AI provider support | `apps/lemon_ai/` |
| Work on model runtime credential glue | `apps/lemon_agent/` |
| Work on coding tools or session management | `apps/coding_agent/` |
| Work on named execution nodes | `apps/coding_agent/` (worker/executor), `apps/lemon_control_plane/` (pairing/presence) |
| Modify Telegram/Discord channel adapters | `apps/lemon_channels/` |
| Modify SMS/voice transports | `apps/lemon_gateway/` |
| Add new messaging channel adapters (X, XMTP, etc.) | `apps/lemon_channels/` |
| Modify setup, onboarding, or Hermes migration CLI flows | `apps/lemon_cli/` |
| Work on agent routing or message flow | `apps/lemon_router/` |
| Build HTTP/WebSocket API features | `apps/lemon_control_plane/` |
| Manage configuration, secrets, or storage | `apps/lemon_core/` |
| Resolve bounded files, folders, diffs, URLs, sessions, or documents | `apps/lemon_core/` (`LemonCore.Context`), `apps/lemon_cli/` (`lemon context`) |
| Work on browser capability driver | `apps/lemon_browser/` |
| Work on media job capability driver | `apps/lemon_media/` |
| Work on LSP capability driver | `apps/lemon_lsp/` |
| Build reusable simulation harnesses | `apps/lemon_sim/` |
| Work on native in-process subagent spawning | `apps/coding_agent/` (`task` tool, `CodingAgent.Coordinator`) |
| Create or modify skills and assistant-platform tools | `apps/lemon_skills/` |
| Work on Honcho memory integration | `apps/lemon_honcho/` |
| Work on deterministic eval harnesses | `apps/lemon_evals/` |
| Build cron jobs or automation | `apps/lemon_automation/` |
| Work on the web UI | `apps/lemon_web/` |
| Debug coding agent via RPC | `apps/coding_agent_ui/` |
| Record or search durable agent memory | `apps/lemon_memory/` |
| Work on the MCP client/server bridge | `apps/lemon_mcp/` |
| Work on the LemonSim control room UI | `apps/lemon_sim_ui/` |
| Work on the on-chain TCG shop arena | `apps/lemon_tcg/` |
| Write contract tests for platform behaviours | `apps/lemon_platform_test/` |
| Work on the X (Twitter) API client | `apps/x_api/` |
| Browser automation via CDP/Playwright | `clients/lemon-browser-node/` |

---

## Parallel Work & Git Worktrees

When working on multiple tasks in parallel (either as the same agent or multiple agents), **use git worktrees to avoid file editing conflicts**.
Store all worktrees under `.worktrees/` in the repository root.

### Workflow:

1. **Create a worktree for each parallel task:**
   ```bash
   mkdir -p .worktrees
   git worktree add .worktrees/task-name -b task-name
   cd .worktrees/task-name
   ```

2. **Work in isolation** — Each worktree is an independent working directory backed by the same repo:
   ```bash
   git status
   ```

3. **Clean up when complete** — After the branch is merged/closed, remove the worktree:
   ```bash
   cd /path/to/main/lemon
   git worktree remove .worktrees/task-name
   git branch -d task-name
   ```

### Why git Worktrees?

- **No file editing conflicts** — Multiple agents can edit different files simultaneously without stepping on each other
- **Clean build contexts** — Each worktree maintains separate `_build/` and `deps/` as needed
- **Easy cleanup** — Remove worktrees when done without affecting the main checkout

### Golden Rule:

> **Never have multiple agents editing the same working directory simultaneously.** Always use separate worktrees for parallel tasks.

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
5. **Update configuration examples** — If you add/remove config options, update the tracked `examples/config.example.toml` and config documentation.

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
├── coding_agent/        # Coding agent runtime, coding tools, session management, budget enforcement
├── coding_agent_ui/     # UI adapters exposing coding_agent over RPC (used for tooling/debugging)
├── lemon_agent/         # Agent runtime: agentic loop, supervised agents, tool registry, subagents, model routing/credentials
├── lemon_ai/            # Provider-agnostic LLM client: 27 providers behind one streaming API, model registry, cost tracking
├── lemon_automation/    # Cron jobs, heartbeat manager, run submitter
├── lemon_browser/       # Browser capability driver and artifact store
├── lemon_channels/      # Channel adapters and delivery outbox (Telegram, Discord, WhatsApp, XMTP, email)
├── lemon_cli/           # User-facing setup, onboarding, and Hermes migration Mix tasks
├── lemon_control_plane/ # HTTP/WebSocket API server with 150+ JSON-RPC methods
├── lemon_core/          # Shared primitives: config, store (ETS/JSONL/SQLite), secrets, PubSub bus
├── lemon_evals/         # Deterministic eval harness and mix lemon.eval task
├── lemon_gateway/       # Singleton-executor scheduler, run lifecycle, launch locks; SMS/voice/email/webhook ingress
├── lemon_honcho/        # Honcho-backed long-term memory: registers a LemonMemory provider and agent tools
├── lemon_lsp/           # LSP server registry and supervised JSON-RPC sessions
├── lemon_mcp/           # MCP (Model Context Protocol) server/client bridge for CodingAgent tools
├── lemon_media/         # Media Task.Supervisor, metadata store, and mix lemon.media
├── lemon_memory/        # Durable agent memory: SQLite full-text store, provider fan-out search, run ingest, redaction
├── lemon_platform_test/ # Contract-test kit (ExUnit case templates) for Lemon extension behaviours
├── lemon_router/        # Message routing, agent directory, run orchestration, queue semantics
├── lemon_sim/           # Reusable simulation harness primitives (projector/updater/action-space contracts)
├── lemon_sim_ui/        # Phoenix LiveView control room for observing and driving lemon_sim runs
├── lemon_skills/        # Skill registry, discovery, installation, assistant-platform tools
├── lemon_tcg/           # Live market data and execution for the agent-operated on-chain TCG shop
├── lemon_web/           # Phoenix LiveView web interface
└── x_api/               # Reusable X API client, OAuth helpers, and token manager

clients/
├── lemon-browser-node/  # Browser automation node via CDP/Playwright (TypeScript)
├── tui/                 # Bun terminal UI client built on @oh-my-pi/pi-tui
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

# Build the self-contained LemonSim UI browser bundle
mix sim_ui.assets.build
MIX_ENV=prod mix sim_ui.assets.deploy  # build + digest/precompress for release

# Canonical repo-level test lanes
scripts/test help
scripts/test fast       # compile with warnings as errors + ExUnit excluding integration
scripts/test quality    # Lemon quality gates and focused quality tests
scripts/test clients    # Bun TUI + web/browser client CI parity checks
scripts/test eval-fast  # small eval harness run
scripts/test smoke      # CI-only product-smoke pointer
scripts/test all        # useful local aggregate
scripts/test path apps/lemon_ai/test --seed 1

# Format code
mix format
```

### Product Release

Keep user-visible notes under `CHANGELOG.md`'s `Unreleased` section, then start
the serialized one-click release workflow from `main`:

```bash
gh workflow run release.yml --ref main -f channel=stable -f draft=false
```

With no version input, the workflow derives the next CalVer, updates and
commits product version metadata, creates the annotated tag, builds and verifies
all native artifacts, publishes the GitHub Release, and then promotes mutable
GHCR channel tags. See `docs/release/versioning_and_channels.md`.

Both runtime profiles assemble `lemon_mcp` with the OTP release mode `:load`
before its dynamic consumers. MCP is a library application with no application
callback; consuming applications supervise every client, server, or transport
process they start.

### TUI Client (Bun)

```bash
cd clients/tui
bun install
bun test
bun run check
bun src/main.ts      # Dev mode
```

### Web Client

```bash
cd clients/lemon-web
npm install
npm run dev      # Build shared once, then start shared/server/web watchers
npm start        # Build generated shared/server entrypoints, then start the server
npm run build    # Build shared/server/web packages
npm run test:coverage
```

### Browser Node Client (TypeScript)

```bash
cd clients/lemon-browser-node
npm install
npm run build
npm run test:coverage
npm run dev      # Watch mode
```

### Quick Dev Bootstrap

```bash
./bin/lemon        # Unified runtime (gateway + control plane + router + channels + web)
./bin/lemon web   # Start the unified runtime if needed and open the local Web UI
./bin/lemon send --to telegram:<chat_id> "done"  # Script notification to Telegram/Discord
./bin/lemon send --to discord:#ops --attach report.txt --attach trace.log "done"  # Upload script artifacts
./bin/lemon send --dry-run --to discord:#ops --attach report.txt "done"  # Validate without delivery
./bin/lemon backup create --json  # Atomic, verified durable-user-state backup
./bin/lemon backup verify ~/.lemon/backups/<bundle>.lemonbackup --json
./bin/lemon node join --name worker-1 --controller wss://controller.example/ws --pair --cwd /path/to/project
./bin/lemon-tui    # Dev TUI; securely token-pairs with a launcher-owned runtime
```

The named-node command runs a destination-side worker capable of starting
native coding sessions against an already-running controller. Use `--pair` on
first connection; later starts reuse the private token stored for that durable
node ID and exact controller URL. Re-run with `--pair` to rotate an expired
seven-day session without creating a second identity or colliding with its
name. Use `--pair --repair --node-id ID` with operator authorization only when
migrating an older local record that has no recovery credential.
Prefer `LEMON_NODE_OPERATOR_TOKEN` / `LEMON_NODE_TOKEN` over token flags. The
`--cwd` directory and provider credentials belong to the destination machine.
Non-loopback controllers require `wss://` by default. Plaintext `ws://` needs
`--allow-insecure-controller` and is acceptable only for development or across
a verified encrypted overlay such as Tailscale.

On Linux and other non-keychain environments, keep `~/.lemon/secrets_master_key` as the canonical local master key file. `./bin/lemon` now normalizes `LEMON_SECRETS_MASTER_KEY` from that file at startup so stale inherited shell env does not break provider or transport secret decryption.

`lemon backup` and `./bin/lemon backup` share the versioned `~/.lemon` data
contract in `docs/user-guide/backups.md`. Durable regular files are included;
installed versions, launchers, runtime state, prior backups, symlinks, special
files, project-local state, and platform keychains are excluded. Local cookie,
environment, master-key, and execution-node credentials require the explicit
`--include-credentials` flag. Restore must verify the entire bundle before
mutation; overwrite authorization is bound to the manifest digest and expanded
target root.

---

## Architecture Overview

### Message Flow

```
[User via Telegram / Discord / XMTP / X / SMS]
    ↓
[lemon_channels or legacy gateway ingress] - Transport adapters and inbound normalization
    ↓
[lemon_router] - Route to appropriate agent, run orchestration, queue semantics
    ↓
[lemon_gateway] - Execution slots and engine lifecycle
    ├─ local → [coding_agent] ─────────────────────────────┐
    └─ named → [LemonCore.NodeRegistry → control-plane WebSocket]
                    → [destination coding_agent] ────────────┤
                                                        ↓
[lemon_agent] - Agentic loop, tool registry, subagent orchestration, model routing/credentials
    ↓
[lemon_ai] - LLM provider calls (Anthropic, OpenAI, Google, Azure, Bedrock)
```

The `task` tool and `@name` personas spawn native in-process child sessions
coordinated by `CodingAgent.Coordinator`. The `agent` tool delegates through
the router and can select the local executor or a named destination. Both paths
reuse `coding_agent` → `lemon_agent` → `lemon_ai`; there are no vendor CLI
subprocess runners.

For named delegation, the `agent` tool's optional `node` parameter selects a
live, uniquely named execution node. Omit it or use `"local"` for local
execution. Only JSON-safe execution-request data crosses the WebSocket
boundary; resolved provider credentials, callbacks, executor options, and
source process state do not. Explicit cancellation is routed to the targeted
destination run, while disconnects fail its pending invocations.

Outbound message delivery goes through `lemon_channels` (Telegram, Discord, WhatsApp, XMTP, email adapters).
The control plane (`lemon_control_plane`) provides the JSON-RPC API used by TUI/web clients.

User-managed profiles reuse the canonical `[profiles.<id>]` router plane rather
than introducing another agent engine. `LemonCore.ProfileStore` owns atomic
lifecycle edits and derives `~/.lemon/profiles/<id>/` boundaries;
`profile.chat` and `lemon profile chat` always submit `agent:<id>:main` through
the existing router. Packaged one-shot chat connects to the authenticated local
control plane so the run outlives its CLI VM; it never starts a second router.
`CodingAgent.Executor.SessionRunner` selects the profile workspace only from
validated `meta.profile_id`. Keep lifecycle storage in `lemon_core` free of
coding-agent/skill dependencies, and never export profile sessions, memory, or
unredacted credential-like content.

### Key Dependencies Between Apps

Derived from complete `deps/0` bodies in the `mix.exs` files and enforced by
`mix lemon.quality` (architecture boundary check). The direct policy must match
this graph exactly; reference-only namespace exceptions are tracked separately
and do not permit adding a Mix dependency:

```
lemon_control_plane ──→ lemon_core, lemon_memory, lemon_browser, lemon_media, lemon_lsp, lemon_router, lemon_channels, lemon_skills, lemon_automation, lemon_agent, lemon_ai
lemon_router ─────────→ lemon_ai, lemon_core, lemon_memory, lemon_media, lemon_channels, lemon_agent
lemon_gateway ────────→ lemon_agent, lemon_core
lemon_automation ─────→ lemon_agent, lemon_core, lemon_router, lemon_skills
lemon_channels ───────→ lemon_core, lemon_media, lemon_agent
lemon_cli ────────────→ lemon_core, lemon_memory, lemon_ai
coding_agent ─────────→ lemon_agent, lemon_ai, lemon_skills, lemon_core, lemon_gateway, lemon_memory, lemon_browser, lemon_platform_test*
coding_agent_ui ──────→ coding_agent, lemon_core
lemon_agent ──────────→ lemon_ai, lemon_core
lemon_evals ──────────→ lemon_agent, lemon_ai, coding_agent, lemon_core, lemon_skills
lemon_mcp ────────────→ coding_agent, lemon_core, lemon_skills, lemon_agent
lemon_honcho ─────────→ lemon_core, lemon_memory, lemon_agent, lemon_ai, lemon_platform_test*
lemon_sim ────────────→ lemon_core, lemon_agent, lemon_ai
lemon_sim_ui ─────────→ lemon_ai, lemon_core, lemon_sim
lemon_tcg ────────────→ lemon_core, lemon_agent, lemon_ai, lemon_sim
lemon_skills ─────────→ lemon_core, lemon_memory, lemon_media, lemon_agent, lemon_ai
lemon_memory ─────────→ lemon_core
lemon_browser ────────→ lemon_core
lemon_lsp ────────────→ lemon_core
lemon_media ──────────→ lemon_core
lemon_platform_test ──→ lemon_core, lemon_channels, lemon_memory, lemon_ai, lemon_agent (all optional: true)
lemon_web ────────────→ lemon_core, lemon_router
x_api ────────────────→ lemon_core, lemon_channels, lemon_agent, lemon_ai, lemon_platform_test*
lemon_ai ─────────────→ (no umbrella deps - standalone LLM client library)
lemon_core ───────────→ (no umbrella deps - foundational shared library)
```

`*` = `only: :test, runtime: false` (compile-time-only test-kit dependency)

---

## Configuration

- **User config**: `~/.lemon/config.toml`
- **Project config**: `.lemon/config.toml` (optional, in repo root; not tracked — copy from `examples/config.example.toml`)
- **Secrets**: Managed via `mix lemon.secrets.*` tasks (`set`, `list`, `delete`, `status`, `init`)
- **Config inspection**: `mix lemon.config` - show resolved runtime config
- **Store migration**: `mix lemon.store.migrate_jsonl_to_sqlite`

Key env vars:
- `ANTHROPIC_API_KEY` - Claude provider
- `OPENAI_API_KEY` - OpenAI provider
- `LEMON_LOG_LEVEL` - Log level (debug/info/warning/error)
- `LEMON_STORE_PATH` - Persistent store path
- `LEMON_HARNESS_SKILLS_DIR` - Override harness-compatible global skills path (`~/.agents/skills`) for isolated runtimes/tests
- `LEMON_WEB_ACCESS_TOKEN` - Optional chat gate and required credential for the `/manage` session-operations shell
- `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` - Shared WebSocket operator credential required by default and used for named-node pairing against an authenticated controller
- `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK` - Explicit, default-off legacy tokenless loopback compatibility
- `LEMON_WEB_HOST` / `LEMON_WEB_PORT` - Web server binding (prod)
- `LEMON_WEB_SECRET_KEY_BASE` - Required in prod
- `LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS` / `LEMON_SIM_UI_MAX_STORED_SIMS` - Bound Sim UI model concurrency and terminal snapshot retention; per-arena `MAX_GAME_RECORDS` bounds league history
- `LEMON_SIM_UI_ACCESS_TOKEN` / `LEMON_SIM_UI_ADMIN_SESSION_TTL_SECONDS` - Protect the Sim UI control room/API and bound browser admin sessions; browser login is form-based and APIs are bearer-only
- `LEMON_WEREWOLF_HOSTED_ENABLED` / `LEMON_WEREWOLF_HOST_CREATE_TOKEN` / `LEMON_WEREWOLF_HOSTED_*` - Opt-in HTTPS hosted Werewolf, creation access, room TTL/retention, and bounded AI configuration
- `LEMON_GATEWAY_HEALTH_PORT` / `LEMON_ROUTER_HEALTH_PORT` - Health server port overrides for local parallel runtimes
- `LEMON_NODE_OPERATOR_TOKEN` / `LEMON_NODE_TOKEN` - Pairing-only operator token or existing session token for `./bin/lemon node join`; prefer these to CLI token flags
- `LEMON_NODE_ALLOW_INSECURE_CONTROLLER` - Explicitly permit non-loopback plaintext `ws://` for development or a verified encrypted overlay only; secure `wss://` remains the default
- `LEMON_TELEGRAM_DEFAULT_CHAT_ID` / `LEMON_DISCORD_DEFAULT_CHANNEL_ID` - Optional env overrides for `./bin/lemon send`; config fallbacks live in `[gateway.telegram] default_chat_id/default_thread_id/default_topic_id` and `[gateway.discord] default_channel_id/default_thread_id`
- `DEEPGRAM_API_KEY` - Speech-to-text
- `ELEVENLABS_API_KEY` / `ELEVENLABS_VOICE_ID` - TTS
- `TWILIO_ACCOUNT_SID` / `TWILIO_AUTH_TOKEN` / `TWILIO_PHONE_NUMBER` - SMS

---

## Key Patterns

### Adding a New Tool

1. Create coding-agent-specific modules in `apps/coding_agent/lib/coding_agent/tools/`; create assistant-platform tools such as media/social/PKM surfaces in `apps/lemon_skills/lib/lemon_skills/tools/`.
2. Implement the tool pattern (see existing tools in the `CodingAgent.Tools.*` namespace)
3. Add to `CodingAgent.Tools` registry
4. Update tool policy if needed

Data-bearing tool output must follow `LemonAgent.Types.AgentToolResult.trust`: ordinary local file/search/shell results, remote/API data, and community/project skill content are untrusted and fenced at the pre-LLM boundary. Intentional bootstrap instruction loading and audited builtin skill semantics are the explicit trusted paths.

### Adding an AI Provider

1. Create provider module in `apps/lemon_ai/lib/lemon_ai/providers/`
2. Implement `LemonAi.Provider` behaviour
3. Register in `LemonAi.ProviderRegistry`

### Adding a Gateway Transport

External channel adapters live in `apps/lemon_channels/`. Current adapters include Telegram and Discord.
Gateway-native transports remain in `apps/lemon_gateway/` (SMS/Twilio, voice, email/webhook glue).

1. Create transport module in `apps/lemon_gateway/lib/lemon_gateway/`
2. Implement appropriate behaviour (see existing transports for patterns)
3. Wire up in `LemonGateway.Application`

### Adding a Native Subagent

Top-level conversations always run through the configured native `CodingAgent.Executor`;
the gateway does not support selectable or custom engines. The `task` tool and
`@name` personas spawn native in-process `CodingAgent.Session` children through
`CodingAgent.Coordinator`. The `agent` tool delegates through the router and
can place that native run locally or on a named execution node.

1. Add a subagent persona (`id`, `description`, `prompt`) to `.lemon/subagents.json` or
   `~/.lemon/agent/subagents.json`; built-ins live in `CodingAgent.Subagents`.
2. Invoke it through the `task` or `agent` tool (or `@name` mentions); execution stays
   on the native `coding_agent` → `lemon_agent` → `lemon_ai` chain, locally or
   on the named destination selected by `agent.node`.
3. There are no vendor CLI subprocess runners (Claude Code, Codex, Kimi, OpenCode, Pi
   were removed); do not wrap external CLIs as subagents.

---

## Testing & Debugging

### Testing & Static Analysis

- **Always run tests from the umbrella root**: `mix test apps/<app>/test`.
  Never `cd apps/<app> && mix test` — running from inside an app directory produces phantom failures.
- **Dialyzer**: as of dialyxir 1.4.7 / OTP 28.5, Dialyzer emits an `:exact_compare` warning tag that
  crashes the `github`/`dialyxir`/`short` formatters. Run `mix dialyzer --format dialyzer` locally —
  CI already does (see `.github/workflows/dialyzer.yml:13-17`).
- **Dialyzer lanes**: the full-umbrella run stays advisory (large backlog), while `scripts/dialyzer_gate.sh` enforces a hard green gate on an allowlist of apps that only ratchets forward.

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

- `docs/platform-split.md` - **Plan of record** for the platform split: package boundaries, extraction phases, and in-place work-item checkboxes
- `docs/architecture_boundaries.md` - Dependency boundaries and allowed cross-app references
- `docs/platform/` - Per-package platform guides (lemon_core, lemon_agent, lemon_ai, lemon_channels, lemon_gateway, lemon_memory, lemon_router, lemon_platform_test)
- `docs/config.md` - Runtime configuration reference
- `docs/user-guide/backups.md` - Versioned user-state backup and guarded restore contract
- `docs/mix-tasks.md` - Grouped reference for every `mix lemon.*` task, including the quality/cleanup harness (`mix lemon.quality`, `mix lemon.cleanup`)
- `docs/skills.md` - Skill system documentation
- `docs/testing.md` - Canonical repo-level test lanes and CI parity guidance
- `docs/assistant_bootstrap_contract.md` - Bootstrap contract
- `docs/context.md` - Context management
- `docs/long-running-agent-harnesses.md` - Long-running harness primitives that keep coding sessions structured across multi-step work
- `docs/user-guide/web.md` - Browser chat/resume plus authenticated session management, redacted export, and guarded prune
- `docs/user-guide/context-references.md` - Bounded context preview/resolve, document formats, budgets, and safety contract
- `docs/plans/2026-03-19-ai-boundary-extraction-plan.md` - Plan for moving auth/config/storage ownership out of `apps/lemon_ai` before extracting it into its own repo
- `docs/subagent-parent-questions.md` - Design for subagent-to-parent clarification requests via a narrow `ask_parent` path
- `docs/telemetry.md` - Telemetry and observability
- `docs/extensions.md` - Extension system
- `docs/beam_agents.md` - BEAM agent architecture
- `docs/benchmarks/` - Benchmark platform guarantees, quickstart, and VendingBench guides
- `docs/model-selection-decoupling.md` - Model selection design
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
| coding_agent | `apps/coding_agent/AGENTS.md` |
| coding_agent_ui | `apps/coding_agent_ui/AGENTS.md` |
| lemon_agent | `apps/lemon_agent/AGENTS.md` |
| lemon_ai | `apps/lemon_ai/AGENTS.md` |
| lemon_automation | `apps/lemon_automation/AGENTS.md` |
| lemon_browser | `apps/lemon_browser/README.md` *(no AGENTS.md yet)* |
| lemon_channels | `apps/lemon_channels/AGENTS.md` |
| lemon_cli | `apps/lemon_cli/README.md` *(no AGENTS.md yet)* |
| lemon_control_plane | `apps/lemon_control_plane/AGENTS.md` |
| lemon_core | `apps/lemon_core/AGENTS.md` |
| lemon_evals | `apps/lemon_evals/README.md` *(no AGENTS.md yet)* |
| lemon_gateway | `apps/lemon_gateway/AGENTS.md` |
| lemon_honcho | `apps/lemon_honcho/AGENTS.md` |
| lemon_lsp | `apps/lemon_lsp/README.md` *(no AGENTS.md yet)* |
| lemon_mcp | `apps/lemon_mcp/AGENTS.md` |
| lemon_media | `apps/lemon_media/README.md` *(no AGENTS.md yet)* |
| lemon_memory | `apps/lemon_memory/README.md` *(no AGENTS.md yet)* |
| lemon_platform_test | `apps/lemon_platform_test/README.md` *(no AGENTS.md yet)* |
| lemon_router | `apps/lemon_router/AGENTS.md` |
| lemon_sim | `apps/lemon_sim/AGENTS.md` |
| lemon_sim_ui | `apps/lemon_sim_ui/AGENTS.md` |
| lemon_skills | `apps/lemon_skills/AGENTS.md` |
| lemon_tcg | `apps/lemon_tcg/README.md` *(no AGENTS.md yet)* |
| lemon_web | `apps/lemon_web/AGENTS.md` |
| x_api | `apps/x_api/README.md` *(no AGENTS.md yet)* |

---

*Last updated: 2026-08-30* (architecture reporting now parses complete `deps/0`
bodies and distinguishes direct dependencies from reference-only exceptions;
`lemon_mcp` is assembled as a library-only `:load` application with no empty
application supervisor; one-shot media jobs use `Task.Supervisor` rather than a
bespoke worker GenServer; documented named execution nodes including controller
pairing, live name-based routing, destination-local cwd/credentials,
cancellation, and the native-only execution boundary)
