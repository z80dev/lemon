defmodule LemonSim.Examples.Poker do
  @moduledoc """
  Multi-hand no-limit hold'em example built on LemonSim.
  """

  alias AgentCore.Types.AgentTool
  alias LemonCore.Config.Modular
  alias LemonCore.MapHelpers
  alias LemonSim.Deciders.ToolLoopDecider

  alias LemonSim.Examples.Poker.{
    ActionSpace,
    DecisionAdapter,
    Events,
    Performance,
    ToolPolicy,
    Updater
  }

  alias LemonSim.Examples.Poker.Engine.{Card, Table}
  alias LemonSim.GameHelpers
  alias LemonSim.GameHelpers.Config, as: GameConfig
  alias LemonSim.Projectors.{SectionedProjector, Toolkit}
  alias LemonSim.{Event, Runner, State, Store}
  alias LemonSim.GameHelpers.Runner, as: GameRunner

  import LemonSim.GameHelpers, only: []

  @default_max_turns 200
  @default_player_count 4
  @default_starting_stack 2_000
  @default_max_hands 12

  @spec initial_world(keyword()) :: map()
  def initial_world(opts \\ []) do
    player_ids = player_ids(opts)
    max_seats = max(Keyword.get(opts, :max_seats, length(player_ids)), length(player_ids))
    base_small_blind = Keyword.get(opts, :small_blind, 50)
    base_big_blind = Keyword.get(opts, :big_blind, 100)
    blind_schedule = normalize_blind_schedule(Keyword.get(opts, :blind_schedule, []))

    {small_blind, big_blind} =
      blinds_for_hand(blind_schedule, 1, base_small_blind, base_big_blind)

    starting_stack = Keyword.get(opts, :starting_stack, @default_starting_stack)
    base_seed = Keyword.get(opts, :seed, :erlang.phash2(:erlang.monotonic_time()))
    max_hands = Keyword.get(opts, :max_hands, @default_max_hands)

    {:ok, seated_table} =
      "poker_table_1"
      |> Table.new(max_seats: max_seats, small_blind: small_blind, big_blind: big_blind)
      |> seat_players(player_ids, starting_stack)

    hand_opts =
      []
      |> GameHelpers.maybe_put(:seed, base_seed)
      |> GameHelpers.maybe_put(:deck, Keyword.get(opts, :deck))

    {:ok, table} = Table.start_hand(seated_table, hand_opts)

    {current_seat, current_actor_id} = current_actor(table)

    %{
      table: table,
      status: "in_progress",
      winner: nil,
      winner_ids: [],
      game_over_reason: nil,
      current_actor_id: current_actor_id,
      current_seat: current_seat,
      completed_hands: 0,
      max_hands: max_hands,
      base_seed: base_seed,
      player_count: length(player_ids),
      starting_stack: starting_stack,
      big_blind: big_blind,
      small_blind: small_blind,
      blind_schedule: blind_schedule,
      player_stats: init_player_stats(player_ids, starting_stack),
      player_notes: Enum.into(player_ids, %{}, &{&1, []}),
      consecutive_rejections: %{},
      chip_counts: chip_counts(table),
      last_hand_result: nil,
      performance: nil
    }
  end

  @spec initial_state(keyword()) :: State.t()
  def initial_state(opts \\ []) do
    world = initial_world(opts)
    table = Map.fetch!(world, :table)
    sim_id = Keyword.get(opts, :sim_id, "poker_#{:erlang.phash2(:erlang.monotonic_time())}")

    State.new(
      sim_id: sim_id,
      world: world,
      intent: %{
        goal: "Play no-limit hold'em and finish with the largest chip stack."
      },
      plan_history: []
    )
    |> State.append_event(Events.hand_started(table.hand, table.seats))
  end

  @spec modules() :: map()
  def modules do
    %{
      action_space: ActionSpace,
      projector: SectionedProjector,
      decider: ToolLoopDecider,
      updater: Updater,
      decision_adapter: DecisionAdapter
    }
  end

  @spec projector_opts() :: keyword()
  def projector_opts do
    [
      section_builders: %{
        table_state: fn frame, _tools, _opts ->
          %{
            id: :table_state,
            title: "Table State",
            format: :json,
            content: public_table_view(frame.world)
          }
        end,
        your_hand: fn frame, _tools, _opts ->
          %{
            id: :your_hand,
            title: "Your Seat",
            format: :json,
            content: actor_view(frame.world)
          }
        end,
        opponents: fn frame, _tools, _opts ->
          %{
            id: :opponents,
            title: "Opponents",
            format: :json,
            content: opponent_view(frame.world)
          }
        end,
        notes: fn frame, _tools, _opts ->
          %{
            id: :notes,
            title: "Private Notes",
            format: :json,
            content: visible_notes(frame.world)
          }
        end,
        hand_actions: fn frame, _tools, _opts ->
          %{
            id: :hand_actions,
            title: "Hand Actions",
            format: :json,
            content: group_actions_by_street(frame.recent_events, frame.world)
          }
        end,
        recent_events: fn frame, _tools, _opts ->
          %{
            id: :recent_events,
            title: "Recent Events",
            format: :json,
            content: visible_recent_events(frame.recent_events, frame.world)
          }
        end
      },
      section_overrides: %{
        decision_contract: """
        POKER RULES:
        - End each turn with exactly one action tool call.
        - `note` is optional and does not end your turn.
        - `bet_to` and `raise_to` expect the total chips you will have committed on this street after the action.
        - Stay inside the legal min/max shown in the tool description.
        - Fold weak hands facing large pressure; preserve chips for later hands.
        - Favor checking when you can reach showdown cheaply with marginal hands.
        - Pursue value bets and raises with strong made hands.
        """
      },
      section_order: [
        :table_state,
        :your_hand,
        :opponents,
        :notes,
        :hand_actions,
        :recent_events,
        :current_intent,
        :available_actions,
        :decision_contract
      ]
    ]
  end

  @spec default_opts(keyword()) :: keyword()
  def default_opts(overrides \\ []) when is_list(overrides) do
    config = Modular.load(project_dir: File.cwd!())

    model =
      Keyword.get_lazy(overrides, :model, fn ->
        GameConfig.resolve_configured_model!(config, "poker")
      end)

    stream_options =
      Keyword.get_lazy(overrides, :stream_options, fn ->
        %{api_key: GameConfig.resolve_provider_api_key!(model.provider, config, "poker")}
      end)

    projector_opts()
    |> Kernel.++(
      model: model,
      stream_options: stream_options,
      driver_max_turns: @default_max_turns,
      persist?: true,
      terminal?: &terminal?/1,
      tool_policy: ToolPolicy,
      support_tool_matcher: &support_tool?/1,
      on_before_step: &announce_turn/2,
      on_after_step: &print_step/2
    )
    |> GameHelpers.maybe_put(:complete_fn, Keyword.get(overrides, :complete_fn))
  end

  @spec run_multi_model(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run_multi_model(opts \\ []) when is_list(opts) do
    _model_assignments = Keyword.fetch!(opts, :model_assignments)
    state = initial_state(opts)

    state =
      State.put_world(state, %{
        active_actor_id: MapHelpers.get_key(state.world, :current_actor_id)
      })

    default_opts_fn = fn overrides ->
      default_opts(Keyword.merge(opts, overrides))
    end

    GameRunner.run_multi_model(state, modules(), default_opts_fn, opts,
      print_setup: fn s ->
        world = s.world
        IO.puts("Starting Poker (multi-model)")

        IO.puts(
          "Players: #{MapHelpers.get_key(world, :player_count)} | Max hands: #{MapHelpers.get_key(world, :max_hands)}"
        )
      end,
      print_result: fn world ->
        perf = Performance.summarize(world)
        print_game_result(Map.put(world, :performance, perf))
      end,
      announce_turn: &announce_turn/2,
      print_step: &print_step/2,
      transcript_detail: fn _world -> %{} end,
      transcript_game_over_extra: fn world ->
        %{completed_hands: MapHelpers.get_key(world, :completed_hands)}
      end
    )
  end

  defp print_game_result(world) do
    winner_ids = MapHelpers.get_key(world, :winner_ids) || []
    reason = MapHelpers.get_key(world, :game_over_reason)

    IO.puts(
      "  status=#{MapHelpers.get_key(world, :status)} reason=#{reason} completed_hands=#{MapHelpers.get_key(world, :completed_hands)} winners=#{Enum.join(winner_ids, ", ")}"
    )

    Enum.each(MapHelpers.get_key(world, :chip_counts) || [], fn seat_info ->
      IO.puts(
        "  seat=#{seat_info["seat"]} player=#{seat_info["player_id"]} stack=#{seat_info["stack"]} status=#{seat_info["status"]}"
      )
    end)

    case MapHelpers.get_key(world, :performance) do
      nil ->
        :ok

      perf ->
        IO.puts("\nPerformance:")

        Enum.each(Map.get(perf, :players, %{}), fn {pid, pstats} ->
          IO.puts(
            "  #{pid}: stack=#{pstats.final_stack} P/L=#{pstats.profit_loss} bb/h=#{pstats.bb_per_hand} VPIP=#{pstats.vpip} PFR=#{pstats.pfr}"
          )
        end)
    end
  end

  @spec run(keyword()) :: {:ok, State.t()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    state = initial_state(opts)
    run_opts = Keyword.merge(default_opts(opts), opts)

    IO.puts("Starting Poker self-play")

    IO.puts(
      "Players: #{MapHelpers.get_key(state.world, :player_count)} | Max hands: #{MapHelpers.get_key(state.world, :max_hands)}"
    )

    case Runner.run_until_terminal(state, modules(), run_opts) do
      {:ok, final_state} ->
        performance = Performance.summarize(final_state.world)
        final_state = State.put_world(final_state, %{performance: performance})

        IO.puts("Final state:")
        print_summary(final_state)

        if Keyword.get(run_opts, :persist?, true) do
          _ = Store.put_state(final_state)
        end

        {:ok, final_state}

      {:error, reason} = error ->
        IO.puts("Poker sim failed:")
        IO.inspect(reason)
        error
    end
  end

  defp terminal?(state), do: MapHelpers.get_key(state.world, :status) == "game_over"

  defp announce_turn(turn, state) do
    table = MapHelpers.get_key(state.world, :table)
    street = table.hand && table.hand.street
    actor = MapHelpers.get_key(state.world, :current_actor_id)
    pot = table.hand && table.hand.pot

    IO.puts("Step #{turn} | hand=#{table.hand_id} street=#{street} actor=#{actor} pot=#{pot}")
  end

  defp print_step(_turn, %{state: next_state}) do
    print_status(next_state)
  end

  defp print_step(_turn, _result), do: :ok

  defp print_status(state) do
    world = state.world
    table = MapHelpers.get_key(world, :table)

    cond do
      MapHelpers.get_key(world, :status) == "game_over" ->
        print_summary(state)

      table.hand ->
        IO.puts(
          "  hand=#{table.hand.id} street=#{table.hand.street} board=#{Enum.join(Enum.map(table.hand.board, &Card.to_short_string/1), " ")} actor=#{MapHelpers.get_key(world, :current_actor_id)}"
        )

      true ->
        IO.puts("  waiting for next hand")
    end
  end

  defp print_summary(state) do
    world = state.world
    winner_ids = MapHelpers.get_key(world, :winner_ids) || []
    reason = MapHelpers.get_key(world, :game_over_reason)

    IO.puts(
      "  status=#{MapHelpers.get_key(world, :status)} reason=#{reason} completed_hands=#{MapHelpers.get_key(world, :completed_hands)} winners=#{Enum.join(winner_ids, ", ")}"
    )

    Enum.each(MapHelpers.get_key(world, :chip_counts) || [], fn seat_info ->
      IO.puts(
        "  seat=#{seat_info["seat"]} player=#{seat_info["player_id"]} stack=#{seat_info["stack"]} status=#{seat_info["status"]}"
      )
    end)
  end

  defp public_table_view(world) do
    table = MapHelpers.get_key(world, :table)
    hand = table.hand

    %{
      "status" => MapHelpers.get_key(world, :status),
      "completed_hands" => MapHelpers.get_key(world, :completed_hands),
      "max_hands" => MapHelpers.get_key(world, :max_hands),
      "current_actor_id" => MapHelpers.get_key(world, :current_actor_id),
      "current_seat" => MapHelpers.get_key(world, :current_seat),
      "small_blind" => table.small_blind,
      "big_blind" => table.big_blind,
      "board" => board_strings(hand),
      "street" => hand && hand.street,
      "pot" => hand && hand.pot,
      "to_call" => hand && hand.to_call,
      "min_raise" => hand && hand.min_raise,
      "button_player_id" => player_id_for(table, hand && hand.button_seat),
      "small_blind_player_id" => player_id_for(table, hand && hand.small_blind_seat),
      "big_blind_player_id" => player_id_for(table, hand && hand.big_blind_seat),
      "seats" => seat_summaries(table),
      "last_hand_result" => MapHelpers.get_key(world, :last_hand_result)
    }
  end

  defp actor_view(world) do
    table = MapHelpers.get_key(world, :table)
    seat = MapHelpers.get_key(world, :current_seat)

    case table.hand && Map.get(table.hand.players, seat) do
      nil ->
        %{
          "player_id" => MapHelpers.get_key(world, :current_actor_id),
          "status" => MapHelpers.get_key(world, :status)
        }

      player ->
        %{
          "player_id" => player.player_id,
          "seat" => player.seat,
          "position" => position_label(seat, table),
          "stack" => player.stack,
          "hole_cards" => Enum.map(player.hole_cards, &Card.to_short_string/1),
          "committed_round" => player.committed_round,
          "committed_total" => player.committed_total,
          "all_in" => player.all_in,
          "folded" => player.folded
        }
    end
  end

  defp opponent_view(world) do
    table = MapHelpers.get_key(world, :table)
    current_seat = MapHelpers.get_key(world, :current_seat)
    hand_players = if table.hand, do: table.hand.players, else: %{}

    table.seats
    |> Enum.sort_by(fn {seat, _player} -> seat end)
    |> Enum.reject(fn {seat, _player} -> seat == current_seat end)
    |> Enum.map(fn {seat, seat_player} ->
      hand_player = Map.get(hand_players, seat, %{})

      %{
        "seat" => seat,
        "player_id" => seat_player.player_id,
        "position" => position_label(seat, table),
        "stack" => seat_player.stack,
        "status" => to_string(seat_player.status),
        "committed_round" => Map.get(hand_player, :committed_round, 0),
        "committed_total" => Map.get(hand_player, :committed_total, 0),
        "all_in" => Map.get(hand_player, :all_in, false),
        "folded" => Map.get(hand_player, :folded, false)
      }
    end)
  end

  defp visible_notes(world) do
    player_id = MapHelpers.get_key(world, :current_actor_id)

    case MapHelpers.get_key(world, :player_notes) do
      notes when is_map(notes) -> Map.get(notes, player_id, [])
      _ -> []
    end
  end

  defp visible_recent_events(events, world) do
    actor_id = MapHelpers.get_key(world, :current_actor_id)

    events
    |> Enum.take(-12)
    |> Enum.filter(&event_visible?(&1, actor_id))
    |> Enum.map(&sanitize_event/1)
    |> Toolkit.normalize_events()
  end

  defp event_visible?(%Event{kind: "player_note", payload: payload}, actor_id) do
    Map.get(payload, "player_id", Map.get(payload, :player_id)) == actor_id
  end

  defp event_visible?(%Event{kind: "action_rejected", payload: payload}, actor_id) do
    Map.get(payload, "player_id", Map.get(payload, :player_id)) == actor_id
  end

  defp event_visible?(%Event{kind: "deal_hole_cards", payload: payload}, actor_id) do
    Map.get(payload, "player_id", Map.get(payload, :player_id)) == actor_id
  end

  defp event_visible?(%Event{}, _actor_id), do: true
  defp event_visible?(_event, _actor_id), do: true

  defp sanitize_event(%Event{kind: "hand_completed", payload: payload} = event) do
    showdown =
      payload
      |> Map.get("showdown", Map.get(payload, :showdown, %{}))
      |> sanitize_showdown()

    %{event | payload: Map.put(payload, "showdown", showdown)}
  end

  defp sanitize_event(event), do: event

  defp sanitize_showdown(showdown) when is_map(showdown) do
    Enum.into(showdown, %{}, fn {seat, info} ->
      normalized = Map.new(info)

      {seat,
       Map.take(normalized, [
         "category",
         :category,
         "tiebreaker",
         :tiebreaker,
         "hole_cards",
         :hole_cards
       ])}
    end)
  end

  defp sanitize_showdown(other), do: other

  defp group_actions_by_street(events, world) do
    current_hand_id = current_hand_id(world)

    base = %{"preflop" => [], "flop" => [], "turn" => [], "river" => []}

    Enum.reduce(events, base, fn event, acc ->
      case normalize_action_event(event, world, current_hand_id) do
        nil ->
          acc

        {street, action} ->
          Map.update!(acc, street, &(&1 ++ [action]))
      end
    end)
  end

  defp normalize_action_event(%Event{kind: "poker_action", payload: payload}, world, hand_id) do
    event_hand_id = Map.get(payload, "hand_id", Map.get(payload, :hand_id))

    if is_nil(hand_id) or event_hand_id == hand_id do
      street =
        payload
        |> Map.get("street", Map.get(payload, :street))
        |> normalize_street()

      if street do
        {street,
         %{
           "player" => Map.get(payload, "player_id", Map.get(payload, :player_id)),
           "position" => seat_position(Map.get(payload, "seat", Map.get(payload, :seat)), world),
           "action" => Map.get(payload, "action", Map.get(payload, :action)),
           "amount" => action_amount(payload)
         }
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> Enum.into(%{})}
      end
    end
  end

  defp normalize_action_event(_event, _world, _hand_id), do: nil

  defp current_hand_id(world) do
    table = MapHelpers.get_key(world, :table)
    last_hand_result = MapHelpers.get_key(world, :last_hand_result)

    cond do
      table && table.hand -> table.hand.id
      is_map(last_hand_result) -> MapHelpers.get_key(last_hand_result, :hand_id)
      true -> nil
    end
  end

  defp action_amount(payload) do
    Map.get(
      payload,
      "amount",
      Map.get(payload, :amount, Map.get(payload, "total", Map.get(payload, :total)))
    )
  end

  defp normalize_street(street) when street in [:preflop, :flop, :turn, :river],
    do: Atom.to_string(street)

  defp normalize_street(street)
       when is_binary(street) and street in ["preflop", "flop", "turn", "river"],
       do: street

  defp normalize_street(_street), do: nil

  defp player_ids(opts) do
    case Keyword.get(opts, :player_ids) do
      ids when is_list(ids) and ids != [] ->
        ids
        |> Enum.map(&to_string/1)
        |> Enum.take(9)

      _ ->
        count =
          opts
          |> Keyword.get(:player_count, @default_player_count)
          |> max(2)
          |> min(9)

        Enum.map(1..count, &"player_#{&1}")
    end
  end

  def blind_schedule_for_hand(world, hand_number) do
    base_small_blind = MapHelpers.get_key(world, :small_blind) || 50
    base_big_blind = MapHelpers.get_key(world, :big_blind) || 100
    blind_schedule = MapHelpers.get_key(world, :blind_schedule) || []

    blinds_for_hand(blind_schedule, hand_number, base_small_blind, base_big_blind)
  end

  defp normalize_blind_schedule(schedule) when is_list(schedule) do
    schedule
    |> Enum.map(&normalize_blind_level/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1["hand_number"])
  end

  defp normalize_blind_schedule(_schedule), do: []

  defp normalize_blind_level({hand_number, small_blind, big_blind})
       when is_integer(hand_number) and is_integer(small_blind) and is_integer(big_blind) do
    normalize_blind_level(%{
      hand_number: hand_number,
      small_blind: small_blind,
      big_blind: big_blind
    })
  end

  defp normalize_blind_level(%{
         hand_number: hand_number,
         small_blind: small_blind,
         big_blind: big_blind
       })
       when is_integer(hand_number) and is_integer(small_blind) and is_integer(big_blind) and
              hand_number > 0 and small_blind > 0 and big_blind >= small_blind do
    %{
      "hand_number" => hand_number,
      "small_blind" => small_blind,
      "big_blind" => big_blind
    }
  end

  defp normalize_blind_level(%{
         "hand_number" => hand_number,
         "small_blind" => small_blind,
         "big_blind" => big_blind
       }) do
    normalize_blind_level(%{
      hand_number: hand_number,
      small_blind: small_blind,
      big_blind: big_blind
    })
  end

  defp normalize_blind_level(_level), do: nil

  defp blinds_for_hand(schedule, hand_number, default_small_blind, default_big_blind) do
    schedule
    |> Enum.reduce({default_small_blind, default_big_blind}, fn
      %{"hand_number" => start_hand, "small_blind" => small_blind, "big_blind" => big_blind}, _acc
      when start_hand <= hand_number ->
        {small_blind, big_blind}

      _level, acc ->
        acc
    end)
  end

  defp seat_players(table, player_ids, starting_stack) do
    Enum.reduce_while(Enum.with_index(player_ids, 1), {:ok, table}, fn {player_id, seat},
                                                                       {:ok, acc} ->
      case Table.seat_player(acc, seat, player_id, starting_stack) do
        {:ok, next_table} -> {:cont, {:ok, next_table}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp current_actor(%Table{hand: %Table.Hand{} = hand}) do
    case hand.acting_seat do
      nil ->
        {nil, nil}

      seat ->
        player = Map.get(hand.players, seat)
        {seat, player && player.player_id}
    end
  end

  defp current_actor(_table), do: {nil, nil}

  defp chip_counts(table) do
    table.seats
    |> Enum.sort_by(fn {seat, _player} -> seat end)
    |> Enum.map(fn {seat, player} ->
      %{
        "seat" => seat,
        "player_id" => player.player_id,
        "stack" => player.stack,
        "status" => to_string(player.status)
      }
    end)
  end

  defp seat_summaries(table) do
    table.seats
    |> Enum.sort_by(fn {seat, _player} -> seat end)
    |> Enum.map(fn {seat, player} ->
      %{
        "seat" => seat,
        "player_id" => player.player_id,
        "position" => position_label(seat, table),
        "stack" => player.stack,
        "status" => to_string(player.status)
      }
    end)
  end

  defp player_id_for(_table, nil), do: nil

  defp player_id_for(table, seat) do
    case Map.get(table.seats, seat) do
      %{player_id: player_id} -> player_id
      _ -> nil
    end
  end

  defp position_label(nil, _table), do: nil

  defp position_label(seat, %Table{} = table) do
    {button_seat, sb_seat, bb_seat, active_seats} = hand_position_inputs(table)
    Table.position_label(seat, button_seat, sb_seat, bb_seat, active_seats)
  end

  defp seat_position(nil, _world), do: nil

  defp seat_position(seat, world) do
    position_label(seat, MapHelpers.get_key(world, :table))
  end

  defp hand_position_inputs(%Table{hand: %Table.Hand{} = hand}) do
    {hand.button_seat, hand.small_blind_seat, hand.big_blind_seat,
     Map.keys(hand.players) |> Enum.sort()}
  end

  defp hand_position_inputs(%Table{} = table) do
    active_seats =
      table.seats
      |> Enum.filter(fn {_seat, player} -> player.status == :active and player.stack > 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    {table.button_seat, nil, nil, active_seats}
  end

  defp board_strings(nil), do: []
  defp board_strings(hand), do: Enum.map(hand.board, &Card.to_short_string/1)

  defp init_player_stats(player_ids, starting_stack) do
    Enum.into(player_ids, %{}, fn player_id ->
      {player_id,
       %{
         starting_stack: starting_stack,
         hands_played: 0,
         hands_won: 0,
         vpip_hands: 0,
         pfr_hands: 0,
         total_actions: 0,
         fold_count: 0,
         check_count: 0,
         call_count: 0,
         bet_count: 0,
         raise_count: 0,
         current_hand: %{vpip: false, pfr: false}
       }}
    end)
  end

  defp support_tool?(%AgentTool{name: "note"}), do: true
  defp support_tool?(%AgentTool{}), do: false
end
