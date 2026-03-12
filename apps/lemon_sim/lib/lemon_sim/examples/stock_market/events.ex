defmodule LemonSim.Examples.StockMarket.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  # -- Automatic phase events --

  @spec market_news_generated(pos_integer(), String.t(), map()) :: Event.t()
  def market_news_generated(round, news_text, tips_distributed) do
    Event.new("market_news_generated", %{
      "round" => round,
      "news_text" => news_text,
      "tips_distributed" => tips_distributed
    })
  end

  @spec tip_received(String.t(), String.t(), String.t(), map()) :: Event.t()
  def tip_received(player_id, stock, hint_text, price_range) do
    Event.new("tip_received", %{
      "player_id" => player_id,
      "stock" => stock,
      "hint_text" => hint_text,
      "price_range" => price_range
    })
  end

  # -- Player actions --

  @spec make_statement(String.t(), String.t()) :: Event.t()
  def make_statement(player_id, statement) do
    Event.new("make_statement", %{
      "player_id" => player_id,
      "statement" => statement
    })
  end

  @spec broadcast_market_call(String.t(), String.t(), String.t(), pos_integer(), String.t()) ::
          Event.t()
  def broadcast_market_call(player_id, stock, stance, confidence, thesis) do
    Event.new("broadcast_market_call", %{
      "player_id" => player_id,
      "stock" => stock,
      "stance" => stance,
      "confidence" => confidence,
      "thesis" => thesis
    })
  end

  @spec send_whisper(String.t(), String.t(), String.t()) :: Event.t()
  def send_whisper(from_id, to_id, message) do
    Event.new("send_whisper", %{
      "from_id" => from_id,
      "to_id" => to_id,
      "message" => message
    })
  end

  @spec skip_whisper(String.t()) :: Event.t()
  def skip_whisper(player_id) do
    Event.new("skip_whisper", %{
      "player_id" => player_id
    })
  end

  @spec place_trade(String.t(), String.t(), String.t(), non_neg_integer()) :: Event.t()
  def place_trade(player_id, action, stock, quantity) do
    Event.new("place_trade", %{
      "player_id" => player_id,
      "action" => action,
      "stock" => stock,
      "quantity" => quantity
    })
  end

  # -- Resolution events --

  @spec round_resolved(pos_integer(), map(), map()) :: Event.t()
  def round_resolved(round, price_changes, portfolio_values) do
    Event.new("round_resolved", %{
      "round" => round,
      "price_changes" => price_changes,
      "portfolio_values" => portfolio_values,
      "message" => "Round #{round} resolved. Prices updated and trades executed."
    })
  end

  @spec phase_changed(String.t(), pos_integer()) :: Event.t()
  def phase_changed(new_phase, round) do
    Event.new("phase_changed", %{
      "phase" => new_phase,
      "round" => round,
      "message" =>
        case new_phase do
          "news" -> "Round #{round}: Market news arrives..."
          "discussion" -> "Round #{round}: Trading floor discussion begins."
          "trading" -> "Round #{round}: Place your trades now."
          "resolution" -> "Round #{round}: Markets are closing. Prices updating..."
          "game_over" -> "Final round complete. The market is closed."
          _ -> "Phase changed to #{new_phase}."
        end
    })
  end

  @spec game_over(String.t(), list(), String.t()) :: Event.t()
  def game_over(winner, final_standings, message) do
    Event.new("game_over", %{
      "status" => "game_over",
      "winner" => winner,
      "final_standings" => final_standings,
      "message" => message
    })
  end

  @spec action_rejected(String.t(), String.t(), String.t()) :: Event.t()
  def action_rejected(kind, player_id, reason) do
    Event.new("action_rejected", %{
      "kind" => kind,
      "player_id" => player_id,
      "reason" => reason
    })
  end
end
