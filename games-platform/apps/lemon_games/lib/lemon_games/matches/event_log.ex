defmodule LemonGames.Matches.EventLog do
  @moduledoc """
  Append-only event log for match lifecycle.

  Events are stored in `:game_match_events` keyed by `{match_id, seq}`.
  """

  @table :game_match_events

  @spec append(String.t(), String.t(), map(), map()) :: {:ok, non_neg_integer()}
  def append(match_id, event_type, actor, payload) do
    seq = next_seq(match_id)

    event = %{
      "match_id" => match_id,
      "seq" => seq,
      "event_type" => event_type,
      "actor" => actor,
      "payload" => payload,
      "ts_ms" => System.system_time(:millisecond)
    }

    :ok = LemonCore.Store.put(@table, {match_id, seq}, event)
    {:ok, seq}
  end

  @spec list(String.t(), non_neg_integer(), non_neg_integer()) :: [map()]
  def list(match_id, after_seq \\ 0, limit \\ 100) do
    @table
    |> LemonCore.Store.list()
    |> Enum.filter(fn {{mid, seq}, _} -> mid == match_id and seq > after_seq end)
    |> Enum.sort_by(fn {{_, seq}, _} -> seq end)
    |> Enum.take(limit)
    |> Enum.map(fn {_key, event} -> event end)
  end

  @spec latest_seq(String.t()) :: non_neg_integer()
  def latest_seq(match_id) do
    @table
    |> LemonCore.Store.list()
    |> Enum.filter(fn {{mid, _seq}, _} -> mid == match_id end)
    |> Enum.map(fn {{_, seq}, _} -> seq end)
    |> Enum.max(fn -> 0 end)
  end

  defp next_seq(match_id), do: latest_seq(match_id) + 1
end
