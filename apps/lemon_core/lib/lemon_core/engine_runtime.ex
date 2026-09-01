defmodule LemonCore.EngineRuntime do
  @moduledoc """
  Behaviour for execution runtimes used by router run processes.

  This is the whole seam between `lemon_router` and whatever actually runs a
  model: the router builds a `LemonCore.ExecutionCommand`, hands it to the
  configured runtime, and then learns everything else from `LemonCore.Bus`
  events. It has no compile-time reference to the runtime module, which is why
  `lemon_gateway` can hold the scheduler, engine registry, run registry and
  cancellation machinery without the router knowing any of them exist.

  ## Injection

  The runtime is a module name in application config:

      config :lemon_router, :engine_runtime, LemonGateway.Runtime

  That binding (`config/config.exs`) is the reference wiring. A run process
  will also take `:engine_runtime` in its start options, which is how tests
  substitute a stub for a single run; otherwise it falls back to the
  application env at start time. Nothing caches the module beyond the life of
  the run process, so swapping the config affects the next run.

  ## Contract

  Rules the callback signatures cannot express. The router defends itself
  against all of them — every call is wrapped in `rescue`/`catch` and a
  `function_exported?/3` guard — but a runtime that violates them degrades into
  silent no-ops rather than errors, which is much harder to diagnose than a
  clean `{:error, reason}`.

    * **No callback may raise.** A raise from `c:submit_execution/1` is
      converted to a submit failure and retried; a raise from the other three
      is swallowed entirely, so a cancellation that raises simply does not
      cancel.
    * **`c:submit_execution/1` is asynchronous.** `:ok` means *accepted*, not
      *finished*. Progress, output and completion travel back over the bus as
      run events keyed by the command's `run_id`; the return value carries no
      results.
    * **`c:available?/0` is polled before every submit and must be cheap.** It
      is a liveness question ("is the runtime up right now"), not a capacity
      question — see the retry note below before answering `false` for load.
    * **`c:cancel_by_run_id/2` is total and idempotent.** It is called for runs
      that already completed, runs that were never submitted, and runs whose
      process has died. Unknown run id is `:ok`, not an error.
    * **`c:run_pid/1` returns `nil` for anything it does not know about.** The
      router monitors the returned pid, so returning a pid for a run the
      runtime is not really executing produces a spurious `:DOWN`.

  ## Degradation

  Unavailability is a normal state, not a failure. When `c:available?/0`
  returns `false`, when the configured module is not loadable, or when no
  runtime is configured at all, the run process does not drop the run: it
  re-arms `:submit_to_gateway` with exponential backoff and keeps the run
  parked until a runtime shows up. A router-only node therefore boots and
  queues work rather than crashing, and a gateway restart is absorbed.

  The same backoff handles `{:error, reason}` from `c:submit_execution/1`, and
  it never gives up. Return `{:error, reason}` for a rejection the runtime
  expects to outlive (a full queue, a locked engine); a permanently invalid
  command will be retried forever, so reject those by completing the run with
  an error event instead.

  For a runtime that predates `c:available?/0` and does not export it, the
  router falls back to `GenServer.whereis/1` on the module name — implement the
  callback rather than relying on that.

  ## Cancellation reasons

  The router passes an atom describing why it is cancelling; runtimes are free
  to ignore it, but it is worth logging. The ones it emits are
  `:user_requested`, `:run_watchdog_timeout` (the run exceeded its wall clock
  budget) and `:run_process_terminated` (the router-side run process is going
  away, so nothing is left to receive the output).

  ## The reference implementation

  `LemonGateway.Runtime` is the implementation the platform ships.
  `submit_execution/1` fills in the command's conversation key, converts it to
  the gateway-private `LemonGateway.ExecutionRequest`, and hands that to
  `LemonGateway.Scheduler`, which owns slot limits and engine locks.
  `run_pid/1` is a lookup in `LemonGateway.RunRegistry`, and `available?/0` is
  simply whether the scheduler process is alive. The command→request
  conversion is the point of the indirection: `ExecutionRequest` is gateway
  private state and must not leak back into the router.

  ## Implementing a runtime

      defmodule MyRuntime do
        @behaviour LemonCore.EngineRuntime

        @impl true
        def submit_execution(%LemonCore.ExecutionCommand{} = command) do
          MyScheduler.enqueue(command)
        end

        @impl true
        def cancel_by_run_id(run_id, _reason) do
          case run_pid(run_id) do
            pid when is_pid(pid) -> MyScheduler.cancel(pid)
            nil -> :ok
          end
        end

        @impl true
        def run_pid(run_id) do
          case Registry.lookup(MyRuntime.RunRegistry, run_id) do
            [{pid, _}] -> pid
            _ -> nil
          end
        end

        @impl true
        def available?, do: is_pid(GenServer.whereis(MyScheduler))
      end

  The runtime is then responsible for publishing run events on
  `LemonCore.Bus` under the command's `run_id`; without them the router sees a
  run that was accepted and never finished, and its watchdog will eventually
  cancel it.
  """

  alias LemonCore.ExecutionCommand

  @doc """
  Validates that `module` is loadable and implements every callback of this
  behaviour, so the router can call it directly once configured.
  """
  @spec validate(term()) :: :ok | {:error, LemonCore.Contract.error()}
  def validate(module), do: LemonCore.Contract.validate(module, __MODULE__)

  @doc """
  Accept a command for execution.

  `:ok` (or `{:ok, term}`, which the router treats identically) means the
  command has been accepted; anything else is a rejection that will be retried
  with backoff. Results are not returned here — publish them as bus events
  under the command's `run_id`.

  The command arrives fully resolved: session key, conversation key, engine id,
  model and prompt are already decided by the router. A runtime that needs a
  different shape converts it into its own request type rather than pushing
  that type back across the boundary.
  """
  @callback submit_execution(ExecutionCommand.t()) :: :ok | {:error, term()}

  @doc """
  Cancel the run with this id, for this reason.

  Must return `:ok` whatever happens, including for a run that finished long
  ago or was never submitted — the router cancels defensively on watchdog
  timeout and on its own termination, and cannot know whether the runtime still
  has the run.

  Cancellation is best-effort and asynchronous: returning `:ok` means the
  request was delivered, not that the run has stopped.
  """
  @callback cancel_by_run_id(binary(), term()) :: :ok

  @doc """
  The process executing this run, or `nil`.

  Used by the router to decide whether cancelling is worth attempting and to
  monitor the executing process so a runtime crash is noticed promptly. Return
  `nil` for unknown, finished or queued-but-not-started runs; a pid the router
  monitors should be one whose death really means the run is over.
  """
  @callback run_pid(binary()) :: pid() | nil

  @doc """
  Whether the runtime can accept submissions right now.

  Checked before every submit, so keep it to a registry or process lookup.
  `false` parks the run and retries with backoff rather than failing it, which
  makes this the right answer for "the runtime is down or still starting" and
  the wrong one for "the runtime is busy" — backpressure belongs in the
  runtime's own queue, where it can be reported and observed.
  """
  @callback available?() :: boolean()
end
