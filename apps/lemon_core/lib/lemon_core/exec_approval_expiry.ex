defmodule LemonCore.ExecApprovalExpiry do
  @moduledoc """
  Expires execution approvals immediately when their run or native session ends.

  Store finalization hooks only cast here, avoiding recursive Store calls.
  Native sessions register a process monitor, so forced shutdown is observed even
  when `terminate/2` cannot run. Duplicate notifications use the same exact-record
  transition and cannot overwrite a resolution.

  Pending records carry a private VM incarnation and native owner PID. Startup
  reconciles retained records (in `handle_continue/2`, before any call is
  served): owners from an earlier runtime cannot still exist. A store that is
  unavailable at startup never stops the worker or `:lemon_core`; reconciliation
  is retried with exponential backoff, and until it succeeds `ensure_ready/0`
  returns `{:error, :store_unavailable}`, so no approval can be resolved. An expiry-worker restart keeps the same
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
  # Shorter than the Store call timeout, so a slow store fails session start
  # with an error instead of the caller's exit.
  @watch_timeout_ms 2_000
  @retry_initial_ms 100
  @retry_max_ms 30_000

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def runtime_id, do: :persistent_term.get(@runtime_key)

  @doc false
  def init_runtime_id do
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

  @doc """
  Register a native session's ownership before it can request approval.

  Returns `{:error, :timeout}` when the worker does not answer within
  `timeout_ms` (default #{@watch_timeout_ms} ms), and the store's error when
  ownership could not be recorded. A late registration of a session that has
  already stopped is cleaned up by its monitor.
  """
  @spec watch_session(binary(), pid(), timeout()) :: :ok | {:error, term()}
  def watch_session(session_id, pid, timeout_ms \\ @watch_timeout_ms)
      when is_binary(session_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:watch_session, session_id, pid}, timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :unavailable}
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
    {:ok, %{sessions: %{}, monitors: %{}, ready: false, retry_ms: @retry_initial_ms},
     {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: reconcile(state)

  defp reconcile(state) do
    case recover(state) do
      {:ok, state} ->
        {:noreply, %{state | ready: true, retry_ms: @retry_initial_ms}}

      {:error, reason} ->
        Logger.warning(
          "exec approval recovery failed (#{inspect(reason)}); retrying in #{state.retry_ms} ms"
        )

        Process.send_after(self(), :reconcile, state.retry_ms)
        {:noreply, %{state | retry_ms: min(state.retry_ms * 2, @retry_max_ms)}}
    end
  end

  defp recover(state) do
    with {:ok, _count} <- safely(&ExecApprovals.reconcile_runtime/0),
         {:ok, owners} <- safely(&ExecApprovalStore.fetch_session_owners/0),
         {:ok, state} <- restore_owners(owners, state),
         {:ok, rows} <- safely(&ExecApprovalStore.fetch_pending_list/0) do
      {:ok, Enum.reduce(rows, state, &restore_pending/2)}
    end
  end

  defp restore_owners(owners, state) do
    runtime = runtime_id()

    Enum.reduce_while(owners, {:ok, state}, fn
      {id, %{runtime_id: ^runtime, pid: pid}}, {:ok, state} when is_pid(pid) ->
        {:cont, {:ok, monitor_session(state, id, pid)}}

      {id, _owner}, {:ok, state} ->
        case ExecApprovalStore.delete_session_owner(id) do
          :ok -> {:cont, {:ok, state}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp restore_pending({_id, %{session_id: id, owner_session_pid: pid}}, state)
       when is_binary(id) and is_pid(pid),
       do: monitor_session(state, id, pid)

  defp restore_pending(_row, state), do: state

  defp safely(fun) do
    fun.()
  catch
    _kind, _reason -> {:error, :store_unavailable}
  end

  @impl true
  def handle_call({:watch_session, id, pid}, _from, state) do
    case ExecApprovalStore.put_session_owner(id, %{runtime_id: runtime_id(), pid: pid}) do
      :ok ->
        {:reply, :ok, monitor_session(state, id, pid)}

      # The owner row may exist; the monitor removes it when the session stops.
      {:error, :outcome_unknown} = error ->
        {:reply, error, monitor_session(state, id, pid)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:ready, _from, %{ready: true} = state), do: {:reply, :ok, state}
  def handle_call(:ready, _from, state), do: {:reply, {:error, :store_unavailable}, state}

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
  def handle_info(:reconcile, state), do: reconcile(state)

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
