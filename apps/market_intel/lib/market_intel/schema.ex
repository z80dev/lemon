defmodule MarketIntel.Schema do
  @moduledoc """
  Ecto schemas for market data persistence.
  """
  
  use Ecto.Schema
  import Ecto.Changeset
  
  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  
  schema "price_snapshots" do
    field :token_symbol, :string
    field :token_address, :string
    field :price_usd, :decimal
    field :price_eth, :decimal
    field :market_cap, :decimal
    field :liquidity_usd, :decimal
    field :volume_24h, :decimal
    field :price_change_24h, :decimal
    field :source, :string  # dexscreener, coingecko, etc.
    
    timestamps()
  end
  
  schema "mention_events" do
    field :platform, :string  # twitter, farcaster, telegram
    field :author_handle, :string
    field :content, :string
    field :sentiment, :string  # positive, negative, neutral
    field :engagement_score, :integer  # likes + retweets
    field :mentioned_tokens, {:array, :string}
    field :raw_metadata, :map
    
    timestamps()
  end
  
  schema "commentary_history" do
    field :tweet_id, :string
    field :content, :string
    field :trigger_event, :string  # scheduled, price_movement, mention, manual
    field :market_context, :map  # snapshot of data at time of tweet
    field :engagement_metrics, :map  # filled in later
    
    timestamps()
  end
  
  schema "market_signals" do
    field :signal_type, :string  # price_spike, volume_surge, sentiment_shift
    field :severity, :string  # low, medium, high
    field :description, :string
    field :data, :map
    field :acknowledged, :boolean, default: false
    
    timestamps()
  end
end
