defmodule LemonCore.UsageReport do
  @moduledoc """
  Handler for the usage.cost control plane method.

  Returns cost breakdown for a specified time period (at most the last 366 days
  of the requested range).

  Besides the historical totals (`totalCost`, provider-keyed `breakdown`,
  `totalRequests`, `totalTokens`, `daily`), the response carries bounded
  projections of the counters recorded by `LemonCore.UsageLedger`:
  `providers` and `models` (`cost`, `requests`, `inputTokens`, `outputTokens`;
  at most 50 models), `sessions` (top 20 by cost with `sessionKey`/`lastAtMs`;
  `sessionsOmitted` counts the rest) and `dailyUsage` (per-day cost, requests
  and tokens, oldest first).

  ## Usage Data Format

  Usage records are stored in the `:usage_records` store with keys like
  `"2025-01-15"` (date strings). Each record contains:

  ```elixir
  %{
    date: "2025-01-15",
    total_cost: 0.50,
    breakdown: %{
      "claude" => 0.30,
      "openai" => 0.20
    },
    requests: %{
      "claude" => 10,
      "openai" => 5
    },
    tokens: %{
      "claude" => %{input: 5000, output: 2000},
      "openai" => %{input: 3000, output: 1000}
    }
  }
  ```

  ## Enforcement

  This is a bounded presentation of known-cost subtotals. Use `usage.records`
  and exhaust every page for spend accounting; unknown prices and unattributed
  historical totals are incomplete, never evidence of free execution.
  Recording belongs to `LemonCore.UsageLedger` and the native run owner.
  """

  alias LemonCore.UsageStore

  @doc "Builds the bounded usage.cost projection directly from the ledger store."
  def query(params, opts \\ []) do
    start_date = params["startDate"] || params["start_date"]
    end_date = params["endDate"] || params["end_date"]
    group_by = params["groupBy"] || params["group_by"] || "day"

    # Parse dates or use defaults
    {start_ms, end_ms} = parse_date_range(start_date, end_date)

    case fetch_records(start_ms, end_ms, opts) do
      {:ok, records} ->
        costs = calculate_costs(records, group_by)
        details = details(records)

        result = %{
          "startDate" => format_date(start_ms),
          "endDate" => format_date(end_ms),
          "totalCost" => costs.total,
          "knownCostSubtotal" => costs.total,
          "incomplete" =>
            Enum.any?(records, fn record ->
              not Map.has_key?(record, :unknown_cost_records) or
                Map.get(record, :unknown_cost_records, 0) > 0
            end),
          "breakdown" => costs.breakdown,
          "totalRequests" => costs.total_requests,
          "totalTokens" => costs.total_tokens,
          "providers" => details.providers,
          "models" => details.models,
          "sessions" => details.sessions,
          "sessionsOmitted" => details.sessions_omitted,
          "dailyUsage" => details.daily
        }

        # Add daily breakdown if grouped by day
        result =
          if group_by == "day" and map_size(costs.daily) > 0 do
            Map.put(result, "daily", costs.daily)
          else
            result
          end

        {:ok, Map.put(result, "summary", summary(result, group_by))}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  defp summary(result, group_by) do
    %{
      "groupBy" => group_by,
      "providerCount" => result["breakdown"] |> Map.keys() |> length(),
      "dailyReturned" => Map.has_key?(result, "daily"),
      "dailyCount" => result |> Map.get("daily", %{}) |> map_size(),
      "totalRequests" => result["totalRequests"] || 0,
      "totalTokenCount" => total_token_count(result["totalTokens"]),
      "cleanup" => %{
        "includesPrompts" => false,
        "includesResponses" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp total_token_count(tokens) when is_map(tokens) do
    (get_field(tokens, :input) || 0) + (get_field(tokens, :output) || 0)
  end

  defp total_token_count(_), do: 0

  defp parse_date_range(nil, nil) do
    # Default to last 30 days
    now = System.system_time(:millisecond)
    thirty_days_ago = now - 30 * 24 * 60 * 60 * 1000
    {thirty_days_ago, now}
  end

  defp parse_date_range(start_str, end_str) do
    start_ms =
      parse_date_string(start_str) || System.system_time(:millisecond) - 30 * 24 * 60 * 60 * 1000

    end_ms = parse_date_string(end_str) || System.system_time(:millisecond)
    {start_ms, end_ms}
  end

  defp parse_date_string(nil), do: nil

  defp parse_date_string(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} ->
        date
        |> DateTime.new!(~T[00:00:00], "Etc/UTC")
        |> DateTime.to_unix(:millisecond)

      _ ->
        nil
    end
  end

  # At most a year of daily records is read per request, ending at `end_ms`.
  @max_range_days 366
  @max_models 50
  @max_sessions 20

  defp fetch_records(start_ms, end_ms, opts) do
    start_date = DateTime.from_unix!(start_ms, :millisecond) |> DateTime.to_date()
    end_date = DateTime.from_unix!(end_ms, :millisecond) |> DateTime.to_date()
    start_date = Enum.max([start_date, Date.add(end_date, 1 - @max_range_days)], Date)

    with {:ok, records} <-
           UsageStore.fetch_daily_records(Keyword.get(opts, :store, LemonCore.Store)) do
      dates = MapSet.new(generate_date_range(start_date, end_date))

      {:ok,
       Enum.flat_map(records, fn {date, record} ->
         if MapSet.member?(dates, date), do: [record], else: []
       end)}
    end
  end

  defp calculate_costs(records, group_by) do
    if Enum.empty?(records) do
      # No records found - return zeros
      %{
        total: 0.0,
        breakdown: %{"claude" => 0.0, "openai" => 0.0, "other" => 0.0},
        total_requests: 0,
        total_tokens: %{"input" => 0, "output" => 0},
        daily: %{}
      }
    else
      # Aggregate records
      initial = %{
        total: 0.0,
        breakdown: %{},
        total_requests: 0,
        total_tokens: %{input: 0, output: 0},
        daily: %{}
      }

      Enum.reduce(records, initial, fn record, acc ->
        record_cost = get_field(record, :total_cost) || 0.0
        record_breakdown = get_field(record, :breakdown) || %{}
        record_requests = get_field(record, :requests) || %{}
        record_tokens = get_field(record, :tokens) || %{}
        record_date = get_field(record, :date)

        # Sum up totals
        total = acc.total + record_cost

        # Merge breakdowns
        breakdown =
          Enum.reduce(record_breakdown, acc.breakdown, fn {provider, cost}, b ->
            Map.update(b, provider, cost, &(&1 + cost))
          end)

        # Sum requests
        total_requests = acc.total_requests + sum_map_values(record_requests)

        # Sum tokens
        total_tokens =
          Enum.reduce(record_tokens, acc.total_tokens, fn {_provider, tokens}, t ->
            %{
              input: t.input + (get_field(tokens, :input) || 0),
              output: t.output + (get_field(tokens, :output) || 0)
            }
          end)

        # Add to daily if grouping by day
        daily =
          if group_by == "day" and record_date do
            Map.put(acc.daily, record_date, %{
              "cost" => record_cost,
              "requests" => sum_map_values(record_requests),
              "breakdown" => record_breakdown
            })
          else
            acc.daily
          end

        %{
          acc
          | total: total,
            breakdown: breakdown,
            total_requests: total_requests,
            total_tokens: total_tokens,
            daily: daily
        }
      end)
    end
  end

  defp generate_date_range(start_date, end_date) do
    if Date.compare(start_date, end_date) == :gt do
      []
    else
      start_date
      |> Date.range(end_date)
      |> Enum.map(&Date.to_iso8601/1)
    end
  end

  # Bounded provider/model/session/day projections built from the counters
  # `LemonCore.UsageLedger` records. Only identifiers and numbers leave here.
  defp details(records) do
    providers =
      records
      |> Enum.reduce(%{}, fn record, acc ->
        tokens = get_field(record, :tokens) || %{}
        requests = get_field(record, :requests) || %{}
        breakdown = get_field(record, :breakdown) || %{}

        [tokens, requests, breakdown]
        |> Enum.flat_map(&Map.keys/1)
        |> Enum.uniq()
        |> Enum.reduce(acc, fn provider, acc ->
          provider_tokens = Map.get(tokens, provider) || %{}

          add_usage(acc, to_string(provider), %{
            cost: number(Map.get(breakdown, provider)),
            requests: integer(Map.get(requests, provider)),
            input: integer(get_field(provider_tokens, :input)),
            output: integer(get_field(provider_tokens, :output))
          })
        end)
      end)
      |> Enum.map(fn {provider, usage} -> Map.put(usage_json(usage), "provider", provider) end)
      |> Enum.reject(&(&1["requests"] == 0 and &1["cost"] == 0.0))
      |> top(:infinity)

    models =
      records
      |> Enum.reduce(%{}, fn record, acc ->
        Enum.reduce(get_field(record, :models) || %{}, acc, fn {key, usage}, acc ->
          acc
          |> add_usage(to_string(key), usage_counts(usage))
          |> Map.update!(to_string(key), fn merged ->
            Map.merge(merged, %{
              provider: get_field(usage, :provider),
              model: get_field(usage, :model)
            })
          end)
        end)
      end)
      |> Enum.map(fn {_key, usage} ->
        usage
        |> usage_json()
        |> Map.put("provider", to_string(usage.provider || "unknown"))
        |> Map.put("model", to_string(usage.model || "unknown"))
      end)
      |> top(@max_models)

    {sessions, omitted} =
      Enum.reduce(records, {%{}, 0}, fn record, {acc, omitted} ->
        acc =
          Enum.reduce(get_field(record, :sessions) || %{}, acc, fn {key, usage}, acc ->
            acc
            |> add_usage(to_string(key), usage_counts(usage))
            |> Map.update!(to_string(key), fn merged ->
              Map.put(
                merged,
                :last_at_ms,
                max(merged[:last_at_ms] || 0, integer(get_field(usage, :last_at_ms)))
              )
            end)
          end)

        {acc, omitted + integer(get_field(record, :sessions_omitted))}
      end)

    all_sessions =
      Enum.map(sessions, fn {key, usage} ->
        usage
        |> usage_json()
        |> Map.put("sessionKey", key)
        |> Map.put("lastAtMs", usage[:last_at_ms])
      end)

    daily =
      records
      |> Enum.flat_map(fn record ->
        case get_field(record, :date) do
          date when is_binary(date) ->
            tokens = get_field(record, :tokens) || %{}

            [
              %{
                "date" => date,
                "cost" => number(get_field(record, :total_cost)),
                "requests" => sum_map_values(get_field(record, :requests) || %{}),
                "inputTokens" =>
                  tokens
                  |> Map.values()
                  |> Enum.map(&integer(get_field(&1, :input)))
                  |> Enum.sum(),
                "outputTokens" =>
                  tokens
                  |> Map.values()
                  |> Enum.map(&integer(get_field(&1, :output)))
                  |> Enum.sum()
              }
            ]

          _ ->
            []
        end
      end)
      |> Enum.sort_by(& &1["date"])

    %{
      providers: providers,
      models: models,
      sessions: top(all_sessions, @max_sessions),
      sessions_omitted: omitted + max(length(all_sessions) - @max_sessions, 0),
      daily: daily
    }
  end

  defp add_usage(acc, key, usage) do
    Map.update(acc, key, usage, fn current ->
      %{
        current
        | cost: current.cost + usage.cost,
          requests: current.requests + usage.requests,
          input: current.input + usage.input,
          output: current.output + usage.output
      }
    end)
  end

  defp usage_counts(usage) when is_map(usage) do
    %{
      cost: number(get_field(usage, :cost)),
      requests: integer(get_field(usage, :requests)),
      input: integer(get_field(usage, :input)),
      output: integer(get_field(usage, :output))
    }
  end

  defp usage_counts(_usage), do: %{cost: 0.0, requests: 0, input: 0, output: 0}

  defp usage_json(usage) do
    %{
      "cost" => usage.cost,
      "requests" => usage.requests,
      "inputTokens" => usage.input,
      "outputTokens" => usage.output
    }
  end

  defp top(rows, limit) do
    rows =
      Enum.sort_by(rows, &{&1["cost"], &1["inputTokens"] + &1["outputTokens"]}, :desc)

    if limit == :infinity, do: rows, else: Enum.take(rows, limit)
  end

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_value), do: 0.0

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  defp sum_map_values(map) do
    map
    |> Map.values()
    |> Enum.sum()
  end

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp format_date(ms) when is_integer(ms) do
    DateTime.from_unix!(ms, :millisecond)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end
