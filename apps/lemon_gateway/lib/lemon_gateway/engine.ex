defmodule LemonGateway.Engine do
  @moduledoc """
  Behaviour for AI engine plugins.

  An engine wraps an AI backend (CLI tool, API, or native integration) and
  provides a uniform interface for starting runs, streaming output, cancellation,
  session resumption, and mid-run steering.

  ## Implementing an Engine

      defmodule MyEngine do
        @behaviour LemonGateway.Engine

        @impl true
        def id, do: "myengine"

        @impl true
        def start_run(job, opts, sink_pid) do
          # Start the AI run, send events to sink_pid
          {:ok, make_ref(), cancel_context}
        end

        # ... implement remaining callbacks
      end

  ## Event Protocol

  Engines send events to `sink_pid` as `{:engine_event, run_ref, event}` messages
  where event is a plain tagged map built via `Event.started/1`, `Event.action_event/1`,
  or `Event.completed/1`. Streaming text is sent as `{:engine_delta, run_ref, text}`.
  """

  alias LemonCore.ResumeToken
  alias LemonGateway.Types.Job

  @type run_opts :: %{
          optional(:cwd) => String.t(),
          optional(:env) => %{String.t() => String.t()},
          optional(:timeout_ms) => non_neg_integer(),
          optional(:capabilities) => map()
        }

  @callback id() :: String.t()

  @callback format_resume(ResumeToken.t()) :: String.t()
  @callback extract_resume(String.t()) :: ResumeToken.t() | nil
  @callback is_resume_line(String.t()) :: boolean()

  @callback start_run(job :: Job.t(), opts :: run_opts(), sink_pid :: pid()) ::
              {:ok, run_ref :: reference(), cancel_ctx :: term()} | {:error, term()}

  @doc """
  Stop a run, given the `cancel_ctx` that `c:start_run/3` returned.

  Must return `:ok` for **any** term, including a context this engine never
  produced, and must be idempotent — cancelling twice, or cancelling a run that
  already completed, is still `:ok`.

  That is stricter than it looks like it needs to be, and it is deliberate: the
  gateway calls `cancel/1` from supervisors and timeout paths, after crashes and
  across restarts, where the context it holds may be stale or partial. An engine
  that pattern-matches only its own happy-path context turns a routine
  cancellation into a `FunctionClauseError` in the caller. End your clauses with
  a catch-all:

      def cancel(%{task_pid: pid}) when is_pid(pid) do
        Process.exit(pid, :kill)
        :ok
      end

      def cancel(_ctx), do: :ok
  """
  @callback cancel(cancel_ctx :: term()) :: :ok

  @doc """
  Whether this engine accepts mid-run steering.

  Must be pure and stable. Answering `true` obliges the engine to export
  `c:steer/2`; there is no way to declare that in the behaviour itself, since
  `steer/2` has to stay optional for the engines that do not support it, so it
  is checked by `LemonPlatformTest.EngineCase` instead.
  """
  @callback supports_steer?() :: boolean()

  @doc """
  Inject text into a run that is already in flight.

  Optional, and only called when `c:supports_steer?/0` answers `true`. Receives
  the same `cancel_ctx` as `c:cancel/1` and, like it, should report a context it
  cannot use as `{:error, reason}` rather than raising.
  """
  @callback steer(cancel_ctx :: term(), text :: String.t()) :: :ok | {:error, term()}

  @doc """
  Whether this engine accepts mid-run redirects.

  A redirect cancels only the in-flight model request — completed tool results
  are kept — then retries with the injected correction appended. Unlike
  `c:supports_steer?/0` this callback is optional: an engine that does not
  export it is treated as answering `false`, and the gateway degrades a
  redirect to a steer when the engine supports that instead.
  """
  @callback supports_redirect?() :: boolean()

  @doc """
  Redirect a run that is already in flight.

  Optional, and only called when `c:supports_redirect?/0` is exported and
  answers `true`. Receives the same `cancel_ctx` as `c:cancel/1` and, like
  `c:steer/2`, should report a context it cannot use as `{:error, reason}`
  rather than raising.
  """
  @callback redirect(cancel_ctx :: term(), text :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks steer: 2, supports_redirect?: 0, redirect: 2
end
