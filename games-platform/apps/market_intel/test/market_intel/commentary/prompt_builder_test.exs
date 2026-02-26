defmodule MarketIntel.Commentary.PromptBuilderTest do
  @moduledoc """
  Tests for the PromptBuilder module.
  
  These tests verify that prompt construction works correctly for all vibes,
  trigger types, and data availability scenarios.
  """

  use ExUnit.Case, async: true

  alias MarketIntel.Commentary.PromptBuilder

  describe "build/1" do
    test "builds a complete prompt with all sections" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: {:ok, %{price_usd: 1.23, price_change_24h: 5.5, name: "TestToken"}},
          eth: {:ok, %{price_usd: 3500.0}},
          polymarket: {:ok, %{trending: ["event1", "event2"]}}
        },
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      prompt = PromptBuilder.build(builder)

      assert prompt =~ "You are"
      assert prompt =~ "Current market context:"
      assert prompt =~ "TestToken: $1.23"
      assert prompt =~ "ETH: $3500"
      assert prompt =~ "Polymarket: 2 trending markets"
      assert prompt =~ "market commentary"
      assert prompt =~ "Roast ETH gas"
      assert prompt =~ "Regular market update"
      assert prompt =~ "Under 280 characters"
    end

    test "includes price change percentage for token" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: {:ok, %{price_usd: 1.23, price_change_24h: -2.5, name: "TestToken"}},
          eth: {:ok, %{price_usd: 3500.0}},
          polymarket: {:ok, %{trending: []}}
        },
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      prompt = PromptBuilder.build(builder)
      assert prompt =~ "(-2.5% 24h)"
    end
  end

  describe "build_base_prompt/0" do
    test "returns base prompt with persona" do
      base = PromptBuilder.build_base_prompt()

      assert base =~ "You are"
      assert base =~ "AI agent running on the Lemon platform"
      assert base =~ "Current market context:"
    end
  end

  describe "build_market_context/1" do
    test "formats all market data correctly" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: {:ok, %{price_usd: 1.23, price_change_24h: 5.5, name: "TestToken"}},
          eth: {:ok, %{price_usd: 3500.0}},
          polymarket: {:ok, %{trending: ["event1", "event2", "event3"]}}
        },
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      context = PromptBuilder.build_market_context(builder)

      assert context =~ "TestToken: $1.23 (5.5% 24h)"
      assert context =~ "ETH: $3500"
      assert context =~ "Polymarket: 3 trending markets"
    end

    test "handles missing price data gracefully" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: {:ok, %{price_change_24h: 5.5, name: "TestToken"}},
          eth: {:ok, %{}},
          polymarket: {:ok, %{trending: []}}
        },
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      context = PromptBuilder.build_market_context(builder)

      assert context =~ "TestToken: $unknown"
      assert context =~ "ETH: $unknown"
      assert context =~ "Polymarket: 0 trending markets"
    end

    test "handles error data gracefully" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: :error,
          eth: :expired,
          polymarket: {:ok, %{trending: nil}}
        },
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      context = PromptBuilder.build_market_context(builder)

      assert context =~ "TestToken: data unavailable"
      assert context =~ "ETH: data unavailable"
      assert context =~ "Polymarket: 0 trending markets"
    end

    test "handles nil trending data" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{
          token: {:ok, %{price_usd: 1.0}},
          eth: {:ok, %{price_usd: 3000.0}},
          polymarket: {:ok, %{}}
        },
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      context = PromptBuilder.build_market_context(builder)

      assert context =~ "Polymarket: 0 trending markets"
    end
  end

  describe "build_vibe_instructions/1" do
    test "returns crypto commentary instructions" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      instructions = PromptBuilder.build_vibe_instructions(builder)

      assert instructions =~ "market commentary"
      assert instructions =~ "Roast ETH gas"
      assert instructions =~ "Comment on $TEST price action"
    end

    test "returns gaming joke instructions" do
      builder = %PromptBuilder{
        vibe: :gaming_joke,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      instructions = PromptBuilder.build_vibe_instructions(builder)

      assert instructions =~ "gaming-related joke"
      assert instructions =~ "Mario, Zelda, Doom"
      assert instructions =~ "under 280 chars"
    end

    test "returns agent self-aware instructions" do
      builder = %PromptBuilder{
        vibe: :agent_self_aware,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      instructions = PromptBuilder.build_vibe_instructions(builder)

      assert instructions =~ "self-aware"
      assert instructions =~ "memory files"
      assert instructions =~ "BEAM runtime"
    end

    test "returns lemon persona instructions" do
      builder = %PromptBuilder{
        vibe: :lemon_persona,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      instructions = PromptBuilder.build_vibe_instructions(builder)

      assert instructions =~ "Lemon"
    end
  end

  describe "build_trigger_context/1" do
    test "returns price spike context" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :price_spike,
        trigger_context: %{change: 15.5}
      }

      context = PromptBuilder.build_trigger_context(builder)

      assert context =~ "pumped 15.5%"
      assert context =~ "React accordingly"
    end

    test "returns price drop context" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :price_drop,
        trigger_context: %{change: -8.3}
      }

      context = PromptBuilder.build_trigger_context(builder)

      assert context =~ "dropped -8.3%"
      assert context =~ "Make a joke"
    end

    test "returns mention reply context" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :mention_reply,
        trigger_context: %{}
      }

      context = PromptBuilder.build_trigger_context(builder)

      assert context =~ "Someone important mentioned us"
    end

    test "returns weird market context" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :weird_market,
        trigger_context: %{}
      }

      context = PromptBuilder.build_trigger_context(builder)

      assert context =~ "weird Polymarket trending"
    end

    test "returns scheduled context for unknown trigger types" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :scheduled,
        trigger_context: %{}
      }

      context = PromptBuilder.build_trigger_context(builder)

      assert context =~ "Regular market update"
    end

    test "handles missing change value gracefully" do
      builder = %PromptBuilder{
        vibe: :crypto_commentary,
        market_data: %{},
        token_name: "TestToken",
        token_ticker: "$TEST",
        trigger_type: :price_spike,
        trigger_context: %{}
      }

      context = PromptBuilder.build_trigger_context(builder)

      assert context =~ "pumped unknown%"
    end
  end

  describe "build_rules/0" do
    test "returns rules section" do
      rules = PromptBuilder.build_rules()

      assert rules =~ "Under 280 characters"
      assert rules =~ "No @mentions unless replying"
      assert rules =~ "Be witty, not cringe"
      assert rules =~ "Use emojis sparingly"
    end
  end
end
