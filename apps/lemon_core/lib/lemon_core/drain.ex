defmodule LemonCore.Drain do
  @moduledoc """
  Coordinated drain before a graceful runtime stop.

  A stop request — SIGTERM from a launcher or service manager, the
  `system.stop` control-plane method, or the release launcher's stop RPC — runs
  every registered participant in two phases before `System.stop/1`:

    1. `:ingress` stops taking new external work (channel polling pauses,
       webhook transports answer 503) and hands buffered inbound to the router.
    2. `:work` lets active runs finish, suspends the rest at a tool boundary
       and persists whatever must continue after the restart.

  One deadline bounds the whole drain. A participant that fails or overruns is
  reported and skipped; the VM stops regardless. A second stop request during a
  drain stops immediately.

  Participants implement `c:drain/2` and register at application start with
  `register/3`. `phase/0` is a cheap read for hot paths.

  Timing comes from `config :lemon_core, LemonCore.Drain`: `:grace_ms`
  (default 5000) for active runs to finish on their own and `:timeout_ms`
  (default 20000) for the whole drain. `:signal_trap` (default `false`) makes
  SIGTERM drain before stopping; Lemon's runtime config enables it.
  """

  use GenServer

  require Logger

  @type phase :: :serving | :draining | :stopping
  @type ctx :: %{
          reason: atom(),
          started_at_ms: integer(),
          grace_deadline_ms: integer(),
          deadline_ms: integer()
        }

  @doc """
  Run one drain phase. `ctx` deadlines are `System.monotonic_time(:millisecond)`
  values. Return `:ok` or `{:ok, summary}` with a small JSON-safe summary.
  """
  @callback drain(:ingress | :work, ctx()) :: :ok | {:ok, map()} | {:error, term()}

  @phase_key {__MODULE__, :phase}
  @default_grace_ms 5_000
  @default_timeout_ms 20_000
  @ingress_budget_ms 5_000
  @failsafe_margin_ms 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register `module` as a drain participant. Lower `:order` runs first within a phase."
  @spec register(atom(), module(), keyword()) :: :ok
  def register(name, module, opts \\ []) when is_atom(name) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, name, module, Keyword.get(opts, :order, 50)})
  end

  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name), do: GenServer.call(__MODULE__, {:unregister, name})

  @doc "Current runtime phase; `:serving` when the coordinator is not running."
  @spec phase() :: phase()
  def phase, do: :persistent_term.get(@phase_key, :serving)

  @spec draining?() :: boolean()
  def draining?, do: phase() != :serving

  @doc """
  Drain synchronously and return a report. Only one drain runs per VM; a
  concurrent call returns `{:error, :already_draining}`.

  Options: `:reason`, `:grace_ms`, `:timeout_ms`.
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, :already_draining | :unavailable}
  def run(opts \\ []) do
    ctx = context(opts)

    case begin(ctx) do
      {:ok, participants} ->
        report = %{
          reason: ctx.reason,
          ingress: run_phase(:ingress, participants, ingress_ctx(ctx)),
          work: run_phase(:work, participants, ctx)
        }

        report = Map.put(report, :duration_ms, now() - ctx.started_at_ms)
        GenServer.cast(__MODULE__, {:finished, report})
        Logger.warning("Runtime drain finished: #{inspect(summary(report))}")
        {:ok, report}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Drain, then stop the VM. Returns immediately; the drain runs in its own
  process with a failsafe stop after the configured timeout. A request while a
  drain is already running stops the VM at once.
  """
  @spec request_stop(keyword()) :: :ok
  def request_stop(opts \\ []) do
    opts = Keyword.put_new(opts, :reason, :stop)

    case safe_call(:stop_requested) do
      :first ->
        timeout_ms = Keyword.get(opts, :timeout_ms, config(:timeout_ms, @default_timeout_ms))

        spawn(fn ->
          Process.sleep(timeout_ms + @failsafe_margin_ms)
          Logger.error("Runtime drain overran its deadline; stopping now")
          System.stop(0)
        end)

        spawn(fn ->
          try do
            run(opts)
          after
            System.stop(0)
          end
        end)

        :ok

      _repeat_or_unavailable ->
        System.stop(0)
        :ok
    end
  end

  @doc """
  Make SIGTERM drain before stopping, when
  `config :lemon_core, LemonCore.Drain, signal_trap: true`.

  OTP's `:erl_signal_handler` stops the VM on SIGTERM no matter what other
  handlers (including `System.trap_signal/3`) do, so it is swapped for
  `LemonCore.Drain.SignalHandler`, which keeps its behaviour for every other
  signal.
  """
  @spec maybe_install_signal_trap() :: :ok
  def maybe_install_signal_trap do
    if config(:signal_trap, false) do
      handlers = :gen_event.which_handlers(:erl_signal_server)

      result =
        cond do
          LemonCore.Drain.SignalHandler in handlers ->
            :ok

          :erl_signal_handler in handlers ->
            :gen_event.swap_handler(
              :erl_signal_server,
              {:erl_signal_handler, :swap},
              {LemonCore.Drain.SignalHandler, []}
            )

          true ->
            :gen_event.add_handler(:erl_signal_server, LemonCore.Drain.SignalHandler, [])
        end

      if result != :ok,
        do: Logger.warning("SIGTERM drain handler unavailable: #{inspect(result)}")
    end

    :ok
  end

  @doc false
  def last_report, do: safe_call(:last_report)

  @doc false
  # Returns the coordinator to `:serving` without touching participants; tests only.
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc false
  # `[{name, module, order}]`, so tests can isolate the coordinator.
  def participants, do: GenServer.call(__MODULE__, :participants)

  # ── GenServer ────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :persistent_term.put(@phase_key, :serving)
    {:ok, %{participants: %{}, phase: :serving, stop_requested?: false, last_report: nil}}
  end

  @impl true
  def handle_call({:register, name, module, order}, _from, state) do
    {:reply, :ok, put_in(state.participants[name], %{module: module, order: order})}
  end

  def handle_call({:unregister, name}, _from, state) do
    {:reply, :ok, %{state | participants: Map.delete(state.participants, name)}}
  end

  def handle_call({:begin, _ctx}, _from, %{phase: phase} = state) when phase != :serving do
    {:reply, {:error, :already_draining}, state}
  end

  def handle_call({:begin, ctx}, _from, state) do
    put_phase(:draining)
    Logger.warning("Runtime drain started: reason=#{inspect(ctx.reason)}")

    participants =
      state.participants
      |> Enum.sort_by(fn {name, %{order: order}} -> {order, name} end)
      |> Enum.map(fn {name, %{module: module}} -> {name, module} end)

    {:reply, {:ok, participants}, %{state | phase: :draining}}
  end

  def handle_call(:stop_requested, _from, %{stop_requested?: true} = state),
    do: {:reply, :repeat, state}

  def handle_call(:stop_requested, _from, state),
    do: {:reply, :first, %{state | stop_requested?: true}}

  def handle_call(:last_report, _from, state), do: {:reply, state.last_report, state}

  def handle_call(:reset, _from, state) do
    put_phase(:serving)
    {:reply, :ok, %{state | phase: :serving, stop_requested?: false, last_report: nil}}
  end

  def handle_call(:participants, _from, state) do
    {:reply, Enum.map(state.participants, fn {name, p} -> {name, p.module, p.order} end), state}
  end

  @impl true
  def handle_cast({:finished, report}, state) do
    put_phase(:stopping)
    {:noreply, %{state | phase: :stopping, last_report: report}}
  end

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@phase_key)
    :ok
  end

  # ── Phases ───────────────────────────────────────────────────────────────

  defp begin(ctx) do
    case safe_call({:begin, ctx}) do
      {:ok, participants} -> {:ok, participants}
      {:error, _} = error -> error
      :unavailable -> {:error, :unavailable}
    end
  end

  defp run_phase(phase, participants, ctx) do
    Map.new(participants, fn {name, module} ->
      {name, run_participant(phase, name, module, ctx)}
    end)
  end

  # Unlinked: a crashing or overrunning participant must not take the drain down.
  defp run_participant(phase, name, module, ctx) do
    budget = max(ctx.deadline_ms - now(), 0)
    parent = self()
    ref = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {ref, module.drain(phase, ctx)}) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])

        case result do
          :ok -> %{status: :ok}
          {:ok, summary} when is_map(summary) -> Map.put(summary, :status, :ok)
          {:error, reason} -> failed(phase, name, reason)
          other -> failed(phase, name, {:unexpected, other})
        end

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        failed(phase, name, reason)
    after
      budget + 1_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        failed(phase, name, :timeout)
    end
  end

  defp failed(phase, name, reason) do
    Logger.error(
      "Drain participant #{inspect(name)} failed in #{phase}: #{inspect(reason, limit: 10)}"
    )

    %{status: :failed}
  end

  defp context(opts) do
    started = now()
    grace = Keyword.get(opts, :grace_ms, config(:grace_ms, @default_grace_ms))
    timeout = Keyword.get(opts, :timeout_ms, config(:timeout_ms, @default_timeout_ms))

    %{
      reason: Keyword.get(opts, :reason, :stop),
      started_at_ms: started,
      grace_deadline_ms: started + min(grace, timeout),
      deadline_ms: started + timeout
    }
  end

  defp ingress_ctx(ctx),
    do: %{ctx | deadline_ms: min(ctx.deadline_ms, ctx.started_at_ms + @ingress_budget_ms)}

  defp summary(report), do: Map.take(report, [:reason, :duration_ms, :work])

  defp put_phase(phase), do: :persistent_term.put(@phase_key, phase)

  defp safe_call(message) do
    GenServer.call(__MODULE__, message, 5_000)
  catch
    :exit, _ -> :unavailable
  end

  defp config(key, default) do
    :lemon_core |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
