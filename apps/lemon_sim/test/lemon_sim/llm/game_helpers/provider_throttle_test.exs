defmodule LemonSim.LLM.GameHelpers.ProviderThrottleTest do
  use ExUnit.Case, async: true

  alias Ai.Types.{AssistantMessage, Context, Model}
  alias LemonSim.LLM.GameHelpers.ProviderThrottle

  test "applies a default per-provider interval when none is configured" do
    complete_fn = fn model, _ctx, _stream_opts -> {:ok, ok_message(model)} end

    {opts, throttle_agent} =
      ProviderThrottle.wrap_opts(
        complete_fn: complete_fn,
        default_provider_min_interval_ms: 40
      )

    assert is_pid(throttle_agent)
    throttled = Keyword.fetch!(opts, :complete_fn)

    start = System.monotonic_time(:millisecond)
    {:ok, _} = throttled.(fake_model(:anthropic), Context.new(), %{})
    {:ok, _} = throttled.(fake_model(:anthropic), Context.new(), %{})
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed >= 35

    ProviderThrottle.stop(throttle_agent)
  end

  test "per-provider override wins over the default interval" do
    complete_fn = fn model, _ctx, _stream_opts -> {:ok, ok_message(model)} end

    {opts, throttle_agent} =
      ProviderThrottle.wrap_opts(
        complete_fn: complete_fn,
        default_provider_min_interval_ms: 5,
        provider_min_interval_ms: %{zai: 60}
      )

    throttled = Keyword.fetch!(opts, :complete_fn)

    start = System.monotonic_time(:millisecond)
    {:ok, _} = throttled.(fake_model(:zai), Context.new(), %{})
    {:ok, _} = throttled.(fake_model(:zai), Context.new(), %{})
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed >= 55

    ProviderThrottle.stop(throttle_agent)
  end

  test "a provider explicitly set to 0 skips throttling even under a default" do
    complete_fn = fn model, _ctx, _stream_opts -> {:ok, ok_message(model)} end

    {opts, throttle_agent} =
      ProviderThrottle.wrap_opts(
        complete_fn: complete_fn,
        default_provider_min_interval_ms: 200,
        provider_min_interval_ms: %{zai: 0}
      )

    throttled = Keyword.fetch!(opts, :complete_fn)

    start = System.monotonic_time(:millisecond)
    {:ok, _} = throttled.(fake_model(:zai), Context.new(), %{})
    {:ok, _} = throttled.(fake_model(:zai), Context.new(), %{})
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed < 150

    ProviderThrottle.stop(throttle_agent)
  end

  test "passing 0 for provider_min_interval_ms disables throttling entirely" do
    complete_fn = fn model, _ctx, _stream_opts -> {:ok, ok_message(model)} end

    {opts, throttle_agent} =
      ProviderThrottle.wrap_opts(
        complete_fn: complete_fn,
        default_provider_min_interval_ms: 500,
        provider_min_interval_ms: 0
      )

    assert throttle_agent == nil
    # opts pass through untouched (no throttle wrapper installed)
    assert Keyword.fetch!(opts, :complete_fn) == complete_fn
  end

  test "passing nil for provider_min_interval_ms disables throttling entirely" do
    complete_fn = fn model, _ctx, _stream_opts -> {:ok, ok_message(model)} end

    {opts, throttle_agent} =
      ProviderThrottle.wrap_opts(
        complete_fn: complete_fn,
        default_provider_min_interval_ms: 500,
        provider_min_interval_ms: nil
      )

    assert throttle_agent == nil
    assert Keyword.fetch!(opts, :complete_fn) == complete_fn
  end

  test "setting default_provider_min_interval_ms to 0 leaves unlisted providers unthrottled" do
    complete_fn = fn model, _ctx, _stream_opts -> {:ok, ok_message(model)} end

    {opts, throttle_agent} =
      ProviderThrottle.wrap_opts(
        complete_fn: complete_fn,
        default_provider_min_interval_ms: 0,
        provider_min_interval_ms: %{zai: 60}
      )

    assert is_pid(throttle_agent)
    throttled = Keyword.fetch!(opts, :complete_fn)

    start = System.monotonic_time(:millisecond)
    {:ok, _} = throttled.(fake_model(:anthropic), Context.new(), %{})
    {:ok, _} = throttled.(fake_model(:anthropic), Context.new(), %{})
    elapsed = System.monotonic_time(:millisecond) - start

    assert elapsed < 55

    ProviderThrottle.stop(throttle_agent)
  end

  defp ok_message(%Model{}) do
    %AssistantMessage{role: :assistant, content: [], stop_reason: :stop}
  end

  defp fake_model(provider) do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: provider,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end
end
