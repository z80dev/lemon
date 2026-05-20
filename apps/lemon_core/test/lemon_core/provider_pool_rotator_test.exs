defmodule LemonCore.ProviderPoolRotatorTest do
  use ExUnit.Case, async: false

  test "priority strategy preserves configured ordering" do
    providers = ["openai", "zai", "anthropic"]

    assert LemonCore.ProviderPoolRotator.ordered_providers(:priority_test, providers, "priority") ==
             providers

    assert LemonCore.ProviderPoolRotator.ordered_providers(:priority_test, providers, "priority") ==
             providers
  end

  test "round_robin strategy rotates per key" do
    providers = ["openai", "zai", "anthropic"]
    key = {:round_robin_test, System.unique_integer([:positive])}

    assert LemonCore.ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["openai", "zai", "anthropic"]

    assert LemonCore.ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["zai", "anthropic", "openai"]

    assert LemonCore.ProviderPoolRotator.ordered_providers(key, providers, "round_robin") ==
             ["anthropic", "openai", "zai"]
  end
end
