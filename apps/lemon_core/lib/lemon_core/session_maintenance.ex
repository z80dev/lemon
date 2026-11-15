defmodule LemonCore.SessionMaintenance do
  @moduledoc false

  alias LemonCore.{AgentRuntime, Store}

  @table :session_maintenance_previews
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
           {:ok, entries} <- Store.fetch_all(@table),
           :ok <- evict(entries, owner, now) do
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        entry = %{
          provider: provider,
          older_than_ms: cutoff,
          plan: plan,
          store_owner: owner,
          expires_at_ms: now + @ttl_ms,
          sequence: System.unique_integer([:positive, :monotonic])
        }

        with :ok <- Store.put(Store, @table, token, entry, durable: true),
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

  defp evict(entries, owner, now) do
    {live, expired} =
      Enum.split_with(entries, fn {_, entry} ->
        is_map(entry) and entry[:store_owner] == owner and
          is_integer(entry[:expires_at_ms]) and entry.expires_at_ms > now
      end)

    evicted =
      live
      |> Enum.sort_by(fn {_, entry} -> entry.sequence end, :desc)
      |> Enum.drop(@max_previews - 1)

    Enum.reduce_while(expired ++ evicted, :ok, fn {token, entry}, :ok ->
      case Store.compare_and_delete(Store, @table, token, entry, durable: true) do
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

      case call(entry.provider, :session_maintenance_execute, [entry.plan]) do
        {:ok, result} -> finish(report, result, true)
        {:error, :confirmation_mismatch} -> {:error, :confirmation_mismatch}
        {:error, {:partial_failure, result}} -> finish(report, result, false)
        _ -> {:error, {:partial_failure, report}}
      end
    end
  end

  defp consume(cutoff, token) do
    locked(fn ->
      case Store.fetch(@table, token) do
        {:ok, entry} when is_map(entry) ->
          # Consume durably BEFORE dispatch: a killed caller, failed owner, or
          # unknown mutation outcome can never authorize a second execution.
          case Store.compare_and_delete(Store, @table, token, entry, durable: true) do
            :ok ->
              if entry[:older_than_ms] == cutoff and
                   entry[:provider] == AgentRuntime.provider() and
                   entry[:store_owner] == Process.whereis(Store) and
                   is_integer(entry[:expires_at_ms]) and
                   entry.expires_at_ms > System.system_time(:millisecond) do
                {:ok, entry}
              else
                {:error, :confirmation_mismatch}
              end

            {:error, :mismatch} ->
              {:error, :confirmation_mismatch}

            _ ->
              {:error, :maintenance_unavailable}
          end

        {:ok, nil} ->
          {:error, :confirmation_mismatch}

        _ ->
          {:error, :maintenance_unavailable}
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
      {:error, {:partial_failure, report}}
    end
  end

  defp finish(report, _result, _success?), do: {:error, {:partial_failure, report}}

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
    if is_atom(provider) and not is_nil(provider) and Code.ensure_loaded?(provider) and
         function_exported?(provider, function, length(args)) do
      apply(provider, function, args)
    else
      {:error, :maintenance_unavailable}
    end
  rescue
    _ -> {:error, :maintenance_unavailable}
  catch
    _, _ -> {:error, :maintenance_unavailable}
  end

  defp locked(fun) do
    case :global.trans({{__MODULE__, :previews}, self()}, fun, [node()]) do
      :aborted -> {:error, :maintenance_unavailable}
      result -> result
    end
  end
end
