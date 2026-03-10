# Part 6: The Agent (coding_agent + agent_core)

[< The Engine Room](05-the-engine-room.md) | [Next: Talking to LLMs >](07-talking-to-llms.md)

---

This is the heart of Lemon — where the AI actually thinks, uses tools, and
generates responses. It's split into two apps:

- **agent_core** — the generic runtime (the "engine block")
- **coding_agent** — the specific personality and capabilities (the "car body")

agent_core knows how to run an agent loop, call LLMs, execute tools, and stream
events. coding_agent knows what tools to provide, how to compose system prompts,
how to persist sessions, and how to manage memory. Together, they make Lemon
a capable AI assistant.

---

## The Agent Loop

The agent loop is the fundamental cycle that drives all AI interactions in Lemon.
Here's how it works in plain English:

```
1. Take the user's message + conversation history + system prompt
2. Send it all to the LLM (Claude, GPT, etc.)
3. The LLM responds with either:
   a. Just text → we're done, deliver the response
   b. Text + tool calls → execute the tools, add results to history, go to step 2
4. Repeat until the LLM responds with just text (no more tool calls)
```

That's it. The loop is simple in concept but powerful in practice — the AI can
chain together multiple tool calls across multiple turns to accomplish complex
tasks.

### A Concrete Example

You ask: "What's the largest file in my project?"

```
Turn 1:
  You: "What's the largest file in my project?"
  AI: [tool_call: bash("find . -type f -exec ls -la {} + | sort -k5 -rn | head -5")]

Turn 2:
  Tool result: "-rw-r--r-- 1 user user 245632 Mar 10 data.json\n..."
  AI: "The largest file in your project is `data.json` at 240 KB, followed by..."
  → No tool calls, so we're done.
```

The user sees the final text response on Telegram. The intermediate tool calls
happen behind the scenes (though tool status updates may appear briefly).

### Inside the Loop (Technical Detail)

The loop is implemented across several modules:

- **`AgentCore.Agent`** — a GenServer that holds conversation state, spawns the
  loop task, and fans out events to subscribers
- **`AgentCore.Loop`** — the stateless recursive loop with an outer loop
  (handles follow-up messages) and an inner loop (handles tool calls)
- **`AgentCore.Loop.Streaming`** — handles one LLM call: builds the context,
  calls `Ai.stream/3`, processes the token stream
- **`AgentCore.Loop.ToolCalls`** — executes all tool calls from one turn in
  parallel, collects results

### Parallel Tool Execution

