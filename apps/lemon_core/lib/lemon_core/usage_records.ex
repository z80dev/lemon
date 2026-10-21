defmodule LemonCore.UsageRecords do
  @moduledoc """
  Canonical usage pages over the usage and native run owners. Costs are recorded
  response prices, never estimates. Missing historical attribution/time/price is
  explicit; aggregate-only history makes the result incomplete even for a scoped
  query because it cannot be assigned to a run or session safely.
  """
  alias LemonCore.{UsageLedger, UsageStore}

  def query(params, opts \\ []) do
    store = Keyword.get(opts, :store, LemonCore.Store)

    with {:ok, filters, limit} <- filters(params),
         {:ok, after_key} <- decode_cursor(Map.get(params, "cursor"), filters),
         {:ok, stored} <- UsageStore.fetch_occurrences(store),
         {:ok, runs} <- UsageStore.fetch_runs(store),
         {:ok, daily} <- UsageStore.fetch_daily_records(store) do
      native = Map.new(stored)

      records =
        Enum.reduce(runs, native, fn {run_id, run}, acc ->
          case field(run, :summary) do
            summary when is_map(summary) ->
              UsageLedger.entries(run_id, field(summary, :session_key), summary)
              |> Enum.reduce(acc, fn entry, records ->
                record = UsageLedger.occurrence_record(entry)
                usage = summary |> field(:completed) |> field(:usage)

                record =
                  if is_list(field(usage, :occurrences)),
                    do: record,
                    else: Map.put(record, :incomplete, true)

                Map.put_new(records, record.id, record)
              end)

            _ ->
              acc
          end
        end)
        |> Map.values()

      matching = records |> Enum.filter(&matches?(&1, filters)) |> Enum.sort_by(&key/1)

      incomplete =
        Enum.any?(matching, &incomplete?/1) or historical_gap?(daily, records, filters) or
          missing_history?(runs, filters)

      page =
        matching
        |> Enum.filter(&(is_nil(after_key) or key(&1) > after_key))
        |> Enum.take(limit + 1)

      returned = Enum.take(page, limit)

      cursor =
        if length(page) > limit, do: encode_cursor(key(List.last(returned)), filters), else: nil

      {:ok, %{records: returned, next_cursor: cursor, incomplete: incomplete}}
    end
  end

  defp filters(params) when is_map(params) do
    from = params["fromMs"]
    to = params["toMs"]
    limit = Map.get(params, "limit", 100)
    run = params["runId"]
    session = params["sessionKey"]

    if is_integer(from) and from >= 0 and is_integer(to) and to > from and
         is_integer(limit) and limit in 1..500 and valid_id?(run) and valid_id?(session) do
      {:ok, %{from: from, to: to, run: run, session: session}, limit}
    else
      {:error, :invalid_usage_filters}
    end
  end

  defp filters(_), do: {:error, :invalid_usage_filters}
  defp valid_id?(nil), do: true
  defp valid_id?(id), do: is_binary(id) and byte_size(id) in 1..1024 and String.valid?(id)

  defp matches?(record, filters) do
    (is_nil(record.at_ms) or (record.at_ms >= filters.from and record.at_ms < filters.to)) and
      (is_nil(filters.run) or record.run_id == filters.run) and
      (is_nil(filters.session) or record.session_key == filters.session)
  end

  defp incomplete?(record),
    do:
      Map.get(record, :incomplete, false) or
        not record.price_known or is_nil(record.cost_usd) or is_nil(record.at_ms) or
        is_nil(record.input_tokens) or is_nil(record.output_tokens) or is_nil(record.total_tokens) or
        is_nil(record.session_key) or is_nil(record.agent_id) or
        record.model == "unknown" or record.provider == "unknown"

  defp key(record), do: {record.at_ms || -1, record.id}

  defp missing_history?(runs, filters) do
    Enum.any?(runs, fn {run_id, run} ->
      summary = field(run, :summary)
      completed = field(summary, :completed)
      usage = field(completed, :usage)
      at = field(summary, :completed_at_ms)
      session = field(summary, :session_key)

      is_map(completed) and field(usage, :occurrences) != [] and
        UsageLedger.entries(run_id, session, summary) == [] and
        (is_nil(at) or (at >= filters.from and at < filters.to)) and
        (is_nil(filters.run) or run_id == filters.run) and
        (is_nil(filters.session) or session == filters.session)
    end)
  end

  defp historical_gap?(daily, records, filters) do
    coverage =
      records |> Enum.filter(&is_integer(&1.at_ms)) |> Enum.group_by(&div(&1.at_ms, 86_400_000))

    Enum.any?(daily, fn {date, record} ->
      case Date.from_iso8601(date) do
        {:ok, date} ->
          start = Date.diff(date, ~D[1970-01-01]) * 86_400_000

          if start < filters.to and start + 86_400_000 > filters.from do
            requests = field(record, :requests) || %{}
            count = requests |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()
            known_calls = length(Map.get(coverage, div(start, 86_400_000), []))
            count > known_calls
          else
            false
          end

        _ ->
          true
      end
    end)
  end

  defp fingerprint(filters),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(filters)) |> Base.url_encode64(padding: false)

  defp encode_cursor({at, id}, filters),
    do: Jason.encode!([fingerprint(filters), at, id]) |> Base.url_encode64(padding: false)

  defp decode_cursor(nil, _), do: {:ok, nil}

  defp decode_cursor(cursor, filters) when is_binary(cursor) and byte_size(cursor) <= 2048 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [hash, at, id]} <- Jason.decode(json),
         true <- hash == fingerprint(filters) and is_integer(at) and is_binary(id) do
      {:ok, {at, id}}
    else
      _ -> {:error, :invalid_usage_cursor}
    end
  end

  defp decode_cursor(_, _), do: {:error, :invalid_usage_cursor}
  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_, _), do: nil
end
