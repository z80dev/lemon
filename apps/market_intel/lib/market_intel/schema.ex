defmodule MarketIntel.Schema do
  @moduledoc """
  Ecto schemas for market data persistence.
  """
end

defmodule MarketIntel.Schema.PriceSnapshot do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "price_snapshots" do
    field(:token_symbol, :string)
    field(:token_address, :string)
    field(:price_usd, :decimal)
    field(:price_eth, :decimal)
    field(:market_cap, :decimal)
    field(:liquidity_usd, :decimal)
    field(:volume_24h, :decimal)
    field(:price_change_24h, :decimal)
    field(:source, :string)

    timestamps()
  end
end

defmodule MarketIntel.Schema.MentionEvent do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "mention_events" do
    field(:platform, :string)
    field(:author_handle, :string)
    field(:content, :string)
    field(:sentiment, :string)
    field(:engagement_score, :integer)
    field(:mentioned_tokens, {:array, :string})
    field(:raw_metadata, :map)

    timestamps()
  end
end

defmodule MarketIntel.Schema.CommentaryHistory do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "commentary_history" do
    field(:tweet_id, :string)
    field(:content, :string)
    field(:trigger_event, :string)
    field(:market_context, :map)
    field(:engagement_metrics, :map)

    timestamps()
  end
end

defmodule MarketIntel.Schema.MarketSignal do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "market_signals" do
    field(:signal_type, :string)
    field(:severity, :string)
    field(:description, :string)
    field(:data, :map)
    field(:acknowledged, :boolean, default: false)

    timestamps()
  end
end
