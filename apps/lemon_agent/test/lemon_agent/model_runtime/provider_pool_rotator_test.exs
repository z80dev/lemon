defmodule LemonAgent.ModelRuntime.ProviderPoolRotatorTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.ProviderPoolRotator

  test "priority strategy preserves configured ordering" do
    providers = ["openai", "zai", "anthropic"]

    assert ProviderPoolRotator.ordered_providers(:priority_test, providers, "priority") ==
             providers

    assert ProviderPoolRotator.ordered_providers(:priority_test, providers, "priority") ==
             providers
  end

  test "round_robin strategy rotates per key" do
    providers = ["openai", "zai", "anthropic"]
    key = {:round_robin_test, System.unique_integer([:positive])}

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["openai", "zai", "anthropic"]

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["zai", "anthropic", "openai"]

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["anthropic", "openai", "zai"]
  end

  test "session scopes claim a slot once and keep it" do
    providers = ["openai", "zai", "anthropic"]
    key = {:session_scope_test, System.unique_integer([:positive])}

    first_a =
      ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
        session_scope: "sess-a"
      )

    first_b =
      ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
        session_scope: "sess-b"
      )

    assert first_a == ["openai", "zai", "anthropic"]
    assert first_b == ["zai", "anthropic", "openai"]

    # Repeated resolutions for the same session keep hitting the same slot.
    for _ <- 1..3 do
      assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
               session_scope: "sess-a"
             ) == first_a

      assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
               session_scope: "sess-b"
             ) == first_b
    end
  end

  test "global scope keeps advancing around pinned sessions" do
    providers = ["openai", "zai"]
    key = {:mixed_scope_test, System.unique_integer([:positive])}

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["openai", "zai"]

    pinned =
      ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
        session_scope: "sess-a"
      )

    assert pinned == ["zai", "openai"]

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["openai", "zai"]

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
             session_scope: "sess-a"
           ) == pinned
  end

  test "idle session assignments are pruned by the periodic sweep" do
    providers = ["openai", "zai", "anthropic"]
    key = {:sweep_test, System.unique_integer([:positive])}

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
             session_scope: "sess-idle"
           ) == providers

    pid = Process.whereis(ProviderPoolRotator)
    assert Map.has_key?(:sys.get_state(pid).assignments, {key, "sess-idle"})

    # Age every assignment past the TTL, then trigger the sweep directly.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | assignments: Map.new(state.assignments, fn {k, {offset, _ts}} -> {k, {offset, 0}} end)
      }
    end)

    send(pid, :sweep)

    refute Map.has_key?(:sys.get_state(pid).assignments, {key, "sess-idle"})

    # A pruned session simply claims a fresh slot on its next resolution.
    assert is_list(
             ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
               session_scope: "sess-idle"
             )
           )

    assert Map.has_key?(:sys.get_state(pid).assignments, {key, "sess-idle"})
  end

  test "active session assignments refresh their last-used timestamp" do
    providers = ["openai", "zai"]
    key = {:refresh_test, System.unique_integer([:positive])}

    first =
      ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
        session_scope: "sess-active"
      )

    pid = Process.whereis(ProviderPoolRotator)
    {_offset, ts1} = :sys.get_state(pid).assignments[{key, "sess-active"}]

    Process.sleep(5)

    assert ProviderPoolRotator.ordered_providers(key, providers, "round_robin",
             session_scope: "sess-active"
           ) == first

    {_offset, ts2} = :sys.get_state(pid).assignments[{key, "sess-active"}]
    assert ts2 > ts1
  end

  test "single provider pools skip rotation" do
    key = {:single_test, System.unique_integer([:positive])}

    assert ProviderPoolRotator.ordered_providers(key, ["openai"], "round_robin") == ["openai"]
    assert ProviderPoolRotator.ordered_providers(key, ["openai"], "round_robin") == ["openai"]
  end
end
