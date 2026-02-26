defmodule LemonControlPlane.Methods.UsageCost do
  @moduledoc """
  Handler for the usage.cost control plane method.

  Returns cost breakdown for a specified time period.

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

  ## Recording Usage

  Use `LemonControlPlane.Methods.UsageCost.record_usage/1` to record usage:

  ```elixir
  UsageCost.record_usage(%{
    provider: "claude",
    cost: 0.05,
    input_tokens: 500,
    output_tokens: 200
  })
  ```
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "usage.cost"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    start_date = params["startDate"] || params["start_date"]
    end_date = params["endDate"] || params["end_date"]
    group_by = params["groupBy"] || params["group_by"] || "day"

    # Parse dates or use defaults
    {start_ms, end_ms} = parse_date_range(start_date, end_date)

    # Calculate costs for the period
    costs = calculate_costs(start_ms, end_ms, group_by)

    result = %{
      "startDate" => format_date(start_ms),
      "endDate" => format_date(end_ms),
      "totalCost" => costs.total,
      "breakdown" => costs.breakdown,
      "totalRequests" => costs.total_requests,
      "totalTokens" => costs.total_tokens
    }

    # Add daily breakdown if grouped by day
    result =
      if group_by == "day" and map_size(costs.daily) > 0 do
        Map.put(result, "daily", costs.daily)
      else
        result
      end

    {:ok, result}
  end

  @doc """
  Record a usage event for cost tracking.

  ## Options

  - `:provider` - Provider name (e.g., "claude", "openai")
  - `:cost` - Cost in USD
  - `:input_tokens` - Number of input tokens
  - `:output_tokens` - Number of output tokens
  - `:model` - Optional model name
  """
  @spec record_usage(map()) :: :ok
  def record_usage(usage) do
    provider = usage[:provider] || usage["provider"] || "other"
    cost = usage[:cost] || usage["cost"] || 0.0
    input_tokens = usage[:input_tokens] || usage["input_tokens"] || 0
    output_tokens = usage[:output_tokens] || usage["output_tokens"] || 0

    # Get today's date key
    date_key = Date.utc_today() |> Date.to_iso8601()

    # Get or create today's record
    record = LemonCore.Store.get(:usage_records, date_key) || %{
      date: date_key,
      total_cost: 0.0,
      breakdown: %{},
      requests: %{},
      tokens: %{}
    }

    # Update totals
    record = %{record |
      total_cost: (get_field(record, :total_cost) || 0.0) + cost,
      breakdown: update_breakdown(get_field(record, :breakdown) || %{}, provider, cost),
      requests: update_count(get_field(record, :requests) || %{}, provider, 1),
      tokens: update_tokens(get_field(record, :tokens) || %{}, provider, input_tokens, output_tokens)
    }

    # Store updated record
    LemonCore.Store.put(:usage_records, date_key, record)

    # Also update the current summary for quick access
    update_current_summary(provider, cost, input_tokens, output_tokens)

    :ok
  end

  defp update_breakdown(breakdown, provider, cost) do
    current = get_field(breakdown, provider) || 0.0
    Map.put(breakdown, provider, current + cost)
  end

  defp update_count(counts, provider, delta) do
    current = get_field(counts, provider) || 0
    Map.put(counts, provider, current + delta)
  end

  defp update_tokens(tokens, provider, input, output) do
    current = get_field(tokens, provider) || %{input: 0, output: 0}
    current_input = get_field(current, :input) || 0
    current_output = get_field(current, :output) || 0
    Map.put(tokens, provider, %{input: current_input + input, output: current_output + output})
  end

  defp update_current_summary(provider, cost, input_tokens, output_tokens) do
    summary = LemonCore.Store.get(:usage_data, :current) || %{
      total_cost: 0.0,
      breakdown: %{},
      total_requests: 0,
      total_tokens: %{input: 0, output: 0}
    }

    updated = %{summary |
      total_cost: (get_field(summary, :total_cost) || 0.0) + cost,
      breakdown: update_breakdown(get_field(summary, :breakdown) || %{}, provider, cost),
      total_requests: (get_field(summary, :total_requests) || 0) + 1,
      total_tokens: %{
        input: (get_in_field(summary, [:total_tokens, :input]) || 0) + input_tokens,
        output: (get_in_field(summary, [:total_tokens, :output]) || 0) + output_tokens
      }
    }

    LemonCore.Store.put(:usage_data, :current, updated)
  end

  defp parse_date_range(nil, nil) do
    # Default to last 30 days
    now = System.system_time(:millisecond)
    thirty_days_ago = now - 30 * 24 * 60 * 60 * 1000
    {thirty_days_ago, now}
  end

  defp parse_date_range(start_str, end_str) do
    start_ms = parse_date_string(start_str) || (System.system_time(:millisecond) - 30 * 24 * 60 * 60 * 1000)
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

  defp calculate_costs(start_ms, end_ms, group_by) do
    start_date = DateTime.from_unix!(start_ms, :millisecond) |> DateTime.to_date()
    end_date = DateTime.from_unix!(end_ms, :millisecond) |> DateTime.to_date()

    # Get all date keys in range
    date_keys = generate_date_range(start_date, end_date)

    # Fetch records for each date
    records = Enum.flat_map(date_keys, fn date_key ->
      case LemonCore.Store.get(:usage_records, date_key) do
        nil -> []
        record -> [record]
      end
    end)

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
        breakdown = Enum.reduce(record_breakdown, acc.breakdown, fn {provider, cost}, b ->
          Map.update(b, provider, cost, &(&1 + cost))
        end)

        # Sum requests
        total_requests = acc.total_requests + sum_map_values(record_requests)

        # Sum tokens
        total_tokens = Enum.reduce(record_tokens, acc.total_tokens, fn {_provider, tokens}, t ->
          %{
            input: t.input + (get_field(tokens, :input) || 0),
            output: t.output + (get_field(tokens, :output) || 0)
          }
        end)

        # Add to daily if grouping by day
        daily = if group_by == "day" and record_date do
          Map.put(acc.daily, record_date, %{
            "cost" => record_cost,
            "requests" => sum_map_values(record_requests),
            "breakdown" => record_breakdown
          })
        else
          acc.daily
        end

        %{acc |
          total: total,
          breakdown: breakdown,
          total_requests: total_requests,
          total_tokens: total_tokens,
          daily: daily
        }
      end)
    end
  end

  defp generate_date_range(start_date, end_date) do
    Date.range(start_date, end_date)
    |> Enum.map(&Date.to_iso8601/1)
  end

  defp sum_map_values(map) do
    map
    |> Map.values()
    |> Enum.sum()
  end

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp get_field(map, key) when is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  defp get_in_field(map, [key | rest]) do
    value = get_field(map, key)
    if rest == [] do
      value
    else
      if is_map(value), do: get_in_field(value, rest), else: nil
    end
  end

  defp format_date(ms) when is_integer(ms) do
    DateTime.from_unix!(ms, :millisecond)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp format_date(_), do: nil
end
