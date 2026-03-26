defmodule LemonSim.Examples.PokerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonSim.{DecisionFrame, Runner, State}
  alias LemonSim.Examples.Poker
  alias LemonSim.Examples.Poker.{Events, Performance, ToolPolicy, Updater}
  alias LemonSim.Examples.Poker.Engine.{Card, Deck, Table}

  test "example runs one scripted hand to completion" do
    deck = scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d))

    {:ok, turns} =
      Agent.start_link(fn ->
        [
          {"call", %{}},
          {"check", %{}},
          {"check", %{}},
          {"check", %{}},
          {"check", %{}},
          {"check", %{}},
          {"check", %{}},
          {"check", %{}}
        ]
      end)

    complete_fn = fn _model, _context, _stream_opts ->
      {tool_name, arguments} =
        Agent.get_and_update(turns, fn
          [next | rest] -> {next, rest}
          [] -> {{"check", %{}}, []}
        end)

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "poker-#{System.unique_integer([:positive])}",
             name: tool_name,
             arguments: arguments
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    output =
      capture_io(fn ->
        assert {:ok, final_state} =
                 Poker.run(
                   model: fake_model(),
                   complete_fn: complete_fn,
                   stream_options: %{},
                   persist?: false,
                   max_hands: 1,
                   player_count: 2,
                   seed: 7,
                   deck: deck,
                   max_turns: 20
                 )

        assert final_state.world[:status] == "game_over"
        assert final_state.world[:winner] == "player_1"
        assert final_state.world[:winner_ids] == ["player_1"]
        assert final_state.world[:completed_hands] == 1
        assert is_map(final_state.world[:performance])
      end)

    assert output =~ "Starting Poker self-play"
    assert output =~ "Final state:"
  end

  test "projection shows positions and per-street hand actions" do
    state =
      Poker.initial_state(
        player_count: 3,
        max_hands: 1,
        deck: scripted_deck(~w(Qh Js As Qd Jd Ac 7s 2s 3h 4c 8d 9d Tc Kc))
      )

    assert {:ok, next_state, {:decide, "next action"}} =
             Updater.apply_event(
               state,
               action_event(state.world.table, "call"),
               []
             )

    builders = Keyword.fetch!(Poker.projector_opts(), :section_builders)
    frame = DecisionFrame.from_state(next_state)

    table_state = builders.table_state.(frame, [], []).content
    opponents = builders.opponents.(frame, [], []).content
    hand_actions = builders.hand_actions.(frame, [], []).content

    assert Enum.map(table_state["seats"], & &1["position"]) == ["BTN", "SB", "BB"]
    assert Enum.all?(opponents, &Map.has_key?(&1, "position"))
    refute Enum.any?(opponents, &Map.has_key?(&1, "hole_cards"))

    assert hand_actions["preflop"] == [
             %{
               "player" => "player_1",
               "position" => "BTN",
               "action" => "call",
               "amount" => 100
             }
           ]

    assert hand_actions["flop"] == []
    assert hand_actions["turn"] == []
    assert hand_actions["river"] == []
  end

  test "recent events and notes stay private to the acting player" do
    state =
      Poker.initial_state(
        player_count: 2,
        max_hands: 1,
        deck: scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d))
      )

    assert {:ok, note_state, :skip} =
             Updater.apply_event(state, Events.player_note("player_1", 1, "bb overfolds"), [])

    private_state =
      note_state
      |> State.append_event(Events.player_note("player_2", 2, "hidden"))
      |> State.append_event(Events.action_rejected("player_2", 2, "call", :invalid_action, "bad"))

    builders = Keyword.fetch!(Poker.projector_opts(), :section_builders)
    frame = DecisionFrame.from_state(private_state)

    your_hand = builders.your_hand.(frame, [], []).content
    notes = builders.notes.(frame, [], []).content
    recent_events = builders.recent_events.(frame, [], []).content

    assert your_hand["hole_cards"] == ["As", "Ks"]
    assert Enum.map(notes, & &1["content"]) == ["bb overfolds"]
    refute Enum.any?(recent_events, &event_for_player?(&1, "player_2"))
  end

  test "note tool persists notes without ending the turn" do
    state =
      Poker.initial_state(
        player_count: 2,
        max_hands: 1,
        deck: scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d))
      )

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "note-1",
             name: "note",
             arguments: %{"content" => "bb overfolds"}
           },
           %ToolCall{
             type: :tool_call,
             id: "call-1",
             name: "call",
             arguments: %{}
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    assert {:ok, %{state: next_state}} =
             Runner.step(state, Poker.modules(),
               model: fake_model(),
               complete_fn: complete_fn,
               stream_options: %{},
               tool_policy: ToolPolicy,
               support_tool_matcher: fn tool -> tool.name == "note" end
             )

    assert [%{"content" => "bb overfolds"} | _] = next_state.world.player_notes["player_1"]
    assert next_state.world.current_actor_id == "player_2"
  end

  test "side pot: one all-in below the big blind splits main and side pots correctly" do
    deck = scripted_deck(~w(Qh Js As Qd Jd Ac 7s 2s 3h 4c 8d 9d Tc Kc))

    {:ok, table} =
      Table.new("short_all_in", small_blind: 50, big_blind: 100)
      |> seat!(1, "player_1", 40)
      |> seat!(2, "player_2", 200)
      |> seat!(3, "player_3", 200)
      |> Table.start_hand(deck: deck)

    {:ok, table} = Table.act(table, 1, :call)
    {:ok, table} = Table.act(table, 2, :call)
    {:ok, table} = Table.act(table, 3, :check)
    {:ok, table} = check_to_completion(table)

    assert table.hand == nil
    assert table.last_hand_result.winners == %{1 => 120, 2 => 120}
    assert Enum.map(table.last_hand_result.pots, & &1.amount) == [120, 120]
  end

  test "side pot: two all-ins at different levels distribute correctly" do
    deck = scripted_deck(~w(Ks Qh As Kd Qd Ac Jc 7s 2s 3h Qc 4c Kc 8d))

    {:ok, table} =
      Table.new("two_all_ins", small_blind: 50, big_blind: 100)
      |> seat!(1, "player_1", 100)
      |> seat!(2, "player_2", 200)
      |> seat!(3, "player_3", 400)
      |> Table.start_hand(deck: deck)

    {:ok, table} = Table.act(table, 1, :call)
    {:ok, table} = Table.act(table, 2, {:raise, 200})
    {:ok, table} = Table.act(table, 3, :call)
    {:ok, table} = check_to_completion(table)

    assert table.hand == nil
    assert table.last_hand_result.winners == %{1 => 300, 2 => 200}
    assert Enum.map(table.last_hand_result.pots, & &1.amount) == [300, 200]
  end

  test "split pot on tied hands awards odd chip left of the button" do
    deck = scripted_deck(~w(Th Td 4s 9c 8c 4d 7s As Ks Qh Jd Tc 2c Kc))

    {:ok, table} =
      Table.new("odd_chip", small_blind: 1, big_blind: 2)
      |> seat!(1, "player_1", 1)
      |> seat!(2, "player_2", 10)
      |> seat!(3, "player_3", 10)
      |> Table.start_hand(deck: deck)

    {:ok, table} = Table.act(table, 1, :call)
    {:ok, table} = Table.act(table, 2, :call)
    {:ok, table} = Table.act(table, 3, :check)
    {:ok, table} = check_to_completion(table)

    assert table.hand == nil
    assert table.last_hand_result.winners == %{2 => 3, 3 => 2}
  end

  test "action rejection: action out of turn is rejected" do
    state = initial_two_player_state()

    assert {:ok, next_state, {:decide, message}} =
             Updater.apply_event(
               state,
               %{
                 "kind" => "poker_action",
                 "payload" => %{
                   "player_id" => "player_2",
                   "seat" => 2,
                   "action" => "call"
                 }
               },
               []
             )

    assert message == "not your turn"
    assert List.last(next_state.recent_events).kind == "action_rejected"
  end

  test "action rejection: invalid bet amount is rejected" do
    state = initial_two_player_state()

    assert {:ok, next_state, {:decide, message}} =
             Updater.apply_event(
               state,
               %{
                 "kind" => "poker_action",
                 "payload" => %{
                   "player_id" => "player_1",
                   "seat" => 1,
                   "action" => "raise",
                   "total" => 1
                 }
               },
               []
             )

    assert message == "invalid amount"
    assert List.last(next_state.recent_events).kind == "action_rejected"
  end

  test "action rejection: action after game over is rejected" do
    state =
      initial_two_player_state()
      |> State.put_world(%{status: "game_over"})

    assert {:ok, next_state, {:decide, message}} =
             Updater.apply_event(
               state,
               %{
                 "kind" => "poker_action",
                 "payload" => %{
                   "player_id" => "player_1",
                   "seat" => 1,
                   "action" => "call"
                 }
               },
               []
             )

    assert message == "hand already finished"
    assert List.last(next_state.recent_events).kind == "action_rejected"
  end

  test "timeout fallback auto-folds after three consecutive rejected actions" do
    state = initial_two_player_state()

    invalid_raise = %{
      "kind" => "poker_action",
      "payload" => %{
        "player_id" => "player_1",
        "seat" => 1,
        "action" => "raise",
        "total" => 1
      }
    }

    assert {:ok, state, {:decide, "invalid amount"}} =
             Updater.apply_event(state, invalid_raise, [])

    assert {:ok, state, {:decide, "invalid amount"}} =
             Updater.apply_event(state, invalid_raise, [])

    assert {:ok, state, :skip} = Updater.apply_event(state, invalid_raise, [])

    fold_event =
      Enum.find(state.recent_events, fn event ->
        event.kind == "poker_action" and event.payload["auto_fold"] == true
      end)

    assert fold_event.payload["action"] == "fold"
    assert state.world.status == "game_over"
  end

  test "multi-hand progression increments completed_hands and rotates the button" do
    state = Poker.initial_state(player_count: 3, max_hands: 3, seed: 7)
    {final_state, buttons} = autoplay_until_hands(state, 3)

    assert final_state.world.completed_hands == 3
    assert final_state.world.status == "game_over"
    assert buttons == [2, 3]
  end

  test "blind schedule applies updated levels on later hands" do
    state =
      Poker.initial_state(
        player_count: 3,
        max_hands: 3,
        seed: 7,
        small_blind: 25,
        big_blind: 50,
        blind_schedule: [
          {1, 25, 50},
          {3, 50, 100}
        ]
      )

    assert state.world.table.small_blind == 25
    assert state.world.table.big_blind == 50

    {final_state, _buttons} = autoplay_until_hands(state, 3)

    assert final_state.world.completed_hands == 3
    assert final_state.world.table.small_blind == 50
    assert final_state.world.table.big_blind == 100
  end

  test "all-in edge case: player with stack below big blind is forced all-in" do
    {:ok, table} =
      Table.new("forced_all_in", small_blind: 50, big_blind: 100)
      |> seat!(1, "player_1", 40)
      |> seat!(2, "player_2", 200)
      |> Table.start_hand(seed: 1)

    player_1 = table.hand.players[1]
    assert player_1.all_in
    assert player_1.committed_total == 40
    assert player_1.stack == 0
  end

  test "all-in edge case: all players all-in runs out the board and reaches showdown" do
    deck = scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d Tc 5d))

    state =
      Poker.initial_state(
        player_count: 2,
        max_hands: 1,
        small_blind: 25,
        big_blind: 50,
        starting_stack: 50,
        deck: deck
      )

    assert {:ok, final_state, :skip} =
             Updater.apply_event(
               state,
               %{
                 "kind" => "poker_action",
                 "payload" => %{
                   "player_id" => "player_1",
                   "seat" => 1,
                   "action" => "call"
                 }
               },
               []
             )

    assert final_state.world.status == "game_over"
    assert final_state.world.last_hand_result.ended_by == :showdown
    assert length(final_state.world.last_hand_result.board) == 5
  end

  test "heads-up: dealer posts the small blind and acts first preflop" do
    {:ok, table} =
      Table.new("heads_up", small_blind: 10, big_blind: 20)
      |> seat!(1, "player_1", 1000)
      |> seat!(2, "player_2", 1000)
      |> Table.start_hand(seed: 1)

    assert table.hand.small_blind_seat == table.hand.button_seat
    assert table.hand.big_blind_seat != table.hand.button_seat
    assert table.hand.acting_seat == table.hand.button_seat
  end

  test "heads-up: button rotates between hands" do
    {:ok, table} =
      Table.new("heads_up_rotation", small_blind: 10, big_blind: 20)
      |> seat!(1, "player_1", 1000)
      |> seat!(2, "player_2", 1000)
      |> Table.start_hand(seed: 1)

    {:ok, completed} = fold_all_in(table)
    {:ok, next_hand} = Table.start_hand(completed, seed: 2)

    assert next_hand.button_seat != table.button_seat
    assert next_hand.hand.small_blind_seat == next_hand.button_seat
  end

  test "performance summarize reports benchmark metrics from final world state" do
    world = %{
      completed_hands: 4,
      chip_counts: [
        %{"player_id" => "player_1", "stack" => 2_400},
        %{"player_id" => "player_2", "stack" => 1_600}
      ],
      table: %{big_blind: 100},
      player_stats: %{
        "player_1" => %{
          starting_stack: 2_000,
          hands_played: 4,
          hands_won: 2,
          vpip_hands: 3,
          pfr_hands: 1,
          total_actions: 7,
          fold_count: 1,
          check_count: 2,
          call_count: 2,
          bet_count: 1,
          raise_count: 1,
          current_hand: %{vpip: false, pfr: false}
        },
        "player_2" => %{
          starting_stack: 2_000,
          hands_played: 4,
          hands_won: 2,
          vpip_hands: 2,
          pfr_hands: 1,
          total_actions: 7,
          fold_count: 1,
          check_count: 2,
          call_count: 3,
          bet_count: 1,
          raise_count: 0,
          current_hand: %{vpip: false, pfr: false}
        }
      }
    }

    summary = Performance.summarize(world)

    assert summary.hands_completed == 4
    assert summary.big_blind == 100
    assert summary.players["player_1"].profit_loss == 400
    assert summary.players["player_1"].bb_per_hand == 1.0
    assert summary.players["player_1"].vpip == 0.75
    assert summary.players["player_2"].profit_loss == -400
  end

  defp initial_two_player_state do
    Poker.initial_state(
      player_count: 2,
      max_hands: 1,
      deck: scripted_deck(~w(As Qh Ks Qd 2s Ac 7s 2c 3h 9h 4c 4d))
    )
  end

  defp autoplay_until_hands(state, target_hands, buttons \\ [], steps \\ 0)

  defp autoplay_until_hands(state, target_hands, buttons, _steps)
       when state.world.completed_hands >= target_hands do
    {state, buttons}
  end

  defp autoplay_until_hands(_state, _target_hands, _buttons, steps) when steps > 200 do
    flunk("autoplay exceeded step budget")
  end

  defp autoplay_until_hands(state, target_hands, buttons, steps) do
    table = state.world.table
    {:ok, legal} = Table.legal_actions(table)
    player = table.hand.players[legal.seat]

    {action, payload} =
      cond do
        :call in legal.options ->
          {"call", %{}}

        :check in legal.options ->
          {"check", %{}}

        :fold in legal.options ->
          {"fold", %{}}
      end

    event = %{
      "kind" => "poker_action",
      "payload" =>
        Map.merge(payload, %{
          "player_id" => player.player_id,
          "seat" => player.seat,
          "action" => action
        })
    }

    assert {:ok, next_state, _signal} = Updater.apply_event(state, event, [])

    buttons =
      if next_state.world.completed_hands > state.world.completed_hands and
           next_state.world.table.hand do
        buttons ++ [next_state.world.table.hand.button_seat]
      else
        buttons
      end

    autoplay_until_hands(next_state, target_hands, buttons, steps + 1)
  end

  defp event_for_player?(event, player_id) do
    payload = Map.get(event, "payload", %{})
    Map.get(payload, "player_id") == player_id
  end

  defp action_event(table, action, payload \\ %{}) do
    player = table.hand.players[table.hand.acting_seat]

    %{
      "kind" => "poker_action",
      "payload" =>
        Map.merge(payload, %{
          "player_id" => player.player_id,
          "seat" => player.seat,
          "action" => action
        })
    }
  end

  defp seat!(table, seat, player_id, stack) do
    {:ok, table} = Table.seat_player(table, seat, player_id, stack)
    table
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

  defp fold_all_in(%Table{hand: nil} = table), do: {:ok, table}

  defp fold_all_in(%Table{hand: %Table.Hand{acting_seat: seat}} = table) when is_integer(seat) do
    {:ok, next_table} = Table.act(table, seat, :fold)
    fold_all_in(next_table)
  end

  defp check_to_completion(%Table{hand: nil} = table), do: {:ok, table}

  defp check_to_completion(%Table{} = table) do
    {:ok, legal} = Table.legal_actions(table)
    action = if :check in legal.options, do: :check, else: :fold
    {:ok, next_table} = Table.act(table, legal.seat, action)
    check_to_completion(next_table)
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end
end
