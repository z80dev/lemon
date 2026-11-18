defmodule LemonCore.SessionActivity do
  @moduledoc """
  Presence for execution the router does not (or no longer) tracks: an idle
  native session's follow-up turn, a direct gateway submission, and a remote
  `coding_agent.run` whose node has not yet proven it stopped (which can
  outlive the router run's terminal summary). Durable unresolved rows written
  before the raw `node.invoke` RPC was removed are honoured the same way.

  `admit/2` registers the calling process for the session and then checks the
  durable lifecycle fence (`LemonCore.LifecycleFenceStore`). A destructive
  lifecycle operation writes its fence before it reads presence, so either the
  operation sees this registration (and refuses as busy) or this check sees its
  fence (and the work is refused). The registration lasts until `release/1` or
  the process exits; `LemonRouter.run_presence/1` reports it as active work.

  Each registration has its own reference as its presence identity, so a
  caller-supplied run id can never merge with, or hide, another session's work.

  Remote work whose stop is not yet proven is kept as durable unresolved
  presence (`retire_unresolved/3`) and reported with unknown status until
  evidence bound to that execution clears it (`resolve_unresolved/2`,
  `resolve_reported_active/3`).

  Every snapshot, registration, release and live-to-unresolved transition is
  serialized through this one process, so a snapshot sees each piece of work
  either live or unresolved, never neither. Owners only monitor this process
  and keep their registrations in their own process dictionary; a replacement
  rebuilds every surviving registration in `init/1`, before it serves anything.
  """

  use GenServer

  alias LemonCore.{LifecycleFenceStore, SessionKey, Store}

  @claims :"$lemon_session_activity"
  @unresolved :session_activity_unresolved

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Register the calling process as executing for `session_key`, unless a
  lifecycle fence holds the session. `attrs` may carry `:kind`, `:run_id` and
  `:profile_id` for presence attribution. Returns the registration reference
  for `release/1`.
  """
  @spec admit(String.t(), map()) ::
          {:ok, reference()}
          | {:error, :session_lifecycle_in_progress | :session_lifecycle_unavailable}
  def admit(session_key, attrs \\ %{}) when is_binary(session_key) and is_map(attrs) do
    ref = make_ref()
    attrs = Map.put(attrs, :started_at_ms, System.system_time(:millisecond))
    put_claim(ref, {session_key, attrs})

    with :ok <- call({:register, ref, self(), session_key, attrs}),
         :ok <- LifecycleFenceStore.check_admission(session_key) do
      {:ok, ref}
    else
      error ->
        release(ref)
        error
    end
  end

  @doc "End the calling process's registration `ref`."
  @spec release(reference()) :: :ok
  def release(ref) when is_reference(ref) do
    drop_claim(ref)
    # A replacement rebuilds registrations from owners' claims, which no longer include `ref`.
    _ = call({:release, ref, self()})
    :ok
  end

  @doc """
  Replace the calling process's live registration `ref` with durable
  unresolved presence for invocation `id`, in one serialized step. `attrs`
  must carry `:node_id` and `:node_pid`. On error the registration stays live.
  """
  @spec retire_unresolved(reference(), String.t(), map()) :: :ok | {:error, term()}
  def retire_unresolved(ref, id, %{node_id: node_id, node_pid: node_pid})
      when is_reference(ref) and is_binary(id) do
    with :ok <- call({:retire, ref, self(), id, %{node_id: node_id, node_pid: node_pid}}) do
      drop_claim(ref)
      :ok
    end
  end

  @doc "Clear `id`'s unresolved presence after `node_id` sent its terminal result."
  @spec resolve_unresolved(String.t(), String.t()) :: :resolved | :not_found
  def resolve_unresolved(id, node_id) when is_binary(id) and is_binary(node_id) do
    case call({:resolve, id, node_id}) do
      :resolved -> :resolved
      _ -> :not_found
    end
  end

  @doc """
  Clear unresolved presence of `node_id`'s earlier connections for every
  invocation absent from `active_ids`, the set the node's worker reports on its
  connection `pid` after its cancellation barrier.
  """
  @spec resolve_reported_active(String.t(), pid(), [String.t()]) :: :ok | {:error, term()}
  def resolve_reported_active(node_id, pid, active_ids)
      when is_binary(node_id) and is_pid(pid) and is_list(active_ids) do
    call({:resolve_reported, node_id, pid, MapSet.new(active_ids)})
  end

  @doc "Registered and unresolved work as presence entries; an unreadable source is never empty."
  @spec entries() :: {:ok, [map()]} | {:error, :unavailable}
  def entries do
    case call(:entries) do
      {:ok, entries} -> {:ok, entries}
      _ -> {:error, :unavailable}
    end
  end

  defp call(request) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _ -> {:error, :session_lifecycle_unavailable}
  end

  defp put_claim(ref, claim),
    do: Process.put(@claims, Map.put(Process.get(@claims, %{}), ref, claim))

  defp drop_claim(ref), do: Process.put(@claims, Map.delete(Process.get(@claims, %{}), ref))

  @impl true
  def init(:ok) do
    state = %{live: %{}, monitors: %{}}

    # Rebuild surviving registrations before this process serves any request.
    state =
      Enum.reduce(Process.list(), state, fn pid, acc ->
        with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
             {@claims, claims} when is_map(claims) <- List.keyfind(dictionary, @claims, 0) do
          Enum.reduce(claims, acc, fn {ref, {session_key, attrs}}, inner ->
            register(inner, ref, pid, session_key, attrs)
          end)
        else
          _ -> acc
        end
      end)

    {:ok, state}
  end

  @impl true
  def handle_call({:register, ref, pid, session_key, attrs}, _from, state) do
    {:reply, :ok, register(state, ref, pid, session_key, attrs)}
  end

  def handle_call({:release, ref, pid}, _from, state) do
    {:reply, :ok, unregister(state, ref, pid)}
  end

  def handle_call({:retire, ref, pid, id, attrs}, _from, state) do
    case Map.fetch(state.live, ref) do
      {:ok, {^pid, session_key, _attrs}} ->
        row =
          Map.merge(attrs, %{
            session_key: session_key,
            recorded_at_ms: System.system_time(:millisecond)
          })

        case durable(fn -> Store.put(Store, @unresolved, id, row, durable: true) end) do
          :ok -> {:reply, :ok, unregister(state, ref, pid)}
          error -> {:reply, error, state}
        end

      _ ->
        {:reply, {:error, :not_registered}, state}
    end
  end

  def handle_call({:resolve, id, node_id}, _from, state) do
    reply =
      with {:ok, %{node_id: ^node_id} = row} <- durable(fn -> Store.fetch(@unresolved, id) end),
           :ok <-
             durable(fn ->
               Store.compare_and_delete(Store, @unresolved, id, row, durable: true)
             end) do
        :resolved
      else
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:resolve_reported, node_id, pid, active}, _from, state) do
    reply =
      case durable(fn -> Store.fetch_all(@unresolved) end) do
        {:ok, rows} ->
          Enum.reduce(rows, :ok, fn
            {id, %{node_id: ^node_id, node_pid: old} = row}, acc when old != pid ->
              if MapSet.member?(active, id) do
                acc
              else
                case durable(fn ->
                       Store.compare_and_delete(Store, @unresolved, id, row, durable: true)
                     end) do
                  :ok -> acc
                  error -> error
                end
              end

            _row, acc ->
              acc
          end)

        error ->
          error
      end

    {:reply, reply, state}
  end

  def handle_call(:entries, _from, state) do
    reply =
      case durable(fn -> Store.fetch_all(@unresolved) end) do
        {:ok, rows} ->
          live =
            Enum.map(state.live, fn {ref, {_pid, session_key, attrs}} ->
              entry({:session_activity, ref}, session_key, :active, attrs)
            end)

          unresolved =
            Enum.map(rows, fn {id, row} ->
              entry({:unresolved, id}, Map.get(row, :session_key), :unknown, %{
                started_at_ms: Map.get(row, :recorded_at_ms)
              })
            end)

          {:ok, live ++ unresolved}

        _ ->
          {:error, :unavailable}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    live = Map.reject(state.live, fn {_ref, {owner, _, _}} -> owner == pid end)
    {:noreply, %{state | live: live, monitors: Map.delete(state.monitors, monitor)}}
  end

  defp durable(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp register(state, ref, pid, session_key, attrs) do
    state = %{state | live: Map.put(state.live, ref, {pid, session_key, attrs})}

    if Enum.any?(state.monitors, fn {_monitor, watched} -> watched == pid end),
      do: state,
      else: %{state | monitors: Map.put(state.monitors, Process.monitor(pid), pid)}
  end

  defp unregister(state, ref, pid) do
    case Map.fetch(state.live, ref) do
      {:ok, {^pid, _, _}} -> %{state | live: Map.delete(state.live, ref)}
      _ -> state
    end
  end

  defp entry(id, session_key, status, attrs) do
    %{
      run_id: id,
      caller_run_id: Map.get(attrs, :run_id),
      session_key: session_key,
      agent_id: session_key && SessionKey.agent_id(session_key),
      profile_id: Map.get(attrs, :profile_id),
      engine: nil,
      started_at_ms: Map.get(attrs, :started_at_ms),
      status: status
    }
  end
end
