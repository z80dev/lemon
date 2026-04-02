defmodule MarketIntel.Schema do
  @moduledoc """
  Ecto schemas for market data persistence.
  """
end

defmodule MarketIntel.Schema.PriceSnapshot do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @castable_fields [
    :token_symbol,
    :token_address,
    :price_usd,
    :price_eth,
    :market_cap,
    :liquidity_usd,
    :volume_24h,
    :price_change_24h,
    :source
  ]
  @required_fields [:token_symbol]

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

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, @castable_fields)
    |> validate_required(@required_fields)
  end
end

defmodule MarketIntel.Schema.MentionEvent do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @castable_fields [
    :platform,
    :author_handle,
    :content,
    :sentiment,
    :engagement_score,
    :mentioned_tokens,
    :raw_metadata
  ]
  @required_fields [:platform]

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

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, @castable_fields)
    |> validate_required(@required_fields)
  end
end

defmodule MarketIntel.Schema.CommentaryHistory do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @castable_fields [:tweet_id, :content, :trigger_event, :market_context, :engagement_metrics]
  @required_fields [:content, :trigger_event]

  schema "commentary_history" do
    field(:tweet_id, :string)
    field(:content, :string)
    field(:trigger_event, :string)
    field(:market_context, :map)
    field(:engagement_metrics, :map)

    timestamps()
  end

  @doc "Build a changeset for inserting or updating a commentary history record."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, @castable_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:tweet_id)
  end
end

defmodule MarketIntel.Schema.MarketSignal do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @castable_fields [:signal_type, :severity, :description, :data, :acknowledged]
  @required_fields [:signal_type, :severity]

  schema "market_signals" do
    field(:signal_type, :string)
    field(:severity, :string)
    field(:description, :string)
    field(:data, :map)
    field(:acknowledged, :boolean, default: false)

    timestamps()
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, @castable_fields)
    |> validate_required(@required_fields)
  end
end
