defmodule MarketIntel.SchemaTest do
  use ExUnit.Case

  alias MarketIntel.Schema.{PriceSnapshot, MentionEvent, CommentaryHistory, MarketSignal}

  describe "PriceSnapshot" do
    test "has expected fields" do
      fields = PriceSnapshot.__schema__(:fields)

      assert :id in fields
      assert :token_symbol in fields
      assert :token_address in fields
      assert :price_usd in fields
      assert :price_eth in fields
      assert :market_cap in fields
      assert :liquidity_usd in fields
      assert :volume_24h in fields
      assert :price_change_24h in fields
      assert :source in fields
      assert :inserted_at in fields
      assert :updated_at in fields
    end

    test "uses binary_id primary key" do
      assert :binary_id == PriceSnapshot.__schema__(:type, :id)
    end

    test "creates a struct with nil defaults" do
      snapshot = %PriceSnapshot{}
      assert snapshot.token_symbol == nil
      assert snapshot.price_usd == nil
      assert snapshot.source == nil
    end

    test "schema source is price_snapshots" do
      assert "price_snapshots" == PriceSnapshot.__schema__(:source)
    end
  end

  describe "MentionEvent" do
    test "has expected fields" do
      fields = MentionEvent.__schema__(:fields)

      assert :id in fields
      assert :platform in fields
      assert :author_handle in fields
      assert :content in fields
      assert :sentiment in fields
      assert :engagement_score in fields
      assert :mentioned_tokens in fields
      assert :raw_metadata in fields
      assert :inserted_at in fields
      assert :updated_at in fields
    end

    test "uses binary_id primary key" do
      assert :binary_id == MentionEvent.__schema__(:type, :id)
    end

    test "mentioned_tokens is an array of strings" do
      assert {:array, :string} == MentionEvent.__schema__(:type, :mentioned_tokens)
    end

    test "raw_metadata is a map type" do
      assert :map == MentionEvent.__schema__(:type, :raw_metadata)
    end

    test "creates a struct with nil defaults" do
      event = %MentionEvent{}
      assert event.platform == nil
      assert event.author_handle == nil
      assert event.mentioned_tokens == nil
    end

    test "schema source is mention_events" do
      assert "mention_events" == MentionEvent.__schema__(:source)
    end
  end

  describe "CommentaryHistory" do
    test "has expected fields" do
      fields = CommentaryHistory.__schema__(:fields)

      assert :id in fields
      assert :tweet_id in fields
      assert :content in fields
      assert :trigger_event in fields
      assert :market_context in fields
      assert :engagement_metrics in fields
      assert :inserted_at in fields
      assert :updated_at in fields
    end

    test "uses binary_id primary key" do
      assert :binary_id == CommentaryHistory.__schema__(:type, :id)
    end

    test "market_context is a map type" do
      assert :map == CommentaryHistory.__schema__(:type, :market_context)
    end

    test "engagement_metrics is a map type" do
      assert :map == CommentaryHistory.__schema__(:type, :engagement_metrics)
    end

    test "creates a struct with nil defaults" do
      history = %CommentaryHistory{}
      assert history.tweet_id == nil
      assert history.content == nil
    end

    test "schema source is commentary_history" do
      assert "commentary_history" == CommentaryHistory.__schema__(:source)
    end
  end

  describe "MarketSignal" do
    test "has expected fields" do
      fields = MarketSignal.__schema__(:fields)

      assert :id in fields
      assert :signal_type in fields
      assert :severity in fields
      assert :description in fields
      assert :data in fields
      assert :acknowledged in fields
      assert :inserted_at in fields
      assert :updated_at in fields
    end

    test "uses binary_id primary key" do
      assert :binary_id == MarketSignal.__schema__(:type, :id)
    end

    test "acknowledged defaults to false" do
      signal = %MarketSignal{}
      assert signal.acknowledged == false
    end

    test "data is a map type" do
      assert :map == MarketSignal.__schema__(:type, :data)
    end

    test "creates a struct with expected defaults" do
      signal = %MarketSignal{}
      assert signal.signal_type == nil
      assert signal.severity == nil
      assert signal.acknowledged == false
    end

    test "schema source is market_signals" do
      assert "market_signals" == MarketSignal.__schema__(:source)
    end
  end
end
