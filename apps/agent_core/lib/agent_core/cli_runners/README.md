# CLI Runners

This module provides infrastructure for wrapping CLI-based AI tools (Codex, Claude, etc.) as subagents. Inspired by the [Takopi](https://github.com/your-org/takopi) project's reliable subprocess management patterns.

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
│                         Types                                    │
│    (ResumeToken, Action, StartedEvent, ActionEvent, etc.)       │
└─────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Basic Usage

```elixir
alias AgentCore.CliRunners.CodexSubagent

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
  alias AgentCore.CliRunners.CodexSubagent
  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

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
alias AgentCore.CliRunners.CodexRunner
alias AgentCore.CliRunners.Types.ResumeToken

# Start runner
{:ok, pid} = CodexRunner.start_link(
  prompt: "Hello",
  cwd: "/path/to/project",
  timeout: 300_000
)

# Get event stream
stream = CodexRunner.stream(pid)

# Process raw events
for event <- AgentCore.EventStream.events(stream) do
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
defmodule AgentCore.CliRunners.ClaudeRunner do
  use AgentCore.CliRunners.JsonlRunner

  alias AgentCore.CliRunners.Types.{EventFactory, ResumeToken}

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

    {"claude", args ++ [prompt]}
  end

  @impl true
  def stdin_payload(_prompt, _resume, _state), do: nil  # Claude takes prompt as arg

  @impl true
  def translate_event(data, state) do
    # Convert Claude's JSONL events to CLI runner events
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
| `types.ex` | Core types: ResumeToken, Action, events, EventFactory |
| `codex_schema.ex` | Codex JSONL event parsing |
| `jsonl_runner.ex` | Base GenServer for JSONL subprocess runners |
| `codex_runner.ex` | Codex CLI implementation |
| `codex_subagent.ex` | High-level API for using Codex as subagent |

## Testing

```bash
# Run CLI runner tests
mix test apps/agent_core/test/agent_core/cli_runners/
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
