defmodule LemonCore.SubagentRunner do
  @moduledoc """
  Contract for a subagent runner — the thing that executes a delegated subtask.

  A runner is what the agent's `task` tool hands work to. It is started by a
  tool call inside an already-running native agent turn. There is no Gateway
  scheduler in this path: `c:start/1` returns a session, `c:events/1` returns a
  lazy stream, and the caller folds that stream into a tool result while the
  parent turn waits.

  Top-level conversations are not a runner extension point. They always use
  the configured native executor.

  ## The contract

  ### Identity

  `c:id/0` returns the string the `task` tool's `engine` parameter accepts. It
  must match `~r/^[a-z][a-z0-9_-]*$/` and must not be `"default"` or `"help"`.
  The id appears in tool schemas the model reads, so treat it as permanent.

  ### Self-description

  `c:describe/0` returns the prose the tool description is generated from:

      %{summary: "OpenAI Codex CLI", caveats: ["accepts a `model` override"]}

  `:summary` names the executor in one line. `:caveats` are short notes about
  *this* runner's option handling — the things a caller gets wrong otherwise,
  like a runner that ignores `:model` because the vendor CLI picks the model
  itself. Neither may contain a newline: both are rendered as list items.

  This callback exists so the vendor prose in a tool description lives with the
  vendor. Nothing in the agent should have to know that Kimi ignores `:model`.

  ### Running

  `c:start/1` takes a keyword list and returns `{:ok, session}` or
  `{:error, reason}`. The session is opaque to the caller except for `:pid`,
  which callers may monitor to abort a run. Options:

    * `:prompt` — the task, required.
    * `:cwd` — working directory. Default `File.cwd!/0`.
    * `:role_prompt` — prepended to `:prompt` when present.
    * `:model` — model override, honoured where the executor supports one.
    * `:thinking_level` — reasoning-effort override, likewise.
    * `:timeout` — milliseconds, or `:infinity` (the default).

  Unknown options must be ignored, not raise: the caller passes the same option
  set to every runner.

  `c:events/1` returns an `Enumerable` of normalised events:

      {:started, LemonCore.ResumeToken.t()}
      {:action, map(), phase :: :started | :updated | :completed, keyword()}
      {:completed, answer :: String.t(), keyword()}
      {:error, reason :: term()}

  The stream must terminate: a run that dies without a `{:completed, _, _}`
  still has to end the enumeration (emit `{:error, reason}` and stop), because
  the parent tool call is blocked on it.

  ### Optional callbacks

    * `c:cancel/1` — stop a running session. Must be total and idempotent:
      `:ok` for a session that already finished, and for one whose process is
      gone. Runners that cannot be cancelled simply omit it.
    * `c:resume_token/1` — the token a later `resume` would take, or `nil`.
    * `c:resume_format/0` — how this runner spells "resume" on a command line,
      as a `LemonCore.ResumeFormat`. Register it alongside the runner
      (`LemonCore.ResumeFormats.register(MyApp.Subagent.resume_format())`) so
      the platform can read and print resume commands in your syntax. Omitting
      it means the generic `<engine> resume <value>` shape.
    * `c:resolve_cli_settings/1` — how this runner's `[runtime.cli.<id>]`
      config section is resolved: takes the raw string-keyed TOML section
      (`%{}` when unconfigured, so defaults still materialize) and returns the
      settled map runners read from `config.agent.cli`. Register it alongside
      the runner (`LemonCore.Config.CliResolvers.register(id, &resolver/1)`)
      so config resolution needs no vendor table in core. Omitting it means
      the raw section passes through unresolved.
    * `c:default_policy/0` — the tool-policy profile children of this runner get
      by default. The value is an opaque profile name the host interprets
      (`CodingAgent.ToolPolicy` is the reference host). Omitting it means
      `#{inspect(:subagent_restricted)}`, which is the right answer for anything
      running outside this VM.

  ## Minimal implementation

      defmodule MyApp.Subagent do
        @behaviour LemonCore.SubagentRunner

        @impl true
        def id, do: "myrunner"

        @impl true
        def describe, do: %{summary: "My CLI", caveats: ["ignores `model`"]}

        @impl true
        def start(opts) do
          case MyApp.Runner.start_link(prompt: Keyword.fetch!(opts, :prompt)) do
            {:ok, pid} -> {:ok, %{pid: pid, stream: MyApp.Runner.stream(pid)}}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl true
        def events(session), do: MyApp.Runner.normalized_events(session.stream)

        @impl true
        def cancel(%{pid: pid}) when is_pid(pid), do: MyApp.Runner.cancel(pid)
        def cancel(_session), do: :ok
      end

  Register it when your application starts:

      LemonCore.SubagentRegistry.register(MyApp.Subagent)

  `LemonPlatformTest.SubagentRunnerCase` holds an implementation to everything
  above.
  """

  @typedoc """
  Opaque per-run state. Callers only rely on `:pid`, when present, to monitor
  or kill the run.
  """
  @type session :: map()

  @typedoc "Prose a tool description is generated from. See the moduledoc."
  @type description :: %{
          required(:summary) => String.t(),
          optional(:caveats) => [String.t()]
        }

  @typedoc "A `describe/0` result after normalization: `:caveats` always present."
  @type normalized_description :: %{summary: String.t(), caveats: [String.t()]}

  @callback id() :: String.t()
  @callback describe() :: description()
  @callback start(keyword()) :: {:ok, session()} | {:error, term()}
  @callback events(session()) :: Enumerable.t()
  @callback cancel(session()) :: :ok
  @callback resume_token(session()) :: LemonCore.ResumeToken.t() | nil
  @callback resume_format() :: LemonCore.ResumeFormat.t()
  @callback resolve_cli_settings(map()) :: map()
  @callback default_policy() :: atom()

  @optional_callbacks cancel: 1,
                      resume_token: 1,
                      resume_format: 0,
                      resolve_cli_settings: 1,
                      default_policy: 0

  @default_policy :subagent_restricted

  @doc """
  The tool policy profile a runner gets when it does not declare one.
  """
  @spec default_policy() :: atom()
  def default_policy, do: @default_policy

  @doc """
  Validates and fills in a `c:describe/0` result.

  Returns `{:ok, normalized}` with `:caveats` defaulted to `[]`, or
  `{:error, reason}` for anything the tool description could not render.

      iex> LemonCore.SubagentRunner.normalize_description(%{summary: "My CLI"})
      {:ok, %{summary: "My CLI", caveats: []}}

      iex> LemonCore.SubagentRunner.normalize_description(%{summary: "two\\nlines"})
      {:error, {:multiline, :summary}}
  """
  @spec normalize_description(term()) :: {:ok, normalized_description()} | {:error, term()}
  def normalize_description(%{summary: summary} = description) when is_binary(summary) do
    caveats = Map.get(description, :caveats, [])

    cond do
      String.trim(summary) == "" -> {:error, {:blank, :summary}}
      String.contains?(summary, "\n") -> {:error, {:multiline, :summary}}
      not is_list(caveats) -> {:error, {:not_a_list, :caveats}}
      not Enum.all?(caveats, &is_binary/1) -> {:error, {:not_strings, :caveats}}
      Enum.any?(caveats, &String.contains?(&1, "\n")) -> {:error, {:multiline, :caveats}}
      true -> {:ok, %{summary: String.trim(summary), caveats: caveats}}
    end
  end

  def normalize_description(other), do: {:error, {:invalid_description, other}}
end
