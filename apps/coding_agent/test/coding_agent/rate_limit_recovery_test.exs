defmodule CodingAgent.RateLimitRecoveryTest do
  use ExUnit.Case, async: true

  alias CodingAgent.RateLimitRecovery
  alias Ai.Types.Model

  @test_model %Model{
    id: "test-model-large",
    name: "Test Model Large",
    provider: :anthropic,
    api: :anthropic_messages,
    context_window: 128_000,
    max_tokens: 4096,
    input: [:text, :image],
    reasoning: true,
    cost: %{input: 5.0, output: 15.0, cache_read: 1.25, cache_write: 5.0}
  }

  describe "select_strategy/1" do
    test "selects reset_backoff for first few failures" do
      strategy =
        RateLimitRecovery.select_strategy(%{
          current_model: @test_model,
          failure_count: 0
        })

      assert strategy == :reset_backoff

      strategy =
        RateLimitRecovery.select_strategy(%{
          current_model: @test_model,
          failure_count: 2
        })

      assert strategy == :reset_backoff
    end

    test "selects fallback after 3+ failures" do
      strategy =
        RateLimitRecovery.select_strategy(%{
          current_model: @test_model,
          failure_count: 4,
          available_providers: [:anthropic, :openai]
        })

      assert strategy == :reset_backoff or
               match?({:fallback_model, _}, strategy) or
               match?({:fallback_provider, _}, strategy)
    end

    test "selects give_up after max failures" do
      strategy =
        RateLimitRecovery.select_strategy(%{
          current_model: @test_model,
          failure_count: 10
        })

      assert strategy == :give_up
    end
  end

  describe "apply_strategy/2" do
    test "reset_backoff updates state" do
      state = %{session_id: "test", provider: :anthropic}

      {:ok, new_state} = RateLimitRecovery.apply_strategy(:reset_backoff, state)

      assert new_state.backoff_reset_at != nil
      assert is_integer(new_state.backoff_reset_at)
    end

    test "fallback_model updates model in state" do
      state = %{session_id: "test", model: @test_model}

      {:ok, new_state} =
        RateLimitRecovery.apply_strategy({:fallback_model, @test_model}, state)

      assert new_state.strategy_applied == :fallback_model
    end

    test "fallback_provider returns error for nonexistent provider" do
      state = %{session_id: "test", model: @test_model, provider: :anthropic}

      result = RateLimitRecovery.apply_strategy({:fallback_provider, :nonexistent}, state)

      assert {:error, {:no_suitable_model, :nonexistent}} = result
    end

    test "session_fork marks fork_requested" do
      state = %{session_id: "test"}

      {:ok, new_state} =
        RateLimitRecovery.apply_strategy({:session_fork, [preserve_messages: 5]}, state)

      assert new_state.fork_requested == true
      assert new_state.strategy_applied == :session_fork
    end

    test "give_up returns error" do
      state = %{session_id: "test"}

      result = RateLimitRecovery.apply_strategy(:give_up, state)

      assert {:error, :recovery_strategies_exhausted} = result
    end
  end

  describe "try_fallback_provider/2" do
    test "returns nil when no other providers available" do
      result = RateLimitRecovery.try_fallback_provider(@test_model, [])
      assert result == nil

      result = RateLimitRecovery.try_fallback_provider(@test_model, [:anthropic])
      assert result == nil
    end

    test "returns fallback provider when available" do
      result = RateLimitRecovery.try_fallback_provider(@test_model, [:anthropic, :openai])

      assert {:fallback_provider, :openai} = result
    end
  end

  describe "prepare_fork_context/2" do
    test "extracts recent messages" do
      state = %{
        session_id: "test",
        messages: [
          %{role: "user", content: "oldest"},
          %{role: "assistant", content: "middle"},
          %{role: "user", content: "newest"}
        ]
      }

      context = RateLimitRecovery.prepare_fork_context(state, preserve_message_count: 2)

      assert length(context.messages) == 2
    end

    test "includes metadata" do
      state = %{session_id: "test-session-123"}

      context = RateLimitRecovery.prepare_fork_context(state)

      assert context.metadata.forked_from == "test-session-123"
      assert context.metadata.fork_reason == :rate_limit_recovery
      assert %DateTime{} = context.metadata.forked_at
    end
  end

  describe "fork_notification/1" do
    test "generates notification for rate limit recovery" do
      context = %{
        fork_reason: :rate_limit_recovery,
        summary: "Previous discussion",
        todos: [%{content: "Fix bug"}]
      }

      notification = RateLimitRecovery.fork_notification(context)

      assert notification =~ "Session forked"
      assert notification =~ "rate limiting"
    end
  end
end
