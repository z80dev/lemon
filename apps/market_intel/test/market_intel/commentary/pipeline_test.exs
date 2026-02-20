defmodule MarketIntel.Commentary.PipelineTest do
  @moduledoc """
  Tests for the Commentary Pipeline module.
  
  These tests verify the public API and pure helper functions of the pipeline.
  GenStage callback tests are handled via the process_commentary flow.
  """

  use ExUnit.Case, async: false

  alias MarketIntel.Commentary.Pipeline

  describe "API functions" do
    test "trigger/2 casts a message to the pipeline" do
      # Just verify the function doesn't raise
      # Actual GenStage testing would require starting the process
      assert :ok = Pipeline.trigger(:scheduled, %{})
    end

    test "generate_now/0 triggers immediate commentary" do
      # Just verify the function doesn't raise
      assert :ok = Pipeline.generate_now()
    end
  end

  describe "insert_commentary_history/1" do
    test "accepts a valid commentary record" do
      record = %{
        tweet_id: "1234567890",
        content: "Test tweet content",
        trigger_event: "scheduled",
        market_context: %{
          timestamp: "2024-01-01T00:00:00Z",
          token: %{price_usd: 1.0},
          eth: %{price_usd: 3000.0},
          polymarket: %{trending: []}
        },
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      # Currently returns :ok as it's a stub
      assert :ok = Pipeline.insert_commentary_history(record)
    end

    test "handles records with minimal data" do
      record = %{
        tweet_id: "999",
        content: "Minimal",
        trigger_event: "manual",
        market_context: %{},
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      assert :ok = Pipeline.insert_commentary_history(record)
    end
  end
end
