defmodule LemonGames.Bot.Connect4BotTest do
  use ExUnit.Case, async: true

  alias LemonGames.Bot.Connect4Bot
  alias LemonGames.Games.Connect4

  test "chooses immediate winning column when available" do
    state =
      Connect4.init(%{})
      |> put_piece!("p2", 0)
      |> put_piece!("p2", 1)
      |> put_piece!("p2", 2)

    assert %{"kind" => "drop", "column" => 3} = Connect4Bot.choose_move(state, "p2")
  end

  test "blocks opponent winning column" do
    state =
      Connect4.init(%{})
      |> put_piece!("p1", 0)
      |> put_piece!("p1", 1)
      |> put_piece!("p1", 2)

    assert %{"kind" => "drop", "column" => 3} = Connect4Bot.choose_move(state, "p2")
  end

  test "prefers center on neutral board" do
    state = Connect4.init(%{})

    assert %{"kind" => "drop", "column" => 3} = Connect4Bot.choose_move(state, "p1")
  end

  defp put_piece!(state, slot, col) do
    case Connect4.apply_move(state, slot, %{"kind" => "drop", "column" => col}) do
      {:ok, new_state} -> new_state
      {:error, code, reason} -> flunk("unexpected move error #{inspect(code)}: #{reason}")
    end
  end
end
