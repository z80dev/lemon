defmodule AgentCore.CliRunners.KimiSubagent do
  @moduledoc """
  High-level API for using Kimi (Kimi CLI) as a collaborating subagent.

  This module provides a convenient interface for spawning Kimi CLI sessions
  and interacting with them over time. Unlike one-shot LLM calls, Kimi subagents
  maintain state across multiple prompts when a resume token is provided.
  """

  alias AgentCore.CliRunners.KimiRunner
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, ResumeToken, StartedEvent}

  @typedoc "A Kimi subagent session"
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

  @doc """
  Start a new Kimi subagent session.
  """
  @spec start(keyword()) :: {:ok, session()} | {:error, term()}
  def start(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, 600_000)
    role_prompt = Keyword.get(opts, :role_prompt)

    full_prompt = if role_prompt, do: role_prompt <> "\n\n" <> prompt, else: prompt

    case KimiRunner.start_link(prompt: full_prompt, cwd: cwd, timeout: timeout) do
      {:ok, pid} ->
        stream = KimiRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> nil end)
        {:ok, %{pid: pid, stream: stream, resume_token: nil, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resume an existing Kimi session with a new prompt.
  """
  @spec resume(ResumeToken.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def resume(%ResumeToken{engine: "kimi"} = token, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, 600_000)

    case KimiRunner.start_link(prompt: prompt, resume: token, cwd: cwd, timeout: timeout) do
      {:ok, pid} ->
        stream = KimiRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> token end)

        {:ok,
         %{pid: pid, stream: stream, resume_token: token, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Continue an existing session with a follow-up prompt.
  """
  @spec continue(session(), String.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def continue(session, prompt, opts \\ []) do
    case resume_token(session) do
      nil ->
        {:error, :no_resume_token}

      token ->
        opts = Keyword.put_new(opts, :cwd, session.cwd)
        resume(token, Keyword.merge(opts, prompt: prompt))
    end
  end

  @doc """
  Get the event stream as an enumerable of normalized events.
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
  Collect the final answer from the session.
  """
  @spec collect_answer(session()) :: String.t()
  def collect_answer(session) do
    session
    |> events()
    |> Enum.reduce(nil, fn
      {:completed, answer, _opts}, _acc -> answer
      _, acc -> acc
    end)
  end

  @doc """
  Run a Kimi task synchronously and return the answer.
  """
  @spec run!(keyword()) :: String.t()
  def run!(opts) do
    {:ok, session} = start(opts)
    collect_answer(session)
  end

  @doc """
  Return the resume token for a session if available.
  """
  @spec resume_token(session()) :: ResumeToken.t() | nil
  def resume_token(session) do
    token_agent = session.token_agent

    cond do
      is_pid(token_agent) ->
        Agent.get(token_agent, & &1)

      session.resume_token != nil ->
        session.resume_token

      true ->
        nil
    end
  end

  # ============================================================================
  # Internal event normalization
  # ============================================================================

  defp normalize_event({:cli_event, %StartedEvent{resume: token}}) do
    [{:started, token}]
  end

  defp normalize_event({:cli_event, %ActionEvent{action: action, phase: phase, ok: ok}}) do
    [{:action, action, phase, ok: ok}]
  end

  defp normalize_event(
         {:cli_event, %CompletedEvent{answer: answer, resume: resume, error: error, usage: usage}}
       ) do
    opts =
      []
      |> maybe_put(:resume, resume)
      |> maybe_put(:error, error)
      |> maybe_put(:usage, usage)

    [{:completed, answer, opts}]
  end

  defp normalize_event({:cli_event, other}), do: [{:error, {:unknown_event, other}}]
  defp normalize_event({:error, reason}), do: [{:error, reason}]
  defp normalize_event(_), do: []

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
