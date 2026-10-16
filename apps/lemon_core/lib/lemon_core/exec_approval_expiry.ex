defmodule LemonCore.ExecApprovalExpiry do
  @moduledoc """
  Expires execution approvals immediately when their run or native session ends.

  Store finalization hooks only cast here, avoiding recursive Store calls.
  Native sessions register a process monitor, so forced shutdown is observed even
  when `terminate/2` cannot run. Duplicate notifications use the same exact-record
  transition and cannot overwrite a resolution.

  Pending records carry a private VM incarnation and native owner PID. Startup
  reconciles retained records before this worker accepts calls: owners from an
  earlier runtime cannot still exist. An expiry-worker restart keeps the same
  incarnation, preserves live approvals and restores their session monitors.
  Resolution also checks this evidence, closing the startup/monitor-delivery race.
  Session ownership is retained separately in Store from session initialization,
  even before any approval exists. Worker recovery therefore restores watches for
  unregistered sessions and custom registries without calling session processes.
  """

  use GenServer

  require Logger

  alias LemonCore.{ExecApprovals, ExecApprovalStore}

  @runtime_key {__MODULE__, :runtime_id}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def runtime_id do
    case :persistent_term.get(@runtime_key, nil) do
      nil ->
        # Initialization is serialized by the application callback, before any
        # worker or approval producer starts. Worker restarts never replace it.
        id = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        :persistent_term.put(@runtime_key, id)
        id

      id ->
        id
    end
  end

  @doc "Register a native session's ownership before it can request approval."
  def watch_session(session_id, pid) when is_binary(session_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:watch_session, session_id, pid})
  end

  @doc false
  def session_owner(nil), do: nil
  def session_owner(session_id), do: GenServer.call(__MODULE__, {:session_owner, session_id})
  @doc false
  def ensure_ready do
    GenServer.call(__MODULE__, :ready)
  catch
    :exit, _ -> {:error, :store_unavailable}
  end

  @doc "Store finalize hook; never calls Store synchronously."
  def handle_finalize_run(%{run_id: run_id}), do: run_ended(run_id)
  def handle_finalize_run(_event), do: :ok

  @doc "Expire pending approvals for an ended run."
  def run_ended(run_id) when is_binary(run_id) and run_id != "", do: notify({:run, run_id})
  def run_ended(_run_id), do: :ok

  @doc "Expire pending approvals for an ended native session."
  def session_ended(session_id) when is_binary(session_id) and session_id != "",
    do: notify({:session, session_id})

  def session_ended(_session_id), do: :ok

  defp notify(owner), do: GenServer.cast(__MODULE__, {:expire, owner})

  @impl true
  def init(_opts) do
    with {:ok, _count} <- ExecApprovals.reconcile_runtime(),
         {:ok, owners} <- ExecApprovalStore.fetch_session_owners(),
         {:ok, rows} <- ExecApprovalStore.fetch_pending_list() do
      runtime = runtime_id()

      state =
        Enum.reduce(owners, %{sessions: %{}, monitors: %{}}, fn
          {id, %{runtime_id: ^runtime, pid: pid}}, state when is_pid(pid) ->
            monitor_session(state, id, pid)

          {id, _owner}, state ->
            :ok = ExecApprovalStore.delete_session_owner(id)
            state
        end)

      state =
        Enum.reduce(rows, state, fn {_id, pending}, state ->
          case pending do
            %{session_id: id, owner_session_pid: pid} when is_binary(id) and is_pid(pid) ->
              monitor_session(state, id, pid)

            _ ->
              state
          end
        end)

      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:watch_session, id, pid}, _from, state) do
    case ExecApprovalStore.put_session_owner(id, %{runtime_id: runtime_id(), pid: pid}) do
      :ok -> {:reply, :ok, monitor_session(state, id, pid)}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:ready, _from, state), do: {:reply, :ok, state}

  def handle_call({:session_owner, id}, _from, state) do
    pid = Map.get(state.sessions, id) || registered_session(id)
    state = if is_pid(pid), do: monitor_session(state, id, pid), else: state
    {:reply, pid, state}
  end

  @impl true
  def handle_cast({:expire, owner}, state) do
    expire(owner)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {id, monitors} ->
        expire({:session, id})
        if state.sessions[id] == pid, do: ExecApprovalStore.delete_session_owner(id)

        sessions =
          if state.sessions[id] == pid, do: Map.delete(state.sessions, id), else: state.sessions

        {:noreply, %{state | sessions: sessions, monitors: monitors}}
    end
  end

  defp monitor_session(state, id, pid) do
    if state.sessions[id] == pid do
      state
    else
      ref = Process.monitor(pid)

      %{
        state
        | sessions: Map.put(state.sessions, id, pid),
          monitors: Map.put(state.monitors, ref, id)
      }
    end
  end

  # Runtime lookup never calls a session process; native registries belong to
  # the provider registered through the shared core seam.
  defp registered_session(id) when is_binary(id) do
    LemonCore.AgentRuntime.call(:native_session_owner, [id], nil)
  end

  defp registered_session(_id), do: nil

  defp expire({kind, _id} = owner) do
    case safely_expire(owner) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("exec approval expiry for an ended #{kind} failed: #{inspect(reason)}")
    end
  end

  defp safely_expire(owner) do
    ExecApprovals.expire_owner(owner)
  catch
    _kind, _reason -> {:error, :store_unavailable}
  end
end
