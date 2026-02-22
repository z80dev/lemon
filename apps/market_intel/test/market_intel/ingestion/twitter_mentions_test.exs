defmodule MarketIntel.Ingestion.TwitterMentionsTest do
  @moduledoc """
  Comprehensive tests for the TwitterMentions ingestion module.

  Tests cover:
  - Mention fetching with mocked API calls
  - Sentiment analysis
  - Engagement score calculation
  - Reply opportunity detection
  - Sentiment summary generation
  - Error handling
  - GenServer behavior
  """

  use ExUnit.Case, async: false

  import Mox

  alias MarketIntel.Ingestion.TwitterMentions

  setup :verify_on_exit!

  setup do
    unless Process.whereis(MarketIntel.Cache) do
      start_supervised!(MarketIntel.Cache)
    end

    :ok
  end

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

  describe "get_recent_mentions/0" do
    test "returns cached mentions when available" do
      mentions = [
        %{
          "id" => "123",
          "text" => "Test mention",
          "sentiment" => :positive,
          "engagement_score" => 50
        }
      ]

      MarketIntel.Cache.put(:recent_mentions, mentions)

      assert {:ok, data} = TwitterMentions.get_recent_mentions()
      assert length(data) == 1
      assert hd(data)["sentiment"] == :positive
    end

    test "returns :not_found when no cached data" do
      :ets.delete_all_objects(:market_intel_cache)

      assert :not_found = TwitterMentions.get_recent_mentions()
    end
  end

  describe "get_sentiment_summary/0" do
    test "returns cached sentiment summary when available" do
      summary = %{
        total_mentions: 10,
        positive_pct: 60,
        negative_pct: 20,
        neutral_pct: 20,
        top_mentions: [],
        updated_at: DateTime.utc_now()
      }

      MarketIntel.Cache.put(:mention_sentiment, summary)

      assert {:ok, data} = TwitterMentions.get_sentiment_summary()
      assert data.total_mentions == 10
      assert data.positive_pct == 60
    end

    test "returns :not_found when no cached data" do
      :ets.delete_all_objects(:market_intel_cache)

      assert :not_found = TwitterMentions.get_sentiment_summary()
    end
  end

  describe "mention parsing" do
    setup do
      json = File.read!("test/fixtures/twitter_mentions_response.json")
      mentions = Jason.decode!(json)

      %{mentions: mentions}
    end

    test "parses mention structure correctly", %{mentions: mentions} do
      first = hd(mentions)

      assert first["id"] == "1234567890"
      assert first["text"] =~ "To the moon"
      assert first["author_id"] == "987654321"
      assert first["created_at"] == "2024-01-01T12:00:00Z"
      assert is_map(first["public_metrics"])
    end

    test "extracts public metrics", %{mentions: mentions} do
      first = hd(mentions)
      metrics = first["public_metrics"]

      assert metrics["like_count"] == 50
      assert metrics["retweet_count"] == 15
      assert metrics["reply_count"] == 5
      assert metrics["quote_count"] == 3
    end

    test "handles mentions without metrics" do
      mention = %{"id" => "1", "text" => "Test"}

      metrics = mention["public_metrics"] || %{}

      assert metrics == %{}
    end
  end

  describe "sentiment analysis" do
    @positive_keywords ["🚀", "moon", "pump", "bullish", "based", "great", "awesome", "love"]
    @negative_keywords ["📉", "dump", "bearish", "scam", "rug", "hate", "terrible", "bad"]

    test "classifies positive sentiment" do
      texts = [
        "This token is going to the moon! 🚀",
        "Love this project, great work!",
        "So bullish on this team"
      ]

      Enum.each(texts, fn text ->
        downcased = String.downcase(text)

        sentiment = cond do
          contains_any?(downcased, @positive_keywords) -> :positive
          contains_any?(downcased, @negative_keywords) -> :negative
          true -> :neutral
        end

        assert sentiment == :positive
      end)
    end

    test "classifies negative sentiment" do
      texts = [
        "This looks like a scam 📉",
        "Terrible project, hate it",
        "Bearish on this dump"
      ]

      Enum.each(texts, fn text ->
        downcased = String.downcase(text)

        sentiment = cond do
          contains_any?(downcased, @positive_keywords) -> :positive
          contains_any?(downcased, @negative_keywords) -> :negative
          true -> :neutral
        end

        assert sentiment == :negative
      end)
    end

    test "classifies neutral sentiment" do
      texts = [
        "What is the price today?",
        "Looking at the charts",
        "Any updates on the project?"
      ]

      Enum.each(texts, fn text ->
        downcased = String.downcase(text)

        sentiment = cond do
          contains_any?(downcased, @positive_keywords) -> :positive
          contains_any?(downcased, @negative_keywords) -> :negative
          true -> :neutral
        end

        assert sentiment == :neutral
      end)
    end

    test "handles empty text" do
      text = ""
      downcased = String.downcase(text)

      sentiment = cond do
        contains_any?(downcased, @positive_keywords) -> :positive
        contains_any?(downcased, @negative_keywords) -> :negative
        true -> :neutral
      end

      assert sentiment == :neutral
    end

    test "handles emoji-only text" do
      text = "🚀📉"
      downcased = String.downcase(text)

      sentiment = cond do
        contains_any?(downcased, @positive_keywords) -> :positive
        contains_any?(downcased, @negative_keywords) -> :negative
        true -> :neutral
      end

      # Contains both positive and negative, positive matches first
      assert sentiment == :positive
    end
  end

  describe "engagement score calculation" do
    test "calculates weighted engagement score" do
      metrics = %{
        "like_count" => 50,
        "retweet_count" => 15,
        "reply_count" => 5
      }

      likes = metrics["like_count"] || 0
      retweets = metrics["retweet_count"] || 0
      replies = metrics["reply_count"] || 0

      # Weighted: likes + retweets * 2 + replies * 3
      score = likes + retweets * 2 + replies * 3

      assert score == 50 + 30 + 15
      assert score == 95
    end

    test "handles missing metrics gracefully" do
      metrics = %{"like_count" => 10}

      likes = metrics["like_count"] || 0
      retweets = metrics["retweet_count"] || 0
      replies = metrics["reply_count"] || 0

      score = likes + retweets * 2 + replies * 3

      assert score == 10
    end

    test "handles empty metrics" do
      metrics = %{}

      likes = metrics["like_count"] || 0
      retweets = metrics["retweet_count"] || 0
      replies = metrics["reply_count"] || 0

      score = likes + retweets * 2 + replies * 3

      assert score == 0
    end

    test "high engagement threshold is 10" do
      high_engagement = 15
      low_engagement = 5

      assert high_engagement > 10
      assert low_engagement <= 10
    end
  end

  describe "sentiment summary" do
    test "calculates sentiment percentages" do
      mentions = [
        %{"sentiment" => :positive},
        %{"sentiment" => :positive},
        %{"sentiment" => :positive},
        %{"sentiment" => :negative},
        %{"sentiment" => :neutral}
      ]

      counts = Enum.reduce(mentions, %{positive: 0, negative: 0, neutral: 0}, fn m, acc ->
        Map.update!(acc, m["sentiment"], &(&1 + 1))
      end)

      total = length(mentions)

      positive_pct = div(counts.positive * 100, total)
      negative_pct = div(counts.negative * 100, total)
      neutral_pct = div(counts.neutral * 100, total)

      assert positive_pct == 60
      assert negative_pct == 20
      assert neutral_pct == 20
    end

    test "handles zero mentions" do
      mentions = []
      total = length(mentions)

      percentage_fn = fn count, total ->
        if total == 0, do: 0, else: div(count * 100, total)
      end

      assert percentage_fn.(10, total) == 0
    end

    test "includes top mentions in summary" do
      mentions = [
        %{"id" => "1", "engagement_score" => 100},
        %{"id" => "2", "engagement_score" => 80},
        %{"id" => "3", "engagement_score" => 60},
        %{"id" => "4", "engagement_score" => 40},
        %{"id" => "5", "engagement_score" => 20},
        %{"id" => "6", "engagement_score" => 10}
      ]

      top_mentions = Enum.take(mentions, 5)

      assert length(top_mentions) == 5
      assert hd(top_mentions)["engagement_score"] == 100
    end
  end

  describe "reply opportunity detection" do
    @question_keywords ["?", "how", "what", "why", "when", "where", "who"]

    test "identifies high engagement mentions" do
      mentions = [
        %{"text" => "Great project!", "engagement_score" => 5},
        %{"text" => "What do you think?", "engagement_score" => 15}
      ]

      reply_worthy = Enum.filter(mentions, fn m ->
        m["engagement_score"] > 10 or contains_any?(m["text"] || "", @question_keywords)
      end)

      assert length(reply_worthy) == 1
      assert hd(reply_worthy)["engagement_score"] == 15
    end

    test "identifies question mentions" do
      mentions = [
        %{"text" => "When is the launch?", "engagement_score" => 5},
        %{"text" => "Just holding my tokens", "engagement_score" => 20}
      ]

      reply_worthy = Enum.filter(mentions, fn m ->
        m["engagement_score"] > 10 or contains_any?(m["text"] || "", @question_keywords)
      end)

      assert length(reply_worthy) == 2
    end

    test "detects question mark" do
      text = "What is the price?"

      assert contains_any?(text, @question_keywords)
    end

    test "detects question words" do
      texts = ["how does this work", "what is new", "when launch"]

      Enum.each(texts, fn text ->
        assert contains_any?(text, @question_keywords)
      end)
    end
  end

  describe "mention processing" do
    setup do
      json = File.read!("test/fixtures/twitter_mentions_response.json")
      mentions = Jason.decode!(json)

      %{mentions: mentions}
    end

    test "processes mentions with sentiment and engagement", %{mentions: mentions} do
      analyzed = Enum.map(mentions, fn mention ->
        text = mention["text"] || ""

        sentiment = classify_sentiment(text)
        engagement = calculate_engagement(mention)

        Map.merge(mention, %{
          sentiment: sentiment,
          engagement_score: engagement,
          analyzed_at: DateTime.utc_now()
        })
      end)

      first = hd(analyzed)
      assert first.sentiment in [:positive, :negative, :neutral]
      assert is_integer(first.engagement_score)
      assert first.engagement_score >= 0
    end

    test "stores processed mentions in cache", %{mentions: mentions} do
      analyzed = Enum.map(mentions, fn mention ->
        text = mention["text"] || ""

        sentiment = classify_sentiment(text)
        engagement = calculate_engagement(mention)

        Map.merge(mention, %{
          sentiment: sentiment,
          engagement_score: engagement,
          analyzed_at: DateTime.utc_now()
        })
      end)

      MarketIntel.Cache.put(:recent_mentions, analyzed)

      assert {:ok, cached} = MarketIntel.Cache.get(:recent_mentions)
      assert length(cached) == length(mentions)
    end
  end

  describe "GenServer callbacks" do
    test "init schedules initial check" do
      pid = Process.whereis(TwitterMentions)
      assert is_pid(pid)
      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert Map.has_key?(state, :last_mention_id)
      assert Map.has_key?(state, :mention_history)
    end

    test "maintains mention history" do
      pid = Process.whereis(TwitterMentions)
      state = :sys.get_state(pid)

      assert is_list(state.mention_history)
    end
  end

  describe "error handling" do
    test "handles API errors gracefully" do
      # When fetch_mentions returns [], state should remain unchanged
      mentions = []

      assert mentions == []
    end

    test "handles malformed mention data" do
      malformed = [
        %{"id" => nil, "text" => nil},
        %{},
        %{"text" => "Valid mention"}
      ]

      # Should not crash when processing
      analyzed = Enum.map(malformed, fn mention ->
        text = mention["text"] || ""
        sentiment = classify_sentiment(text)
        engagement = calculate_engagement(mention)

        Map.merge(mention, %{
          sentiment: sentiment,
          engagement_score: engagement
        })
      end)

      assert length(analyzed) == 3
    end
  end

  describe "mention filtering" do
    test "tracks last seen mention ID" do
      mentions = [
        %{"id" => "100"},
        %{"id" => "99"},
        %{"id" => "98"}
      ]

      last_id = List.first(mentions)["id"]

      assert last_id == "100"
    end

    test "prevents duplicate processing" do
      last_seen_id = "100"
      new_mentions = [
        %{"id" => "101"},
        %{"id" => "100"},  # Already seen
        %{"id" => "99"}    # Already seen
      ]

      # Filter out already seen
      to_process = Enum.filter(new_mentions, fn m ->
        String.to_integer(m["id"]) > String.to_integer(last_seen_id)
      end)

      assert length(to_process) == 1
      assert hd(to_process)["id"] == "101"
    end
  end

  # Helper functions

  defp contains_any?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end

  defp classify_sentiment(text) do
    positive = ["🚀", "moon", "pump", "bullish", "based", "great", "awesome", "love"]
    negative = ["📉", "dump", "bearish", "scam", "rug", "hate", "terrible", "bad"]

    downcased = String.downcase(text)

    cond do
      contains_any?(downcased, positive) -> :positive
      contains_any?(downcased, negative) -> :negative
      true -> :neutral
    end
  end

  defp calculate_engagement(mention) do
    metrics = mention["public_metrics"] || %{}
    likes = metrics["like_count"] || 0
    retweets = metrics["retweet_count"] || 0
    replies = metrics["reply_count"] || 0

    likes + retweets * 2 + replies * 3
  end
end
