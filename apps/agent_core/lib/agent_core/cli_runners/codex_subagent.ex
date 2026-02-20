defmodule AgentCore.CliRunners.CodexSubagent do
  @moduledoc """
  High-level API for using Codex as a collaborating subagent.

  This module provides a convenient interface for spawning Codex CLI sessions
  and interacting with them over time. Unlike one-shot LLM calls, Codex subagents
  maintain state across multiple prompts, enabling iterative collaboration.

  ## Features

  - **Long-lived sessions**: Keep talking to the same Codex session
  - **Session persistence**: Resume sessions after interruptions
  - **Event streaming**: Process events as they happen
  - **Progress tracking**: Monitor commands, tool calls, file changes

  ## Quick Start

      # Start a new session
      {:ok, session} = CodexSubagent.start(
        prompt: "Create a GenServer that manages a counter",
        cwd: "/path/to/project"
      )

      # Process events
      for event <- CodexSubagent.events(session) do
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
      {:ok, session2} = CodexSubagent.continue(session, "Now add decrement functionality")

  ## Session Resume

  Sessions can be resumed after the process terminates:

      # Get the resume token from a completed session
      token = CodexSubagent.resume_token(session)

      # Later, resume the session
      {:ok, session} = CodexSubagent.resume(token, "Continue from where we left off")

  ## Event Types

  Events are normalized into a simple format:

  - `{:started, resume_token}` - Session began
  - `{:action, action, phase, opts}` - Action lifecycle (phase = :started | :updated | :completed)
  - `{:completed, answer, opts}` - Session ended (opts may include :resume, :error, :usage)

  ## Integration with Main Agent

  Use Codex subagents when you need:

  - Autonomous code generation with review
  - Multi-step refactoring tasks
  - Complex implementations that benefit from Codex's reasoning

  Example tool integration:

      def codex_subagent_tool(cwd) do
        %AgentTool{
          name: "codex_subagent",
          description: "Spawn a Codex subagent to handle a complex coding task",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "task" => %{"type" => "string", "description" => "The task to perform"}
            },
            "required" => ["task"]
          },
          execute: fn _id, %{"task" => task}, _signal, on_update ->
            {:ok, session} = CodexSubagent.start(prompt: task, cwd: cwd)

            # Collect answer
            answer = CodexSubagent.collect_answer(session)

            %AgentToolResult{
              content: [%Ai.Types.TextContent{text: answer}],
              details: %{resume_token: CodexSubagent.resume_token(session)}
            }
          end
        }
      end

  """

  alias AgentCore.CliRunners.CodexRunner
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  require Logger

  # ============================================================================
  # Types
  # ============================================================================

  @typedoc "A Codex subagent session"
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
  Start a new Codex subagent session.

  ## Options

  - `:prompt` - The initial prompt/task (required)
  - `:cwd` - Working directory (default: current directory)
  - `:timeout` - Session timeout in ms (default: `:infinity`)
  - `:model` - Optional model override (passed to Codex CLI `--model`)

  ## Returns

  `{:ok, session}` on success, `{:error, reason}` on failure.

  ## Example

      {:ok, session} = CodexSubagent.start(
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
    model = Keyword.get(opts, :model)

    # Prepend role prompt if provided
    full_prompt = if role_prompt, do: role_prompt <> "\n\n" <> prompt, else: prompt

    runner_opts =
      [prompt: full_prompt, cwd: cwd, timeout: timeout]
      |> maybe_put(:model, model)

    case CodexRunner.start_link(runner_opts) do
      {:ok, pid} ->
        stream = CodexRunner.stream(pid)
        # Create an agent to track the resume token across event processing
        {:ok, token_agent} = Agent.start_link(fn -> nil end)
        {:ok, %{pid: pid, stream: stream, resume_token: nil, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume an existing Codex session with a new prompt.

  ## Example

      token = %ResumeToken{engine: "codex", value: "thread_abc123"}

      {:ok, session} = CodexSubagent.resume(token,
        prompt: "Continue implementing the delete method",
        cwd: "/home/user/project"
      )

  """
  @spec resume(ResumeToken.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def resume(%ResumeToken{engine: "codex"} = token, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)
    model = Keyword.get(opts, :model)

    runner_opts =
      [prompt: prompt, resume: token, cwd: cwd, timeout: timeout]
      |> maybe_put(:model, model)

    case CodexRunner.start_link(runner_opts) do
      {:ok, pid} ->
        stream = CodexRunner.stream(pid)
        # Create an agent to track the resume token, initialized with the provided token
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

      {:ok, session1} = CodexSubagent.start(prompt: "Create a module")
      _events = CodexSubagent.events(session1) |> Enum.to_list()

      {:ok, session2} = CodexSubagent.continue(session1, "Add a public function")

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

  ## Example

      for event <- CodexSubagent.events(session) do
        case event do
          {:started, token} ->
            IO.puts("Session started: \#{token.value}")

          {:action, %{kind: :command, title: cmd}, :started, _} ->
            IO.puts("Running: \#{cmd}")

          {:action, %{kind: :command}, :completed, ok: false} ->
            IO.puts("Command failed!")

          {:completed, answer, opts} ->
            if opts[:error] do
              IO.puts("Error: \#{opts[:error]}")
            else
              IO.puts("Answer: \#{answer}")
            end

          _ -> :ok
        end
      end

  """
  @spec events(session()) :: Enumerable.t()
  def events(session) do
    token_agent = session.token_agent

    session.stream
    |> AgentCore.EventStream.events()
    |> Stream.flat_map(&normalize_event/1)
    |> Stream.each(fn event ->
      # Track resume token in agent for later retrieval
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

      {:ok, session} = CodexSubagent.start(prompt: "What is 2+2?", cwd: ".")
      answer = CodexSubagent.collect_answer(session)
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
  Run a Codex task synchronously and return the answer.

  This is a convenience function that starts a session, waits for completion,
  and returns the answer.

  ## Options

  - `:prompt` - The task prompt (required)
  - `:cwd` - Working directory
  - `:timeout` - Timeout in ms
  - `:on_event` - Optional callback `fn event -> :ok end` for progress tracking

  ## Example

      answer = CodexSubagent.run!(
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
    # Internal event, already handled by CompletedEvent
    []
  end

  defp normalize_event(_other) do
    []
  end

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
