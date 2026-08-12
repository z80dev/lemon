defmodule LemonCliRunners.OpencodeSubagent do
  @moduledoc """
  High-level API for using OpenCode (opencode CLI) as a collaborating subagent.
  """

  alias LemonCliRunners.OpencodeRunner
  alias LemonCore.RunEvents.{ActionEvent, CompletedEvent, StartedEvent}
  alias LemonCore.ResumeFormat
  alias LemonCore.ResumeToken

  @typedoc "An OpenCode subagent session"
  @type session :: %{
          pid: pid(),
          stream: LemonAgent.EventStream.t(),
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

  @behaviour LemonCore.SubagentRunner

  @impl true
  def id, do: "opencode"

  @impl true
  def describe do
    %{
      summary: "OpenCode CLI",
      caveats: ["ignores `model`: the opencode CLI's own configuration selects it"]
    }
  end

  @doc """
  The OpenCode CLI's resume syntax, registered into `LemonCore.ResumeFormats` at
  boot so the platform can print and parse it without knowing this vendor.

  The pattern is wider than what `render_resume/1` prints: opencode accepts
  `run --session` and `-s` too, and users paste what their shell history holds.
  """
  @impl true
  @spec resume_format() :: ResumeFormat.t()
  def resume_format do
    ResumeFormat.new(id(),
      pattern: ~r/`?opencode(?:\s+run)?\s+(?:--session|-s)\s+(ses_[A-Za-z0-9]+)`?/i,
      render: &__MODULE__.render_resume/1
    )
  end

  @doc false
  @spec render_resume(String.t()) :: String.t()
  def render_resume(value), do: "opencode --session #{value}"

  @doc """
  Resolves the raw `[runtime.cli.opencode]` config section.

  Registered with `LemonCore.Config.CliResolvers` at boot; called with `%{}`
  when the section is unconfigured so the defaults still materialize.
  """
  @impl true
  @spec resolve_cli_settings(map()) :: map()
  def resolve_cli_settings(opencode) when is_map(opencode) do
    %{
      model: normalize_optional_string(opencode["model"])
    }
  end

  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(str) when is_binary(str), do: str
  defp normalize_optional_string(_), do: nil

  @impl true
  @spec start(keyword()) :: {:ok, session()} | {:error, term()}
  def start(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)
    role_prompt = Keyword.get(opts, :role_prompt)

    full_prompt = if role_prompt, do: role_prompt <> "\n\n" <> prompt, else: prompt

    case OpencodeRunner.start_link(prompt: full_prompt, cwd: cwd, timeout: timeout) do
      {:ok, pid} ->
        stream = OpencodeRunner.stream(pid)
        {:ok, token_agent} = Agent.start_link(fn -> nil end)
        {:ok, %{pid: pid, stream: stream, resume_token: nil, token_agent: token_agent, cwd: cwd}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec resume(ResumeToken.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def resume(%ResumeToken{engine: "opencode"} = token, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    timeout = Keyword.get(opts, :timeout, :infinity)

    case OpencodeRunner.start_link(prompt: prompt, resume: token, cwd: cwd, timeout: timeout) do
      {:ok, pid} ->
        stream = OpencodeRunner.stream(pid)
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
        resume(token, Keyword.merge(Keyword.put_new(opts, :cwd, session.cwd), prompt: prompt))
    end
  end

  @impl true
  @spec events(session()) :: Enumerable.t()
  def events(session) do
    token_agent = session.token_agent

    session.stream
    |> LemonAgent.EventStream.events()
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

  @spec collect_answer(session()) :: String.t()
  def collect_answer(session) do
    session
    |> events()
    |> Enum.reduce("", fn
      {:completed, answer, _opts}, _acc -> answer
      _, acc -> acc
    end)
  end

  @spec run!(keyword()) :: String.t()
  def run!(opts) do
    {:ok, session} = start(opts)
    collect_answer(session)
  end

  @impl true
  @spec resume_token(session()) :: ResumeToken.t() | nil
  def resume_token(session) do
    token_agent = session.token_agent

    cond do
      is_pid(token_agent) -> Agent.get(token_agent, & &1)
      session.resume_token != nil -> session.resume_token
      true -> nil
    end
  end

  @doc """
  Stop a running session. Idempotent, and `:ok` for a session already finished.
  """
  @impl true
  @spec cancel(session()) :: :ok
  def cancel(%{pid: pid}) when is_pid(pid), do: OpencodeRunner.cancel(pid)
  def cancel(_session), do: :ok

  defp normalize_event({:cli_event, %StartedEvent{resume: token}}), do: [{:started, token}]

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
