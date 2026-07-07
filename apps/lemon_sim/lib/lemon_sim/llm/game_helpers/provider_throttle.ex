defmodule LemonSim.LLM.GameHelpers.ProviderThrottle do
  @moduledoc false

  # Sane floor for always-on arenas so callers get spacing between requests
  # to the same provider without having to opt in explicitly. Zero under
  # `MIX_ENV=test` so the many game/example tests that stub `complete_fn`
  # with in-memory functions (no real HTTP call to space) don't pay for
  # throttling meant for real provider traffic.
  @default_provider_min_interval_ms if Code.ensure_loaded?(Mix) and Mix.env() == :test,
                                      do: 0,
                                      else: 500

  @doc """
  Wraps `opts[:complete_fn]` with per-provider request spacing.

  ## Options

    * `:provider_min_interval_ms` - a map of `provider => interval_ms` for
      explicit per-provider overrides (e.g. `%{google_gemini_cli: 5_000}`).
      A provider entry of `0` or `nil` disables throttling for that provider
      only. Passing `0` or `nil` directly (instead of a map) disables
      throttling entirely, regardless of `:default_provider_min_interval_ms`.
    * `:default_provider_min_interval_ms` - the interval applied to any
      provider not explicitly listed in `:provider_min_interval_ms`.
      Defaults to #{@default_provider_min_interval_ms}ms. Set to `0` or `nil`
      to only throttle providers explicitly listed.

  Returns `{opts, throttle_agent}` where `throttle_agent` is `nil` when
  throttling is fully disabled.
  """
  def wrap_opts(opts) when is_list(opts) do
    case resolve_intervals(opts) do
      :disabled ->
        {opts, nil}

      {default_interval_ms, provider_min_interval_ms} ->
        {:ok, throttle_agent} = Agent.start_link(fn -> %{} end)
        base_complete_fn = Keyword.get(opts, :complete_fn, &Ai.complete/3)

        throttled_complete_fn = fn model, context, stream_options ->
          wait(throttle_agent, model.provider, default_interval_ms, provider_min_interval_ms)
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

  defp resolve_intervals(opts) do
    default_interval_ms =
      opts
      |> Keyword.get(:default_provider_min_interval_ms, @default_provider_min_interval_ms)
      |> normalize_default_interval()

    case Keyword.get(opts, :provider_min_interval_ms, %{}) do
      value when is_map(value) ->
        provider_min_interval_ms = normalize_provider_intervals(value)

        if map_size(provider_min_interval_ms) == 0 and is_nil(default_interval_ms) do
          :disabled
        else
          {default_interval_ms, provider_min_interval_ms}
        end

      value when value in [0, nil] ->
        :disabled

      _other ->
        {default_interval_ms, %{}}
    end
  end

  defp normalize_default_interval(value) when is_integer(value) and value > 0, do: value
  defp normalize_default_interval(_), do: nil

  defp normalize_provider_intervals(intervals) when is_map(intervals) do
    Enum.reduce(intervals, %{}, fn
      {provider, interval_ms}, acc when is_integer(interval_ms) and interval_ms >= 0 ->
        Map.put(acc, normalize_provider_key(provider), interval_ms)

      {provider, nil}, acc ->
        Map.put(acc, normalize_provider_key(provider), 0)

      _, acc ->
        acc
    end)
  end

  defp normalize_provider_intervals(_), do: %{}

  defp wait(throttle_agent, provider, default_interval_ms, provider_min_interval_ms) do
    provider_key = normalize_provider_key(provider)

    interval_ms =
      case Map.fetch(provider_min_interval_ms, provider_key) do
        {:ok, value} -> value
        :error -> default_interval_ms
      end

    do_wait(throttle_agent, provider_key, interval_ms)
  end

  defp do_wait(throttle_agent, provider_key, interval_ms)
       when is_integer(interval_ms) and interval_ms > 0 do
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
  end

  defp do_wait(_throttle_agent, _provider_key, _interval_ms), do: :ok

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
