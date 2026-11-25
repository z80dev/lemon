defmodule LemonControlPlane.SessionMaintenance do
  @moduledoc false

  alias LemonCore.{AgentRuntime, Store}

  @table :session_maintenance_previews
  @index_table :session_maintenance_preview_index
  @index_key :retained
  # Operator-surface policy: ten-minute, single-use previews; at most 32 private
  # plans of 8 MiB each. Display bounds never truncate the authorized plan.
  @ttl_ms 600_000
  @max_previews 32
  @max_plan_bytes 8 * 1024 * 1024
  @display_limit 100

  def maintenance(opts) do
    cutoff = Keyword.get(opts, :older_than_ms)

    cond do
      not is_integer(cutoff) or cutoff <= 0 ->
        {:error, :invalid_older_than_ms}

      Keyword.get(opts, :dry_run, true) != false ->
        preview(cutoff)

      true ->
        execute(cutoff, Keyword.get(opts, :confirm_token))
    end
  end

  defp preview(cutoff) do
    provider = AgentRuntime.provider()

    with {:ok, plan} <- call(provider, :session_maintenance_plan, [cutoff]),
         true <- valid_plan?(plan),
         true <- :erlang.external_size(plan) <= @max_plan_bytes,
         {:ok, token} <- retain(provider, cutoff, plan) do
      {:ok, report(plan, cutoff, token, true)}
    else
      _ -> {:error, :maintenance_unavailable}
    end
  end

  defp retain(provider, cutoff, plan) do
    locked(fn ->
      owner = Process.whereis(Store)
      now = System.system_time(:millisecond)

      with true <- is_pid(owner),
           {:ok, index} <- fetch_index(owner),
           {:ok, kept} <- trim_index(index, owner, now) do
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        entry = %{
          provider: provider,
          older_than_ms: cutoff,
          plan: plan,
          store_owner: owner,
          expires_at_ms: now + @ttl_ms,
          sequence: System.unique_integer([:positive, :monotonic])
        }

        # Index first: even an ambiguous write cannot leave an unindexed plan.
        metadata = Map.take(entry, [:store_owner, :expires_at_ms, :sequence])

        with :ok <- write_index(owner, Map.put(kept, token, metadata)),
             :ok <- Store.put(owner, @table, token, entry, durable: true),
             true <- Process.whereis(Store) == owner do
          {:ok, token}
        else
          _ -> {:error, :maintenance_unavailable}
        end
      else
        _ -> {:error, :maintenance_unavailable}
      end
    end)
  end

  defp fetch_index(owner) do
    case Store.fetch(owner, @index_table, @index_key) do
      {:ok, index} when is_map(index) ->
        {:ok, index}

      {:ok, nil} ->
        # Legacy previews share this table but lack index entries. They are
        # invalid across a Store restart; clear only their keys at first use.
        with {:ok, keys} <- Store.fetch_keys(owner, @table),
             :ok <- evict(keys, owner),
             :ok <- write_index(owner, %{}),
             do: {:ok, %{}}

      _ ->
        {:error, :maintenance_unavailable}
    end
  end

  defp write_index(owner, index),
    do: Store.put(owner, @index_table, @index_key, index, durable: true)

  defp trim_index(index, owner, now) do
    newest =
      for {token, %{store_owner: ^owner, expires_at_ms: expiry, sequence: seq}} <- index,
          expiry > now,
          do: {seq, token}

    kept =
      newest
      |> Enum.sort(:desc)
      |> Enum.take(@max_previews - 1)
      |> Map.new(fn {_seq, token} -> {token, Map.fetch!(index, token)} end)

    with :ok <- evict(Map.keys(index) -- Map.keys(kept), owner), do: {:ok, kept}
  end

  defp evict(tokens, owner) do
    Enum.reduce_while(tokens, :ok, fn token, :ok ->
      case Store.delete(owner, @table, token, durable: true) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :maintenance_unavailable}}
      end
    end)
  end

  defp execute(_cutoff, token) when not is_binary(token) or token == "",
    do: {:error, :confirmation_required}

  defp execute(cutoff, token) do
    with {:ok, entry} <- consume(cutoff, token) do
      report = report(entry.plan, cutoff, token, false)

      case execute_plan(entry.provider, entry.plan) do
        {:ok, result} -> finish(report, result, true)
        {:error, :confirmation_mismatch} -> {:error, :confirmation_mismatch}
        {:error, {:partial_failure, result}} -> finish(report, result, false)
        # Never reached: the consumed preview applied nothing.
        :not_dispatched -> {:error, :maintenance_unavailable}
        # Reached and failed, or answered malformed: deletions may have applied.
        _ -> {:error, :outcome_unknown}
      end
    end
  end

  defp consume(cutoff, token) do
    locked(fn ->
      with owner when is_pid(owner) <- Process.whereis(Store),
           {:ok, index} <- fetch_index(owner),
           true <- Map.has_key?(index, token),
           {:ok, entry} when is_map(entry) <- Store.fetch(owner, @table, token),
           # Consume durably before dispatch; never execute after an unknown write.
           :ok <- Store.compare_and_delete(owner, @table, token, entry, durable: true),
           :ok <- write_index(owner, Map.delete(index, token)) do
        if entry[:older_than_ms] == cutoff and
             entry[:provider] == AgentRuntime.provider() and
             entry[:store_owner] == Process.whereis(Store) and
             is_integer(entry[:expires_at_ms]) and
             entry.expires_at_ms > System.system_time(:millisecond) do
          {:ok, entry}
        else
          {:error, :confirmation_mismatch}
        end
      else
        false -> {:error, :confirmation_mismatch}
        {:ok, nil} -> {:error, :confirmation_mismatch}
        {:error, :mismatch} -> {:error, :confirmation_mismatch}
        _ -> {:error, :maintenance_unavailable}
      end
    end)
  end

  defp finish(report, result, success?) when is_map(result) do
    archived = result[:archived_count]
    swept = result[:swept_count]

    if is_integer(archived) and archived >= 0 and archived <= report.archive_count and
         is_integer(swept) and swept >= 0 and swept <= report.orphan_count do
      verified =
        success? and result[:verified] == true and
          archived == report.archive_count and swept == report.orphan_count

      report = %{report | archived_count: archived, swept_count: swept, verified: verified}
      if verified, do: {:ok, report}, else: {:error, {:partial_failure, report}}
    else
      {:error, :outcome_unknown}
    end
  end

  defp finish(_report, _result, _success?), do: {:error, :outcome_unknown}

  defp report(plan, cutoff, token, dry_run) do
    %{
      dry_run: dry_run,
      older_than_ms: cutoff,
      confirmation_token: token,
      archive_count: Enum.count(plan.candidates, &(&1.kind == :archive)),
      orphan_count: Enum.count(plan.candidates, &(&1.kind == :orphan_artifact)),
      archived_count: 0,
      swept_count: 0,
      candidates:
        plan.candidates
        |> Enum.take(@display_limit)
        |> Enum.map(fn candidate ->
          %{
            kind: candidate.kind,
            id: Base.encode16(:crypto.hash(:sha256, candidate.id), case: :lower),
            bytes: candidate.bytes
          }
        end),
      verified: false
    }
  end

  defp valid_plan?(%{candidates: candidates}) when is_list(candidates) do
    Enum.all?(candidates, fn
      %{kind: kind, id: id, bytes: bytes}
      when kind in [:archive, :orphan_artifact] and is_binary(id) and
             is_integer(bytes) and bytes >= 0 ->
        true

      _ ->
        false
    end)
  end

  defp valid_plan?(_), do: false

  defp call(provider, function, args) do
    LemonCore.RuntimeSeam.invoke(provider, function, args,
      unavailable: {:error, :maintenance_unavailable},
      log: "SessionMaintenance plan",
      log_level: :warning
    )
  end

  defp execute_plan(provider, plan) do
    LemonCore.RuntimeSeam.invoke(provider, :session_maintenance_execute, [plan],
      unavailable: :not_dispatched,
      exception: {:error, :outcome_unknown},
      exit: {:error, :outcome_unknown},
      throw: {:error, :outcome_unknown},
      log: "SessionMaintenance execute"
    )
  end

  defp locked(fun) do
    case :global.trans({{__MODULE__, :previews}, self()}, fun, [node()], 3) do
      :aborted -> {:error, :maintenance_unavailable}
      result -> result
    end
  end
end
