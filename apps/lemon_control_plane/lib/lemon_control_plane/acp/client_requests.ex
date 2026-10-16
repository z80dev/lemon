defmodule LemonControlPlane.ACP.ClientRequests do
  @moduledoc """
  Run-scoped concurrent ACP client calls.

  Terminal exit waits must not block output polling, kill requests, or unrelated
  file operations. The bridge owns callback workers and terminates them with the
  prompt owner; responses are correlated by the core client bridge reference.
  Withdrawing a permission stops only its callback, never the native requester
  which may still be publishing the approval's resolution. Cancellation remains
  effective until the requester exits, including before request registration.
  """
  use GenServer

  def start_link(run_id, owner, exchange) do
    GenServer.start_link(__MODULE__, {run_id, owner, exchange})
  end

  @doc "Withdraw a requester's pending callback without stopping the requester."
  def cancel_request(run_id, requester) when is_binary(run_id) and is_pid(requester) do
    case LemonCore.ACPClientBridge.whereis(run_id) do
      nil -> :ok
      bridge -> GenServer.cast(bridge, {:cancel_request, requester})
    end
  end

  @impl true
  def init({run_id, owner, exchange}) do
    Process.flag(:trap_exit, true)

    case LemonCore.ACPClientBridge.register(run_id) do
      :ok ->
        {:ok,
         %{
           owner: owner,
           owner_ref: Process.monitor(owner),
           exchange: exchange,
           pending: %{},
           cancelled: %{}
         }}

      error ->
        {:stop, error}
    end
  end

  @impl true
  def handle_cast({:cancel_request, requester}, state) do
    cancelled =
      Map.put_new_lazy(state.cancelled, requester, fn -> Process.monitor(requester) end)

    state = %{state | cancelled: cancelled}

    case Enum.find(state.pending, fn {_id, request} -> request.payload.reply_to == requester end) do
      nil -> {:noreply, state}
      {id, request} -> {:noreply, withdraw_request(state, id, request)}
    end
  end

  @impl true
  def handle_info({:acp_client_request, %{reply_to: requester} = payload}, state)
      when is_map_key(state.cancelled, requester) do
    reply(payload, failure())
    {:noreply, state}
  end

  def handle_info({:acp_client_request, payload}, state) do
    bridge = self()
    id = make_ref()
    exchange = state.exchange

    {pid, monitor} =
      spawn_monitor(fn -> send(bridge, {:client_result, id, exchange.(payload)}) end)

    requester = Process.monitor(payload.reply_to)

    pending =
      Map.put(state.pending, id, %{
        pid: pid,
        monitor: monitor,
        requester: requester,
        payload: payload
      })

    {:noreply, %{state | pending: pending}}
  end

  def handle_info({:client_result, id, {response, summary}}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {request, pending} ->
        Process.demonitor(request.monitor, [:flush])
        Process.demonitor(request.requester, [:flush])
        send(state.owner, {:acp_client_summary, summary})
        reply(request.payload, response)
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      if Map.get(state.cancelled, pid) == ref,
        do: %{state | cancelled: Map.delete(state.cancelled, pid)},
        else: state

    case Enum.find(state.pending, fn {_id, request} ->
           request.monitor == ref or request.requester == ref
         end) do
      nil ->
        {:noreply, state}

      {id, request} ->
        {:noreply, withdraw_request(state, id, request)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.pending, fn {_id, request} ->
      reply(request.payload, failure())
      Process.exit(request.pid, :kill)
    end)

    :ok
  end

  defp withdraw_request(state, id, request) do
    Process.demonitor(request.monitor, [:flush])
    Process.demonitor(request.requester, [:flush])
    Process.exit(request.pid, :kill)
    reply(request.payload, failure())
    %{state | pending: Map.delete(state.pending, id)}
  end

  defp reply(%{reply_to: pid, ref: ref}, response) when is_pid(pid),
    do: send(pid, {:acp_client_response, ref, response})

  defp reply(_, _), do: :ok
  defp failure, do: %{"error" => %{"code" => -32_000, "message" => "ACP client request ended"}}
end
