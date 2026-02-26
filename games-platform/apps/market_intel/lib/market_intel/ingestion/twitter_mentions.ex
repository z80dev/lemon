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

  alias MarketIntel.Ingestion.HttpClient

  @source_name "TwitterMentions"
  @fetch_interval :timer.minutes(2)

  # Sentiment keywords
  @positive_keywords ["🚀", "moon", "pump", "bullish", "based", "great", "awesome", "love"]
  @negative_keywords ["📉", "dump", "bearish", "scam", "rug", "hate", "terrible", "bad"]
  @question_keywords ["?", "how", "what", "why", "when", "where", "who"]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_recent_mentions do
    MarketIntel.Cache.get(:recent_mentions)
  end

  def get_sentiment_summary do
    MarketIntel.Cache.get(:mention_sentiment)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    send(self(), :check_mentions)
    {:ok, %{last_mention_id: nil, mention_history: []}}
  end

  @impl true
  def handle_info(:check_mentions, state) do
    new_state = do_check_mentions(state)
    schedule_next()
    {:noreply, new_state}
  end

  # Private Functions

  defp do_check_mentions(state) do
    HttpClient.log_info(@source_name, "checking mentions...")

    case fetch_mentions(state.last_mention_id) do
      [] ->
        state

      mentions ->
        process_mentions(mentions, state)
    end
  end

  defp process_mentions(mentions, state) do
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
  end

  defp fetch_mentions(_since_id) do
    # Integration with existing X API tools
    # This would call the get_x_mentions functionality
    []
  end

  defp analyze_mention(mention) do
    text = mention["text"] || ""

    sentiment = classify_sentiment(text)
    engagement = calculate_engagement(mention)

    Map.merge(mention, %{
      sentiment: sentiment,
      engagement_score: engagement,
      analyzed_at: DateTime.utc_now()
    })
  end

  defp classify_sentiment(text) do
    downcased = String.downcase(text)

    cond do
      contains_any?(downcased, @positive_keywords) -> :positive
      contains_any?(downcased, @negative_keywords) -> :negative
      true -> :neutral
    end
  end

  defp calculate_engagement(mention) do
    metrics = mention["public_metrics"] || %{}
    likes = metrics["like_count"] || 0
    retweets = metrics["retweet_count"] || 0
    replies = metrics["reply_count"] || 0

    # Weighted engagement score
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
      positive_pct: percentage(counts.positive, total),
      negative_pct: percentage(counts.negative, total),
      neutral_pct: percentage(counts.neutral, total),
      top_mentions: Enum.take(mentions, 5),
      updated_at: DateTime.utc_now()
    }

    MarketIntel.Cache.put(:mention_sentiment, summary)
  end

  defp check_reply_opportunities(mentions) do
    reply_worthy =
      Enum.filter(mentions, fn m ->
        m.engagement_score > 10 or contains_any?(m["text"] || "", @question_keywords)
      end)

    if length(reply_worthy) > 0 do
      MarketIntel.Commentary.Pipeline.trigger(:mention_reply, %{
        mentions: reply_worthy
      })
    end
  end

  defp percentage(_count, 0), do: 0
  defp percentage(count, total), do: div(count * 100, total)

  defp contains_any?(text, keywords) do
    Enum.any?(keywords, &String.contains?(text, &1))
  end

  defp schedule_next do
    HttpClient.schedule_next_fetch(self(), :check_mentions, @fetch_interval)
  end
end