When the AI makes multiple tool calls in a single response (e.g., "read these
three files"), they execute **in parallel** under a Task.Supervisor. There's a
configurable `max_tool_concurrency` to prevent resource exhaustion. Results are
collected and sent back to the LLM as a batch.

### Abort (Cancellation)

When you tap `/cancel` in Telegram, an **AbortSignal** is set (an ETS flag).
The loop checks this flag:
- Before each LLM call
- Before each tool batch
- Tools can check it themselves during execution

Abort is cooperative — it doesn't kill anything forcefully. This allows
in-progress work to clean up gracefully.

---

## Events and Streaming

Everything in the agent produces **events** that flow through an `EventStream`.
This is how Telegram shows you the AI "typing" in real-time.

The event lifecycle for one run:

```
{:agent_start}
  {:turn_start}
    {:message_start, :user, ...}
    {:message_end, :user, ...}
    {:message_start, :assistant, ...}
    {:message_update, :assistant, "Here"}         ← token
    {:message_update, :assistant, "Here is"}      ← token
    {:message_update, :assistant, "Here is the"}  ← token
    ...
    {:message_end, :assistant, full_message}
    {:tool_execution_start, "bash", ...}          ← if tool call
    {:tool_execution_update, "bash", partial}     ← streaming tool output
    {:tool_execution_end, "bash", result}
    {:message_start, :tool_result, ...}
    {:message_end, :tool_result, ...}
    ... (another LLM call if there were tool calls)
  {:turn_end}
{:agent_end, all_new_messages}
```

The `EventStream` is a bounded FIFO queue with backpressure — if the consumer
(the gateway/router) falls behind, the producer blocks rather than growing
memory unboundedly.

---

## The 30+ Tools

coding_agent gives the AI a rich toolkit. Here are the main categories:

### File Operations

| Tool | What It Does |
|------|-------------|
| `read` | Read file contents, optionally a specific line range |
| `write` | Create or overwrite a file |
| `edit` | Find-and-replace text in a file (must be a unique match) |
| `hashline_edit` | Edit by line number when text isn't unique |
| `patch` | Apply a unified diff patch |
| `multiedit` | Multiple find-and-replace edits in one call |
| `ls` | List directory contents |

### Search

| Tool | What It Does |
|------|-------------|
| `grep` | Search file contents with regex (via ripgrep) |
| `find` | Find files by name pattern |

### Execution

| Tool | What It Does |
|------|-------------|
| `bash` | Run a shell command (streaming output, abort-aware) |
| `exec` | Run a long-running background process |
| `process` | Control background processes (poll output, send input, kill) |
| `browser` | Control Chrome via Playwright (navigate, click, type, screenshot) |

### Web

| Tool | What It Does |
|------|-------------|
| `websearch` | Search the web via Brave Search API or Perplexity |
| `webfetch` | Fetch and extract text from a URL |
| `webdownload` | Download binary content (images, PDFs) to disk |

### Task Delegation

| Tool | What It Does |
|------|-------------|
| `task` | Spawn a subtask session (can use any engine: lemon, claude, codex, kimi) |
| `agent` | Delegate work to another named Lemon agent |
| `await` | Wait for async background jobs to complete |

### Organization

| Tool | What It Does |
|------|-------------|
| `todo` | Manage a session todo list (add, check off, view) |

### Social

| Tool | What It Does |
|------|-------------|
| `post_to_x` | Post a tweet to X/Twitter |
| `get_x_mentions` | Fetch X/Twitter mentions |

### Tool Precedence

When multiple sources provide tools with the same name, the precedence is:
1. **Built-in tools** (the ones listed above)
2. **WASM tools** (from `.lemon/wasm/` — Rust-compiled WebAssembly modules)
3. **Extension tools** (from `.lemon/extensions/` — Elixir modules)

Later sources shadow earlier ones with the same name.

---

## Sessions and Persistence

### How Sessions Work

A **session** in coding_agent is a persistent conversation backed by a JSONL
file on disk. The file lives at:

```
~/.lemon/agent/sessions/{encoded-cwd}/{session_id}.jsonl
```

Each line in the file is either a `SessionHeader` (line 1) or a `SessionEntry`.
Entries form a tree structure (each has an `id` and `parent_id`) supporting
branching conversations. Entry types include:
- `:message` — a user, assistant, or tool result message
- `:compaction` — a summary replacing older messages
- `:branch_summary` — a summary of a conversation branch
- `:label` — a user-assigned label

### Session Lifecycle

1. **Creation:** When the gateway starts a native Lemon engine run,
   `CodingAgent.Session` initializes: loads/creates the JSONL file, loads
   config, composes the system prompt, starts the WASM sidecar (if any),
   loads extensions, builds the tool list, starts `AgentCore.Agent`, and
   restores message history.

2. **During a run:** As events flow through the agent loop, the Session's
   `EventHandler` processes each one — persisting messages to JSONL on
   `message_end`, running extension hooks, updating UI status, and tracking
   compaction triggers.

3. **Between runs:** The session's resume token is saved in `ChatStateStore`.
   When a new message arrives, the gateway loads this token and continues
   the same CodingAgent session, preserving full conversation history.

### Compaction

Conversations can grow very long. When they get close to the AI's context
window limit, **compaction** kicks in:

1. Find a valid cut point in the history (never cut in the middle of a
   tool call/result pair)
2. Generate an LLM summary of the compacted messages
3. Replace the old messages with the summary + a compaction marker in the
   JSONL file

The AI then continues with the summary in its context instead of the full
history. This is transparent to the user — the conversation flows naturally
even though older messages have been summarized.

---

## The System Prompt

The system prompt tells the AI who it is and what it can do. coding_agent
composes it from multiple sources, layered in order:

1. **Opening line** — "You are a personal assistant running inside Lemon."
2. **Available skills** — a list of lemon_skills discovered for the current
   working directory
3. **Memory guidance** — instructions for using SOUL.md, MEMORY.md, daily notes
4. **Workspace bootstrap files:**
   - `SOUL.md` — the agent's personality and values
   - `USER.md` — facts about the user
   - `AGENTS.md` — project-specific agent instructions
   - `TOOLS.md` — tool configuration notes
   - `MEMORY.md` — persistent memory across sessions
   - `HEARTBEAT.md` — heartbeat task config
   - `BOOTSTRAP.md` — additional bootstrap content
5. **Prompt template** (if configured)
6. **Explicit system_prompt** (if provided by caller)
7. **Resource walk** — CLAUDE.md/AGENTS.md files found by walking up the
   directory tree from cwd to root

The system prompt is **rebuilt before each user prompt** so it picks up any
edits to workspace files. If you update SOUL.md between messages, the next
message will use the updated version.

Subagents (spawned via the `task` tool) get a reduced set — only AGENTS.md and
TOOLS.md, not the personality files.

---

## Context Guardrails

When tool results are very large (e.g., reading a huge file or getting verbose
command output), they can eat up the AI's context window. The
**ContextGuardrails** system handles this:

1. **Truncation:** Oversized tool results are truncated to a configurable limit
2. **Spill-to-disk:** The full content is saved to a "spill" file on disk
3. **Reference:** The truncated result includes a reference to the spill file
4. **Recovery:** The AI can use the `read` tool to access the full content
   from the spill file if needed

This means the AI never loses information — it just has to explicitly request
large results rather than having them forced into its context.

---

## Budget Enforcement

Lemon tracks resource usage per run to prevent runaway costs:

- **Token budget:** Maximum input + output tokens per run
- **Cost budget:** Maximum dollar cost per run
- **Subagent limit:** Maximum concurrent child tasks

The `BudgetTracker` records usage in ETS, and the `BudgetEnforcer` checks
limits before each LLM call and subagent spawn. Child tasks inherit budget
limits from their parent, and child usage is aggregated into the parent's
totals.

When a budget is exceeded, the configured action is taken: cancel the run,
suggest compaction, warn only, or return an error.

---

## Extensions and WASM Tools

Beyond the built-in tools, Lemon supports two extension mechanisms:

### Elixir Extensions

Drop Elixir modules into `~/.lemon/agent/extensions/` or
`.lemon/extensions/`. They implement a behaviour with lifecycle hooks
(`:on_turn_start`, `:on_message_end`, etc.) and can provide additional tools.
Extensions are hot-reloadable.

### WASM Tools

Place Rust-compiled WebAssembly modules in `.lemon/wasm/`. Each WASM tool runs
in a sandboxed environment with explicit capability declarations. They're
compiled on demand if `auto_build = true` is set in config.

---

## CLI Runners

For the CLI-based gateway engines (claude, codex, kimi, opencode, pi),
agent_core provides **CLI Runners** — a three-layer architecture for wrapping
external CLI tools:

1. **`JsonlRunner`** — generic GenServer that spawns a subprocess, reads its
   stdout line by line, handles graceful shutdown (SIGTERM → grace → SIGKILL),
   session locking, and owner process monitoring
2. **Engine-specific Runner** — implements `build_command/3` (CLI binary and
   flags), `stdin_payload/3`, and `translate_event/2` (parses the engine's JSON
   into unified event structs)
3. **Engine-specific Subagent** — high-level API with `start/1`, `events/1`,
   `continue/2`, `resume/2`

All CLI runners produce the same event types: `StartedEvent`, `ActionEvent`,
`CompletedEvent`. This uniformity is what lets the gateway treat all engines
identically.

---

## Key Takeaways

1. **The agent loop is simple: prompt → LLM → maybe tools → repeat.** The power
   comes from the tools and the LLM's ability to chain them together.
2. **Tools execute in parallel** when the AI requests multiple tools in one turn.
3. **Sessions persist as JSONL files** — conversation history survives restarts.
4. **Compaction handles long conversations** by summarizing old messages.
5. **The system prompt is rebuilt each turn** — changes to workspace files take
   effect immediately.
6. **Context guardrails with spill-to-disk** prevent large tool results from
   overwhelming the context window.
7. **agent_core is generic, coding_agent is specific** — the runtime knows
   nothing about coding; the personality layer knows nothing about loop
   mechanics.

---

[Next: Talking to LLMs (ai) >](07-talking-to-llms.md)
