defmodule MarketIntel.Ingestion.TwitterMentions do
  @moduledoc """
  Ingests Twitter/X mentions related to the configured account and tracked token.

  Tracks:
  - Direct mentions
  - Token ticker mentions
  - Sentiment analysis
  - Engagement metrics
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Check for mentions every 2 minutes
    send(self(), :check_mentions)
    {:ok, %{last_mention_id: nil, mention_history: []}}
  end

  # Public API

  def get_recent_mentions do
    MarketIntel.Cache.get(:recent_mentions)
  end

  def get_sentiment_summary do
    MarketIntel.Cache.get(:mention_sentiment)
  end

  # GenServer callbacks

  @impl true
  def handle_info(:check_mentions, state) do
    new_state = do_check_mentions(state)
    schedule_next()
    {:noreply, new_state}
  end

  # Private

  defp do_check_mentions(state) do
    Logger.info("[MarketIntel] Checking Twitter mentions...")

    # This would use the X API via the existing x tool
    # For now, placeholder that could integrate with get_x_mentions

    mentions = fetch_mentions(state.last_mention_id)

    if length(mentions) > 0 do
      # Analyze sentiment
      analyzed = Enum.map(mentions, &analyze_mention/1)

      # Store in cache
      MarketIntel.Cache.put(:recent_mentions, analyzed)

      # Update sentiment summary
      update_sentiment_summary(analyzed)

      # Check for reply-worthy mentions
      check_reply_opportunities(analyzed)

      # Update last seen
      last_id = List.first(mentions)["id"]
      %{state | last_mention_id: last_id, mention_history: mentions ++ state.mention_history}
    else
      state
    end
  end

  defp fetch_mentions(_since_id) do
    # Integration with existing X API tools
    # This would call the get_x_mentions functionality
    []
  end

  defp analyze_mention(mention) do
    text = mention["text"] || ""

    sentiment =
      cond do
        String.contains?(text, ["🚀", "moon", "pump", "bullish", "based"]) -> :positive
        String.contains?(text, ["📉", "dump", "bearish", "scam", "rug"]) -> :negative
        true -> :neutral
      end

    engagement = calculate_engagement(mention)

    Map.merge(mention, %{
      sentiment: sentiment,
      engagement_score: engagement,
      analyzed_at: DateTime.utc_now()
    })
  end

  defp calculate_engagement(mention) do
    likes = mention["public_metrics"]["like_count"] || 0
    retweets = mention["public_metrics"]["retweet_count"] || 0
    replies = mention["public_metrics"]["reply_count"] || 0

    likes + retweets * 2 + replies * 3
  end

  defp update_sentiment_summary(mentions) do
    counts =
      Enum.reduce(mentions, %{positive: 0, negative: 0, neutral: 0}, fn m, acc ->
        Map.update!(acc, m.sentiment, &(&1 + 1))
      end)

    total = length(mentions)

    summary = %{
      total_mentions: total,
      positive_pct: div(counts.positive * 100, total),
      negative_pct: div(counts.negative * 100, total),
      neutral_pct: div(counts.neutral * 100, total),
      top_mentions: Enum.take(mentions, 5),
      updated_at: DateTime.utc_now()
    }

    MarketIntel.Cache.put(:mention_sentiment, summary)
  end

  defp check_reply_opportunities(mentions) do
    # Find high-engagement or interesting mentions that deserve replies
    reply_worthy =
      Enum.filter(mentions, fn m ->
        m.engagement_score > 10 or
          String.contains?(m["text"], ["?", "how", "what", "why"])
      end)

    if length(reply_worthy) > 0 do
      MarketIntel.Commentary.Pipeline.trigger(:mention_reply, %{
        mentions: reply_worthy
      })
    end
  end

  defp schedule_next do
    Process.send_after(self(), :check_mentions, :timer.minutes(2))
  end
end
