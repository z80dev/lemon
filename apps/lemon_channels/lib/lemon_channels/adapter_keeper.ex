defmodule LemonChannels.AdapterKeeper do
  @moduledoc """
  Restart boundary for one channel adapter under `LemonChannels.AdapterSupervisor`.

  The keeper starts the adapter's child spec linked to itself and restarts it
  with capped exponential backoff when it exits. A crash-looping adapter
  therefore never exhausts the shared `AdapterSupervisor` restart intensity
  and cannot take the other adapters down with it.
  """

  use GenServer

  require Logger

  @default_base_backoff_ms 1_000
  @default_max_backoff_ms 60_000
  # A run that lasted this long resets the backoff.
  @stable_after_ms 30_000

  @doc false
  def child_spec({adapter_module, adapter_spec, opts}) do
    %{
      id: adapter_spec.id,
      start: {__MODULE__, :start_link, [{adapter_module, adapter_spec, opts}]},
      type: :worker,
      restart: :permanent,
      shutdown: :infinity,
      modules: Enum.uniq([adapter_module, start_module(adapter_spec), __MODULE__])
    }
  end

  @doc false
  def start_link({adapter_module, adapter_spec, opts}) do
    GenServer.start_link(__MODULE__, {adapter_module, adapter_spec, opts})
  end

  @doc "Pid of the adapter process the keeper currently runs, or `nil`."
  @spec adapter_pid(pid()) :: pid() | nil
  def adapter_pid(keeper), do: GenServer.call(keeper, :adapter_pid)

  @impl true
  def init({adapter_module, adapter_spec, opts}) do
    Process.flag(:trap_exit, true)

    state = %{
      module: adapter_module,
      spec: adapter_spec,
      pid: nil,
      started_at: nil,
      attempt: 0,
      base_ms: Keyword.get(opts, :base_backoff_ms, @default_base_backoff_ms),
      max_ms: Keyword.get(opts, :max_backoff_ms, @default_max_backoff_ms)
    }

    # The first start reports its outcome to the caller, exactly like starting
    # the adapter directly under the supervisor.
    case start_adapter(adapter_spec) do
      {:ok, pid} -> {:ok, %{state | pid: pid, started_at: now()}}
      :ignore -> :ignore
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:adapter_pid, _from, state), do: {:reply, state.pid, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    attempt = if now() - state.started_at >= @stable_after_ms, do: 0, else: state.attempt
    record_error(state.module, reason)
    {:noreply, schedule_restart(%{state | pid: nil, attempt: attempt})}
  end

  def handle_info(:restart_adapter, %{pid: nil} = state) do
    case start_adapter(state.spec) do
      {:ok, pid} ->
        {:noreply, %{state | pid: pid, started_at: now(), attempt: state.attempt + 1}}

      :ignore ->
        {:noreply, state}

      {:error, reason} ->
        record_error(state.module, reason)
        {:noreply, schedule_restart(%{state | attempt: state.attempt + 1})}
    end
  end

  # The supervisor shutting the keeper down.
  def handle_info({:EXIT, _parent, reason}, state), do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{pid: pid, spec: spec}) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    case Map.get(spec, :shutdown, default_shutdown(spec)) do
      :infinity ->
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)

      timeout when is_integer(timeout) ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          timeout ->
            Process.exit(pid, :kill)
            receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
        end

      :brutal_kill ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok)
    end
  end

  def terminate(_reason, _state), do: :ok

  defp start_adapter(%{start: {module, function, args}}) do
    case apply(module, function, args) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      :ignore -> :ignore
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp schedule_restart(state) do
    delay =
      min(
        LemonCore.Retry.exponential_backoff(state.base_ms, min(state.attempt, 16)),
        state.max_ms
      )

    Logger.warning(
      "#{inspect(state.module)} adapter exited; restarting in #{delay}ms (attempt #{state.attempt + 1})"
    )

    Process.send_after(self(), :restart_adapter, delay)
    state
  end

  defp record_error(module, reason) do
    LemonChannels.Registry.record_status(module.id(), {:error, adapter_exit_reason(reason)})
  rescue
    _ -> :ok
  end

  # Registry health only renders known reasons; never forward raw exit terms.
  defp adapter_exit_reason(reason) when is_atom(reason), do: reason
  defp adapter_exit_reason(_reason), do: :adapter_exited

  defp default_shutdown(%{type: :supervisor}), do: :infinity
  defp default_shutdown(_spec), do: 5_000

  defp start_module(%{start: {module, _function, _args}}), do: module

  defp now, do: System.monotonic_time(:millisecond)
end
