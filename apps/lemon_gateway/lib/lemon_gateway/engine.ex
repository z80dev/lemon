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

  alias LemonGateway.Types.{Job, ResumeToken}

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

  @callback cancel(cancel_ctx :: term()) :: :ok

  @callback supports_steer?() :: boolean()
  @callback steer(cancel_ctx :: term(), text :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks steer: 2
end
