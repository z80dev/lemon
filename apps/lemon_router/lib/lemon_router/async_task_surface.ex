defmodule LemonRouter.AsyncTaskSurface do
  @moduledoc """
  Router-owned lifecycle surface for an async task.

  This is a migration scaffold for the async task surface redesign. It only owns
  per-task lifecycle state and discoverability; it does not replace the existing
  projected-child tool-status path yet.
  """

  use GenServer, restart: :temporary

  alias LemonCore.Clock

  @statuses [:pending_root, :bound, :live, :terminal_grace, :reaped]
  @registry LemonRouter.AsyncTaskSurfaceRegistry
  @snapshot_keys [
    :surface_id,
    :status,
    :metadata,
    :result,
    :error,
    :inserted_at_ms,
    :updated_at_ms,
    :terminal_at_ms
  ]

  @type status :: :pending_root | :bound | :live | :terminal_grace | :reaped

  @type snapshot :: %{
          surface_id: binary(),
          status: status(),
          metadata: map(),
          result: term(),
          error: term(),
          inserted_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          terminal_at_ms: non_neg_integer() | nil
        }

  @allowed_transitions %{
    pending_root: MapSet.new([:bound, :terminal_grace]),
    bound: MapSet.new([:live, :terminal_grace]),
    live: MapSet.new([:terminal_grace]),
    terminal_grace: MapSet.new([:reaped]),
    reaped: MapSet.new()
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    surface_id = surface_id_from_opts!(opts)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(surface_id))
  end

  def child_spec(opts) do
    surface_id = surface_id_from_opts!(opts)

    %{
      id: {__MODULE__, surface_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000
    }
  end

  @spec ensure_started(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(surface_id, opts \\ []) when is_binary(surface_id) do
    LemonRouter.AsyncTaskSurfaceSupervisor.ensure_started(surface_id, opts)
  end

  @spec whereis(binary()) :: pid() | nil
  def whereis(surface_id) when is_binary(surface_id) do
    case Registry.lookup(@registry, surface_id) do
      [{pid, registry_value}] -> current_pid(pid, registry_value)
      [] -> nil
    end
  end

  @spec get(binary() | pid()) :: {:ok, snapshot()} | {:error, :not_found}
  def get(surface_id_or_pid) do
    with {:ok, pid} <- resolve_pid(surface_id_or_pid) do
      safe_call(pid, :get)
    end
  end

  @spec lookup_identity_by_task_id(binary()) ::
          {:ok, %{surface_id: binary(), surface: term(), root_action_id: binary()}} | :error
  def lookup_identity_by_task_id(task_id) when is_binary(task_id) and task_id != "" do
    find_identity(fn snapshot -> identity_for_task_id(snapshot, task_id) end)
  end

  def lookup_identity_by_task_id(_task_id), do: :error

  @spec lookup_identity_by_root_action_id(binary()) ::
          {:ok, %{surface_id: binary(), surface: term(), root_action_id: binary()}} | :error
  def lookup_identity_by_root_action_id(root_action_id)
      when is_binary(root_action_id) and root_action_id != "" do
    find_identity(fn snapshot -> identity_for_root_action_id(snapshot, root_action_id) end)
  end

  def lookup_identity_by_root_action_id(_root_action_id), do: :error

  defp find_identity(fun) when is_function(fun, 1) do
    LemonRouter.AsyncTaskSurfaceSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.reduce([], fn pid, acc ->
      case get(pid) do
        {:ok, snapshot} ->
          case fun.(snapshot) do
            {:ok, _identity} = identity -> [{snapshot, identity} | acc]
            _ -> acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.max_by(&identity_match_rank/1, fn -> nil end)
    |> case do
      nil -> :error
      {_snapshot, identity} -> identity
    end
  end

  @spec lookup_identity(binary()) ::
          {:ok, %{surface_id: binary(), surface: term(), root_action_id: binary()}} | :error
  def lookup_identity(surface_id) when is_binary(surface_id) and surface_id != "" do
    case get(surface_id) do
      {:ok, snapshot} -> identity_from_snapshot(snapshot)
      _ -> :error
    end
  end

  def lookup_identity(_surface_id), do: :error

  @spec transition(binary() | pid(), status(), map()) ::
          {:ok, snapshot()}
          | {:error,
             :not_found
             | {:invalid_transition, status(), status()}
             | {:invalid_metadata, :expected_map_or_key_value_list}}
  def transition(surface_id_or_pid, next_status, attrs \\ %{})
      when is_map(attrs) and next_status in @statuses do
    with {:ok, pid} <- resolve_pid(surface_id_or_pid) do
      safe_call(pid, {:transition, next_status, attrs})
    end
  end

  @impl true
  def init(opts) do
    now_ms = Clock.now_ms()
    surface_id = surface_id_from_opts!(opts)

    case normalize_metadata(Keyword.get(opts, :metadata, %{})) do
      {:ok, metadata} ->
        state = %{
          surface_id: surface_id,
          status: :pending_root,
          metadata: metadata,
          result: nil,
          error: nil,
          inserted_at_ms: now_ms,
          updated_at_ms: now_ms,
          terminal_at_ms: nil,
          reap_test_hook: Keyword.get(opts, :reap_test_hook)
        }

        refresh_registration(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, {:ok, snapshot_from_state(state)}, state}
  end

  def handle_call({:transition, next_status, attrs}, _from, state) do
    with :ok <- validate_transition(state.status, next_status),
         {:ok, metadata_update} <- metadata_update(attrs) do
      new_state = apply_transition(state, next_status, attrs, metadata_update)
      refresh_registration(new_state)

      if reap_transition?(state.status, next_status) do
        maybe_pause_reap_for_test(new_state)
        unregister_surface(state.surface_id)
        {:stop, :normal, {:ok, snapshot_from_state(new_state)}, new_state}
      else
        {:reply, {:ok, snapshot_from_state(new_state)}, new_state}
      end
    else
      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp via_tuple(surface_id) do
    {:via, Registry, {@registry, surface_id}}
  end

  defp current_pid(pid, registry_value) do
    cond do
      not Process.alive?(pid) ->
        nil

      registry_status(registry_value) == :reaped ->
        nil

      true ->
        pid
    end
  end

  defp resolve_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :not_found}
  end

  defp resolve_pid(surface_id) when is_binary(surface_id) do
    case whereis(surface_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end

  defp safe_call(pid, message, timeout \\ 5_000) do
    try do
      GenServer.call(pid, message, timeout)
    catch
      :exit, _reason -> {:error, :not_found}
    end
  end

  defp surface_id_from_opts!(opts) do
    Keyword.get(opts, :surface_id) || Keyword.fetch!(opts, :task_id)
  end

  defp validate_transition(current, current), do: :ok

  defp validate_transition(current, next_status) do
    if MapSet.member?(@allowed_transitions[current], next_status) do
      :ok
    else
      {:error, {:invalid_transition, current, next_status}}
    end
  end

  defp apply_transition(state, next_status, attrs, metadata_update) do
    metadata = merge_transition_metadata(state.metadata, metadata_update)

    if duplicate_transition?(state.status, next_status) do
      maybe_apply_duplicate_metadata(state, metadata)
    else
      now_ms = Clock.now_ms()
      terminal_at_ms = terminal_at_ms(state, next_status, now_ms)

      state
      |> Map.put(:status, next_status)
      |> Map.put(:metadata, metadata)
      |> Map.put(:result, next_result(state.result, next_status, attrs))
      |> Map.put(:error, next_error(state.error, next_status, attrs))
      |> Map.put(:updated_at_ms, now_ms)
      |> Map.put(:terminal_at_ms, terminal_at_ms)
    end
  end

  defp reap_transition?(current_status, next_status) do
    current_status != :reaped and next_status == :reaped
  end

  defp duplicate_transition?(current, next_status)
       when current == next_status and current in @statuses,
       do: true

  defp duplicate_transition?(_, _), do: false

  defp maybe_apply_duplicate_metadata(state, metadata) do
    if metadata == state.metadata do
      state
    else
      state
      |> Map.put(:metadata, metadata)
      |> Map.put(:updated_at_ms, Clock.now_ms())
    end
  end

  defp metadata_update(attrs) do
    attrs
    |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
    |> normalize_metadata()
  end

  defp merge_transition_metadata(existing, update)
       when is_map(existing) and is_map(update) do
    existing
    |> Map.merge(update, fn key, existing_value, update_value ->
      merge_transition_metadata_value(key, existing_value, update_value)
    end)
    |> merge_task_metadata(existing, update)
  end

  defp merge_transition_metadata(existing, _update), do: existing

  defp merge_transition_metadata_value(key, existing_value, update_value)
       when key in [:surface_id, :surface, :root_action_id, :parent_run_id, :session_key] do
    existing_value || update_value
  end

  defp merge_transition_metadata_value(key, existing_value, update_value)
       when key in ["surface_id", "surface", "root_action_id", "parent_run_id", "session_key"] do
    existing_value || update_value
  end

  defp merge_transition_metadata_value(key, existing_value, update_value)
       when key in [:task_ids, "task_ids"] do
    merge_task_id_values(existing_value, update_value)
  end

  defp merge_transition_metadata_value(_key, existing_value, _update_value), do: existing_value

  defp merge_task_metadata(metadata, existing, update) do
    task_ids =
      merge_task_id_values(task_ids_from_metadata(existing), task_ids_from_metadata(update))

    task_id =
      task_id_from_metadata(existing) || task_id_from_metadata(update) || List.first(task_ids)

    metadata
    |> put_task_metadata(:task_ids, "task_ids", task_ids)
    |> put_task_metadata(:task_id, "task_id", task_id)
  end

  defp put_task_metadata(metadata, _atom_key, _string_key, []), do: metadata
  defp put_task_metadata(metadata, _atom_key, _string_key, nil), do: metadata

  defp put_task_metadata(metadata, atom_key, string_key, value) do
    cond do
      Map.has_key?(metadata, atom_key) -> Map.put(metadata, atom_key, value)
      Map.has_key?(metadata, string_key) -> Map.put(metadata, string_key, value)
      true -> Map.put(metadata, atom_key, value)
    end
  end

  defp task_id_from_metadata(metadata) when is_map(metadata) do
    metadata[:task_id] || metadata["task_id"]
  end

  defp task_id_from_metadata(_metadata), do: nil

  defp task_ids_from_metadata(metadata) when is_map(metadata) do
    merge_task_id_values(metadata[:task_ids], metadata["task_ids"])
  end

  defp task_ids_from_metadata(_metadata), do: []

  defp merge_task_id_values(left, right) do
    (normalize_task_ids(left) ++ normalize_task_ids(right))
    |> Enum.uniq()
  end

  defp normalize_task_ids(task_ids) when is_list(task_ids) do
    Enum.filter(task_ids, &(is_binary(&1) and &1 != ""))
  end

  defp normalize_task_ids(task_id) when is_binary(task_id) and task_id != "", do: [task_id]
  defp normalize_task_ids(_task_ids), do: []

  defp next_result(current_result, :terminal_grace, attrs) do
    Map.get(attrs, :result, Map.get(attrs, "result", current_result))
  end

  defp next_result(current_result, _next_status, _attrs), do: current_result

  defp next_error(current_error, :terminal_grace, attrs) do
    Map.get(attrs, :error, Map.get(attrs, "error", current_error))
  end

  defp next_error(current_error, _next_status, _attrs), do: current_error

  defp terminal_at_ms(state, next_status, now_ms)
       when next_status in [:terminal_grace, :reaped] do
    state.terminal_at_ms || now_ms
  end

  defp terminal_at_ms(_state, _next_status, _now_ms), do: nil

  defp normalize_metadata(nil), do: {:ok, %{}}
  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, Map.new(metadata)}

  defp normalize_metadata(metadata) when is_list(metadata) do
    if Enum.all?(metadata, &match?({_, _}, &1)) do
      {:ok, Map.new(metadata)}
    else
      {:error, {:invalid_metadata, :expected_map_or_key_value_list}}
    end
  end

  defp normalize_metadata(_metadata),
    do: {:error, {:invalid_metadata, :expected_map_or_key_value_list}}

  defp unregister_surface(surface_id) do
    Registry.unregister(@registry, surface_id)
  end

  defp refresh_registration(state) do
    Registry.update_value(@registry, state.surface_id, fn _value ->
      %{status: state.status}
    end)
  end

  defp registry_status(%{status: status}) when status in @statuses, do: status
  defp registry_status(_registry_value), do: nil

  defp snapshot_from_state(state) do
    Map.take(state, @snapshot_keys)
  end

  defp identity_from_snapshot(%{status: :reaped}), do: :error

  defp identity_from_snapshot(%{surface_id: surface_id, metadata: metadata})
       when is_binary(surface_id) and is_map(metadata) do
    root_action_id = metadata[:root_action_id] || metadata["root_action_id"]
    surface = metadata[:surface] || metadata["surface"]

    if is_binary(root_action_id) and not is_nil(surface) do
      {:ok, %{surface_id: surface_id, surface: surface, root_action_id: root_action_id}}
    else
      :error
    end
  end

  defp identity_from_snapshot(_snapshot), do: :error

  defp identity_for_task_id(%{status: :reaped}, _task_id), do: nil

  defp identity_for_task_id(%{surface_id: surface_id, metadata: metadata}, task_id)
       when is_binary(surface_id) and is_map(metadata) do
    if task_id_matches?(metadata, task_id) do
      identity_from_snapshot(%{surface_id: surface_id, metadata: metadata})
    end
  end

  defp identity_for_task_id(_snapshot, _task_id), do: nil

  defp identity_for_root_action_id(%{status: :reaped}, _root_action_id), do: nil

  defp identity_for_root_action_id(%{surface_id: surface_id, metadata: metadata}, root_action_id)
       when is_binary(surface_id) and is_map(metadata) do
    if root_action_id_matches?(metadata, root_action_id) do
      identity_from_snapshot(%{surface_id: surface_id, metadata: metadata})
    end
  end

  defp identity_for_root_action_id(_snapshot, _root_action_id), do: nil

  defp task_id_matches?(metadata, task_id) when is_map(metadata) and is_binary(task_id) do
    direct_task_id = metadata[:task_id] || metadata["task_id"]
    task_ids = metadata[:task_ids] || metadata["task_ids"] || []

    direct_task_id == task_id or
      (is_list(task_ids) and Enum.any?(task_ids, &(&1 == task_id)))
  end

  defp root_action_id_matches?(metadata, root_action_id)
       when is_map(metadata) and is_binary(root_action_id) do
    direct_root_action_id = metadata[:root_action_id] || metadata["root_action_id"]
    direct_root_action_id == root_action_id
  end

  defp maybe_pause_reap_for_test(%{surface_id: surface_id, reap_test_hook: {notify_pid, ref}})
       when is_pid(notify_pid) do
    send(notify_pid, {:async_task_surface_reap_blocked, surface_id, self(), ref})

    receive do
      {:continue_async_task_surface_reap, ^ref} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp maybe_pause_reap_for_test(_state), do: :ok

  defp identity_match_rank(
         {snapshot,
          {:ok, %{surface: surface, surface_id: surface_id, root_action_id: root_action_id}}}
       ) do
    explicit_override_bonus =
      if explicit_surface_override?(surface, surface_id, root_action_id), do: 1, else: 0

    {explicit_override_bonus, snapshot.updated_at_ms || 0, snapshot.inserted_at_ms || 0}
  end

  defp explicit_surface_override?(surface, surface_id, root_action_id)
       when is_binary(surface_id) and surface_id != "" and is_binary(root_action_id) and
              root_action_id != "" do
    surface_id != root_action_id or surface != {:status_task, root_action_id}
  end

  defp explicit_surface_override?(_surface, _surface_id, _root_action_id), do: false
end
