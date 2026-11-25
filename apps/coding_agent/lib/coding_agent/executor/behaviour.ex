defmodule CodingAgent.Executor.Behaviour do
  @moduledoc """
  Contract between a run owner and its native executor.

  `LemonRouter.RunProcess` owns each run and calls `CodingAgent.Executor`
  directly; the router depends on `coding_agent`, so no configuration resolves
  the executor at runtime. Test executors implement this behaviour and are
  passed to the run owner as its `:executor` option.

  Executors send lifecycle events (`CodingAgent.Executor.Event`) to the sink as
  `{:engine_event, run_ref, event}` and streamed text as
  `{:engine_delta, run_ref, text}`. With `canonical_delta: true`, a local
  executor can forward the existing `LemonCore.Event` delta in place of text.
  A started executor finishes with exactly one `:completed` event.
  Control operations that an executor cannot perform return
  `{:error, :unsupported}`. `cancel/1` only requests cancellation and must not
  block: the run owner keeps its permit and engine-session claim until the
  executor process exits or the 15-second drain deadline passes.

  Run options are local to the owner's node and never serialized: `:cwd`,
  `:run_id` and, for the router's execution permits, `:slot_lender` (a module
  exporting `lend(run_id) :: {:ok, token} | :none` and
  `return(token, :wait | :nowait) :: :ok`).
  """

  alias LemonCore.ExecutionCommand

  @type run_opts :: keyword()
  @type control_context :: term()

  @callback start_run(ExecutionCommand.t(), run_opts(), pid()) ::
              {:ok, reference(), control_context()} | {:error, term()}
  @callback cancel(control_context()) :: :ok
  @callback steer(control_context(), String.t()) :: :ok | {:error, :unsupported | term()}
  @callback redirect(control_context(), String.t()) :: :ok | {:error, :unsupported | term()}
end
