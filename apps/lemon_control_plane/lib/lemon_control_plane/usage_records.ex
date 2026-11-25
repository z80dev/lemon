defmodule LemonControlPlane.UsageRecords do
  @moduledoc """
  Canonical usage pages over the usage ledger's occurrences, the only source of
  per-call usage (run records are not consulted). Costs are recorded response
  prices, never estimates. Missing historical attribution/time/price is
  explicit; aggregate-only history makes the result incomplete even for a scoped
  query because it cannot be assigned to a run or session safely.

  A page reads the occurrences and daily aggregates for the days the window
  touches (plus untimed rows), rather than reading both tables whole.
  """
  alias LemonAgent.UsageStore

  @day_ms 86_400_000

  def query(params, opts \\ []) do
    store = Keyword.get(opts, :store, LemonCore.Store)

    with {:ok, filters, limit} <- filters(params),
         {:ok, after_key} <- decode_cursor(Map.get(params, "cursor"), filters),
         # Whole days, so each touched day's coverage can be compared with its
         # aggregate.
         from = day_start(filters.from),
         to = day_start(filters.to - 1) + @day_ms,
         {:ok, stored} <- UsageStore.fetch_occurrences_between(store, from, to),
         {:ok, daily} <- UsageStore.fetch_daily_records_between(store, from, to) do
      records = Enum.map(stored, &elem(&1, 1))
      matching = records |> Enum.filter(&matches?(&1, filters)) |> Enum.sort_by(&key/1)

      incomplete =
        Enum.any?(matching, &incomplete?/1) or historical_gap?(daily, records)

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

  defp day_start(ms), do: Integer.floor_div(ms, @day_ms) * @day_ms

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

  defp historical_gap?(daily, records) do
    coverage =
      Enum.reduce(records, %{}, fn
        %{at_ms: ms}, acc when is_integer(ms) -> Map.update(acc, day_start(ms), 1, &(&1 + 1))
        _untimed, acc -> acc
      end)

    Enum.any?(daily, fn {date, record} ->
      case LemonCore.Store.Backend.range_timestamp(:usage_records, date, record) do
        nil ->
          true

        start ->
          requests = field(record, :requests) || %{}
          count = requests |> Map.values() |> Enum.filter(&is_integer/1) |> Enum.sum()
          count > Map.get(coverage, start, 0)
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
