# CLI Runners

This module provides infrastructure for wrapping CLI-based AI tools (Codex, Claude, Kimi, etc.) as subagents. Inspired by the [Takopi](https://github.com/your-org/takopi) project's reliable subprocess management patterns.

## Overview

CLI Runners enable you to:

- **Spawn AI CLI tools as subprocesses** with proper lifecycle management
- **Stream JSONL events** from the CLI's output
- **Maintain long-lived sessions** with resume capability
- **Integrate external agents** as collaborators in your main agent loop

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        CodexSubagent                             │
│                   (High-level API)                               │
├─────────────────────────────────────────────────────────────────┤
│                        CodexRunner                               │
│             (Codex-specific event translation)                   │
├─────────────────────────────────────────────────────────────────┤
│                       JsonlRunner                                │
│           (Generic JSONL subprocess GenServer)                   │
├─────────────────────────────────────────────────────────────────┤
│                  LemonCore.RunEvents (lemon_core)                │
│    (ResumeToken, Action, StartedEvent, ActionEvent, etc.)       │
└─────────────────────────────────────────────────────────────────┘
```

The event vocabulary is owned by `lemon_core`, not by this package: every
engine — these CLI wrappers and Lemon's own native session alike — emits
`LemonCore.RunEvents` structs, so consumers never branch on the vendor.

## Registration

Each `*Subagent` module implements `LemonCore.SubagentRunner` and is registered
into `LemonCore.SubagentRegistry` by `LemonCliRunners.Application` at boot. That
is the whole integration with the agent: the `task` tool reads the registry for
its engine list, its tool-description prose (from each runner's `describe/0`)
and the module to run, so nothing in the agent names a vendor. Drop this
package from a build and those engines simply stop being offered.

Each `*Subagent` also declares `resume_format/0` — how its CLI spells "resume"
(`codex resume X`, `claude --resume X`, pi's quoted transcript paths) — which
`LemonCliRunners.Application` registers into `LemonCore.ResumeFormats`.
`LemonCore.ResumeToken` prints and parses those lines for the whole platform
without knowing any vendor; without this package it falls back to the generic
`<engine> resume <token>`.

## Quick Start

### Basic Usage

```elixir
alias LemonCliRunners.CodexSubagent

# Start a new Codex session
{:ok, session} = CodexSubagent.start(
  prompt: "Create a GenServer that manages a counter with increment/decrement",
  cwd: "/path/to/project"
)

# Process events as they stream
for event <- CodexSubagent.events(session) do
  case event do
    {:started, token} ->
      IO.puts("Session: #{token.value}")

    {:action, %{kind: :command, title: cmd}, :started, _} ->
      IO.puts("Running: #{cmd}")

    {:action, %{kind: :file_change, title: title}, :completed, ok: true} ->
      IO.puts("Changed: #{title}")

    {:completed, answer, _opts} ->
      IO.puts("Done: #{answer}")

    _ -> :ok
  end
end
```

### One-Shot Execution

```elixir
# Run synchronously and get the answer
answer = CodexSubagent.run!(
  prompt: "Explain this error: undefined function foo/2",
  cwd: ".",
  on_event: &IO.inspect/1
)

IO.puts(answer)
```

### Session Continuation

```elixir
# Start initial session
{:ok, session1} = CodexSubagent.start(prompt: "Create a User struct", cwd: ".")
_events = CodexSubagent.events(session1) |> Enum.to_list()

# Continue the session
{:ok, session2} = CodexSubagent.continue(session1, "Add validation for email field")
_events = CodexSubagent.events(session2) |> Enum.to_list()

# Or resume later using the token
token = CodexSubagent.resume_token(session2)
{:ok, session3} = CodexSubagent.resume(token, prompt: "Now add a changeset function")
```

## Event Types

Events are normalized into a simple format:

| Event | Description |
|-------|-------------|
| `{:started, token}` | Session began, token can be saved for resume |
| `{:action, action, :started, opts}` | Action began |
| `{:action, action, :updated, opts}` | Action has progress |
| `{:action, action, :completed, ok: bool}` | Action finished |
| `{:completed, answer, opts}` | Session ended |
| `{:error, reason}` | Error occurred |

### Action Kinds

| Kind | Description |
|------|-------------|
| `:command` | Shell command execution |
| `:tool` | MCP tool call |
| `:file_change` | File modifications |
| `:web_search` | Web search |
| `:note` | Informational note |
| `:turn` | Conversation turn |
| `:warning` | Warning message |

## Integration as Agent Tool

```elixir
defmodule MyAgent.Tools do
  alias LemonCliRunners.CodexSubagent
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  def codex_tool(cwd) do
    %AgentTool{
      name: "codex",
      description: "Delegate a complex coding task to a Codex subagent",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "The coding task to perform"
          }
        },
        "required" => ["task"]
      },
      execute: fn _id, %{"task" => task}, _signal, on_update ->
        {:ok, session} = CodexSubagent.start(prompt: task, cwd: cwd)

        # Stream progress updates
        answer = session
        |> CodexSubagent.events()
        |> Enum.reduce("", fn
          {:action, %{title: title}, :completed, ok: true}, acc ->
            if on_update do
              on_update.(%AgentToolResult{
                content: [%TextContent{text: "Completed: #{title}"}]
              })
            end
            acc

          {:completed, answer, _}, _acc ->
            answer

          _, acc ->
            acc
        end)

        %AgentToolResult{
          content: [%TextContent{text: answer}],
          details: %{
            resume_token: CodexSubagent.resume_token(session)
          }
        }
      end
    }
  end
