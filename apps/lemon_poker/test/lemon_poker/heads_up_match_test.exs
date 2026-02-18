defmodule LemonPoker.HeadsUpMatchTest do
  use ExUnit.Case

  alias LemonPoker.HeadsUpMatch

  test "parses canonical action format" do
    assert {:ok, :call} = HeadsUpMatch.parse_action("ACTION: call")
    assert {:ok, :check} = HeadsUpMatch.parse_action("action: check")
    assert {:ok, :fold} = HeadsUpMatch.parse_action("ACTION: fold")
    assert {:ok, {:bet, 120}} = HeadsUpMatch.parse_action("ACTION: bet 120")
    assert {:ok, {:raise, 350}} = HeadsUpMatch.parse_action("ACTION: raise 350")
  end

  test "parses action line from fenced output" do
    answer = """
    ```text
    ACTION: raise 240
    ```
    """

    assert {:ok, {:raise, 240}} = HeadsUpMatch.parse_action(answer)
  end

  test "returns error for invalid format" do
    assert {:error, :invalid_format} = HeadsUpMatch.parse_action("I think calling is best.")
  end

  test "supports configurable player count up to nine" do
    {:ok, table} = HeadsUpMatch.play(table_id: "test-six", players: 6, hands: 0)

    assert map_size(table.seats) == 6
    assert Map.keys(table.seats) |> Enum.sort() == [1, 2, 3, 4, 5, 6]
  end

  test "rejects player counts outside allowed range" do
    assert_raise ArgumentError, ~r/players must be between 2 and 9/, fn ->
      HeadsUpMatch.play(table_id: "test-ten", players: 10, hands: 0)
    end
  end
end
