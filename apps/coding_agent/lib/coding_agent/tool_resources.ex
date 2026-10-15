defmodule CodingAgent.ToolResources do
  @moduledoc """
  Volatile tool lifecycle for a durable native session identity.

  Successful executor turns detach resources before stopping their transient
  Session process; resumed turns bind the same registry keys to their new pid.
  Explicit stop/abort, unexpected owner death, logical history deletion and idle
  expiry still dispose of resources. Registry keys remain the durable owner; a
  different live Session pid cannot take over a resource. The lifecycle listener
  uses existing registry metadata and keeps no second ownership store.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def handoff(id, owner) do
    results =
      Enum.map(resources(id), fn {_supervisor, pid} ->
        call(pid, {:detach_owner, owner})
      end)

    if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :handoff_failed}
  end

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
  def owner_reply(operation, owner, state) do
    result =
      case operation do
        :bind_owner -> bind_owner(state, owner)
        :detach_owner -> detach_owner(state, owner)
      end

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

  defp detach_owner(%{owner_pid: owner} = state, owner) when is_pid(owner) do
    clear_monitor(state.owner_ref)
    {:ok, %{state | owner_pid: nil, owner_ref: nil}}
  end

  defp detach_owner(%{owner_pid: nil} = state, _owner), do: {:ok, state}
  defp detach_owner(_state, _owner), do: {:error, :owner_conflict}

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
      Enum.flat_map(["py", "js"], fn language ->
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
