defmodule LemonGateway.Engine do
  @moduledoc false

  alias LemonGateway.Types.{Job, ResumeToken}
  alias LemonGateway.Event

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
