defmodule LemonPoker.TableTest do
  use ExUnit.Case

  alias LemonPoker.Table
  import LemonPoker.TestHelpers

  test "starts hand, posts blinds, and exposes legal preflop actions" do
    table = three_player_table([1000, 1000, 1000])
    {:ok, table} = Table.start_hand(table, seed: 1)

    hand = table.hand
    assert hand.button_seat == 1
    assert hand.small_blind_seat == 2
    assert hand.big_blind_seat == 3
    assert hand.street == :preflop
    assert hand.pot == 150
    assert hand.to_call == 100
    assert hand.acting_seat == 1

    assert hand.players[2].stack == 950
    assert hand.players[3].stack == 900

    {:ok, legal} = Table.legal_actions(table)
    assert legal.seat == 1
    assert :fold in legal.options
    assert :call in legal.options
    assert :raise in legal.options
    refute :check in legal.options
  end

  test "rejects check while facing a bet" do
    table = three_player_table([1000, 1000, 1000])
    {:ok, table} = Table.start_hand(table, seed: 1)

    assert {:error, :invalid_action} = Table.act(table, 1, :check)
  end

  test "preflop call/call/check advances to flop" do
    table = three_player_table([1000, 1000, 1000])
    {:ok, table} = Table.start_hand(table, seed: 1)
    {:ok, table} = Table.act(table, 1, :call)
    {:ok, table} = Table.act(table, 2, :call)
    {:ok, table} = Table.act(table, 3, :check)

    hand = table.hand
    assert hand.street == :flop
    assert length(hand.board) == 3
    assert hand.to_call == 0
    assert hand.acting_seat == 2
  end

  test "validates minimum bet and raise sizing on postflop streets" do
    table = three_player_table([1000, 1000, 1000]) |> to_flop!()

    {:ok, legal} = Table.legal_actions(table)
    assert legal.seat == 2
    assert legal.bet == %{min: 100, max: 900, all_in_only: false}

    assert {:error, :invalid_amount} = Table.act(table, 2, {:bet, 50})

    {:ok, table} = Table.act(table, 2, {:bet, 120})
    {:ok, legal} = Table.legal_actions(table)

    assert legal.seat == 3
    assert legal.to_call == 120
    assert legal.raise == %{min: 240, max: 900, all_in_only: false}
  end

  test "short all-in raise is allowed but does not reopen raising for prior aggressor" do
    table = three_player_table([1000, 1000, 250]) |> to_flop!()

    {:ok, table} = Table.act(table, 2, {:bet, 100})

    {:ok, legal_for_3} = Table.legal_actions(table)
    assert legal_for_3.seat == 3
    assert legal_for_3.raise == %{min: 150, max: 150, all_in_only: true}

    {:ok, table} = Table.act(table, 3, {:raise, 150})
    {:ok, table} = Table.act(table, 1, :call)

    {:ok, legal_for_2} = Table.legal_actions(table)
    assert legal_for_2.seat == 2
    assert :call in legal_for_2.options
    refute :raise in legal_for_2.options
  end

  test "awards pot immediately when everyone folds to a raise" do
    table = three_player_table([1000, 1000, 1000])
    {:ok, table} = Table.start_hand(table, seed: 1)
    {:ok, table} = Table.act(table, 1, {:raise, 300})
    {:ok, table} = Table.act(table, 2, :fold)
    {:ok, table} = Table.act(table, 3, :fold)

    assert table.hand == nil
    assert table.seats[1].stack == 1150
    assert table.seats[2].stack == 950
    assert table.seats[3].stack == 900
    assert table.last_hand_result.ended_by == :fold
    assert table.last_hand_result.winners == %{1 => 450}
  end

  test "splits pot on tied showdown" do
    deck =
      deck_with_top([
        "Ah",
        "As",
        "Kd",
        "Qd",
        "9c",
        "2c",
        "3d",
        "4h",
        "Jh",
        "5s",
        "Qs",
        "6c"
      ])

    table =
      Table.new("heads-up", max_seats: 2, small_blind: 50, big_blind: 100)
      |> seat_players!([{1, "p1", 1000}, {2, "p2", 1000}])

    {:ok, table} = Table.start_hand(table, deck: deck)
    {:ok, table} = Table.act(table, 1, :call)
    {:ok, table} = Table.act(table, 2, :check)
    {:ok, table} = check_round!(table, [2, 1])
    {:ok, table} = check_round!(table, [2, 1])
    {:ok, table} = check_round!(table, [2, 1])

    assert table.hand == nil
    assert table.last_hand_result.ended_by == :showdown
    assert table.last_hand_result.winners == %{1 => 100, 2 => 100}
    assert table.seats[1].stack == 1000
    assert table.seats[2].stack == 1000
  end

  test "handles side pots and busts players correctly" do
    deck =
      deck_with_top([
        "7c",
        "Kc",
        "As",
        "7d",
        "Qc",
        "Ad",
        "3h",
        "7h",
        "2s",
        "2d",
        "4h",
        "9c",
        "5h",
        "Jc"
      ])

    table = three_player_table([500, 300, 500])
    {:ok, table} = Table.start_hand(table, deck: deck)
    {:ok, table} = Table.act(table, 1, {:raise, 500})
    {:ok, table} = Table.act(table, 2, :call)
    {:ok, table} = Table.act(table, 3, :call)

    assert table.hand == nil
    assert table.last_hand_result.ended_by == :showdown
    assert table.last_hand_result.winners == %{1 => 400, 2 => 900}
    assert Enum.sort(Enum.map(table.last_hand_result.pots, & &1.amount)) == [400, 900]

    assert table.seats[1].stack == 400
    assert table.seats[2].stack == 900
    assert table.seats[3].stack == 0
    assert table.seats[3].status == :busted
  end

  test "button advances each hand and skips busted seats" do
    deck =
      deck_with_top([
        "7c",
        "Kc",
        "As",
        "7d",
        "Qc",
        "Ad",
        "3h",
        "7h",
        "2s",
        "2d",
        "4h",
        "9c",
        "5h",
        "Jc"
      ])

    table = three_player_table([500, 300, 500])
    {:ok, table} = Table.start_hand(table, deck: deck)
    assert table.hand.button_seat == 1
    {:ok, table} = Table.act(table, 1, {:raise, 500})
    {:ok, table} = Table.act(table, 2, :call)
    {:ok, table} = Table.act(table, 3, :call)

    assert table.seats[3].status == :busted

    {:ok, table} = Table.start_hand(table, seed: 10)
    assert table.hand.button_seat == 2
    assert table.hand.small_blind_seat == 2
    assert table.hand.big_blind_seat == 1
  end

  defp three_player_table([s1, s2, s3]) do
    Table.new("table-1", max_seats: 6, small_blind: 50, big_blind: 100)
    |> seat_players!([{1, "p1", s1}, {2, "p2", s2}, {3, "p3", s3}])
  end

  defp to_flop!(table) do
    {:ok, table} = Table.start_hand(table, seed: 42)
    {:ok, table} = Table.act(table, 1, :call)
    {:ok, table} = Table.act(table, 2, :call)
    {:ok, table} = Table.act(table, 3, :check)
    table
  end

  defp check_round!(table, seats) do
    Enum.reduce_while(seats, {:ok, table}, fn seat, {:ok, acc} ->
      case Table.act(acc, seat, :check) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
