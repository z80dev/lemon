defmodule MarketIntel.Ingestion.TwitterMentionsTest do
  use ExUnit.Case
  alias MarketIntel.Ingestion.TwitterMentions

  describe "module structure" do
    test "exports expected functions" do
      assert function_exported?(TwitterMentions, :start_link, 1)
      assert function_exported?(TwitterMentions, :get_recent_mentions, 0)
      assert function_exported?(TwitterMentions, :get_sentiment_summary, 0)
    end

    test "is a GenServer" do
      assert Process.whereis(TwitterMentions) != nil
    end
  end
end
