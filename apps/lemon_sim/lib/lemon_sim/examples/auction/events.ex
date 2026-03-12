defmodule LemonSim.Examples.Auction.Events do
  @moduledoc false

  alias LemonSim.Event

  @spec normalize(Event.t() | map() | keyword()) :: Event.t()
  def normalize(raw_event), do: Event.new(raw_event)

  @spec place_bid(String.t(), non_neg_integer()) :: Event.t()
  def place_bid(player_id, amount) do
    Event.new("place_bid", %{"player_id" => player_id, "amount" => amount})
  end

  @spec pass_auction(String.t()) :: Event.t()
  def pass_auction(player_id) do
    Event.new("pass_auction", %{"player_id" => player_id})
  end

  @spec bid_accepted(String.t(), non_neg_integer(), String.t()) :: Event.t()
  def bid_accepted(player_id, amount, item_name) do
    Event.new("bid_accepted", %{
      "player_id" => player_id,
      "amount" => amount,
      "item" => item_name
    })
  end

  @spec bid_rejected(String.t(), non_neg_integer(), String.t()) :: Event.t()
  def bid_rejected(player_id, amount, reason) do
    Event.new("bid_rejected", %{
      "player_id" => player_id,
      "amount" => amount,
      "reason" => reason
    })
  end

  @spec player_passed(String.t()) :: Event.t()
  def player_passed(player_id) do
    Event.new("player_passed", %{"player_id" => player_id})
  end

  @spec item_won(String.t(), String.t(), String.t(), non_neg_integer()) :: Event.t()
  def item_won(player_id, item_name, category, price) do
    Event.new("item_won", %{
      "player_id" => player_id,
      "item" => item_name,
      "category" => category,
      "price" => price
    })
  end

  @spec item_unsold(String.t()) :: Event.t()
  def item_unsold(item_name) do
    Event.new("item_unsold", %{"item" => item_name})
  end

  @spec round_started(pos_integer(), [map()]) :: Event.t()
  def round_started(round_number, items) do
    item_names = Enum.map(items, fn item -> get_name(item) end)

    Event.new("round_started", %{
      "round" => round_number,
      "items" => item_names
    })
  end

  @spec auction_started(String.t(), String.t(), non_neg_integer()) :: Event.t()
  def auction_started(item_name, category, base_value) do
    Event.new("auction_started", %{
      "item" => item_name,
      "category" => category,
      "base_value" => base_value
    })
  end

  @spec scoring_complete(map()) :: Event.t()
  def scoring_complete(scores) do
    Event.new("scoring_complete", %{"scores" => scores})
  end

  @spec game_over(String.t(), map()) :: Event.t()
  def game_over(winner, scores) do
    Event.new("game_over", %{
      "status" => "game_over",
      "winner" => winner,
      "scores" => scores,
      "message" => "#{winner} wins the auction house!"
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

  defp get_name(item) when is_map(item) do
    Map.get(item, :name, Map.get(item, "name", "Unknown"))
  end
end
