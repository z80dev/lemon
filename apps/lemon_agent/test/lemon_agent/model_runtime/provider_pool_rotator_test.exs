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

  test "single provider pools skip rotation" do
    key = {:single_test, System.unique_integer([:positive])}

    assert ProviderPoolRotator.ordered_providers(key, ["openai"], "round_robin") == ["openai"]
    assert ProviderPoolRotator.ordered_providers(key, ["openai"], "round_robin") == ["openai"]
  end
end
