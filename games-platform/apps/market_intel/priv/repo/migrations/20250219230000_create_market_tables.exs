defmodule MarketIntel.Repo.Migrations.CreateMarketTables do
  use Ecto.Migration

  def change do
    create table(:price_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_symbol, :string, null: false
      add :token_address, :string
      add :price_usd, :decimal
      add :price_eth, :decimal
      add :market_cap, :decimal
      add :liquidity_usd, :decimal
      add :volume_24h, :decimal
      add :price_change_24h, :decimal
      add :source, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:price_snapshots, [:token_symbol, :inserted_at])
    create index(:price_snapshots, [:inserted_at])

    create table(:mention_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :platform, :string, null: false
      add :author_handle, :string
      add :content, :text
      add :sentiment, :string
      add :engagement_score, :integer
      add :mentioned_tokens, {:array, :string}
      add :raw_metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mention_events, [:platform, :inserted_at])
    create index(:mention_events, [:sentiment])

    create table(:commentary_history, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tweet_id, :string
      add :content, :text
      add :trigger_event, :string
      add :market_context, :map
      add :engagement_metrics, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:commentary_history, [:trigger_event, :inserted_at])

    create table(:market_signals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :signal_type, :string, null: false
      add :severity, :string, null: false
      add :description, :text
      add :data, :map
      add :acknowledged, :boolean, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:market_signals, [:signal_type, :inserted_at])
    create index(:market_signals, [:acknowledged])
  end
end
