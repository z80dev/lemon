defmodule CodingAgent.ToolResources do
  @moduledoc """
  Volatile tool lifecycle for a durable native session identity.

  Executor turns keep their Session process alive, retaining resources under the
  same owner. Explicit stop/abort, unexpected owner death, history deletion and
  idle parking dispose of resources. A different live Session pid cannot take
  over a resource. The lifecycle listener uses existing registry metadata and
  keeps no second ownership store.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def stop(id) do
    Enum.each(resources(id), fn {supervisor, pid} ->
      _ = DynamicSupervisor.terminate_child(supervisor, pid)
    end)

    :ok
  end

  def bind(pid, owner), do: call(pid, {:bind_owner, owner})

  defp call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, _ -> {:error, :session_lost}
  end

  @doc false
  def owner_reply(:bind_owner, owner, state) do
    result = bind_owner(state, owner)

    case result do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp bind_owner(%{owner_pid: nil} = state, nil), do: {:ok, state}
  defp bind_owner(_state, nil), do: {:error, :owner_conflict}
  defp bind_owner(%{owner_pid: owner} = state, owner), do: {:ok, state}

  defp bind_owner(state, owner) when is_pid(owner) do
    if is_nil(state.owner_pid) do
      clear_monitor(state.owner_ref)
      {:ok, %{state | owner_pid: owner, owner_ref: Process.monitor(owner)}}
    else
      {:error, :owner_conflict}
    end
  end

  defp clear_monitor(ref) when is_reference(ref), do: Process.demonitor(ref, [:flush])
  defp clear_monitor(_ref), do: :ok

  @impl true
  def init(_opts) do
    :ok = LemonCore.Bus.subscribe("sessions:lifecycle")
    {:ok, nil}
  end

  @impl true
  def handle_info({:session_history_deleted, key, cutoff}, state) do
    Enum.each(registries(), fn {registry, supervisor} ->
      if Process.whereis(registry) do
        pids =
          Registry.select(registry, [
            {{:"$1", :"$2", %{session_key: key, started_at: :"$3"}}, [{:"=<", :"$3", cutoff}],
             [:"$2"]}
          ])

        Enum.each(pids, &DynamicSupervisor.terminate_child(supervisor, &1))
      end
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp registries do
    [
      {CodingAgent.Eval.Registry, CodingAgent.Eval.KernelSupervisor},
      {CodingAgent.Debug.Registry, CodingAgent.Debug.Supervisor},
      {CodingAgent.Tools.Lsp.Registry, CodingAgent.Tools.Lsp.Supervisor}
    ]
  end

  defp resources(id) do
    eval =
      Enum.flat_map(["py", "js", "code_mode"], fn language ->
        lookup(CodingAgent.Eval.Registry, {id, language}, CodingAgent.Eval.KernelSupervisor)
      end)

    debug = lookup(CodingAgent.Debug.Registry, id, CodingAgent.Debug.Supervisor)

    lsp =
      if Process.whereis(CodingAgent.Tools.Lsp.Registry) do
        Enum.map(
          CodingAgent.Tools.Lsp.Client.list(id),
          &{CodingAgent.Tools.Lsp.Supervisor, &1.pid}
        )
      else
        []
      end

    eval ++ debug ++ lsp
  end

  defp lookup(registry, key, supervisor) do
    if Process.whereis(registry) do
      Enum.map(Registry.lookup(registry, key), fn {pid, _} -> {supervisor, pid} end)
    else
      []
    end
  end
end
