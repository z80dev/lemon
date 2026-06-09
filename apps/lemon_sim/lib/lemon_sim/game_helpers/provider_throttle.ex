defmodule LemonSim.GameHelpers.ProviderThrottle do
  @moduledoc false

  def wrap_opts(opts) when is_list(opts) do
    provider_min_interval_ms =
      opts
      |> Keyword.get(:provider_min_interval_ms, %{})
      |> normalize_provider_intervals()

    if map_size(provider_min_interval_ms) == 0 do
      {opts, nil}
    else
      {:ok, throttle_agent} = Agent.start_link(fn -> %{} end)
      base_complete_fn = Keyword.get(opts, :complete_fn, &Ai.complete/3)

      throttled_complete_fn = fn model, context, stream_options ->
        wait(throttle_agent, model.provider, provider_min_interval_ms)
        base_complete_fn.(model, context, stream_options)
      end

      {Keyword.put(opts, :complete_fn, throttled_complete_fn), throttle_agent}
    end
  end

  def stop(nil), do: :ok

  def stop(agent) when is_pid(agent) do
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  defp normalize_provider_intervals(intervals) when is_map(intervals) do
    Enum.reduce(intervals, %{}, fn
      {provider, interval_ms}, acc when is_integer(interval_ms) and interval_ms > 0 ->
        Map.put(acc, normalize_provider_key(provider), interval_ms)

      _, acc ->
        acc
    end)
  end

  defp normalize_provider_intervals(_), do: %{}

  defp wait(throttle_agent, provider, provider_min_interval_ms) do
    provider_key = normalize_provider_key(provider)

    case Map.get(provider_min_interval_ms, provider_key) do
      interval_ms when is_integer(interval_ms) and interval_ms > 0 ->
        now_ms = System.monotonic_time(:millisecond)

        wait_ms =
          Agent.get_and_update(throttle_agent, fn state ->
            next_allowed_at = Map.get(state, provider_key, now_ms)
            wait_ms = max(next_allowed_at - now_ms, 0)
            scheduled_at = max(now_ms, next_allowed_at) + interval_ms
            {wait_ms, Map.put(state, provider_key, scheduled_at)}
          end)

        if wait_ms > 0, do: Process.sleep(wait_ms)
        :ok

      _ ->
        :ok
    end
  end

  defp normalize_provider_key(provider) when is_atom(provider), do: provider

  defp normalize_provider_key(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_provider_key(provider), do: provider
end
