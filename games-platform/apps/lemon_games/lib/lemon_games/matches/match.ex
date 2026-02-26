defmodule LemonGames.Matches.Match do
  @moduledoc """
  Match record shape and helpers.

  Matches are stored as plain maps with string keys in `LemonCore.Store`.
  This module provides constructors and status predicates.
  """

  @statuses ~w(pending_accept active finished expired aborted)

  @spec new(map()) :: map()
  def new(params) do
    now = System.system_time(:millisecond)
    match_id = "match_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    %{
      "id" => match_id,
      "game_type" => params["game_type"],
      "status" => "pending_accept",
      "visibility" => params["visibility"] || "public",
      "ruleset_version" => 1,
      "players" => %{},
      "created_by" => params["created_by"],
      "turn_number" => 0,
      "next_player" => nil,
      "snapshot_seq" => 0,
      "snapshot_state" => %{},
      "result" => nil,
      "timeouts" => %{"p1" => 0, "p2" => 0},
      "deadline_at_ms" => now + accept_timeout_ms(params["game_type"]),
      "inserted_at_ms" => now,
      "updated_at_ms" => now
    }
  end

  @spec add_player(map(), String.t(), map()) :: map()
  def add_player(match, slot, player_info) do
    put_in(match, ["players", slot], player_info)
  end

  @spec active?(map()) :: boolean()
  def active?(%{"status" => "active"}), do: true
  def active?(_), do: false

  @spec terminal?(map()) :: boolean()
  def terminal?(%{"status" => s}) when s in ["finished", "expired", "aborted"], do: true
  def terminal?(_), do: false

  @spec valid_status?(String.t()) :: boolean()
  def valid_status?(s), do: s in @statuses

  @spec accept_timeout_ms(String.t()) :: non_neg_integer()
  defp accept_timeout_ms(_game_type), do: 5 * 60 * 1000

  @spec turn_timeout_ms(String.t()) :: non_neg_integer()
  def turn_timeout_ms("rock_paper_scissors"), do: 30_000
  def turn_timeout_ms("connect4"), do: 60_000
  def turn_timeout_ms(_), do: 60_000
end