end
```

## Low-Level API

For more control, use the runner directly:

```elixir
alias LemonCliRunners.CodexRunner
alias LemonCore.ResumeToken

# Start runner
{:ok, pid} = CodexRunner.start_link(
  prompt: "Hello",
  cwd: "/path/to/project",
  timeout: 300_000
)

# Get event stream
stream = CodexRunner.stream(pid)

# Process raw events
for event <- LemonAgent.EventStream.events(stream) do
  case event do
    {:cli_event, event} -> handle_cli_event(event)
    {:agent_end, _} -> :done
    _ -> :ok
  end
end
```

## Implementing New Runners

To add support for a new CLI tool (e.g., Claude):

```elixir
defmodule LemonCliRunners.ClaudeRunner do
  use LemonCliRunners.JsonlRunner

  alias LemonCore.RunEvents.EventFactory
  alias LemonCore.ResumeToken

  @impl true
  def engine, do: "claude"

  @impl true
  def build_command(prompt, resume, _state) do
    args = ["-p", "--output-format", "stream-json"]

    args = case resume do
      %ResumeToken{value: session_id} ->
        args ++ ["--resume", session_id]
      nil ->
        args
    end

    {"claude", args ++ ["--input-format", "text"]}
  end

  @impl true
  def stdin_payload(prompt, _resume, _state), do: String.trim_trailing(prompt) <> "\n"

  @impl true
  def translate_event(data, state) do
    # Convert Claude's JSONL events to LemonCore.RunEvents structs
    # ... implementation ...
  end

  @impl true
  def handle_exit_error(code, state) do
    # Handle non-zero exit
  end

  @impl true
  def handle_stream_end(state) do
    # Handle normal exit without completion event
  end
end
```

## Files

| File | Description |
|------|-------------|
| `application.ex` | Registers the vendor subagents and their resume formats with `lemon_core` at boot |
| `jsonl_runner.ex` | Base GenServer for JSONL subprocess runners |
| `tool_action_helpers.ex` | Shared helpers for translating tool calls to action events |
| `codex_schema.ex` | Codex JSONL event parsing |
| `codex_runner.ex` | Codex CLI implementation |
| `codex_subagent.ex` | High-level API for using Codex as subagent |
| `claude_schema.ex` | Claude JSONL event parsing |
| `claude_runner.ex` | Claude CLI implementation |
| `claude_subagent.ex` | High-level API for using Claude as subagent |
| `kimi_schema.ex` | Kimi JSONL event parsing |
| `kimi_runner.ex` | Kimi CLI implementation |
| `kimi_subagent.ex` | High-level API for using Kimi as subagent |
| `opencode_schema.ex` | Opencode JSONL event parsing |
| `opencode_runner.ex` | Opencode CLI implementation |
| `opencode_subagent.ex` | High-level API for using Opencode as subagent |
| `pi_schema.ex` | Pi Coding Agent JSONL event parsing |
| `pi_runner.ex` | Pi CLI implementation |
| `pi_subagent.ex` | High-level API for using Pi as subagent |

## Testing

```bash
# Run CLI runner tests
mix test apps/lemon_cli_runners/test/lemon_cli_runners/
```

## Design Notes

### Session Locking

When resuming a session, the runner acquires a lock (via ETS) to prevent concurrent execution of the same session. This ensures consistency when multiple callers try to resume the same session.

### Graceful Shutdown

Subprocess termination follows a graceful pattern:
1. Close stdin to signal end of input
2. Wait for process to exit naturally
3. On timeout: SIGTERM → wait 2s → SIGKILL

### Event Translation

Each runner translates tool-specific events to a unified format:
- `StartedEvent` - Session began with resume token
- `ActionEvent` - Action lifecycle with phase tracking
- `CompletedEvent` - Session ended with answer and optional resume

This allows the same UI/progress tracking code to work with any CLI tool.

## Adding a New CLI Runner

Implement the `LemonCliRunners.JsonlRunner` behaviour:

```elixir
defmodule LemonCliRunners.MyEngineRunner do
  use LemonCliRunners.JsonlRunner

  alias LemonCore.RunEvents.EventFactory
  alias LemonCore.ResumeToken

  @engine "myengine"

  @impl true
  def engine, do: @engine

  @impl true
  def init_state(_prompt, _resume, cwd, _opts) do
    %{factory: EventFactory.new(@engine), last_text: nil}
  end

  @impl true
  def build_command(prompt, resume, _state) do
    args = ["--json", "--output-format", "jsonl"]
    args = if resume, do: args ++ ["--resume", resume.value], else: args
    {"myengine", args ++ ["--", prompt]}
  end

  @impl true
  def translate_event(data, state) do
    case data do
      %{"type" => "init", "session_id" => sid} ->
        token = ResumeToken.new(@engine, sid)
        {started, factory} = EventFactory.started(state.factory, token)
        {[started], %{state | factory: factory}, [found_session: token]}

      %{"type" => "done", "result" => result} ->
        {completed, factory} = EventFactory.completed_ok(state.factory, result || "")
        {[completed], %{state | factory: factory}, [done: true]}

      _ ->
        {[], state, []}
    end
  end

  @impl true
  def handle_exit_error(exit_code, state) do
    {event, factory} = EventFactory.completed_error(state.factory, "failed (rc=#{exit_code})")
    {[event], %{state | factory: factory}}
  end

  @impl true
  def handle_stream_end(state) do
    {event, factory} = EventFactory.completed_error(state.factory, "ended without result")
    {[event], %{state | factory: factory}}
  end
end
```
