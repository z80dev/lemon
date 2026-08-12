defmodule LemonAgent.ModelRuntime.CredentialHealthTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.CredentialHealth

  setup do
    CredentialHealth.reset()
    on_exit(fn -> CredentialHealth.reset() end)
    :ok
  end

  test "no recorded state means no cooldown" do
    refute CredentialHealth.in_cooldown?(:openai, "default")
    assert CredentialHealth.cooldown_until(:openai, "default") == nil
  end

  test "a failure starts a cooldown and success clears it" do
    CredentialHealth.record_failure(:openai, "secret:key_a", :auth)

    assert CredentialHealth.in_cooldown?(:openai, "secret:key_a")
    refute CredentialHealth.in_cooldown?(:openai, "secret:key_b")

    CredentialHealth.record_success(:openai, "secret:key_a")
    refute CredentialHealth.in_cooldown?(:openai, "secret:key_a")
  end

  test "provider names normalize to the same key" do
    CredentialHealth.record_failure("openai-codex", "default", :auth)

    assert CredentialHealth.in_cooldown?(:openai_codex, "default")
    assert CredentialHealth.in_cooldown?("openai_codex", "default")
  end

  test "repeated failures back off exponentially per category" do
    CredentialHealth.record_failure(:openai, "default", :transient)
    first = CredentialHealth.cooldown_until(:openai, "default")

    CredentialHealth.record_failure(:openai, "default", :transient)
    second = CredentialHealth.cooldown_until(:openai, "default")

    CredentialHealth.record_failure(:openai, "default", :transient)
    third = CredentialHealth.cooldown_until(:openai, "default")

    assert second > first
    assert third > second
  end

  test "auth cooldowns are much longer than transient ones" do
    CredentialHealth.record_failure(:openai, "auth_ref", :auth)
    CredentialHealth.record_failure(:openai, "transient_ref", :transient)

    auth_until = CredentialHealth.cooldown_until(:openai, "auth_ref")
    transient_until = CredentialHealth.cooldown_until(:openai, "transient_ref")

    now = System.monotonic_time(:millisecond)
    assert auth_until - now >= 60_000
    assert transient_until - now < 60_000
  end

  test "rate limit failures honor retry_after_ms" do
    CredentialHealth.record_failure(:openai, "default", :rate_limit, retry_after_ms: 40)

    assert CredentialHealth.in_cooldown?(:openai, "default")
    Process.sleep(60)
    refute CredentialHealth.in_cooldown?(:openai, "default")
  end

  test "rate limit failures without retry_after use backoff" do
    CredentialHealth.record_failure(:openai, "default", :rate_limit)

    until_ms = CredentialHealth.cooldown_until(:openai, "default")
    assert until_ms - System.monotonic_time(:millisecond) > 5_000
  end

  test "success resets the backoff progression" do
    CredentialHealth.record_failure(:openai, "default", :transient)
    CredentialHealth.record_failure(:openai, "default", :transient)
    CredentialHealth.record_success(:openai, "default")

    CredentialHealth.record_failure(:openai, "default", :transient)
    fresh = CredentialHealth.cooldown_until(:openai, "default")

    # A fresh first failure gets the base window, not the escalated one.
    assert fresh - System.monotonic_time(:millisecond) <= 2_000
  end
end
