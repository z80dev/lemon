defmodule MarketIntel.Repo do
  @moduledoc """
  Ecto repo for time-series market data persistence.
  
  Schema:
  - price_snapshots: token prices over time
  - mention_events: social media mentions
  - commentary_history: generated tweets for analysis
  - market_signals: alerts and anomaly signals
  """
  
  use Ecto.Repo,
    otp_app: :market_intel,
    adapter: Ecto.Adapters.SQLite3
end
