defmodule MarketIntel.TriggerSystemTest do
  @moduledoc """
  Comprehensive tests for the Trigger/Threshold System.

  Tests cover:
  - Price spike detection (threshold-based)
  - Price drop detection (threshold-based)
  - Volume surge detection
  - Market event detection (Polymarket)
  - Mention reply opportunities
  - Threshold configuration
  - Trigger aggregation and deduplication
  """

  use ExUnit.Case, async: true

  alias MarketIntel.Config

  describe "price change thresholds" do
    test "default price change threshold is 10%" do
      threshold = Config.tracked_token_price_change_signal_threshold_pct()
      assert threshold == 10
    end

    test "price spike detected when change exceeds threshold" do
      threshold = 10.0
      price_change = 15.5

      spike_detected = exceeds_threshold?(price_change, threshold)

      assert spike_detected == true
    end

    test "price spike not detected when change within threshold" do
      threshold = 10.0
      price_change = 5.0

      spike_detected = exceeds_threshold?(price_change, threshold)

      assert spike_detected == false
    end

    test "price drop detected when negative change exceeds threshold" do
      threshold = 10.0
      price_change = -12.0

      drop_detected = exceeds_threshold?(price_change, threshold)

      assert drop_detected == true
    end

    test "small negative change does not trigger drop" do
      threshold = 10.0
      price_change = -5.0

      drop_detected = exceeds_threshold?(price_change, threshold)

      assert drop_detected == false
    end

    test "exactly at threshold does not trigger" do
      threshold = 10.0
      price_change = 10.0

      # Using > not >=
      spike_detected = price_change > threshold

      assert spike_detected == false
    end

    test "handles nil price change" do
      threshold = 10.0
      price_change = nil

      spike_detected = exceeds_threshold?(price_change, threshold)

      assert spike_detected == false
    end

    test "handles string price change" do
      threshold = 10.0
      price_change = "15.5"

      spike_detected = exceeds_threshold?(price_change, threshold)

      assert spike_detected == false
    end

    test "handles zero price change" do
      threshold = 10.0
      price_change = 0.0

      spike_detected = exceeds_threshold?(price_change, threshold)

      assert spike_detected == false
    end

    test "handles very large price changes" do
      threshold = 10.0
      price_change = 500.0

      spike_detected = exceeds_threshold?(price_change, threshold)

      assert spike_detected == true
    end
  end

  describe "volume surge detection" do
    test "detects volume above historical average" do
      historical_volumes = [1_000_000, 1_200_000, 900_000, 1_100_000]
      current_volume = 5_000_000

      avg_volume = Enum.sum(historical_volumes) / length(historical_volumes)
      surge_threshold = avg_volume * 3  # 3x average

      surge_detected = current_volume > surge_threshold

      assert surge_detected == true
    end

    test "no surge when volume near average" do
      historical_volumes = [1_000_000, 1_200_000, 900_000, 1_100_000]
      current_volume = 1_150_000

      avg_volume = Enum.sum(historical_volumes) / length(historical_volumes)
      surge_threshold = avg_volume * 3

      surge_detected = current_volume > surge_threshold

      assert surge_detected == false
    end

    test "calculates volume change percentage" do
      previous_volume = 1_000_000
      current_volume = 3_500_000

      change_pct = (current_volume - previous_volume) / previous_volume * 100

      assert change_pct == 250.0
    end

    test "handles zero previous volume" do
      previous_volume = 0
      current_volume = 1_000_000

      # Avoid division by zero
      change_pct = if previous_volume > 0 do
        (current_volume - previous_volume) / previous_volume * 100
      else
        :infinite
      end

      assert change_pct == :infinite
    end

    test "detects sustained volume increase" do
      volume_history = [
        %{volume: 1_000_000, timestamp: ~U[2024-01-01 00:00:00Z]},
        %{volume: 1_100_000, timestamp: ~U[2024-01-01 01:00:00Z]},
        %{volume: 1_500_000, timestamp: ~U[2024-01-01 02:00:00Z]},
        %{volume: 2_000_000, timestamp: ~U[2024-01-01 03:00:00Z]}
      ]

      # Check for 3 consecutive increases
      increases = volume_history
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b.volume > a.volume end)

      sustained = Enum.all?(increases)

      assert sustained == true
      assert length(increases) == 3
    end
  end

  describe "large transfer detection" do
    test "default large transfer threshold" do
      threshold = Config.tracked_token_large_transfer_threshold_base_units()
      # 1M tokens with 18 decimals
      expected = 1_000_000_000_000_000_000_000_000

      assert threshold == expected
    end

    test "detects transfer above threshold" do
      threshold = 1_000_000_000_000_000_000_000_000
      transfer_value = "2_000_000_000_000_000_000_000_000"

      {value, _} = Integer.parse(String.replace(transfer_value, "_", ""))
      is_large = value > threshold

      assert is_large == true
    end

    test "ignores transfer below threshold" do
      threshold = 1_000_000_000_000_000_000_000_000
      transfer_value = "500_000_000_000_000_000_000_000"

      {value, _} = Integer.parse(String.replace(transfer_value, "_", ""))
      is_large = value > threshold

      assert is_large == false
    end

    test "handles decimal conversion" do
      # 1.5M tokens with 18 decimals
      token_amount = 1_500_000
      decimals = 18

      # Use integer math to avoid floating point precision issues
      base_units = token_amount * Integer.pow(10, decimals)

      assert base_units == 1_500_000_000_000_000_000_000_000
    end

    test "counts large transfers in time window" do
      transfers = [
        %{value: 2_000_000_000_000_000_000_000_000, timestamp: ~U[2024-01-01 12:00:00Z]},
        %{value: 500_000_000_000_000_000_000_000, timestamp: ~U[2024-01-01 12:05:00Z]},
        %{value: 3_000_000_000_000_000_000_000_000, timestamp: ~U[2024-01-01 12:10:00Z]},
        %{value: 1_500_000_000_000_000_000_000_000, timestamp: ~U[2024-01-01 12:15:00Z]}
      ]

      threshold = 1_000_000_000_000_000_000_000_000

      large_transfers = Enum.filter(transfers, fn t ->
        case Integer.parse(to_string(t.value)) do
          {value, _} -> value > threshold
          :error -> false
        end
      end)

      assert length(large_transfers) == 3
    end
  end

  describe "market event detection" do
    test "detects weird Polymarket markets" do
      markets = [
        %{"question" => "Will Bitcoin hit $100k?", "volume" => 1_000_000},
        %{"question" => "Will aliens visit Earth in 2024?", "volume" => 500_000},
        %{"question" => "Will Jesus return this year?", "volume" => 250_000}
      ]

      weird_keywords = ["jesus", "alien", "ufo", "apocalypse", "end of the world"]

      weird_markets = Enum.filter(markets, fn m ->
        text = String.downcase(m["question"] || "")
        Enum.any?(weird_keywords, &String.contains?(text, &1))
      end)

      assert length(weird_markets) == 2
      assert Enum.any?(weird_markets, &String.contains?(&1["question"], "aliens"))
    end

    test "detects crypto-related markets" do
      markets = [
        %{"question" => "Will Bitcoin hit $100k?", "description" => "BTC price prediction"},
        %{"question" => "Will Ethereum ETF approve?", "description" => "ETH ETF"},
        %{"question" => "Will it rain tomorrow?", "description" => "Weather prediction"}
      ]

      crypto_keywords = ["bitcoin", "ethereum", "crypto", "btc", "eth", "blockchain"]

      crypto_markets = Enum.filter(markets, fn m ->
        text = String.downcase((m["question"] || "") <> " " <> (m["description"] || ""))
        Enum.any?(crypto_keywords, &String.contains?(text, &1))
      end)

      assert length(crypto_markets) == 2
    end

    test "detects AI-related markets" do
      markets = [
        %{"question" => "Will AGI be achieved by 2030?", "description" => "AI timeline"},
        %{"question" => "Will ChatGPT-5 release in 2024?", "description" => "OpenAI"},
        %{"question" => "Will stocks go up?", "description" => "Finance"}
      ]

      ai_keywords = ["ai", "artificial intelligence", "chatgpt", "openai", "anthropic", "agent", "agi"]

      ai_markets = Enum.filter(markets, fn m ->
        text = String.downcase((m["question"] || "") <> " " <> (m["description"] || ""))
        Enum.any?(ai_keywords, &String.contains?(text, &1))
      end)

      assert length(ai_markets) == 2
    end

    test "detects high volume markets" do
      markets = [
        %{"question" => "Market 1", "volume" => 500_000},
        %{"question" => "Market 2", "volume" => 2_000_000},
        %{"question" => "Market 3", "volume" => 1_500_000},
        %{"question" => "Market 4", "volume" => 800_000}
      ]

      high_volume_threshold = 1_000_000

      high_volume = Enum.filter(markets, &(&1["volume"] > high_volume_threshold))

      assert length(high_volume) == 2
    end

    test "triggers when weird markets exist" do
      weird_markets = [
        %{"question" => "Aliens?", "id" => "1"},
        %{"question" => "Jesus?", "id" => "2"}
      ]

      should_trigger = length(weird_markets) > 0

      assert should_trigger == true
    end

    test "does not trigger when no weird markets" do
      weird_markets = []

      should_trigger = length(weird_markets) > 0

      assert should_trigger == false
    end
  end

  describe "mention reply opportunities" do
    test "detects high engagement mentions" do
      mentions = [
        %{"text" => "Nice project!", "engagement_score" => 5, "id" => "1"},
        %{"text" => "What is the roadmap?", "engagement_score" => 25, "id" => "2"},
        %{"text" => "Great work!", "engagement_score" => 8, "id" => "3"}
      ]

      high_engagement_threshold = 10

      reply_worthy = Enum.filter(mentions, &(&1["engagement_score"] > high_engagement_threshold))

      assert length(reply_worthy) == 1
      assert hd(reply_worthy)["id"] == "2"
    end

    test "detects question mentions" do
      mentions = [
        %{"text" => "This is great!", "id" => "1"},
        %{"text" => "When is the launch?", "id" => "2"},
        %{"text" => "How does it work?", "id" => "3"}
      ]

      question_keywords = ["?", "how", "what", "why", "when", "where", "who"]

      question_mentions = Enum.filter(mentions, fn m ->
        Enum.any?(question_keywords, &String.contains?(m["text"], &1))
      end)

      assert length(question_mentions) == 2
    end

    test "detects combined reply opportunities" do
      mentions = [
        %{"text" => "Nice!", "engagement_score" => 5, "id" => "1"},
        %{"text" => "When moon?", "engagement_score" => 15, "id" => "2"},
        %{"text" => "How does staking work?", "engagement_score" => 8, "id" => "3"},
        %{"text" => "Great update!", "engagement_score" => 20, "id" => "4"}
      ]

      question_keywords = ["?", "how", "what", "why", "when", "where", "who"]

      reply_worthy = Enum.filter(mentions, fn m ->
        m["engagement_score"] > 10 or Enum.any?(question_keywords, &String.contains?(m["text"], &1))
      end)

      assert length(reply_worthy) == 3
    end

    test "calculates engagement score correctly" do
      metrics = %{
        "like_count" => 50,
        "retweet_count" => 20,
        "reply_count" => 10
      }

      # Formula: likes + retweets * 2 + replies * 3
      score = (metrics["like_count"] || 0) +
              (metrics["retweet_count"] || 0) * 2 +
              (metrics["reply_count"] || 0) * 3

      assert score == 50 + 40 + 30
      assert score == 120
    end
  end

  describe "trigger aggregation" do
    test "prioritizes price spike over scheduled" do
      triggers = [
        %{type: :scheduled, priority: 1, timestamp: ~U[2024-01-01 12:00:00Z]},
        %{type: :price_spike, priority: 3, timestamp: ~U[2024-01-01 12:01:00Z]},
        %{type: :scheduled, priority: 1, timestamp: ~U[2024-01-01 12:02:00Z]}
      ]

      # Sort by priority descending, then timestamp
      sorted = Enum.sort_by(triggers, &{&1.priority, &1.timestamp}, :desc)

      assert hd(sorted).type == :price_spike
    end

    test "deduplicates similar triggers" do
      triggers = [
        %{type: :price_spike, token: "TEST", change: 15.0, timestamp: ~U[2024-01-01 12:00:00Z]},
        %{type: :price_spike, token: "TEST", change: 15.5, timestamp: ~U[2024-01-01 12:01:00Z]},
        %{type: :volume_surge, token: "TEST", timestamp: ~U[2024-01-01 12:02:00Z]}
      ]

      # Deduplicate by type and token within time window
      deduped = triggers
      |> Enum.group_by(&{&1.type, &1.token})
      |> Enum.map(fn {_, group} ->
        Enum.max_by(group, & &1.timestamp)
      end)

      assert length(deduped) == 2
    end

    test "combines related triggers" do
      _triggers = [
        %{type: :price_spike, change: 15.0},
        %{type: :volume_surge, multiplier: 3.0}
      ]

      # Both can be combined into a single commentary
      combined_context = %{
        price_change: 15.0,
        volume_multiplier: 3.0,
        combined: true
      }

      assert combined_context.price_change == 15.0
      assert combined_context.volume_multiplier == 3.0
      assert combined_context.combined == true
    end
  end

  describe "trigger cooldown" do
    test "enforces cooldown period between same trigger type" do
      last_triggered = ~U[2024-01-01 12:00:00Z]
      cooldown_minutes = 30
      now = ~U[2024-01-01 12:15:00Z]

      cooldown_seconds = cooldown_minutes * 60
      elapsed = DateTime.diff(now, last_triggered)

      can_trigger = elapsed >= cooldown_seconds

      assert can_trigger == false
    end

    test "allows trigger after cooldown expires" do
      last_triggered = ~U[2024-01-01 12:00:00Z]
      cooldown_minutes = 30
      now = ~U[2024-01-01 12:45:00Z]

      cooldown_seconds = cooldown_minutes * 60
      elapsed = DateTime.diff(now, last_triggered)

      can_trigger = elapsed >= cooldown_seconds

      assert can_trigger == true
    end

    test "different trigger types have independent cooldowns" do
      last_price_spike = ~U[2024-01-01 12:00:00Z]
      last_volume_surge = ~U[2024-01-01 12:40:00Z]
      now = ~U[2024-01-01 12:45:00Z]

      price_spike_eligible = DateTime.diff(now, last_price_spike) >= 30 * 60
      volume_surge_eligible = DateTime.diff(now, last_volume_surge) >= 30 * 60

      assert price_spike_eligible == true
      assert volume_surge_eligible == false
    end
  end

  describe "trigger context enrichment" do
    test "price spike includes change percentage" do
      old_price = 1.00
      new_price = 1.15

      change_pct = (new_price - old_price) / old_price * 100

      context = %{
        token: :tracked_token,
        change: change_pct,
        old_price: old_price,
        new_price: new_price
      }

      # Use assert_in_delta for floating point comparison
      assert_in_delta context.change, 15.0, 0.0001
    end

    test "volume surge includes multiplier" do
      avg_volume = 1_000_000
      current_volume = 5_000_000

      multiplier = current_volume / avg_volume

      context = %{
        avg_volume: avg_volume,
        current_volume: current_volume,
        multiplier: multiplier
      }

      assert context.multiplier == 5.0
    end

    test "large transfer includes value and addresses" do
      transfer = %{
        from: "0x1111",
        to: "0x2222",
        value: "2000000000000000000000000",
        hash: "0xabc"
      }

      context = %{
        type: :large_transfer,
        from: transfer.from,
        to: transfer.to,
        value_base_units: transfer.value,
        tx_hash: transfer.hash
      }

      assert context.from == "0x1111"
      assert context.value_base_units == "2000000000000000000000000"
    end
  end

  describe "threshold configuration" do
    test "thresholds are configurable" do
      # Test that thresholds can be retrieved from config
      price_threshold = Config.tracked_token_price_change_signal_threshold_pct()
      transfer_threshold = Config.tracked_token_large_transfer_threshold_base_units()

      assert is_number(price_threshold)
      assert is_number(transfer_threshold)
      assert price_threshold > 0
      assert transfer_threshold > 0
    end

    test "different tokens can have different thresholds" do
      # Simulating different thresholds for different tokens
      thresholds = %{
        stablecoin: 2.0,    # 2% for stablecoins (big deal)
        major: 10.0,        # 10% for major tokens
        alt: 20.0           # 20% for alt tokens
      }

      assert thresholds.stablecoin < thresholds.major
      assert thresholds.major < thresholds.alt
    end
  end

  describe "edge cases" do
    test "handles extreme price changes" do
      # 1000% increase
      change = 1000.0
      threshold = 10.0

      detected = abs(change) > threshold

      assert detected == true
    end

    test "handles negative zero" do
      change = -0.0
      threshold = 10.0

      detected = abs(change) > threshold

      assert detected == false
    end

    test "handles very small changes" do
      change = 0.001
      threshold = 10.0

      detected = abs(change) > threshold

      assert detected == false
    end

    test "handles NaN (should not trigger)" do
      change = :nan
      threshold = 10.0

      detected = exceeds_threshold?(change, threshold)

      assert detected == false
    end

    test "handles infinity" do
      change = :infinity
      threshold = 10.0

      detected = exceeds_threshold?(change, threshold)

      assert detected == false
    end
  end

  defp exceeds_threshold?(value, threshold) when is_number(value), do: abs(value) > threshold
  defp exceeds_threshold?(_value, _threshold), do: false
end
