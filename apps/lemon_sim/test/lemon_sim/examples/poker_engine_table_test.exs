defmodule LemonSim.Examples.Poker.Engine.TableTest do
  use ExUnit.Case, async: true

  alias LemonSim.Examples.Poker.Engine.{Card, Deck, Table}

  test "table runs a deterministic showdown and awards the pot" do
    deck = scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d))

    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "player_1", 1_000)
      |> then(fn {:ok, table} -> Table.seat_player(table, 2, "player_2", 1_000) end)
      |> then(fn {:ok, table} -> Table.start_hand(table, deck: deck) end)

    final =
      Stream.iterate(table, fn current ->
        if current.hand == nil do
          current
        else
          {:ok, legal} = Table.legal_actions(current)

          action =
            cond do
              :call in legal.options -> :call
              :check in legal.options -> :check
              true -> :fold
            end

          {:ok, next_table} = Table.act(current, legal.seat, action)
          next_table
        end
      end)
      |> Enum.find(fn current -> current.hand == nil end)

    assert final.last_hand_result.ended_by == :showdown
    assert final.last_hand_result.winners == %{1 => 200}
    assert final.seats[1].stack == 1_100
    assert final.seats[2].stack == 900
  end

  # -- Seating validation --

  test "seat_player validates seat bounds and occupancy" do
    table = Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)

    assert {:error, :invalid_seat} = Table.seat_player(table, 0, "p1", 1_000)
    assert {:error, :invalid_seat} = Table.seat_player(table, 3, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 1, "p1", 1_000)
    assert {:error, :seat_occupied} = Table.seat_player(table, 1, "p2", 1_000)
    assert {:error, :player_already_seated} = Table.seat_player(table, 2, "p1", 1_000)
    assert {:error, :invalid_player} = Table.seat_player(table, 2, "p2", 0)
  end

  test "set_status transitions a seat's status" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    assert {:ok, updated} = Table.set_status(table, 1, :sitting_out)
    assert updated.seats[1].status == :sitting_out
    assert {:error, :seat_not_found} = Table.set_status(table, 2, :active)
  end

  test "set_blinds updates blinds between hands but not while a hand is active" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)

    assert {:ok, updated} = Table.set_blinds(table, 100, 200)
    assert updated.small_blind == 100
    assert updated.big_blind == 200
    assert {:error, :invalid_blinds} = Table.set_blinds(table, 0, 200)
    assert {:error, :invalid_blinds} = Table.set_blinds(table, 200, 100)

    {:ok, in_hand} = Table.start_hand(table, seed: 4)
    assert {:error, :hand_in_progress} = Table.set_blinds(in_hand, 100, 200)
  end

  # -- Starting a hand --

  test "start_hand requires at least two active players" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    assert {:error, :not_enough_players} = Table.start_hand(table)
  end

  test "start_hand rejects starting a new hand while one is in progress" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 1)

    assert {:error, :hand_in_progress} = Table.start_hand(table)
  end

  # -- Blinds / button rotation --

  test "heads-up hands rotate the button and the button posts the small blind" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 7)

    assert table.button_seat == 1
    assert table.hand.small_blind_seat == 1
    assert table.hand.big_blind_seat == 2
    assert table.hand.acting_seat == 1
    assert table.hand.players[1].committed_round == 50
    assert table.hand.players[2].committed_round == 100

    {:ok, table} = Table.act(table, 1, :fold)
    assert table.hand == nil
    assert table.last_hand_result.ended_by == :fold
    assert table.last_hand_result.winners == %{2 => 150}
    assert table.seats[2].stack == 1_050
    assert table.seats[1].stack == 950

    {:ok, table} = Table.start_hand(table, seed: 9)
    assert table.button_seat == 2
    assert table.hand.small_blind_seat == 2
    assert table.hand.big_blind_seat == 1
  end

  # -- Legal actions / validation --

  test "legal_actions reports the call amount and raise bounds preflop" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 3)

    {:ok, legal} = Table.legal_actions(table)

    assert legal.seat == 1
    assert legal.to_call == 50
    assert :fold in legal.options
    assert :call in legal.options
    refute :check in legal.options
    refute :bet in legal.options
    assert :raise in legal.options
    assert legal.raise.min == 200
    assert legal.raise.max == 1_000
  end

  test "legal_actions returns an error when no hand is in progress" do
    table = Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
    assert {:error, :no_hand_in_progress} = Table.legal_actions(table)
  end

  test "act rejects acting out of turn" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 3)

    assert {:error, :not_your_turn} = Table.act(table, 2, :call)
  end

  test "act rejects an action that is not currently legal" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 3)

    assert {:error, :invalid_action} = Table.act(table, 1, :check)
  end

  test "act rejects a raise below the minimum raise size" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 3)

    assert {:error, :invalid_amount} = Table.act(table, 1, {:raise, 150})
  end

  test "act rejects a raise above the player's stack" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 3)

    assert {:error, :invalid_amount} = Table.act(table, 1, {:raise, 1_500})
  end

  # -- Position labels --

  test "position_label identifies BTN/SB/BB and labels the remaining seats for a 6-max table" do
    active_seats = [1, 2, 3, 4, 5, 6]

    assert Table.position_label(1, 1, 2, 3, active_seats) == "BTN"
    assert Table.position_label(2, 1, 2, 3, active_seats) == "SB"
    assert Table.position_label(3, 1, 2, 3, active_seats) == "BB"
    assert Table.position_label(4, 1, 2, 3, active_seats) == "UTG"
    assert Table.position_label(5, 1, 2, 3, active_seats) == "MP"
    assert Table.position_label(6, 1, 2, 3, active_seats) == "CO"
    assert Table.position_label(7, 1, 2, 3, active_seats) == nil
  end

  test "position_label merges BTN/SB for heads-up tables" do
    assert Table.position_label(1, 1, 1, 2, [1, 2]) == "BTN/SB"
    assert Table.position_label(2, 1, 1, 2, [1, 2]) == "BB"
  end

  # -- Uncontested pots --

  test "folding to a single remaining player awards the pot uncontested" do
    {:ok, table} =
      Table.new("table", max_seats: 2, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "p1", 1_000)

    {:ok, table} = Table.seat_player(table, 2, "p2", 1_000)
    {:ok, table} = Table.start_hand(table, seed: 11)

    {:ok, table} = Table.act(table, 1, :fold)

    assert table.last_hand_result.ended_by == :fold
    assert table.last_hand_result.winners == %{2 => 150}
    assert table.seats[2].stack == 1_050
    assert table.seats[1].stack == 950
  end

  # -- Side pots / all-ins --

  test "an all-in short stack creates an independently resolved side pot at showdown" do
    # Deal order for 3 players (button=1, sb=2, bb=3) is [seat 2, seat 3, seat 1]
    # for each of the two hole-card rounds, so this prefix assigns:
    #   seat 1 => Jc Js (trips w/ board Jd), seat 2 => Ac Ad (pair of aces),
    #   seat 3 => Kc Qh (high card only). Board = 2c 3d 7h 9s Jd.
    deck = scripted_deck(~w(Ac Kc Jc Ad Qh Js 4s 2c 3d 7h 5d 9s 6d Jd))

    {:ok, table} =
      Table.new("table", max_seats: 3, small_blind: 50, big_blind: 100)
      |> Table.seat_player(1, "short_stack", 300)

    {:ok, table} = Table.seat_player(table, 2, "medium_stack", 1_000)
    {:ok, table} = Table.seat_player(table, 3, "big_stack", 1_000)
    {:ok, table} = Table.start_hand(table, deck: deck)

    {:ok, legal} = Table.legal_actions(table)
    assert legal.seat == 1
    {:ok, table} = Table.act(table, 1, {:raise, 300})

    {:ok, legal} = Table.legal_actions(table)
    assert legal.seat == 2
    {:ok, table} = Table.act(table, 2, :call)

    {:ok, legal} = Table.legal_actions(table)
    assert legal.seat == 3
    {:ok, table} = Table.act(table, 3, :call)

    assert table.hand.street == :flop
    assert table.hand.acting_seat == 2

    {:ok, table} = Table.act(table, 2, {:bet, 200})
    {:ok, table} = Table.act(table, 3, :call)

    final =
      Stream.iterate(table, fn current ->
        if current.hand == nil do
          current
        else
          {:ok, legal} = Table.legal_actions(current)

          action =
            cond do
              :check in legal.options -> :check
              :call in legal.options -> :call
              true -> :fold
            end

          {:ok, next_table} = Table.act(current, legal.seat, action)
          next_table
        end
      end)
      |> Enum.find(fn current -> current.hand == nil end)

    assert final.last_hand_result.ended_by == :showdown
    assert final.last_hand_result.board == ~w(2c 3d 7h 9s Jd)

    pots = Enum.sort_by(final.last_hand_result.pots, & &1.amount)

    assert pots == [
             %{amount: 400, eligible_seats: [2, 3]},
             %{amount: 900, eligible_seats: [1, 2, 3]}
           ]

    # Seat 1 has trips (best hand) and wins the main pot; seat 2 has the
    # better of the two remaining hands (pair of aces) and wins the side pot.
    assert final.last_hand_result.winners == %{1 => 900, 2 => 400}
    assert final.seats[1].stack == 900
    assert final.seats[2].stack == 900
    assert final.seats[3].stack == 500
  end

  defp scripted_deck(cards) do
    prefix =
      Enum.map(cards, fn short ->
        {:ok, card} = Card.from_string(short)
        card
      end)

    prefix_shorts = MapSet.new(cards)

    prefix ++
      (Deck.new()
       |> Enum.reject(fn card -> Card.to_short_string(card) in prefix_shorts end))
  end
end
