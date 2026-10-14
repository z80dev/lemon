defmodule LemonRouter.RunPresence do
  @moduledoc false

  alias LemonCore.{MapHelpers, RunStore}
  alias LemonRouter.{RunOrchestrator, SessionCoordinator}

  @scope_keys [:profile_id, :agent_id, :session_key]
  @absorbed_modes [:merged, :steer, :steer_backlog, :redirect]

  # Read barriers bracket the live reads, but no orchestrator callback waits
  # for a coordinator. A concurrent admission/retarget invalidates the proof.
  def query(filters \\ %{}) do
    registry = Process.whereis(LemonRouter.RunRegistry)
    owner = Process.whereis(RunOrchestrator)

    with true <- is_pid(owner) and is_pid(registry),
         {:ok, before} <- RunOrchestrator.presence_snapshot(),
         {:ok, active} <- LemonRouter.active_runs(),
         {:ok, coordinated} <- SessionCoordinator.presence_entries(),
         {:ok, durable} <- durable_entries(before),
         {:ok, after_snapshot} <- RunOrchestrator.presence_snapshot(),
         true <- before == after_snapshot,
         true <- Process.whereis(LemonRouter.RunRegistry) == registry,
         true <- Process.whereis(RunOrchestrator) == owner do
      entries =
        durable ++ coordinated ++ Enum.map(active, &Map.put(&1, :status, :active))

      entries = Enum.reduce(entries, %{}, &merge_entry/2) |> Map.values()
      scoped = Enum.flat_map(entries, &scope_entry(&1, filters))
      counts = Enum.frequencies_by(scoped, & &1.status)
      presence = %{
        active: Map.get(counts, :active, 0),
        queued: Map.get(counts, :queued, 0),
        unknown: Map.get(counts, :unknown, 0),
        idle: scoped == [],
        complete: true
      }

      runs =
        entries
        |> Enum.filter(&(&1.status == :active))
        |> Enum.flat_map(&scope_entry(&1, filters))
        |> Enum.map(&Map.merge(%{session_key: nil, agent_id: nil, profile_id: nil,
                                engine: nil, started_at_ms: nil}, &1))
        |> Enum.sort_by(&(&1.started_at_ms || 0), :desc)

      {:ok, %{runs: runs, presence: presence}}
    else
      false -> {:error, :query_failed}
      {:error, reason} when reason in [:unavailable, :query_failed] -> {:error, reason}
      _ -> {:error, :query_failed}
    end
  rescue
    ArgumentError -> {:error, :query_failed}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp durable_entries(%{admissions: admissions, receipts: receipts}) do
    ids = Map.keys(admissions) ++ Map.keys(receipts)

    resolved =
      Enum.reduce_while(ids, {:ok, MapSet.new()}, fn id, {:ok, acc} ->
        case work_id(id, receipts, MapSet.new()) do
          {:ok, id} -> {:cont, {:ok, MapSet.put(acc, id)}}
          error -> {:halt, error}
        end
      end)

    with {:ok, ids} <- resolved do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, entries} ->
        with admission when is_map(admission) <- Map.get(admissions, id, %{}),
             receipt when is_map(receipt) <- Map.get(receipts, id, %{}),
             {:ok, terminal?} <- terminal?(id, admission, receipt) do
          if terminal? do
            {:cont, {:ok, entries}}
          else
            entry = Map.merge(scope(admission, receipt), %{run_id: id, status: :unknown})
            {:cont, {:ok, [entry | entries]}}
          end
        else
          _ -> {:halt, {:error, :query_failed}}
        end
      end)
    end
  end

  defp terminal?(id, admission, receipt) do
    if admission[:terminal] == true or receipt[:terminal] == true do
      {:ok, true}
    else
      case RunStore.fetch(id) do
        {:ok, nil} -> {:ok, false}
        {:ok, record} when is_map(record) -> {:ok, is_map(MapHelpers.get_key(record, :summary))}
        _ -> {:error, :query_failed}
      end
    end
  end

  defp work_id(id, receipts, visited) do
    if MapSet.member?(visited, id) do
      {:error, :query_failed}
    else
      case Map.get(receipts, id) do
        %{state: :accepted, effective_mode: mode, target_run_id: target}
        when mode in @absorbed_modes and target != id ->
          work_id(target, receipts, MapSet.put(visited, id))

        _ -> {:ok, id}
      end
    end
  end

  defp scope(admission, receipt) do
    stored = MapHelpers.get_key(admission, :scope) || %{}
    scope = Map.new(@scope_keys, fn key -> {key, MapHelpers.get_key(receipt, key) || MapHelpers.get_key(stored, key)} end)
    dependencies = LemonRouter.NativeLineage.dependent_profile_ids(admission) ++
      Map.get(receipt, :dependent_profile_ids, [])
    Map.put(scope, :dependent_profile_ids, Enum.uniq(dependencies))
  end

  defp merge_entry(entry, acc) do
    Map.update(acc, entry.run_id, entry, fn previous ->
      # Live scope is authoritative, but a metadata timeout must not erase
      # content-free attribution already established by the admission owner.
      merged = Map.merge(previous, Map.reject(entry, fn {_key, value} -> is_nil(value) end))
      dependencies = Map.get(previous, :dependent_profile_ids, []) ++ Map.get(entry, :dependent_profile_ids, [])
      merged = Map.put(merged, :dependent_profile_ids, Enum.uniq(dependencies))
      status = if rank(previous.status) > rank(entry.status), do: previous.status, else: entry.status
      Map.put(merged, :status, status)
    end)
  end

  defp rank(:active), do: 2
  defp rank(:queued), do: 1
  defp rank(:unknown), do: 0

  defp scope_entry(entry, filters) do
    comparisons =
      for key <- @scope_keys, filter = Map.get(filters, key), not is_nil(filter) do
        case {key, Map.get(entry, key)} do
          {:profile_id, value} ->
            cond do
              value == filter or filter in Map.get(entry, :dependent_profile_ids, []) -> :match
              is_nil(value) -> :unknown
              true -> :different
            end
          {_, nil} -> :unknown
          {_, ^filter} -> :match
          _ -> :different
        end
      end

    cond do
      :different in comparisons -> []
      :unknown in comparisons -> [Map.put(entry, :status, :unknown)]
      true -> [entry]
    end
  end
end
