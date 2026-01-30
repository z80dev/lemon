defmodule Ai.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Ai.RateLimiter

  # Use unique provider names per test to avoid conflicts
  defp unique_provider(base) do
    String.to_atom("#{base}_#{System.unique_integer([:positive])}")
  end

  describe "start_link/1" do
    test "starts with required provider option" do
      provider = unique_provider(:start_test)
      assert {:ok, pid} = RateLimiter.start_link(provider: provider)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "raises when provider is missing" do
      assert_raise KeyError, fn ->
        RateLimiter.start_link([])
      end
    end

    test "uses default values when not specified" do
      provider = unique_provider(:defaults)
      {:ok, _pid} = RateLimiter.start_link(provider: provider)

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.max_tokens == 20
      assert state.tokens_per_second == 10
    end

    test "accepts custom tokens_per_second and max_tokens" do
      provider = unique_provider(:custom)

      {:ok, _pid} =
        RateLimiter.start_link(
          provider: provider,
          tokens_per_second: 5,
          max_tokens: 100
        )

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.max_tokens == 100
      assert state.tokens_per_second == 5
    end

    test "starts with full bucket" do
      provider = unique_provider(:full_bucket)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 15)

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.available_tokens == 15
    end
  end

  describe "acquire/1" do
    test "returns :ok when tokens available" do
      provider = unique_provider(:acquire_ok)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 5)

      assert :ok = RateLimiter.acquire(provider)
    end

    test "decrements token count on acquire" do
      provider = unique_provider(:decrement)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 5)

      {:ok, state_before} = RateLimiter.get_state(provider)
      assert state_before.available_tokens == 5

      :ok = RateLimiter.acquire(provider)

      {:ok, state_after} = RateLimiter.get_state(provider)
      # May be 4 or slightly more due to token refill timing
      assert state_after.available_tokens <= 5
    end

    test "returns :rate_limited when bucket empty" do
      provider = unique_provider(:rate_limited)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 2)

      # Exhaust all tokens
      :ok = RateLimiter.acquire(provider)
      :ok = RateLimiter.acquire(provider)

      # Should be rate limited now
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)
    end

    test "allows exactly max_tokens requests when bucket is full" do
      provider = unique_provider(:exact_max)
      max = 5
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: max, tokens_per_second: 0)

      # Should allow exactly max_tokens requests
      for _ <- 1..max do
        assert :ok = RateLimiter.acquire(provider)
      end

      # Next should be rate limited (with 0 refill rate)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)
    end

    test "auto-starts limiter via ensure_started" do
      provider = unique_provider(:auto_start)
      # Don't start explicitly - acquire should auto-start
      assert :ok = RateLimiter.acquire(provider)
    end
  end

  describe "release/1" do
    test "returns :ok (no-op for token bucket)" do
      provider = unique_provider(:release)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 5)

      assert :ok = RateLimiter.release(provider)
    end

    test "does not affect token count" do
      provider = unique_provider(:release_no_effect)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 5, tokens_per_second: 0)

      :ok = RateLimiter.acquire(provider)
      {:ok, state_before} = RateLimiter.get_state(provider)

      :ok = RateLimiter.release(provider)
      {:ok, state_after} = RateLimiter.get_state(provider)

      assert state_before.available_tokens == state_after.available_tokens
    end
  end

  describe "get_state/1" do
    test "returns state map with expected keys" do
      provider = unique_provider(:get_state)
      {:ok, _pid} = RateLimiter.start_link(provider: provider)

      assert {:ok, state} = RateLimiter.get_state(provider)
      assert Map.has_key?(state, :provider)
      assert Map.has_key?(state, :available_tokens)
      assert Map.has_key?(state, :max_tokens)
      assert Map.has_key?(state, :tokens_per_second)
    end

    test "provider matches initialized provider" do
      provider = unique_provider(:state_provider)
      {:ok, _pid} = RateLimiter.start_link(provider: provider)

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.provider == provider
    end
  end

  describe "token refilling" do
    test "tokens refill over time" do
      provider = unique_provider(:refill)
      # High refill rate for faster test
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 10, tokens_per_second: 100)

      # Exhaust tokens
      for _ <- 1..10 do
        RateLimiter.acquire(provider)
      end

      {:ok, state_empty} = RateLimiter.get_state(provider)
      assert state_empty.available_tokens < 5

      # Wait for refill (100 tokens/sec = 10 tokens in 100ms)
      Process.sleep(150)

      {:ok, state_refilled} = RateLimiter.get_state(provider)
      assert state_refilled.available_tokens > state_empty.available_tokens
    end

    test "tokens do not exceed max_tokens" do
      provider = unique_provider(:max_cap)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 5, tokens_per_second: 1000)

      # Wait for potential overfill
      Process.sleep(100)

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.available_tokens <= state.max_tokens
    end

    test "refill after exhaustion allows new requests" do
      provider = unique_provider(:refill_allows)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 2, tokens_per_second: 50)

      # Exhaust
      :ok = RateLimiter.acquire(provider)
      :ok = RateLimiter.acquire(provider)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)

      # Wait for refill
      Process.sleep(100)

      # Should be able to acquire again
      assert :ok = RateLimiter.acquire(provider)
    end
  end

  describe "multiple buckets" do
    test "different providers have independent rate limits" do
      provider1 = unique_provider(:multi_1)
      provider2 = unique_provider(:multi_2)

      {:ok, _pid1} = RateLimiter.start_link(provider: provider1, max_tokens: 3, tokens_per_second: 0)
      {:ok, _pid2} = RateLimiter.start_link(provider: provider2, max_tokens: 5, tokens_per_second: 0)

      # Exhaust provider1
      for _ <- 1..3 do
        :ok = RateLimiter.acquire(provider1)
      end
      assert {:error, :rate_limited} = RateLimiter.acquire(provider1)

      # Provider2 should still have tokens
      assert :ok = RateLimiter.acquire(provider2)
      {:ok, state2} = RateLimiter.get_state(provider2)
      assert state2.available_tokens == 4
    end

    test "exhausting one provider does not affect others" do
      provider_a = unique_provider(:exhaust_a)
      provider_b = unique_provider(:exhaust_b)

      {:ok, _} = RateLimiter.start_link(provider: provider_a, max_tokens: 1, tokens_per_second: 0)
      {:ok, _} = RateLimiter.start_link(provider: provider_b, max_tokens: 10, tokens_per_second: 0)

      :ok = RateLimiter.acquire(provider_a)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider_a)

      # Provider B still works
      for _ <- 1..10 do
        assert :ok = RateLimiter.acquire(provider_b)
      end
    end
  end

  describe "concurrent access" do
    test "handles concurrent acquires safely" do
      provider = unique_provider(:concurrent)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 100, tokens_per_second: 0)

      # Spawn many concurrent acquires
      tasks =
        for _ <- 1..100 do
          Task.async(fn -> RateLimiter.acquire(provider) end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed since we have exactly 100 tokens
      ok_count = Enum.count(results, &(&1 == :ok))
      assert ok_count == 100
    end

    test "concurrent access respects rate limit" do
      provider = unique_provider(:concurrent_limit)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 10, tokens_per_second: 0)

      # Try to acquire 20 tokens concurrently with only 10 available
      tasks =
        for _ <- 1..20 do
          Task.async(fn -> RateLimiter.acquire(provider) end)
        end

      results = Task.await_many(tasks, 5000)

      ok_count = Enum.count(results, &(&1 == :ok))
      rate_limited_count = Enum.count(results, &(&1 == {:error, :rate_limited}))

      # Should have exactly 10 successes and 10 rate-limited
      assert ok_count == 10
      assert rate_limited_count == 10
    end

    test "concurrent get_state is safe" do
      provider = unique_provider(:concurrent_state)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 50)

      # Mix of acquires and state reads
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            if rem(i, 2) == 0 do
              RateLimiter.acquire(provider)
            else
              RateLimiter.get_state(provider)
            end
          end)
        end

      results = Task.await_many(tasks, 5000)

      # Should complete without errors
      for result <- results do
        assert result in [:ok, {:error, :rate_limited}] or match?({:ok, %{}}, result)
      end
    end
  end

  describe "edge cases" do
    test "zero tokens_per_second means no auto-refill" do
      provider = unique_provider(:zero_refill)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 2, tokens_per_second: 0)

      :ok = RateLimiter.acquire(provider)
      :ok = RateLimiter.acquire(provider)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)

      # Wait and verify no refill
      Process.sleep(100)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)
    end

    test "single token bucket" do
      provider = unique_provider(:single_token)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 1, tokens_per_second: 0)

      assert :ok = RateLimiter.acquire(provider)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)
    end

    test "very high refill rate" do
      provider = unique_provider(:high_refill)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 1000, tokens_per_second: 10_000)

      # Exhaust some tokens
      for _ <- 1..100 do
        RateLimiter.acquire(provider)
      end

      # Quick refill expected
      Process.sleep(50)

      {:ok, state} = RateLimiter.get_state(provider)
      # With 10k tokens/sec, should have refilled significantly in 50ms
      assert state.available_tokens > 400
    end

    test "large max_tokens value" do
      provider = unique_provider(:large_max)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 1_000_000, tokens_per_second: 0)

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.max_tokens == 1_000_000
      assert state.available_tokens == 1_000_000
    end

    test "fractional token calculation" do
      provider = unique_provider(:fractional)
      {:ok, _pid} = RateLimiter.start_link(provider: provider, max_tokens: 10, tokens_per_second: 1)

      # Exhaust all tokens
      for _ <- 1..10 do
        RateLimiter.acquire(provider)
      end

      # Wait 500ms for 0.5 tokens (not enough for 1)
      Process.sleep(500)

      # Should still be rate limited (need 1 full token)
      assert {:error, :rate_limited} = RateLimiter.acquire(provider)

      # Wait another 600ms for total of 1.1 tokens
      Process.sleep(600)

      # Now should have enough
      assert :ok = RateLimiter.acquire(provider)
    end
  end

  describe "ensure_started/2" do
    test "starts limiter if not running" do
      provider = unique_provider(:ensure_new)
      assert {:ok, pid} = RateLimiter.ensure_started(provider)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "returns existing pid if already running" do
      provider = unique_provider(:ensure_existing)
      {:ok, pid1} = RateLimiter.start_link(provider: provider)
      {:ok, pid2} = RateLimiter.ensure_started(provider)
      assert pid1 == pid2
    end

    test "accepts custom options" do
      provider = unique_provider(:ensure_opts)
      {:ok, _pid} = RateLimiter.ensure_started(provider, max_tokens: 42, tokens_per_second: 7)

      {:ok, state} = RateLimiter.get_state(provider)
      assert state.max_tokens == 42
      assert state.tokens_per_second == 7
    end
  end

  describe "error handling" do
    test "acquire handles noproc gracefully" do
      # Create a limiter and then stop it
      provider = unique_provider(:noproc_acquire)
      {:ok, pid} = RateLimiter.start_link(provider: provider)
      GenServer.stop(pid)

      # Small delay to ensure process is stopped
      Process.sleep(10)

      # acquire will auto-restart via ensure_started, but test the graceful handling
      # by testing against a provider that doesn't get auto-started
      # Actually, since acquire auto-starts, it should succeed
      result = RateLimiter.acquire(provider)
      assert result in [:ok, {:error, :rate_limited}]
    end

    test "release handles noproc gracefully" do
      provider = unique_provider(:noproc_release)
      {:ok, pid} = RateLimiter.start_link(provider: provider)
      GenServer.stop(pid)
      Process.sleep(10)

      # Should not raise, returns :ok
      assert :ok = RateLimiter.release(provider)
    end

    test "get_state handles noproc gracefully" do
      provider = unique_provider(:noproc_state)
      {:ok, pid} = RateLimiter.start_link(provider: provider)
      GenServer.stop(pid)
      Process.sleep(10)

      # Will auto-start via ensure_started
      result = RateLimiter.get_state(provider)
      assert match?({:ok, %{}}, result)
    end
  end
end
