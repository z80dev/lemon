# lemon 🍋

an AI coding agent system named after my cat :)

built on the BEAM (Erlang/Elixir). It uses the Erlang Virtual Machine's process model for handling concurrent agent coordination and fault tolerance.

## Table of Contents

- [What is Lemon?](#what-is-lemon)
- [Why BEAM?](#why-beam)
- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Core Components](#core-components)
  - [AI Library](#ai-library)
  - [AgentCore](#agentcore)
  - [CodingAgent](#codingagent)
  - [LemonGateway](#lemongateway)
  - [Lemon TUI](#lemon-tui)
- [Installation](#installation)
- [Usage](#usage)
- [Development](#development)
- [License](#license)

---

## What is Lemon?

Lemon is an AI coding assistant built as a distributed system of concurrent processes running on the BEAM. Unlike traditional coding agents that run as monolithic Python applications or stateless HTTP services, Lemon uses independent processes that communicate via message passing.

### Core Philosophy

1. **Agents as Processes**: Each AI agent runs as an independent GenServer process with its own state, mailbox, and lifecycle. This mirrors the actor model—agents are actors that communicate via message passing.

2. **Streaming as Events**: LLM streaming responses are modeled as event streams, enabling reactive UI updates, parallel processing, and backpressure handling.

3. **Fault Tolerance**: Using OTP supervision trees, agent failures are isolated and recoverable. A crashing tool execution doesn't bring down the entire session.

4. **Live Steering**: Users can inject messages mid-execution to steer the agent, enabled by the BEAM's ability to send messages to any process at any time.

5. **Multi-Provider Abstraction**: Unified interface for OpenAI, Anthropic, Google, Azure, and AWS Bedrock with automatic model configuration and cost tracking.

6. **Multi-Engine Architecture**: Pluggable execution engines supporting native Lemon agents, Claude CLI, and Codex CLI as interchangeable backends with unified event streaming.

### Key Features

- **Multi-turn conversations** with tool use (read, write, edit, bash, grep, find, glob, ls, webfetch, websearch, todoread, todowrite, task)
- **Real-time streaming** of LLM responses with fine-grained event notifications
- **Session persistence** via JSONL with tree-structured conversation history
- **Context compaction** and branch summarization for long conversations
- **Pluggable UI** with a Terminal UI client
- **Extension system** for custom tools and hooks
- **Concurrent tool execution** with abort signaling
- **Multi-provider support** with seamless context handoffs
- **CLI runner infrastructure** for integrating Claude and Codex as subagents
- **Resume tokens** for session persistence and continuation across restarts
- **Telegram bot integration** for remote agent control

---

## Why BEAM?

The BEAM (Bogdan/Björn's Erlang Abstract Machine) provides capabilities that work well for building agentic AI systems:

### 1. Lightweight Concurrency

The BEAM can run millions of lightweight processes concurrently. In Lemon:

- Each **agent** is a GenServer process
- Each **LLM stream** runs in its own process
- Each **tool execution** can spawn worker processes
- **Event streams** are process-based with backpressure

This means an agent can be executing multiple tools concurrently, streaming responses to multiple UIs, and handling steering messages—all without blocking.

### 2. Message Passing Architecture

Agents communicate via asynchronous message passing:

```elixir
# Send a prompt to an agent (non-blocking)
:ok = AgentCore.prompt(agent, "Refactor this module")

# The agent process handles the LLM stream in the background
# Events are streamed back to subscribers
receive do
  {:agent_event, {:message_update, msg, delta}} ->
    IO.write(delta)  # Stream to UI in real-time

  {:agent_event, {:tool_execution_start, id, name, args}} ->
    IO.puts("Executing: #{name}")  # Show tool execution
end
```

This enables **live steering**: users can send messages to an agent while it's running, and the agent will incorporate them at the appropriate point in its execution loop.

### 3. Fault Isolation and Supervision

OTP supervision trees ensure that:

- A crashing tool doesn't kill the agent
- A network error during streaming is recoverable
- The UI remains responsive even during long-running operations
- Sessions can be restarted without losing state

```
Supervisor
├── AgentCore.Application
│   ├── Agent GenServer (per session)
│   └── CLI Runners (Codex, Claude subprocesses)
├── Ai.Application
│   └── Provider processes
├── CodingAgent.Application
│   └── SessionManager processes
└── LemonGateway.Application
    ├── Scheduler (job concurrency)
    ├── ThreadWorkers (per-conversation)
    └── Telegram Transport (optional)
```

### 4. Hot Code Upgrades

The BEAM supports hot code reloading, meaning:

- Tools can be updated without restarting sessions
- Extensions can be loaded dynamically
- The system can be patched without downtime

### 5. Distribution Ready

The BEAM was designed for distributed systems. Lemon is built to eventually support:

- Distributed agent clusters
- Remote tool execution
- Multi-node session persistence
- Load balancing across agent pools

### Comparison with Traditional Approaches

| Feature | Python/Node.js Agents | Lemon (BEAM) |
|---------|----------------------|--------------|
| Concurrency | Threads/asyncio | Millions of processes |
| State Management | External (Redis, DB) | In-process (ETS, state) |
| Streaming | Callbacks/generators | Event streams with backpressure |
| Fault Tolerance | Try/catch, restarts | OTP supervision trees |
| Live Steering | Complex state machines | Message passing |
| Distribution | HTTP APIs, message queues | Native distribution |

### How BEAM is Currently Leveraged in Lemon

#### Process-per-Agent Architecture

Each agent session runs as an independent GenServer process (`AgentCore.Agent`), providing:

- **Isolated State**: Each agent maintains its own conversation context, tool registry, and configuration in process state, eliminating shared-state bugs
- **Mailbox Queue**: The GenServer message box naturally queues incoming prompts, steering messages, and follow-ups
- **Synchronous & Async Operations**: `GenServer.call/3` for operations needing confirmation, `GenServer.cast/2` for fire-and-forget

```elixir
# Each session is a separate process with isolated state
{:ok, pid1} = CodingAgent.start_session(session_id: "session-1")
{:ok, pid2} = CodingAgent.start_session(session_id: "session-2")

# Crash one session, the other continues unaffected
Process.exit(pid1, :kill)
# pid2 still operational
```

#### ETS for High-Performance State

Lemon uses ETS (Erlang Term Storage) tables for shared, read-heavy data:

- **Provider Registry** (`Ai.ProviderRegistry`): Stores provider configurations in `:persistent_term` for O(1) lookups
- **Abort Signals** (`AgentCore.AbortSignal`): Signal storage with `read_concurrency: true` for efficient concurrent checks
- **Todo Store** (`CodingAgent.Tools.TodoStore`): Per-session todo lists with fast lookups

```elixir
# Abort signals use ETS for O(1) concurrent reads
def aborted?(ref) do
  case :ets.lookup(@table, ref) do
    [{^ref, true}] -> true
    _ -> false
  end
end
```

#### Links and Monitors for Lifecycle Management

- **SessionRegistry**: Uses `Registry` (built on ETS) for process discovery
- **SubagentSupervisor**: `DynamicSupervisor` with `:temporary` restart for subagent processes
- **EventStream Owner Monitoring**: Streams auto-cancel when owner process dies

```elixir
# Stream monitors owner process and auto-cancels on death
{:ok, stream} = EventStream.start_link(owner: self())
# If calling process dies, stream automatically cleans up
```

#### Preemptive Scheduling for Responsive UI

The BEAM's preemptive scheduler ensures:

- **Non-blocking UI**: Long-running tool execution (bash commands) doesn't freeze the TUI
- **Concurrent Streaming**: Multiple LLM streams can run simultaneously without blocking each other
- **Responsive Steering**: User can send abort/steering messages even during heavy computation

```elixir
# Tool execution runs in separate Task process
Task.async(fn ->
  BashExecutor.execute(command, cwd, opts)
end)
# Main agent process remains responsive to messages
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Client Layer                                    │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐             │
│  │   Lemon TUI     │  │  Telegram Bot   │  │   Future: Web   │             │
│  │  (TypeScript)   │  │   (Transport)   │  │      UI         │             │
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘             │
└───────────┼────────────────────┼────────────────────┼──────────────────────┘
            │                    │                    │
            │ JSON-RPC/stdio     │ Telegram API       │
            ▼                    ▼                    │
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Gateway Layer                                      │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      LemonGateway                                    │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐ │   │
│  │  │  Scheduler  │  │   Thread    │  │   Engine    │  │  Telegram  │ │   │
│  │  │ (Concurrency)│  │   Workers   │  │  Registry   │  │ Transport  │ │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └────────────┘ │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Application Layer                                  │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      CodingAgent.Session                             │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐ │   │
│  │  │   Session   │  │   Tools     │  │  Compaction │  │   Hooks    │ │   │
│  │  │   Manager   │  │  (Registry) │  │   (Branch)  │  │(Extensions)│ │   │
│  │  └──────┬──────┘  └─────────────┘  └─────────────┘  └────────────┘ │   │
│  │         │                                                          │   │
│  │         ▼                                                          │   │
│  │  ┌─────────────────────────────────────────────────────────────┐   │   │
│  │  │                    AgentCore.Agent                           │   │   │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │   │   │
│  │  │  │    Loop     │  │   Events    │  │   Abort Signaling   │  │   │   │
│  │  │  │  (Stateless)│  │   (Stream)  │  │   (Reference)       │  │   │   │
│  │  │  └──────┬──────┘  └─────────────┘  └─────────────────────┘  │   │   │
│  │  │         │                                                    │   │   │
│  │  │         ├─────────────────────────────────────────────────┐  │   │   │
│  │  │         ▼                                                 ▼  │   │   │
│  │  │  ┌─────────────────────────────┐  ┌────────────────────────┐ │   │   │
│  │  │  │       Ai Library            │  │     CLI Runners        │ │   │   │
│  │  │  │  ┌────────┐ ┌────────┐     │  │  ┌────────┐ ┌────────┐ │ │   │   │
│  │  │  │  │Anthropic│ │ OpenAI │     │  │  │ Codex  │ │ Claude │ │ │   │   │
│  │  │  │  │Provider │ │Provider│ ... │  │  │ Runner │ │ Runner │ │ │   │   │
│  │  │  │  └────────┘ └────────┘     │  │  └────────┘ └────────┘ │ │   │   │
│  │  │  └─────────────────────────────┘  └────────────────────────┘ │   │   │
│  │  └──────────────────────────────────────────────────────────────┘   │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **User Input** → TUI/Telegram sends message to LemonGateway or CodingAgent.Session
2. **Gateway** schedules job, assigns to ThreadWorker, selects execution engine
3. **Engine** (Lemon native, Codex CLI, or Claude CLI) processes the request
4. **Agent** spawns Loop process that streams from AI library or CLI subprocess
5. **Events** flow back: LLM chunks → Agent events → Session/Gateway → UI
6. **Tool Calls** are executed by the Loop, with results fed back into context
7. **Persistence** happens via SessionManager writing to JSONL files

---

## Project Structure

```
lemon/
├── README.md                    # This file
├── mix.exs                      # Umbrella project configuration
├── mix.lock                     # Dependency lock file
├── .formatter.exs               # Elixir formatter configuration
├── .gitignore                   # Git ignore rules
│
├── config/
│   └── config.exs               # Application configuration (Codex CLI settings, etc.)
│
├── bin/                         # Executable scripts
│   └── lemon-dev                # Development launcher script
│
├── apps/                        # Umbrella applications
│   ├── ai/                      # Low-level LLM API abstraction layer
│   │   ├── lib/
│   │   │   ├── ai.ex            # Main API (stream/complete)
│   │   │   └── ai/
│   │   │       ├── application.ex
│   │   │       ├── call_dispatcher.ex  # RPC call coordination
│   │   │       ├── circuit_breaker.ex  # Circuit breaker for providers
│   │   │       ├── error.ex            # Error types
│   │   │       ├── event_stream.ex     # Streaming event handling
│   │   │       ├── models.ex           # Model registry and definitions
│   │   │       ├── provider.ex         # Provider behavior interface
│   │   │       ├── provider_registry.ex # Provider registration and lookup
│   │   │       ├── provider_supervisor.ex
│   │   │       ├── rate_limiter.ex     # Rate limiting logic
│   │   │       ├── types.ex            # Core types (Model, Context, etc.)
│   │   │       └── providers/          # Provider implementations
│   │   │           ├── anthropic.ex
│   │   │           ├── azure_openai_responses.ex
│   │   │           ├── bedrock.ex
│   │   │           ├── google.ex
│   │   │           ├── google_gemini_cli.ex
│   │   │           ├── google_shared.ex
│   │   │           ├── google_vertex.ex
│   │   │           ├── openai_completions.ex
│   │   │           ├── openai_codex_responses.ex
│   │   │           ├── openai_responses.ex
│   │   │           ├── openai_responses_shared.ex
│   │   │           └── text_sanitizer.ex
│   │   └── test/
│   │
│   ├── agent_core/              # Core agent framework (provider-agnostic)
│   │   ├── lib/
│   │   │   ├── agent_core.ex    # Main API
│   │   │   └── agent_core/
│   │   │       ├── application.ex
│   │   │       ├── abort_signal.ex       # Abort signaling mechanism
│   │   │       ├── agent.ex              # GenServer implementation
│   │   │       ├── agent_registry.ex     # Agent process registry
│   │   │       ├── context.ex            # Context management
│   │   │       ├── event_stream.ex       # Event stream handling
│   │   │       ├── loop.ex               # Stateless agent loop
│   │   │       ├── proxy.ex              # Stream proxy utilities
│   │   │       ├── subagent_supervisor.ex # Dynamic supervisor for subagents
│   │   │       ├── types.ex              # Agent types (AgentTool, AgentState, etc.)
│   │   │       └── cli_runners/          # CLI runner infrastructure (NEW)
│   │   │           ├── README.md         # CLI runners documentation
│   │   │           ├── types.ex          # ResumeToken, Action, Event types
│   │   │           ├── jsonl_runner.ex   # Base GenServer for JSONL subprocess runners
│   │   │           ├── codex_runner.ex   # Codex CLI wrapper
│   │   │           ├── codex_schema.ex   # Codex JSONL event parsing
│   │   │           ├── codex_subagent.ex # High-level Codex subagent API
│   │   │           ├── claude_runner.ex  # Claude CLI wrapper
│   │   │           ├── claude_schema.ex  # Claude JSONL event parsing
│   │   │           └── claude_subagent.ex # High-level Claude subagent API
│   │   └── test/
│   │
│   ├── coding_agent/            # Complete coding agent implementation
│   │   ├── lib/
│   │   │   ├── coding_agent.ex  # Main API
│   │   │   └── coding_agent/
│   │   │       ├── application.ex
│   │   │       ├── bash_executor.ex      # Shell command execution
│   │   │       ├── commands.ex           # Project-level command system
│   │   │       ├── compaction.ex         # Context compaction logic
│   │   │       ├── config.ex             # Configuration loading
│   │   │       ├── coordinator.ex        # Multi-session coordination
│   │   │       ├── extensions.ex         # Extension system
│   │   │       ├── extensions/
│   │   │       │   └── extension.ex      # Extension behavior interface
│   │   │       ├── layered_config.ex     # Hierarchical config system
│   │   │       ├── mentions.ex           # Mention/reference system
│   │   │       ├── messages.ex           # Message types & conversion
│   │   │       ├── prompt_builder.ex     # Prompt generation utilities
│   │   │       ├── resource_loader.ex    # CLAUDE.md and resource loading
│   │   │       ├── session.ex            # Session GenServer
│   │   │       ├── session_manager.ex    # JSONL persistence (v3 format)
│   │   │       ├── session_registry.ex   # Session process registry
│   │   │       ├── session_root_supervisor.ex
│   │   │       ├── session_supervisor.ex # Session lifecycle management
│   │   │       ├── settings_manager.ex   # User settings management
│   │   │       ├── skills.ex             # Skill/tool generation
│   │   │       ├── subagents.ex          # Subagent coordination
│   │   │       ├── tool_registry.ex      # Tool registration and lookup
│   │   │       ├── tools.ex              # Tool registration and wiring
│   │   │       ├── ui.ex                 # UI abstraction
│   │   │       ├── ui/
│   │   │       │   └── context.ex        # UI context management
│   │   │       ├── cli_runners/          # Lemon CLI runner (NEW)
│   │   │       │   ├── lemon_runner.ex   # Wraps CodingAgent.Session as CLI runner
│   │   │       │   └── lemon_subagent.ex # High-level Lemon subagent API
│   │   │       └── tools/                # Individual tool implementations
│   │   │           ├── bash.ex           # Bash execution tool
│   │   │           ├── edit.ex           # File editing tool
│   │   │           ├── extensions_status.ex # Extension status tool
│   │   │           ├── find.ex           # File finding tool
│   │   │           ├── glob.ex           # Glob pattern matching tool
│   │   │           ├── grep.ex           # Pattern search tool
│   │   │           ├── ls.ex             # Directory listing tool
│   │   │           ├── multiedit.ex      # Multiple file editing tool
│   │   │           ├── patch.ex          # Patch application tool
│   │   │           ├── read.ex           # File reading tool
│   │   │           ├── task.ex           # Task/subagent tool
│   │   │           ├── todo_store.ex     # Todo list storage (ETS-backed)
│   │   │           ├── todoread.ex       # Read todo list tool
│   │   │           ├── todowrite.ex      # Write todo list tool
│   │   │           ├── truncate.ex       # Text truncation utility
│   │   │           ├── webfetch.ex       # Web fetching tool
│   │   │           ├── websearch.ex      # Web search tool
│   │   │           └── write.ex          # File writing tool
│   │   └── test/
│   │
│   ├── coding_agent_ui/         # UI abstraction layer
│   │   ├── lib/
│   │   │   ├── coding_agent_ui/
│   │   │   │   └── application.ex
│   │   │   └── coding_agent/
│   │   │       └── ui/
│   │   │           ├── debug_rpc.ex     # Debug JSON-RPC interface
│   │   │           ├── headless.ex      # Headless mode implementation
│   │   │           └── rpc.ex           # JSON-RPC interface
│   │   └── test/
│   │
│   └── lemon_gateway/           # Gateway and job orchestration (NEW)
│       ├── lib/
│       │   ├── lemon_gateway.ex         # Main API
│       │   └── lemon_gateway/
│       │       ├── application.ex       # OTP application and supervision tree
│       │       ├── config.ex            # Gateway configuration
│       │       ├── engine.ex            # Engine behavior definition
│       │       ├── engine_lock.ex       # Per-thread mutual exclusion
│       │       ├── engine_registry.ex   # Engine lookup and management
│       │       ├── event.ex             # Event types (Started, Action, Completed)
│       │       ├── renderer.ex          # Renderer behavior
│       │       ├── run.ex               # Job execution GenServer
│       │       ├── run_supervisor.ex    # DynamicSupervisor for runs
│       │       ├── runtime.ex           # Public runtime API
│       │       ├── scheduler.ex         # Job scheduling and concurrency
│       │       ├── store.ex             # ETS-backed state storage
│       │       ├── thread_registry.ex   # Thread worker registry
│       │       ├── thread_worker.ex     # Per-conversation job queue
│       │       ├── thread_worker_supervisor.ex
│       │       ├── transport_supervisor.ex
│       │       ├── types.ex             # Core types (Job, ChatScope, ResumeToken)
│       │       ├── engines/             # Execution engine implementations
│       │       │   ├── echo.ex          # Simple echo engine (default)
│       │       │   ├── claude.ex        # Claude CLI engine
│       │       │   ├── codex.ex         # Codex CLI engine
│       │       │   └── cli_adapter.ex   # Bridge to AgentCore CLI runners
│       │       ├── renderers/
│       │       │   └── basic.ex         # Basic text renderer
│       │       └── telegram/            # Telegram bot integration
│       │           ├── api.ex           # Telegram Bot API wrapper
│       │           ├── dedupe.ex        # Message deduplication
│       │           ├── outbox.ex        # Message queue with throttling
│       │           └── transport.ex     # Bidirectional Telegram bridge
│       └── test/
│
├── clients/                     # Client applications
│   ├── lemon-tui/               # Terminal UI (TypeScript/Node.js)
│   │   ├── src/
│   │   │   ├── index.ts         # Main TUI application (themes, rendering)
│   │   │   ├── agent-connection.ts  # RPC client and connection management
│   │   │   ├── config.ts        # Configuration and argument parsing
│   │   │   ├── config.test.ts   # Configuration tests
│   │   │   ├── state.ts         # State management with multi-session support
│   │   │   ├── state.test.ts    # State management tests
│   │   │   └── types.ts         # TypeScript type definitions
│   │   ├── dist/
│   │   │   └── index.js         # Compiled JavaScript output
│   │   ├── package.json         # Node.js dependencies and scripts
│   │   ├── package-lock.json    # Dependency lock file
│   │   └── tsconfig.json        # TypeScript configuration
│   │
│   └── lemon-web/               # Web UI (placeholder)
│       └── ...
│
├── tools/                       # Utility tools and utilities
│   └── debug_cli/               # Python debug CLI
│       ├── debug_cli.py         # CLI entry point
│       ├── pyproject.toml       # Python project configuration
│       └── README.md
│
├── scripts/                     # Elixir and shell scripts
│   ├── debug_agent_rpc.exs      # Script for debugging agent RPC
│   └── cron_lemon_loop.sh       # Cron job script for agent loop
│
├── docs/                        # Documentation
│   ├── beam_agents.md           # BEAM agents architecture documentation
│   ├── benchmarks.md            # Performance benchmarks
│   ├── context.md               # Context management documentation
│   ├── extensions.md            # Extension system documentation
│   ├── layered_config.md        # Layered configuration documentation
│   ├── skills.md                # Skills system documentation
│   ├── telemetry.md             # Telemetry and observability
│   └── agent-loop/              # Agent loop documentation and runs
│       └── ...
│
└── examples/                    # Example projects and demonstrations
    ├── config.example.json      # Example configuration file
    └── extensions/              # Example extension implementations
```

---

## Core Components

### AI Library

The `Ai` library provides a unified interface for interacting with multiple LLM providers:

```elixir
# Create a context
context = Ai.new_context(system_prompt: "You are a helpful assistant")
context = Ai.Types.Context.add_user_message(context, "Hello!")

# Get a model
model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")

# Stream a response
{:ok, stream} = Ai.stream(model, context)

for event <- Ai.EventStream.events(stream) do
  case event do
    {:text_delta, _idx, delta, _partial_message} -> IO.write(delta)
    {:done, _reason, message} -> IO.puts("\nDone!")
    _ -> :ok
  end
end
```

**Key Features:**
- Provider-agnostic API
- Automatic cost calculation
- Token usage tracking
- Streaming with backpressure
- Session caching support

### AgentCore

`AgentCore` builds on `Ai` to provide a complete agent framework:

```elixir
# Create tools
read_tool = AgentCore.new_tool(
  name: "read_file",
  description: "Read a file",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"}
    },
    "required" => ["path"]
  },
  execute: fn _id, %{"path" => path}, _signal, _on_update ->
    case File.read(path) do
      {:ok, content} -> AgentCore.new_tool_result(content: [AgentCore.text_content(content)])
      {:error, reason} -> {:error, reason}
    end
  end
)

# Start an agent
{:ok, agent} = AgentCore.new_agent(
  model: model,
  system_prompt: "You are a coding assistant.",
  tools: [read_tool]
)

# Subscribe to events
AgentCore.subscribe(agent, self())

# Send a prompt
:ok = AgentCore.prompt(agent, "Read the README.md file")

# Receive events
receive do
  {:agent_event, event} -> handle_event(event)
end
```

**Key Features:**
- GenServer-based stateful agents
- Event-driven architecture
- Steering and follow-up message queues
- Abort signaling for cancellation
- Tool execution with streaming results

#### CLI Runner Infrastructure

AgentCore includes a comprehensive CLI runner infrastructure for integrating external AI tools as subagents:

```elixir
# Use Codex as a subagent
{:ok, session} = AgentCore.CliRunners.CodexSubagent.start(
  prompt: "Refactor this module",
  cwd: "/path/to/project"
)

# Stream events
for event <- AgentCore.CliRunners.CodexSubagent.stream(session) do
  case event do
    {:started, resume_token} -> IO.puts("Session started: #{resume_token}")
    {:action, action, :started, _opts} -> IO.puts("Starting: #{action.title}")
    {:action, action, :completed, _opts} -> IO.puts("Completed: #{action.title}")
    {:completed, answer, _opts} -> IO.puts("Answer: #{answer}")
  end
end

# Resume a session later
{:ok, session} = AgentCore.CliRunners.CodexSubagent.resume(
  resume_token,
  prompt: "Continue with the next step"
)
```

**Supported CLI Runners:**
- **CodexRunner/CodexSubagent**: Wraps Codex CLI with JSONL streaming
- **ClaudeRunner/ClaudeSubagent**: Wraps Claude CLI with stream-json output
- **LemonRunner/LemonSubagent**: Wraps native CodingAgent.Session as CLI runner
- **JsonlRunner**: Base infrastructure for building custom CLI runners

#### Task Tool Integration

The **Task tool** in CodingAgent uses CLI runners to delegate subtasks to different AI engines. This allows your agent to spawn Codex or Claude as subagents for specialized work:

```elixir
# When an agent uses the Task tool, it can specify which engine to use:
%{
  "description" => "Implement authentication",
  "prompt" => "Add JWT authentication to the User controller",
  "engine" => "codex"  # or "claude" or "internal" (default)
}
```

**How it works:**

1. **Internal engine** (default): Spawns a new `CodingAgent.Session` as a subprocess
2. **Codex engine**: Uses `CodexSubagent` to spawn the Codex CLI (`codex exec`)
3. **Claude engine**: Uses `ClaudeSubagent` to spawn Claude CLI (`claude -p`)

All engines support:
- **Streaming progress**: Events flow back to the parent agent
- **Resume tokens**: Sessions can be continued later
- **Role prompts**: Specialize the subagent (research, implement, review, test)
- **Abort signals**: Cancel long-running subtasks

**Example flow:**

```
Parent Agent                    Task Tool                     Codex CLI
     │                              │                             │
     │  tool_call: task             │                             │
     │  engine: "codex"             │                             │
     │  prompt: "Add tests"         │                             │
     │─────────────────────────────►│                             │
     │                              │  CodexSubagent.start()      │
     │                              │────────────────────────────►│
     │                              │                             │
     │                              │  {:started, resume_token}   │
     │                              │◄────────────────────────────│
     │                              │                             │
     │  on_update: "Running..."     │  {:action, "edit file"...}  │
     │◄─────────────────────────────│◄────────────────────────────│
     │                              │                             │
     │                              │  {:completed, answer, ...}  │
     │                              │◄────────────────────────────│
     │  tool_result: answer         │                             │
     │◄─────────────────────────────│                             │
```

**Configuration:**

Configure Codex CLI behavior in settings (`~/.lemon/agent/settings.json`):

```json
{
  "codex": {
    "extraArgs": ["-c", "notify=[]"],
    "autoApprove": false
  }
}
```

Or in `config/config.exs`:

```elixir
config :agent_core, :codex,
  extra_args: ["-c", "notify=[]"],
  auto_approve: false
```

### CodingAgent

`CodingAgent` is a complete coding assistant built on `AgentCore`:

```elixir
# Start a session
{:ok, session} = CodingAgent.start_session(
  cwd: "/path/to/project",
  model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
)

# Subscribe to events
unsubscribe = CodingAgent.Session.subscribe(session)

# Send a prompt
:ok = CodingAgent.Session.prompt(session, "Refactor the User module")

# Navigate session tree
:ok = CodingAgent.Session.navigate_tree(session, entry_id, direction: :parent)

# Compact context when it gets too long
:ok = CodingAgent.Session.compact(session)
```

**Key Features:**
- Session persistence (JSONL v3 format with tree structure)
- Built-in coding tools (read, write, edit, multiedit, patch, bash, grep, find, glob, ls, webfetch, websearch, todoread, todowrite, task)
- Context compaction and branch summarization
- Extension system for custom tools
- Settings management (global + project-level)
- LemonRunner/LemonSubagent for using sessions as CLI runner backends

### LemonGateway

`LemonGateway` provides job orchestration and multi-engine execution:

```elixir
# Submit a job
job = %LemonGateway.Types.Job{
  scope: %LemonGateway.Types.ChatScope{transport: :telegram, chat_id: 123},
  text: "Explain this code",
  engine_hint: "claude"  # or "codex", "lemon"
}

LemonGateway.submit(job)

# Events flow through the system:
# Job → Scheduler → ThreadWorker → Run → Engine → Events → Renderer → Output
```

**Key Features:**
- **Multi-Engine Support**: Echo (default), Codex CLI, Claude CLI engines
- **Job Scheduling**: Configurable concurrency with slot-based allocation
- **Thread Workers**: Per-conversation job queues with sequential execution
- **Resume Tokens**: Persist and continue sessions across restarts
- **Event Streaming**: Unified event format across all engines
- **Telegram Integration**: Bot transport with debouncing and throttling

**Supported Engines:**
| Engine | ID | Description |
|--------|-----|-------------|
| Lemon | `lemon` | Native CodingAgent.Session with full tool support and steering |
| Claude | `claude` | Claude CLI via subprocess |
| Codex | `codex` | Codex CLI via subprocess |
| Echo | `echo` | Simple echo stub for testing |

### Lemon TUI

The Terminal UI client provides a full-featured interactive interface for interacting with the Lemon coding agent. It supports real-time streaming, multi-session management, interactive overlays, keyboard shortcuts, and configurable settings.

#### CLI Usage

```bash
# Start the TUI with default settings (using lemon-dev script)
./bin/lemon-dev

# Specify working directory
./bin/lemon-dev /path/to/project

# Specify AI model (provider:model_id)
./bin/lemon-dev --model anthropic:claude-sonnet-4-20250514
./bin/lemon-dev --model openai:gpt-4-turbo

# Specify provider separately (overrides config/env)
./bin/lemon-dev --provider anthropic

# Set custom base URL (for local/alternative providers)
./bin/lemon-dev --base-url http://localhost:11434/v1

# Enable debug mode
./bin/lemon-dev --debug

# Force rebuild of TUI
./bin/lemon-dev --rebuild
```

#### Configuration

Lemon TUI reads settings from `~/.lemon/config.json`, then applies environment variables, then CLI args (highest priority).

Example `~/.lemon/config.json`:

```json
{
  "default_provider": "anthropic",
  "default_model": "claude-sonnet-4-20250514",
  "providers": {
    "anthropic": {
      "api_key": "sk-ant-..."
    },
    "openai": {
      "api_key": "sk-..."
    },
    "kimi": {
      "api_key": "sk-kimi-...",
      "base_url": "https://api.kimi.com/coding/"
    },
    "google": {
      "api_key": "your-google-api-key"
    }
  },
  "tui": {
    "theme": "lemon",
    "debug": false
  }
}
```

Environment overrides (examples):
- `LEMON_DEFAULT_PROVIDER`, `LEMON_DEFAULT_MODEL`, `LEMON_THEME`, `LEMON_DEBUG`
- `<PROVIDER>_API_KEY`, `<PROVIDER>_BASE_URL` (e.g., `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`)

#### Slash Commands

All commands are prefixed with `/`. Type `/help` within the TUI to see this list:

**Session Management:**
- `/abort` — Stop the current operation
- `/reset` — Clear conversation history and reset the current session
- `/save` — Save the current session to a JSONL file
- `/sessions` — List all saved sessions
- `/resume [name]` — Resume a previously saved session by name
- `/stats` — Show current session statistics (tokens used, cost, message count)
- `/debug [on|off]` — Toggle debug mode

**Search and Settings:**
- `/search <term>` — Search conversation history for matching text
- `/settings` — Open the settings overlay

**Multi-Session Commands:**
- `/running` — List all currently running sessions with their status
- `/new-session [--cwd <path>] [--model <model>]` — Start a new session
- `/switch [session_id]` — Switch to a different session
- `/close-session [session_id]` — Close a session

**Application:**
- `/quit` or `/exit` or `/q` — Exit the application
- `/help` — Display help message with all commands and shortcuts

#### Keyboard Shortcuts

**Message Input:**
- **Enter** — Send message to the agent
- **Shift+Enter** — Insert newline in editor

**Session Management:**
- **Ctrl+N** — Create new session
- **Ctrl+Tab** — Cycle through open sessions

**Tool Output:**
- **Ctrl+O** — Toggle tool output panel visibility

**Application Control:**
- **Ctrl+C** (once, empty editor) — Show quit hint
- **Ctrl+C** (twice) — Exit the application
- **Esc** (once, during agent execution) — Show abort hint
- **Esc** (twice) — Abort current agent operation
- **Escape** — Cancel/close overlay dialogs

#### Key Features

- **Real-time Streaming**: Watch LLM responses appear character-by-character
- **Tool Execution Visualization**: Dedicated panel showing tool execution with outputs and results
- **Multi-Session Management**: Run multiple independent agent sessions, switch between them
- **Markdown Rendering**: Responses rendered with syntax highlighting and formatting
- **Overlay Dialogs**: Interactive select, confirm, input, and editor overlays
- **Session Persistence**: Save and resume sessions with full conversation tree structure
- **Search**: Search across entire conversation history
- **Settings Management**: Configurable themes (lemon/lime), debug mode, persisted to config file
- **Git Integration**: Displays git branch and status in the status bar
- **Token Tracking**: Real-time display of input/output tokens and running cost estimate
- **Auto-Completion**: Smart completion for commands and paths
- **Debug Mode**: Toggle debug output to see internal events and diagnostics
- **Prompt Caching Metrics**: Track cache read/write tokens for efficient API usage

---

## Installation

### Prerequisites

- Elixir 1.19+ and Erlang/OTP 27+
- Node.js 20+ (for TUI)
- Python 3.10+ (for debug CLI, optional)

### Clone and Build

```bash
# Clone the repository
git clone https://github.com/yourusername/lemon.git
cd lemon

# Install Elixir dependencies
mix deps.get

# Build the project
mix compile

# Install TUI dependencies
cd clients/lemon-tui
npm install
npm run build
cd ../..
```

### Quick Start with lemon-dev

The easiest way to run Lemon is using the development launcher:

```bash
# Make executable (first time only)
chmod +x bin/lemon-dev

# Run with defaults
./bin/lemon-dev

# Run in a specific directory
./bin/lemon-dev /path/to/your/project

# Use a specific model
./bin/lemon-dev --model anthropic:claude-sonnet-4-20250514
```

The `lemon-dev` script automatically:
1. Installs Elixir dependencies if needed
2. Compiles the Elixir project
3. Installs and builds the TUI if needed
4. Launches the TUI with your specified options

### Configuration

Create a settings file at `~/.lemon/agent/settings.json`:

```json
{
  "defaultModel": {
    "provider": "anthropic",
    "modelId": "claude-sonnet-4-20250514"
  },
  "providers": {
    "anthropic": {
      "apiKey": "sk-ant-..."
    },
    "openai": {
      "apiKey": "sk-..."
    },
    "google": {
      "apiKey": "your-google-api-key"
    },
    "azure-openai-responses": {
      "apiKey": "your-azure-key"
    }
  }
}
```

Alternatively, use environment variables:

```bash
# Anthropic
export ANTHROPIC_API_KEY="sk-ant-..."

# OpenAI
export OPENAI_API_KEY="sk-..."

# Google Generative AI
export GOOGLE_GENERATIVE_AI_API_KEY="your-api-key"
# or
export GOOGLE_API_KEY="your-api-key"
export GEMINI_API_KEY="your-api-key"

# AWS Bedrock
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION="us-east-1"

# Azure OpenAI
export AZURE_OPENAI_API_KEY="your-api-key"
export AZURE_OPENAI_BASE_URL="https://myresource.openai.azure.com/openai/v1"
export AZURE_OPENAI_RESOURCE_NAME="myresource"
export AZURE_OPENAI_API_VERSION="2024-12-01-preview"
```

### Codex CLI Configuration

To configure Codex CLI runner behavior, add to `config/config.exs`:

```elixir
config :agent_core, :codex,
  extra_args: ["-c", "notify=[]"],  # Extra args passed to codex before exec
  auto_approve: false                # Enable full automation without approvals
```

---

## Usage

### Running the TUI

```bash
# Using lemon-dev (recommended)
./bin/lemon-dev --cwd /path/to/your/project

# With specific model
./bin/lemon-dev \
  --cwd /path/to/project \
  --model anthropic:claude-sonnet-4-20250514

# With custom base URL (for local models)
./bin/lemon-dev \
  --cwd /path/to/project \
  --model openai:llama3.1:8b \
  --base-url http://localhost:11434/v1
```

### Running Tests

```bash
# Run all tests
mix test

# Run tests for specific app
mix test apps/ai
mix test apps/agent_core
mix test apps/coding_agent
mix test apps/lemon_gateway

# Run integration tests (require CLI tools)
mix test --include integration
```

### Interactive Development

```bash
# Start an IEx session with the project loaded
iex -S mix

# In IEx, start a session with required model parameter:
{:ok, session} = CodingAgent.start_session(
  cwd: File.cwd!(),
  model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
)

# Subscribe to session events
unsubscribe = CodingAgent.Session.subscribe(session)

# Send a prompt to the session
:ok = CodingAgent.Session.prompt(session, "Read the mix.exs file")

# Receive and handle events
receive do
  {:session_event, session_id, event} ->
    IO.inspect(event)
end
```

### Settings Configuration

Settings support multiple formats and can be stored globally at `~/.lemon/agent/settings.json` or per-project at `.lemon/settings.json`. Project settings override global settings.

#### Map Format (Recommended)

```json
{
  "defaultModel": {
    "provider": "anthropic",
    "modelId": "claude-sonnet-4-20250514"
  },
  "providers": {
    "anthropic": {
      "apiKey": "sk-ant-..."
    }
  }
}
```

#### Flat Style

```json
{
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "providers": {
    "anthropic": {
      "apiKey": "sk-ant-..."
    }
  }
}
```

#### String Style

```json
{
  "defaultModel": "anthropic:claude-sonnet-4-20250514"
}
```

All three formats are equivalent and will be normalized to the internal representation.

---

## Development

### Architecture Decisions

#### Why an Umbrella Project?

The umbrella structure separates concerns while maintaining tight integration:

- **`ai`**: Pure LLM API abstraction, no agent logic
- **`agent_core`**: Generic agent framework with CLI runner infrastructure
- **`coding_agent`**: Complete coding agent, uses `agent_core`
- **`coding_agent_ui`**: UI abstractions, separate from core logic
- **`lemon_gateway`**: Job orchestration and multi-engine execution

This allows:
- Independent testing and versioning
- Potential extraction to separate libraries
- Clear dependency boundaries

#### Why GenServers for Agents?

GenServers provide:
- **State isolation**: Each agent has its own state
- **Message mailbox**: Natural queue for steering messages
- **Process monitoring**: Automatic cleanup on crashes
- **Synchronous calls**: For operations that need confirmation
- **Asynchronous casts**: For fire-and-forget operations

#### Why Event Streams?

Event streams (implemented as GenServer-based producers) provide:
- **Backpressure**: Consumers control consumption rate
- **Cancellation**: Streams can be aborted mid-flight
- **Composition**: Streams can be mapped, filtered, combined
- **Resource cleanup**: Automatic cleanup when done

### Adding a New Tool

```elixir
# In apps/coding_agent/lib/coding_agent/tools/my_tool.ex
defmodule CodingAgent.Tools.MyTool do
  alias AgentCore.Types.AgentTool

  def tool(cwd, _opts) do
    %AgentTool{
      name: "my_tool",
      description: "Does something useful",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "arg" => %{"type" => "string"}
        },
        "required" => ["arg"]
      },
      execute: fn id, %{"arg" => arg}, signal, on_update ->
        # Do work here
        result = do_something(arg)

        AgentCore.new_tool_result(
          content: [AgentCore.text_content(result)],
          details: %{processed: true}
        )
      end
    }
  end
end
```

Then register it in `CodingAgent.Tools`:

```elixir
def coding_tools(cwd, opts) do
  [
    # ... existing tools
    CodingAgent.Tools.MyTool.tool(cwd, opts)
  ]
end
```

### Adding a New LLM Provider

1. Create a provider module in `apps/ai/lib/ai/providers/my_provider.ex`
2. Implement the `Ai.Provider` behavior
3. Register in `Ai.ProviderRegistry`

See existing providers for examples.

### Adding a New Execution Engine

1. Create an engine module in `apps/lemon_gateway/lib/lemon_gateway/engines/my_engine.ex`
2. Implement the `LemonGateway.Engine` behavior:
   ```elixir
   @callback id() :: String.t()
   @callback start_run(job, opts, sink_pid) :: {:ok, run_ref, cancel_ctx} | {:error, term()}
   @callback cancel(cancel_ctx) :: :ok
   @callback format_resume(ResumeToken.t()) :: String.t()
   @callback extract_resume(String.t()) :: ResumeToken.t() | nil
   ```
3. Register in `LemonGateway.EngineRegistry`

---

## License

MIT License - see LICENSE file for details.

---

## Acknowledgments

### Special Thanks to [Mario Zechner](https://github.com/badlogic) and the [pi](https://github.com/badlogic/pi-mono) Project

This codebase is **heavily inspired by [pi](https://github.com/badlogic/pi-mono)**—Mario Zechner's agent framework. The pi project demonstrated the power of building agentic systems with:

- **Event-driven streaming** for real-time UI updates
- **Composable tool abstractions** with streaming results
- **Session tree structures** for conversation history
- **Context compaction** strategies for long conversations
- **Steering mechanisms** for user intervention

Many of the core concepts, type definitions, and architectural patterns in Lemon were adapted from pi's TypeScript implementation and reimagined for the BEAM. The pi project proved that agents should be built as reactive, event-driven systems—and Lemon brings that philosophy to Elixir/OTP.

Thank you, Mario, for open-sourcing pi and advancing the state of agent frameworks!

### Additional Thanks

- Built with [Elixir](https://elixir-lang.org/) and the [BEAM](https://www.erlang.org/)
- TUI powered by [@mariozechner/pi-tui](https://www.npmjs.com/package/@mariozechner/pi-tui)
- Inspired by [Claude Code](https://claude.ai/code), [Aider](https://aider.chat/), and [Cursor](https://cursor.sh/)
