defmodule AgentCore.CliRunners.Types do
  @moduledoc """
  Core type definitions for CLI-based subprocess runners.

  This module provides the unified event types used by all CLI runners
  (Codex, Claude, etc.) to communicate with the rest of the system.

  ## Event Types

  - `ResumeToken` - Session identifier for resuming interrupted sessions
  - `Action` - A discrete action performed by the CLI agent
  - `StartedEvent` - Emitted when a session begins
  - `ActionEvent` - Emitted for action lifecycle (started/updated/completed)
  - `CompletedEvent` - Emitted when a session ends

  ## Design Philosophy

  These types mirror the Takopi project's event model, enabling:
  - Unified event handling across different CLI tools
  - Session persistence and resumption
  - Progress tracking and UI updates
  """

  # ============================================================================
  # Resume Token
  # ============================================================================

  defmodule ResumeToken do
    @moduledoc """
    Session identifier for resuming interrupted CLI sessions.

    Each CLI tool (codex, claude, etc.) provides its own session ID format.
    The ResumeToken captures both the engine and the session value.

    ## Examples

        # Codex session
        %ResumeToken{engine: "codex", value: "thread_abc123"}

        # Claude session
        %ResumeToken{engine: "claude", value: "session_xyz"}

        # Kimi session
        %ResumeToken{engine: "kimi", value: "session_kimi"}

    """
    @type t :: %__MODULE__{
            engine: String.t(),
            value: String.t()
          }

    @enforce_keys [:engine, :value]
    # Resume tokens are persisted into session JSONL files (via CodingAgent.SessionManager).
    # Encode only the explicit fields to avoid accidental leakage if this struct grows.
    @derive {Jason.Encoder, only: [:engine, :value]}
    defstruct [:engine, :value]

    @doc "Create a new resume token"
    def new(engine, value) when is_binary(engine) and is_binary(value) do
      %__MODULE__{engine: engine, value: value}
    end

    @doc "Format token for display to user"
    def format(%__MODULE__{engine: engine, value: value}) do
      case engine do
        "codex" -> "`codex resume #{value}`"
        "claude" -> "`claude --resume #{value}`"
        "kimi" -> "`kimi --session #{value}`"
        "opencode" -> "`opencode --session #{value}`"
        "pi" -> "`pi --session #{quote_token(value)}`"
        "lemon" -> "`lemon resume #{value}`"
        _ -> "`#{engine} resume #{value}`"
      end
    end

    @doc """
    Extract a resume token from text.

    Searches text for resume line patterns from any supported engine.
    Returns the first token found, or nil if none.

    Handles various formats:
    - Plain text: `codex resume abc123`
    - Backticks: `` `claude --resume xyz` ``
    - Code blocks: ```codex resume abc123```

    ## Examples

        iex> ResumeToken.extract_resume("Please run `codex resume thread_abc123`")
        %ResumeToken{engine: "codex", value: "thread_abc123"}

        iex> ResumeToken.extract_resume("Continue with claude --resume session_xyz")
        %ResumeToken{engine: "claude", value: "session_xyz"}

        iex> ResumeToken.extract_resume("Continue with kimi --session session_kimi")
        %ResumeToken{engine: "kimi", value: "session_kimi"}

        iex> ResumeToken.extract_resume("lemon resume abc12345")
        %ResumeToken{engine: "lemon", value: "abc12345"}

        iex> ResumeToken.extract_resume("No resume token here")
        nil

    """
    @spec extract_resume(String.t()) :: t() | nil
    def extract_resume(text) when is_binary(text) do
      # Try each engine's pattern in order
      patterns = [
        # Codex: `codex resume <thread_id>` or codex resume <thread_id>
        {~r/`?codex\s+resume\s+([a-zA-Z0-9_-]+)`?/i, "codex"},
        # Claude: `claude --resume <session_id>` or claude --resume <session_id>
        {~r/`?claude\s+--resume\s+([a-zA-Z0-9_-]+)`?/i, "claude"},
        # Kimi: `kimi --session <session_id>` or kimi --session <session_id>
        {~r/`?kimi\s+--session\s+([a-zA-Z0-9_-]+)`?/i, "kimi"},
        # OpenCode: `opencode --session <ses_...>` (optionally `opencode run --session`)
        {~r/`?opencode(?:\s+run)?\s+(?:--session|-s)\s+(ses_[A-Za-z0-9]+)`?/i, "opencode"},
        # Pi: `pi --session <token>` (token may be quoted)
        {~r/`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?/i, "pi"},
        # Lemon: `lemon resume <session_id>` or lemon resume <session_id>
        {~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i, "lemon"}
      ]

      Enum.find_value(patterns, fn {regex, engine} ->
        case Regex.run(regex, text) do
          [_, value] ->
            value =
              if engine == "pi" do
                strip_quotes(value)
              else
                value
              end

            new(engine, value)

          _ ->
            nil
        end
      end)
    end

    def extract_resume(_), do: nil

    @doc """
    Extract a resume token for a specific engine from text.

    ## Examples

        iex> ResumeToken.extract_resume("codex resume abc", "codex")
        %ResumeToken{engine: "codex", value: "abc"}

        iex> ResumeToken.extract_resume("codex resume abc", "claude")
        nil

    """
    @spec extract_resume(String.t(), String.t()) :: t() | nil
    def extract_resume(text, engine) when is_binary(text) and is_binary(engine) do
      regex = resume_regex(engine)

      case Regex.run(regex, text) do
        [_, value] ->
          value = if engine == "pi", do: strip_quotes(value), else: value
          new(engine, value)

        _ ->
          nil
      end
    end

    @doc """
    Check if a line is exactly a resume line (for truncation preservation).

    This is a strict check - the line should be primarily a resume command,
    not just contain one among other text.

    ## Examples

        iex> ResumeToken.is_resume_line("codex resume thread_abc123")
        true

        iex> ResumeToken.is_resume_line("`claude --resume session_xyz`")
        true

        iex> ResumeToken.is_resume_line("Please run codex resume abc")
        false

        iex> ResumeToken.is_resume_line("Some other text")
        false

    """
    @spec is_resume_line(String.t()) :: boolean()
    def is_resume_line(line) when is_binary(line) do
      line = String.trim(line)

      patterns = [
        # Strict patterns - line should be essentially just the resume command
        # Codex
        ~r/^`?codex\s+resume\s+[a-zA-Z0-9_-]+`?$/i,
        # Claude
        ~r/^`?claude\s+--resume\s+[a-zA-Z0-9_-]+`?$/i,
        # Kimi
        ~r/^`?kimi\s+--session\s+[a-zA-Z0-9_-]+`?$/i,
        # OpenCode
        ~r/^`?opencode(?:\s+run)?\s+(?:--session|-s)\s+ses_[A-Za-z0-9]+`?$/i,
        # Pi (token may be quoted)
        ~r/^`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?$/i,
        # Lemon
        ~r/^`?lemon\s+resume\s+[a-zA-Z0-9_-]+`?$/i
      ]

      Enum.any?(patterns, fn regex -> Regex.match?(regex, line) end)
    end

    def is_resume_line(_), do: false

    @doc """
    Check if a line is a resume line for a specific engine.
    """
    @spec is_resume_line(String.t(), String.t()) :: boolean()
    def is_resume_line(line, engine) when is_binary(line) and is_binary(engine) do
      line = String.trim(line)
      regex = strict_resume_regex(engine)
      Regex.match?(regex, line)
    end

    # Private helpers for engine-specific regex patterns

    defp resume_regex("codex"), do: ~r/`?codex\s+resume\s+([a-zA-Z0-9_-]+)`?/i
    defp resume_regex("claude"), do: ~r/`?claude\s+--resume\s+([a-zA-Z0-9_-]+)`?/i
    defp resume_regex("kimi"), do: ~r/`?kimi\s+--session\s+([a-zA-Z0-9_-]+)`?/i

    defp resume_regex("opencode"),
      do: ~r/`?opencode(?:\s+run)?\s+(?:--session|-s)\s+(ses_[A-Za-z0-9]+)`?/i

    defp resume_regex("pi"),
      do: ~r/`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?/i

    defp resume_regex("lemon"), do: ~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i
    defp resume_regex(engine), do: ~r/`?#{Regex.escape(engine)}\s+resume\s+([a-zA-Z0-9_-]+)`?/i

    defp strict_resume_regex("codex"), do: ~r/^`?codex\s+resume\s+[a-zA-Z0-9_-]+`?$/i
    defp strict_resume_regex("claude"), do: ~r/^`?claude\s+--resume\s+[a-zA-Z0-9_-]+`?$/i
    defp strict_resume_regex("kimi"), do: ~r/^`?kimi\s+--session\s+[a-zA-Z0-9_-]+`?$/i

    defp strict_resume_regex("opencode"),
      do: ~r/^`?opencode(?:\s+run)?\s+(?:--session|-s)\s+ses_[A-Za-z0-9]+`?$/i

    defp strict_resume_regex("pi"),
      do: ~r/^`?pi\s+--session\s+("(?:[^"\\]|\\.)+"|'(?:[^'\\]|\\.)+'|\S+)`?$/i

    defp strict_resume_regex("lemon"), do: ~r/^`?lemon\s+resume\s+[a-zA-Z0-9_-]+`?$/i

    defp strict_resume_regex(engine),
      do: ~r/^`?#{Regex.escape(engine)}\s+resume\s+[a-zA-Z0-9_-]+`?$/i

    defp strip_quotes(value) when is_binary(value) do
      trimmed = String.trim(value)

      if String.length(trimmed) >= 2 do
        first = String.first(trimmed)
        last = String.last(trimmed)

        if first == last and first in ["\"", "'"] do
          String.slice(trimmed, 1, String.length(trimmed) - 2)
        else
          trimmed
        end
      else
        trimmed
      end
    end

    defp quote_token(value) when is_binary(value) do
      needs_quotes = Regex.match?(~r/\s/, value)

      cond do
        not needs_quotes and not String.contains?(value, "\"") ->
          value

        true ->
          escaped = String.replace(value, "\"", "\\\"")
          "\"#{escaped}\""
      end
    end

    defp quote_token(value), do: to_string(value)
  end

  # ============================================================================
  # Action Types
  # ============================================================================

  @typedoc """
  Phase of an action's lifecycle.

  - `:started` - Action has begun
  - `:updated` - Action is in progress with new information
  - `:completed` - Action has finished
  """
  @type action_phase :: :started | :updated | :completed

  @typedoc """
  Kind of action being performed.

  - `:command` - Shell command execution
  - `:tool` - Tool/MCP call
  - `:file_change` - File modification
  - `:web_search` - Web search
  - `:subagent` - Subagent invocation
  - `:note` - Informational note
  - `:turn` - Conversation turn marker
  - `:warning` - Warning message
  - `:telemetry` - Telemetry/metrics
  """
  @type action_kind ::
          :command
          | :tool
          | :file_change
          | :web_search
          | :subagent
          | :note
          | :turn
          | :warning
          | :telemetry

  @typedoc """
  Severity level for action messages.
  """
  @type action_level :: :debug | :info | :warning | :error

  defmodule Action do
    @moduledoc """
    Represents a discrete action performed by a CLI agent.

    Actions have an ID, kind, human-readable title, and optional detail map.
    """
    @type t :: %__MODULE__{
            id: String.t(),
            kind: AgentCore.CliRunners.Types.action_kind(),
            title: String.t(),
            detail: map()
          }

    @enforce_keys [:id, :kind, :title]
    @derive {Jason.Encoder, only: [:id, :kind, :title, :detail]}
    defstruct [:id, :kind, :title, detail: %{}]

    @doc "Create a new action"
    def new(id, kind, title, detail \\ %{}) do
      %__MODULE__{
        id: id,
        kind: kind,
        title: title,
        detail: detail
      }
    end
  end

  # ============================================================================
  # Events
  # ============================================================================

  defmodule StartedEvent do
    @moduledoc """
    Emitted when a CLI session begins.

    Contains the resume token for session identification and optional metadata.
    """
    @type t :: %__MODULE__{
            type: :started,
            engine: String.t(),
            resume: AgentCore.CliRunners.Types.ResumeToken.t(),
            title: String.t() | nil,
            meta: map() | nil
          }

    @enforce_keys [:engine, :resume]
    @derive {Jason.Encoder, only: [:type, :engine, :resume, :title, :meta]}
    defstruct type: :started, engine: nil, resume: nil, title: nil, meta: nil

    @doc "Create a new started event"
    def new(engine, resume, opts \\ []) do
      %__MODULE__{
        engine: engine,
        resume: resume,
        title: Keyword.get(opts, :title),
        meta: Keyword.get(opts, :meta)
      }
    end
  end

  defmodule ActionEvent do
    @moduledoc """
    Emitted for action lifecycle events (started/updated/completed).

    Tracks individual actions as they progress through their lifecycle.
    """
    @type t :: %__MODULE__{
            type: :action,
            engine: String.t(),
            action: AgentCore.CliRunners.Types.Action.t(),
            phase: AgentCore.CliRunners.Types.action_phase(),
            ok: boolean() | nil,
            message: String.t() | nil,
            level: AgentCore.CliRunners.Types.action_level() | nil
          }

    @enforce_keys [:engine, :action, :phase]
    @derive {Jason.Encoder, only: [:type, :engine, :action, :phase, :ok, :message, :level]}
    defstruct type: :action,
              engine: nil,
              action: nil,
              phase: nil,
              ok: nil,
              message: nil,
              level: nil

    @doc "Create a new action event"
    def new(engine, action, phase, opts \\ []) do
      %__MODULE__{
        engine: engine,
        action: action,
        phase: phase,
        ok: Keyword.get(opts, :ok),
        message: Keyword.get(opts, :message),
        level: Keyword.get(opts, :level)
      }
    end
  end

  defmodule CompletedEvent do
    @moduledoc """
    Emitted when a CLI session ends.

    Contains the final answer, success status, and optional resume token
    for future continuation.
    """
    @type t :: %__MODULE__{
            type: :completed,
            engine: String.t(),
            ok: boolean(),
            answer: String.t(),
            resume: AgentCore.CliRunners.Types.ResumeToken.t() | nil,
            error: String.t() | nil,
            usage: map() | nil
          }

    @enforce_keys [:engine, :ok, :answer]
    @derive {Jason.Encoder, only: [:type, :engine, :ok, :answer, :resume, :error, :usage]}
    defstruct type: :completed,
              engine: nil,
              ok: nil,
              answer: nil,
              resume: nil,
              error: nil,
              usage: nil

    @doc "Create a successful completion event"
    def ok(engine, answer, opts \\ []) do
      %__MODULE__{
        engine: engine,
        ok: true,
        answer: answer,
        resume: Keyword.get(opts, :resume),
        usage: Keyword.get(opts, :usage)
      }
    end

    @doc "Create a failed completion event"
    def error(engine, error, opts \\ []) do
      %__MODULE__{
        engine: engine,
        ok: false,
        answer: Keyword.get(opts, :answer, ""),
        resume: Keyword.get(opts, :resume),
        error: error,
        usage: Keyword.get(opts, :usage)
      }
    end
  end

  # ============================================================================
  # Event Type Union
  # ============================================================================

  @typedoc """
  Union of all CLI runner event types.
  """
  @type cli_event ::
          StartedEvent.t()
          | ActionEvent.t()
          | CompletedEvent.t()

  # ============================================================================
  # Event Factory
  # ============================================================================

  defmodule EventFactory do
    @moduledoc """
    Factory for creating CLI runner events with consistent engine identification.

    The factory caches the resume token after the first `started/2` call,
    allowing subsequent completion events to reference it automatically.

    ## Example

        factory = EventFactory.new("codex")

        # Create started event - caches the resume token
        started = EventFactory.started(factory, token, title: "Codex Session")

        # Create action events
        action = EventFactory.action_started(factory, "cmd_1", :command, "ls -la")

        # Create completed event - uses cached token
        completed = EventFactory.completed_ok(factory, "Done!")

    """
    alias AgentCore.CliRunners.Types.{
      Action,
      ActionEvent,
      CompletedEvent,
      ResumeToken,
      StartedEvent
    }

    @type t :: %__MODULE__{
            engine: String.t(),
            resume: ResumeToken.t() | nil,
            note_seq: non_neg_integer()
          }

    @derive {Jason.Encoder, only: [:engine, :resume, :note_seq]}
    defstruct engine: nil, resume: nil, note_seq: 0

    @doc "Create a new event factory for an engine"
    def new(engine) when is_binary(engine) do
      %__MODULE__{engine: engine}
    end

    @doc "Create a started event and cache the resume token"
    def started(%__MODULE__{} = factory, %ResumeToken{} = token, opts \\ []) do
      if token.engine != factory.engine do
        raise "Resume token engine mismatch: expected #{factory.engine}, got #{token.engine}"
      end

      event = StartedEvent.new(factory.engine, token, opts)
      factory = %{factory | resume: token}
      {event, factory}
    end

    @doc "Create an action event"
    def action(%__MODULE__{} = factory, opts) do
      action_id = Keyword.fetch!(opts, :action_id)
      kind = Keyword.fetch!(opts, :kind)
      title = Keyword.fetch!(opts, :title)
      phase = Keyword.fetch!(opts, :phase)
      detail = Keyword.get(opts, :detail, %{})

      action = Action.new(action_id, kind, title, detail)

      event =
        ActionEvent.new(factory.engine, action, phase,
          ok: Keyword.get(opts, :ok),
          message: Keyword.get(opts, :message),
          level: Keyword.get(opts, :level)
        )

      {event, factory}
    end

    @doc "Create an action started event"
    def action_started(%__MODULE__{} = factory, action_id, kind, title, opts \\ []) do
      action(
        factory,
        Keyword.merge(opts, action_id: action_id, kind: kind, title: title, phase: :started)
      )
    end

    @doc "Create an action updated event"
    def action_updated(%__MODULE__{} = factory, action_id, kind, title, opts \\ []) do
      action(
        factory,
        Keyword.merge(opts, action_id: action_id, kind: kind, title: title, phase: :updated)
      )
    end

    @doc "Create an action completed event"
    def action_completed(%__MODULE__{} = factory, action_id, kind, title, ok, opts \\ []) do
      action(
        factory,
        Keyword.merge(opts,
          action_id: action_id,
          kind: kind,
          title: title,
          phase: :completed,
          ok: ok
        )
      )
    end

    @doc "Create a note event with auto-incrementing ID"
    def note(%__MODULE__{} = factory, message, opts \\ []) do
      note_id = "note_#{factory.note_seq}"
      factory = %{factory | note_seq: factory.note_seq + 1}
      ok = Keyword.get(opts, :ok, false)
      level = Keyword.get(opts, :level, if(ok, do: :info, else: :warning))

      action_completed(factory, note_id, :warning, message, ok, level: level)
    end

    @doc "Create a successful completion event"
    def completed_ok(%__MODULE__{} = factory, answer, opts \\ []) do
      resume = Keyword.get(opts, :resume, factory.resume)
      usage = Keyword.get(opts, :usage)

      event = CompletedEvent.ok(factory.engine, answer, resume: resume, usage: usage)
      {event, factory}
    end

    @doc "Create a failed completion event"
    def completed_error(%__MODULE__{} = factory, error, opts \\ []) do
      resume = Keyword.get(opts, :resume, factory.resume)
      answer = Keyword.get(opts, :answer, "")
      usage = Keyword.get(opts, :usage)

      event =
        CompletedEvent.error(factory.engine, error, resume: resume, answer: answer, usage: usage)

      {event, factory}
    end
  end
end
