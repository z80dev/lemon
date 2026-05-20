defmodule LemonCore.UsageDiagnostics do
  @moduledoc """
  Redacted aggregate usage diagnostics for operator surfaces.
  """

  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    summary = Keyword.get(opts, :summary) || LemonCore.UsageStore.get_summary(:current) || %{}

    today =
      Keyword.get(opts, :today) ||
        LemonCore.UsageStore.get_record(Date.to_iso8601(Date.utc_today())) ||
        %{}

    tokens = token_summary(map_get(summary, :total_tokens, %{}))
    total_requests = int(map_get(summary, :total_requests), 0)
    total_cost = number(map_get(summary, :total_cost), 0.0)
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

  defp unavailable(error) do
    %{
      status: "unknown",
      period: "current",
      total_cost: 0.0,
      total_requests: 0,
      total_tokens: %{input: 0, output: 0, total: 0},
      provider_count: 0,
      providers: [],
      today: %{date: Date.to_iso8601(Date.utc_today()), cost: 0.0, requests: 0},
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
      provider_tokens = usage_get(tokens, provider, %{}) || %{}

      %{
        provider: provider,
        cost: number(usage_get(breakdown, provider), 0.0),
        requests: int(usage_get(requests, provider), 0),
        input_tokens: int(map_get(provider_tokens, :input), 0),
        output_tokens: int(map_get(provider_tokens, :output), 0)
      }
    end)
  end

  defp daily_summary(record) when is_map(record) do
    requests = map_get(record, :requests, %{}) || %{}

    %{
      date: map_get(record, :date) || Date.to_iso8601(Date.utc_today()),
      cost: number(map_get(record, :total_cost), 0.0),
      requests: sum_values(requests)
    }
  end

  defp daily_summary(_),
    do: %{date: Date.to_iso8601(Date.utc_today()), cost: 0.0, requests: 0}

  defp token_summary(tokens) when is_map(tokens) do
    input = int(map_get(tokens, :input), 0)
    output = int(map_get(tokens, :output), 0)
    %{input: input, output: output, total: input + output}
  end

  defp token_summary(_), do: %{input: 0, output: 0, total: 0}

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
      :within in checks -> "within_limits"
      true -> "unlimited"
    end
  end

  defp limit_check(_value, limit) when not is_number(limit), do: :unconfigured
  defp limit_check(value, limit) when value > limit, do: :over
  defp limit_check(_value, _limit), do: :within

  defp sum_values(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.map(&int(&1, 0))
    |> Enum.sum()
  end

  defp sum_values(_), do: 0

  defp usage_get(map, key, default \\ nil)

  defp usage_get(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key) || usage_get_existing_atom(map, key, default)
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
