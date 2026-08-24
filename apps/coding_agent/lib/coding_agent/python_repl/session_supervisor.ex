defmodule CodingAgent.PythonRepl.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for disposable persistent-Python kernel workers.

  The registry is the sole policy owner: workers are always `:temporary`, so a
  failed interpreter is never restarted behind its generation bookkeeping.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec worker_spec(module(), keyword()) :: Supervisor.child_spec()
  def worker_spec(session_mod, opts) when is_atom(session_mod) and is_list(opts) do
    %{
      id: {session_mod, System.unique_integer([:positive, :monotonic])},
      start: {session_mod, :start_link, [opts]},
      restart: :temporary,
      shutdown: 15_000,
      type: :worker
    }
  end

  @spec start_session(DynamicSupervisor.supervisor(), module(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_session(supervisor \\ __MODULE__, session_mod, opts) do
    DynamicSupervisor.start_child(supervisor, worker_spec(session_mod, opts))
  end

  @spec stop_session(DynamicSupervisor.supervisor(), pid()) :: :ok | {:error, :not_found}
  def stop_session(supervisor \\ __MODULE__, pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(supervisor, pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Physically stops a worker after the registry has already released its logical
  ownership and capacity slot.

  A worker that is no longer known to the dynamic supervisor is first offered
  the Session cleanup path. If it remains alive, the caller-owned monitor is
  used to await a final, untrappable kill.
  """
  @spec stop_session(
          DynamicSupervisor.supervisor(),
          module(),
          pid(),
          reference(),
          pos_integer()
        ) :: :ok | {:error, :stop_timeout}
  def stop_session(supervisor, session_mod, pid, monitor_ref, timeout \\ 15_000)
      when is_atom(session_mod) and is_pid(pid) and is_reference(monitor_ref) and
             is_integer(timeout) and timeout > 0 do
    result =
      try do
        DynamicSupervisor.terminate_child(supervisor, pid)
      catch
        :exit, _reason -> {:error, :supervisor_unavailable}
      end

    case result do
      :ok -> :ok
      {:error, _reason} -> stop_orphan(session_mod, pid, monitor_ref, timeout)
    end
  end

  defp stop_orphan(session_mod, pid, monitor_ref, timeout) do
    if Process.alive?(pid) do
      try do
        _ = session_mod.shutdown(pid, timeout)
      catch
        :exit, _reason -> :ok
      end
    end

    if Process.alive?(pid) do
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
      after
        timeout ->
          if Process.alive?(pid), do: {:error, :stop_timeout}, else: :ok
      end
    else
      :ok
    end
  end

  @spec count_kernels(DynamicSupervisor.supervisor()) :: non_neg_integer()
  def count_kernels(supervisor \\ __MODULE__) do
    supervisor
    |> DynamicSupervisor.count_children()
    |> Map.get(:active, 0)
  end
end
