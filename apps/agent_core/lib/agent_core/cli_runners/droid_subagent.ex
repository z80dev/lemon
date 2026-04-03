defmodule AgentCore.CliRunners.DroidSubagent do
  @moduledoc """
  High-level API for using Factory Droid as a collaborating subagent.
  """

  alias AgentCore.CliRunners.DroidRunner
  alias AgentCore.CliRunners.Types.{ActionEvent, CompletedEvent, StartedEvent}
  alias LemonCore.ResumeToken

  @type session :: %{
          pid: pid(),
          stream: AgentCore.EventStream.t(),
          resume_token: ResumeToken.t() | nil,
          token_agent: pid() | nil,
          cwd: String.t()
        }

  @type subagent_event ::
          {:started, ResumeToken.t()}
          | {:action, action :: map(), phase :: atom(), opts :: keyword()}
          | {:completed, answer :: String.t(), opts :: keyword()}
          | {:error, reason :: term()}

  @spec start(keyword()) :: {:ok, session()} | {:error, term()}
  def start(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)
    role_prompt = Keyword.get(opts, :role_prompt)
    model = Keyword.get(opts, :model)
    reasoning_effort = Keyword.get(opts, :reasoning_effort) || Keyword.get(opts, :thinking_level)
    enabled_tools = Keyword.get(opts, :enabled_tools)
    disabled_tools = Keyword.get(opts, :disabled_tools)
    use_spec = Keyword.get(opts, :use_spec)
    spec_model = Keyword.get(opts, :spec_model)

    full_prompt = if role_prompt, do: role_prompt <> "\n\n" <> prompt, else: prompt

    runner_opts =
      [prompt: full_prompt, cwd: cwd, timeout: timeout]
      |> maybe_put(:model, model)
      |> maybe_put(:reasoning_effort, reasoning_effort)
      |> maybe_put(:enabled_tools, enabled_tools)
      |> maybe_put(:disabled_tools, disabled_tools)
      |> maybe_put(:use_spec, use_spec)
      |> maybe_put(:spec_model, spec_model)

    case DroidRunner.start_link(runner_opts) do
      {:ok, pid} ->
        stream = DroidRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> nil end)
        {:ok, %{pid: pid, stream: stream, resume_token: nil, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resume(ResumeToken.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def resume(%ResumeToken{engine: "droid"} = token, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)
    model = Keyword.get(opts, :model)
    reasoning_effort = Keyword.get(opts, :reasoning_effort) || Keyword.get(opts, :thinking_level)
    enabled_tools = Keyword.get(opts, :enabled_tools)
    disabled_tools = Keyword.get(opts, :disabled_tools)
    use_spec = Keyword.get(opts, :use_spec)
    spec_model = Keyword.get(opts, :spec_model)

    runner_opts =
      [prompt: prompt, resume: token, cwd: cwd, timeout: timeout]
      |> maybe_put(:model, model)
      |> maybe_put(:reasoning_effort, reasoning_effort)
      |> maybe_put(:enabled_tools, enabled_tools)
      |> maybe_put(:disabled_tools, disabled_tools)
      |> maybe_put(:use_spec, use_spec)
      |> maybe_put(:spec_model, spec_model)

    case DroidRunner.start_link(runner_opts) do
      {:ok, pid} ->
        stream = DroidRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> token end)

        {:ok,
         %{pid: pid, stream: stream, resume_token: token, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

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
          if token_agent && opts[:resume],
            do: Agent.update(token_agent, fn _ -> opts[:resume] end)

        _ ->
          :ok
      end
    end)
  end

  @spec collect_answer(session()) :: String.t()
  def collect_answer(session) do
    session
    |> events()
    |> Enum.reduce("", fn
      {:completed, answer, _opts}, _acc -> answer
      _, acc -> acc
    end)
  end

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

  defp normalize_event({:cli_event, %StartedEvent{resume: token}}), do: [{:started, token}]

  defp normalize_event({:cli_event, %ActionEvent{action: action, phase: phase, ok: ok}}) do
    action_map = %{id: action.id, kind: action.kind, title: action.title, detail: action.detail}
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

  defp normalize_event({:error, reason, _partial}), do: [{:error, reason}]
  defp normalize_event({:canceled, reason}), do: [{:error, {:canceled, reason}}]
  defp normalize_event({:agent_end, _}), do: []
  defp normalize_event(_other), do: []

  defp maybe_add(opts, _key, nil), do: opts
  defp maybe_add(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
