defmodule LemonCore.UsageDiagnostics do
  @moduledoc """
  Redacted aggregate usage diagnostics for operator surfaces.

  Numeric values are legacy aggregate subtotals, not per-response measurements.
  Empty aggregates start at zero; explicit unknown values remain nil, including
  totals derived from unknown components. A quota cannot be declared satisfied
  when its aggregate is unknown.
  """

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    summary =
      (Keyword.get(opts, :summary) || LemonCore.UsageStore.get_summary(:current) || %{})
      |> current_day_summary()

    today =
      Keyword.get(opts, :today) ||
        LemonCore.UsageStore.get_record(Date.to_iso8601(Date.utc_today())) ||
        %{}

    tokens = token_summary(map_get(summary, :total_tokens, %{}))
    total_requests = int(map_get(summary, :total_requests, 0), nil)
    total_cost = number(map_get(summary, :total_cost, 0.0), nil)
    providers = provider_summaries(summary)
    quotas = Keyword.get(opts, :quotas) || quotas()

    %{
      status: limit_status(total_requests, tokens.total, total_cost, quotas),
      period: "current",
      total_cost: total_cost,
      total_requests: total_requests,
      total_tokens: tokens,
      provider_count: length(providers),
      providers: providers,
      today: daily_summary(today),
      quotas: quotas,
      cleanup: cleanup()
    }
  rescue
    error ->
      unavailable(Exception.message(error))
  catch
    kind, reason ->
      unavailable(inspect({kind, reason}))
  end

  # `LemonCore.UsageLedger` dates the `:current` summary and restarts it each
  # UTC day; a summary left from an earlier day means nothing ran today.
  defp current_day_summary(summary) when is_map(summary) do
    case map_get(summary, :date) do
      nil -> summary
      date -> if date == Date.to_iso8601(Date.utc_today()), do: summary, else: %{}
    end
  end

  defp current_day_summary(_summary), do: %{}

  defp unavailable(error) do
    %{
      status: "unknown",
      period: "current",
      total_cost: nil,
      total_requests: nil,
      total_tokens: %{input: nil, output: nil, total: nil},
      provider_count: 0,
      providers: [],
      today: %{date: Date.to_iso8601(Date.utc_today()), cost: nil, requests: nil},
      quotas: quotas(),
      cleanup: cleanup(),
      error: error
    }
  end

  defp provider_summaries(summary) do
    breakdown = map_get(summary, :breakdown, %{}) || %{}
    requests = map_get(summary, :requests, %{}) || %{}
    tokens = map_get(summary, :tokens, %{}) || %{}

    [breakdown, requests, tokens]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn provider ->
      provider_tokens = usage_get(tokens, provider, %{})
      provider_token_totals = token_summary(provider_tokens)

      %{
        provider: provider,
        cost: number(usage_get(breakdown, provider, 0.0), nil),
        requests: int(usage_get(requests, provider, 0), nil),
        input_tokens: provider_token_totals.input,
        output_tokens: provider_token_totals.output
      }
    end)
  end

  defp daily_summary(record) when is_map(record) do
    requests = map_get(record, :requests, %{})

    %{
      date: map_get(record, :date) || Date.to_iso8601(Date.utc_today()),
      cost: number(map_get(record, :total_cost, 0.0), nil),
      requests: sum_values(requests)
    }
  end

  defp daily_summary(_),
    do: %{date: Date.to_iso8601(Date.utc_today()), cost: 0.0, requests: 0}

  defp token_summary(tokens) when is_map(tokens) do
    input = int(map_get(tokens, :input, 0), nil)
    output = int(map_get(tokens, :output, 0), nil)
    %{input: input, output: output, total: add_known(input, output)}
  end

  defp token_summary(_), do: %{input: nil, output: nil, total: nil}

  defp quotas do
    %{
      runs_limit: Application.get_env(:lemon_control_plane, :runs_limit),
      tokens_limit: Application.get_env(:lemon_control_plane, :tokens_limit),
      cost_limit: Application.get_env(:lemon_control_plane, :cost_limit)
    }
  end

  defp limit_status(runs, tokens, cost, quotas) do
    checks = [
      limit_check(runs, quotas.runs_limit),
      limit_check(tokens, quotas.tokens_limit),
      limit_check(cost, quotas.cost_limit)
    ]

    cond do
      :over in checks -> "over_limit"
      :unknown in checks -> "unknown"
      :within in checks -> "within_limits"
      true -> "unlimited"
    end
  end

  defp limit_check(_value, limit) when not is_number(limit), do: :unconfigured
  defp limit_check(value, _limit) when not is_number(value), do: :unknown
  defp limit_check(value, limit) when value > limit, do: :over
  defp limit_check(_value, _limit), do: :within

  defp sum_values(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.reduce(0, fn value, total -> add_known(total, int(value, nil)) end)
  end

  defp sum_values(_), do: nil

  defp add_known(left, right) when is_number(left) and is_number(right), do: left + right
  defp add_known(_left, _right), do: nil

  defp usage_get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> usage_get_existing_atom(map, key, default)
    end
  end

  defp usage_get(map, key, default), do: map_get(map, key, default)

  defp usage_get_existing_atom(map, key, default) do
    Map.get(map, String.to_existing_atom(key), default)
  rescue
    ArgumentError -> default
  end

  defp int(value, _default) when is_integer(value), do: value
  defp int(value, _default) when is_float(value), do: trunc(value)
  defp int(_value, default), do: default

  defp number(value, _default) when is_integer(value), do: value * 1.0
  defp number(value, _default) when is_float(value), do: value
  defp number(_value, default), do: default

  defp cleanup do
    %{
      includes_prompts: false,
      includes_responses: false,
      includes_message_bodies: false,
      includes_credentials: false,
      includes_secret_values: false
    }
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(map, key, default) when is_map(map), do: Map.get(map, key, default)
  defp map_get(_map, _key, default), do: default
end
