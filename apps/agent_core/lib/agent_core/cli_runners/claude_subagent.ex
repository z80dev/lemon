defmodule AgentCore.CliRunners.ClaudeSubagent do
  @moduledoc """
  High-level API for using Claude (Claude Code CLI) as a collaborating subagent.

  This module provides a convenient interface for spawning Claude CLI sessions
  and interacting with them over time. Unlike one-shot LLM calls, Claude subagents
  maintain state across multiple prompts, enabling iterative collaboration.

  ## Features

  - **Long-lived sessions**: Keep talking to the same Claude session
  - **Session persistence**: Resume sessions after interruptions
  - **Event streaming**: Process events as they happen
  - **Progress tracking**: Monitor tools, commands, file changes

  ## Quick Start

      # Start a new session
      {:ok, session} = ClaudeSubagent.start(
        prompt: "Create a GenServer that manages a counter",
        cwd: "/path/to/project"
      )

      # Process events
      for event <- ClaudeSubagent.events(session) do
        case event do
          {:started, resume_token} ->
            IO.puts("Session: \#{resume_token.value}")

          {:action, action, :completed, ok: true} ->
            IO.puts("Completed: \#{action.title}")

          {:completed, answer, _opts} ->
            IO.puts("Done: \#{answer}")
        end
      end

      # Send a follow-up prompt to continue the conversation
      {:ok, session2} = ClaudeSubagent.continue(session, "Now add decrement functionality")

  ## Session Resume

  Sessions can be resumed after the process terminates:

      # Get the resume token from a completed session
      token = ClaudeSubagent.resume_token(session)

      # Later, resume the session
      {:ok, session} = ClaudeSubagent.resume(token, "Continue from where we left off")

  ## Event Types

  Events are normalized into a simple format:

  - `{:started, resume_token}` - Session began
  - `{:action, action, phase, opts}` - Action lifecycle (phase = :started | :updated | :completed)
  - `{:completed, answer, opts}` - Session ended (opts may include :resume, :error, :usage)

  """

  alias AgentCore.CliRunners.ClaudeRunner
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, StartedEvent}
  alias LemonCore.ResumeToken

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "A Claude subagent session"
  @type session :: %{
          pid: pid(),
          stream: AgentCore.EventStream.t(),
          resume_token: ResumeToken.t() | nil,
          token_agent: pid() | nil,
          cwd: String.t()
        }

  @typedoc "Normalized event from the subagent"
  @type subagent_event ::
          {:started, ResumeToken.t()}
          | {:action, action :: map(), phase :: atom(), opts :: keyword()}
          | {:completed, answer :: String.t(), opts :: keyword()}
          | {:error, reason :: term()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start a new Claude subagent session.

  ## Options

  - `:prompt` - The initial prompt/task (required)
  - `:cwd` - Working directory (default: current directory)
  - `:timeout` - Session timeout in ms (default: `:infinity`)

  ## Returns

  `{:ok, session}` on success, `{:error, reason}` on failure.

  ## Example

      {:ok, session} = ClaudeSubagent.start(
        prompt: "Implement a binary search tree",
        cwd: "/home/user/project"
      )

  """
  @spec start(keyword()) :: {:ok, session()} | {:error, term()}
  def start(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)
    role_prompt = Keyword.get(opts, :role_prompt)

    # Prepend role prompt if provided
    full_prompt = if role_prompt, do: role_prompt <> "\n\n" <> prompt, else: prompt

    case ClaudeRunner.start_link(prompt: full_prompt, cwd: cwd, timeout: timeout) do
      {:ok, pid} ->
        stream = ClaudeRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> nil end)
        {:ok, %{pid: pid, stream: stream, resume_token: nil, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume an existing Claude session with a new prompt.

  ## Example

      token = %ResumeToken{engine: "claude", value: "session_abc123"}

      {:ok, session} = ClaudeSubagent.resume(token,
        prompt: "Continue implementing the delete method",
        cwd: "/home/user/project"
      )

  """
  @spec resume(ResumeToken.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def resume(%ResumeToken{engine: "claude"} = token, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)

    case ClaudeRunner.start_link(prompt: prompt, resume: token, cwd: cwd, timeout: timeout) do
      {:ok, pid} ->
        stream = ClaudeRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> token end)

        {:ok,
         %{pid: pid, stream: stream, resume_token: token, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Continue an existing session with a follow-up prompt.

  This is a convenience wrapper around `resume/2` that extracts the
  resume token from a completed session.

  ## Example

      {:ok, session1} = ClaudeSubagent.start(prompt: "Create a module")
      _events = ClaudeSubagent.events(session1) |> Enum.to_list()

      {:ok, session2} = ClaudeSubagent.continue(session1, "Add a public function")

  """
  @spec continue(session(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def continue(session, prompt, opts \\ []) do
    case resume_token(session) do
      nil ->
        {:error, :no_resume_token}

      token ->
        # Preserve cwd from original session unless explicitly overridden
        opts = Keyword.put_new(opts, :cwd, session.cwd)
        resume(token, Keyword.merge(opts, prompt: prompt))
    end
  end

  @doc """
  Get the event stream as an enumerable of normalized events.

  Events are transformed from internal CLI runner events to a simpler format.
  The stream completes when the session ends.

  ## Event Format

  - `{:started, resume_token}` - Session began, token can be used for resume
  - `{:action, action, phase, opts}` - Action lifecycle event
    - `action` is a map with `:id`, `:kind`, `:title`, `:detail`
    - `phase` is `:started`, `:updated`, or `:completed`
    - `opts` may include `ok: boolean()` for completed phase
  - `{:completed, answer, opts}` - Session ended
    - `opts` may include `:resume`, `:error`, `:usage`
  - `{:error, reason}` - Error occurred

  """
  @spec events(session()) :: Enumerable.t()
  def events(session) do
    token_agent = session.token_agent

    session.stream
    |> AgentCore.EventStream.events()
    |> Stream.flat_map(&normalize_event/1)
    |> Stream.each(fn event ->
      case event do
        {:started, token} ->
          if token_agent, do: Agent.update(token_agent, fn _ -> token end)

        {:completed, _answer, opts} ->
          if token_agent && opts[:resume] do
            Agent.update(token_agent, fn _ -> opts[:resume] end)
          end

        _ ->
          :ok
      end
    end)
  end

  @doc """
  Collect all events and return the final answer.

  This is a convenience function that processes all events and returns
  the final answer string. Useful when you don't need to track progress.

  ## Example

      {:ok, session} = ClaudeSubagent.start(prompt: "What is 2+2?", cwd: ".")
      answer = ClaudeSubagent.collect_answer(session)
      IO.puts(answer)  # "4" or similar

  """
  @spec collect_answer(session()) :: String.t()
  def collect_answer(session) do
    session
    |> events()
    |> Enum.reduce("", fn
      {:completed, answer, _opts}, _acc -> answer
      _, acc -> acc
    end)
  end

  @doc """
  Get the resume token from a session.

  The token is populated after the session starts and can be used
  to resume the session later. The token is updated as events are
  processed, so call this after processing events.
  """
  @spec resume_token(session()) :: ResumeToken.t() | nil
  def resume_token(session) do
    case session.token_agent do
      nil ->
        session.resume_token

      agent ->
        try do
          Agent.get(agent, & &1)
        catch
          :exit, _ -> session.resume_token
        end
    end
  end

  @doc """
  Run a Claude task synchronously and return the answer.

  This is a convenience function that starts a session, waits for completion,
  and returns the answer.

  ## Options

  - `:prompt` - The task prompt (required)
  - `:cwd` - Working directory
  - `:timeout` - Timeout in ms
  - `:on_event` - Optional callback `fn event -> :ok end` for progress tracking

  ## Example

      answer = ClaudeSubagent.run!(
        prompt: "Explain what this code does: ...",
        cwd: "/path/to/project",
        on_event: fn event -> IO.inspect(event) end
      )

  """
  @spec run!(keyword()) :: String.t()
  def run!(opts) do
    on_event = Keyword.get(opts, :on_event)
    {:ok, session} = start(opts)

    session
    |> events()
    |> Enum.reduce("", fn event, acc ->
      if on_event, do: on_event.(event)

      case event do
        {:completed, answer, _opts} -> answer
        _ -> acc
      end
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp normalize_event({:cli_event, %StartedEvent{resume: token}}) do
    [{:started, token}]
  end

  defp normalize_event({:cli_event, %ActionEvent{action: action, phase: phase, ok: ok}}) do
    action_map = %{
      id: action.id,
      kind: action.kind,
      title: action.title,
      detail: action.detail
    }

    opts = if ok != nil, do: [ok: ok], else: []
    [{:action, action_map, phase, opts}]
  end

  defp normalize_event(
         {:cli_event,
          %CompletedEvent{ok: ok, answer: answer, resume: resume, error: error, usage: usage}}
       ) do
    opts =
      [ok: ok]
      |> maybe_add(:resume, resume)
      |> maybe_add(:error, error)
      |> maybe_add(:usage, usage)

    [{:completed, answer, opts}]
  end

  defp normalize_event({:error, reason, _partial}) do
    [{:error, reason}]
  end

  defp normalize_event({:canceled, reason}) do
    [{:error, {:canceled, reason}}]
  end

  defp normalize_event({:agent_end, _}) do
    []
  end

  defp normalize_event(_other) do
    []
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)
end
