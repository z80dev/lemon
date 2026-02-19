defmodule LemonPoker.Table do
  @moduledoc """
  End-to-end no-limit hold'em table state machine.

  The module is intentionally pure-state: each function receives/returns an immutable table struct.
  """

  alias LemonPoker.{Card, Deck, HandRank}

  @type action ::
          :fold
          | :check
          | :call
          | {:bet, non_neg_integer()}
          | {:raise, non_neg_integer()}

  @type seat_status :: :active | :sitting_out | :busted

  defmodule SeatPlayer do
    @moduledoc false
    @enforce_keys [:seat, :player_id, :stack]
    defstruct [:seat, :player_id, :stack, status: :active]

    @type t :: %__MODULE__{
            seat: pos_integer(),
            player_id: String.t(),
            stack: non_neg_integer(),
            status: LemonPoker.Table.seat_status()
          }
  end

  defmodule HandPlayer do
    @moduledoc false
    @enforce_keys [:seat, :player_id, :stack]
    defstruct [
      :seat,
      :player_id,
      :stack,
      hole_cards: [],
      committed_round: 0,
      committed_total: 0,
      folded: false,
      all_in: false,
      can_raise: true
    ]

    @type t :: %__MODULE__{
            seat: pos_integer(),
            player_id: String.t(),
            stack: non_neg_integer(),
            hole_cards: [LemonPoker.Card.t()],
            committed_round: non_neg_integer(),
            committed_total: non_neg_integer(),
            folded: boolean(),
            all_in: boolean(),
            can_raise: boolean()
          }
  end

  defmodule SidePot do
    @moduledoc false
    @enforce_keys [:amount, :eligible_seats]
    defstruct [:amount, :eligible_seats]

    @type t :: %__MODULE__{
            amount: non_neg_integer(),
            eligible_seats: [pos_integer()]
          }
  end

  defmodule Hand do
    @moduledoc false
    @enforce_keys [
      :id,
      :button_seat,
      :small_blind_seat,
      :big_blind_seat,
      :street,
      :deck,
      :board,
      :pot,
      :to_call,
      :min_raise,
      :players,
      :action_queue
    ]
    defstruct [
      :id,
      :button_seat,
      :small_blind_seat,
      :big_blind_seat,
      :street,
      :deck,
      :board,
      :pot,
      :to_call,
      :min_raise,
      :players,
      :action_queue,
      :acting_seat,
      events: []
    ]

    @type t :: %__MODULE__{
            id: pos_integer(),
            button_seat: pos_integer(),
            small_blind_seat: pos_integer(),
            big_blind_seat: pos_integer(),
            street: :preflop | :flop | :turn | :river,
            deck: [LemonPoker.Card.t()],
            board: [LemonPoker.Card.t()],
            pot: non_neg_integer(),
            to_call: non_neg_integer(),
            min_raise: non_neg_integer(),
            players: %{optional(pos_integer()) => HandPlayer.t()},
            action_queue: [pos_integer()],
            acting_seat: pos_integer() | nil,
            events: [map()]
          }
  end

  @type t :: %__MODULE__{
          id: String.t(),
          max_seats: pos_integer(),
          small_blind: pos_integer(),
          big_blind: pos_integer(),
          button_seat: pos_integer() | nil,
          hand_id: non_neg_integer(),
          seats: %{optional(pos_integer()) => SeatPlayer.t()},
          hand: Hand.t() | nil,
          last_hand_result: map() | nil
        }

  @enforce_keys [:id, :max_seats, :small_blind, :big_blind]
  defstruct [
    :id,
    :max_seats,
    :small_blind,
    :big_blind,
    button_seat: nil,
    hand_id: 0,
    seats: %{},
    hand: nil,
    last_hand_result: nil
  ]

  @doc """
  Creates a table state.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(id, opts \\ []) do
    max_seats = Keyword.get(opts, :max_seats, 9)
    small_blind = Keyword.get(opts, :small_blind, 50)
    big_blind = Keyword.get(opts, :big_blind, 100)

    unless max_seats > 1, do: raise(ArgumentError, "max_seats must be > 1")

    unless small_blind > 0 and big_blind > 0 and big_blind >= small_blind,
      do: raise(ArgumentError, "invalid blind values")

    %__MODULE__{
      id: id,
      max_seats: max_seats,
      small_blind: small_blind,
      big_blind: big_blind
    }
  end

  @doc """
  Seats a player at a seat index.
  """
  @spec seat_player(t(), pos_integer(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, atom()}
  def seat_player(%__MODULE__{} = table, seat, player_id, stack)
      when is_integer(seat) and is_binary(player_id) and is_integer(stack) and stack > 0 do
    cond do
      seat < 1 or seat > table.max_seats ->
        {:error, :invalid_seat}

      Map.has_key?(table.seats, seat) ->
        {:error, :seat_occupied}

      Enum.any?(table.seats, fn {_seat, player} -> player.player_id == player_id end) ->
        {:error, :player_already_seated}

      true ->
        seat_player = %SeatPlayer{seat: seat, player_id: player_id, stack: stack, status: :active}
        {:ok, put_in(table.seats[seat], seat_player)}
    end
  end

  def seat_player(_table, _seat, _player_id, _stack), do: {:error, :invalid_player}

  @doc """
  Updates a seated player's status.
  """
  @spec set_status(t(), pos_integer(), seat_status()) :: {:ok, t()} | {:error, atom()}
  def set_status(%__MODULE__{} = table, seat, status)
      when status in [:active, :sitting_out, :busted] do
    case Map.fetch(table.seats, seat) do
      {:ok, player} -> {:ok, put_in(table.seats[seat], %{player | status: status})}
      :error -> {:error, :seat_not_found}
    end
  end

  @doc """
  Starts a new hand and posts blinds.

  Options:
  - `:seed` deterministic shuffle seed.
  - `:deck` explicit deck top-order (for deterministic tests).
  """
  @spec start_hand(t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def start_hand(table, opts \\ [])
  def start_hand(%__MODULE__{hand: %Hand{}}, _opts), do: {:error, :hand_in_progress}

  def start_hand(%__MODULE__{} = table, opts) do
    active = active_seats(table)

    if length(active) < 2 do
      {:error, :not_enough_players}
    else
      button = next_button_seat(table.button_seat, active)
      {small_blind_seat, big_blind_seat} = blind_seats(active, button)

      with {:ok, deck} <- resolve_deck(opts),
           {:ok, hand_players, deck_after_hole} <-
             deal_hole_cards(table, active, small_blind_seat, deck),
           {blind_players, posted_pot, sb_posted, bb_posted} <-
             post_blinds(
               hand_players,
               small_blind_seat,
               table.small_blind,
               big_blind_seat,
               table.big_blind
             ) do
        to_call = max(sb_posted, bb_posted)
        first_actor = preflop_first_actor(active, big_blind_seat, blind_players)
        action_queue = build_queue(blind_players, first_actor)

        hand = %Hand{
          id: table.hand_id + 1,
          button_seat: button,
          small_blind_seat: small_blind_seat,
          big_blind_seat: big_blind_seat,
          street: :preflop,
          deck: deck_after_hole,
          board: [],
          pot: posted_pot,
          to_call: to_call,
          min_raise: table.big_blind,
          players: blind_players,
          action_queue: action_queue,
          acting_seat: List.first(action_queue),
          events: [
            %{type: :blind_posted, seat: small_blind_seat, amount: sb_posted},
            %{type: :blind_posted, seat: big_blind_seat, amount: bb_posted}
          ]
        }

        updated =
          %{
            table
            | button_seat: button,
              hand_id: table.hand_id + 1,
              hand: hand,
              last_hand_result: nil
          }
          |> advance_until_action_or_complete()

        {:ok, updated}
      end
    end
  end

  @doc """
  Returns legal actions for the current actor.
  """
  @spec legal_actions(t()) :: {:ok, map()} | {:error, atom()}
  def legal_actions(%__MODULE__{hand: nil}), do: {:error, :no_hand_in_progress}

  def legal_actions(%__MODULE__{hand: %Hand{} = hand}) do
    case hand.acting_seat do
      nil ->
        {:error, :no_actor}

      seat ->
        player = Map.fetch!(hand.players, seat)
        call_amount = max(hand.to_call - player.committed_round, 0)
        max_total = player.committed_round + player.stack
        facing_bet? = hand.to_call > 0

        raise_spec =
          if player.can_raise and max_total > hand.to_call do
            min_total = hand.to_call + hand.min_raise

            cond do
              max_total < min_total and max_total > hand.to_call ->
                %{min: max_total, max: max_total, all_in_only: true}

              max_total >= min_total ->
                %{min: min_total, max: max_total, all_in_only: false}

              true ->
                nil
            end
          else
            nil
          end

        bet_spec =
          if player.can_raise and not facing_bet? and player.stack > 0 do
            min_total = hand.min_raise

            cond do
              max_total < min_total and max_total > 0 ->
                %{min: max_total, max: max_total, all_in_only: true}

              max_total >= min_total ->
                %{min: min_total, max: max_total, all_in_only: false}

              true ->
                nil
            end
          else
            nil
          end

        options =
          []
          |> maybe_add(:fold, true)
          |> maybe_add(:check, call_amount == 0)
          |> maybe_add(:call, call_amount > 0 and player.stack > 0)
          |> maybe_add(:bet, not is_nil(bet_spec))
          |> maybe_add(:raise, not is_nil(raise_spec))

        {:ok,
         %{
           seat: seat,
           street: hand.street,
           to_call: call_amount,
           options: options,
           bet: bet_spec,
           raise: raise_spec
         }}
    end
  end

  @doc """
  Applies an action for the acting seat.
  """
  @spec act(t(), pos_integer(), action()) :: {:ok, t()} | {:error, atom()}
  def act(%__MODULE__{hand: nil}, _seat, _action), do: {:error, :no_hand_in_progress}

  def act(%__MODULE__{hand: %Hand{} = hand} = table, seat, action) do
    cond do
      hand.acting_seat != seat ->
        {:error, :not_your_turn}

      true ->
        with {:ok, legal} <- legal_actions(table),
             :ok <- validate_action(action, legal),
             {:ok, updated_hand} <- apply_action(hand, seat, action) do
          updated_table = %{table | hand: updated_hand} |> advance_until_action_or_complete()
          {:ok, updated_table}
        end
    end
  end

  defp validate_action(:fold, %{options: options}) do
    if :fold in options, do: :ok, else: {:error, :invalid_action}
  end

  defp validate_action(:check, %{options: options}) do
    if :check in options, do: :ok, else: {:error, :invalid_action}
  end

  defp validate_action(:call, %{options: options}) do
    if :call in options, do: :ok, else: {:error, :invalid_action}
  end

  defp validate_action({:bet, amount}, %{options: options, bet: %{min: min, max: max} = spec})
       when is_integer(amount) do
    if :bet in options,
      do: validate_amount(amount, min, max, spec),
      else: {:error, :invalid_action}
  end

  defp validate_action({:raise, amount}, %{options: options, raise: %{min: min, max: max} = spec})
       when is_integer(amount) do
    if :raise in options,
      do: validate_amount(amount, min, max, spec),
      else: {:error, :invalid_action}
  end

  defp validate_action(_, _), do: {:error, :invalid_action}

  defp validate_amount(amount, _min, max, %{all_in_only: true}) do
    if amount == max, do: :ok, else: {:error, :invalid_amount}
  end

  defp validate_amount(amount, min, max, _spec) do
    if amount >= min and amount <= max, do: :ok, else: {:error, :invalid_amount}
  end

  defp apply_action(hand, seat, :fold) do
    players =
      update_player!(hand.players, seat, fn player ->
        %{player | folded: true, can_raise: false}
      end)

    queue = trim_queue(tl_or_empty(hand.action_queue), players)
    pot = Enum.reduce(players, 0, fn {_seat, player}, acc -> acc + player.committed_total end)

    {:ok,
     %{
       hand
       | players: players,
         action_queue: queue,
         acting_seat: List.first(queue),
         pot: pot,
         events: hand.events ++ [%{type: :action, seat: seat, action: :fold}]
     }}
  end

  defp apply_action(hand, seat, :check) do
    players = update_player!(hand.players, seat, fn player -> %{player | can_raise: false} end)
    queue = trim_queue(tl_or_empty(hand.action_queue), players)

    {:ok,
     %{
       hand
       | players: players,
         action_queue: queue,
         acting_seat: List.first(queue),
         events: hand.events ++ [%{type: :action, seat: seat, action: :check}]
     }}
  end

  defp apply_action(hand, seat, :call) do
    player = Map.fetch!(hand.players, seat)
    call_amount = max(hand.to_call - player.committed_round, 0)
    {updated_player, committed} = commit_chips(player, call_amount)

    players =
      hand.players
      |> Map.put(seat, %{updated_player | can_raise: false})

    queue = trim_queue(tl_or_empty(hand.action_queue), players)

    {:ok,
     %{
       hand
       | players: players,
         action_queue: queue,
         acting_seat: List.first(queue),
         pot: hand.pot + committed,
         events: hand.events ++ [%{type: :action, seat: seat, action: :call, amount: committed}]
     }}
  end

  defp apply_action(hand, seat, {:bet, amount}) do
    player = Map.fetch!(hand.players, seat)
    additional = amount - player.committed_round
    {updated_player, committed} = commit_chips(player, additional)
    raise_size = amount
    full_raise? = raise_size >= hand.min_raise

    {players, new_min_raise} =
      hand.players
      |> Map.put(seat, %{updated_player | can_raise: false})
      |> apply_raise_reopen_rules(seat, full_raise?, hand.min_raise, raise_size)

    queue = queue_after_aggression(players, seat)

    {:ok,
     %{
       hand
       | players: players,
         to_call: amount,
         min_raise: new_min_raise,
         pot: hand.pot + committed,
         action_queue: queue,
         acting_seat: List.first(queue),
         events: hand.events ++ [%{type: :action, seat: seat, action: :bet, amount: amount}]
     }}
  end

  defp apply_action(hand, seat, {:raise, amount}) do
    player = Map.fetch!(hand.players, seat)
    additional = amount - player.committed_round
    {updated_player, committed} = commit_chips(player, additional)
    raise_size = amount - hand.to_call
    full_raise? = raise_size >= hand.min_raise

    {players, new_min_raise} =
      hand.players
      |> Map.put(seat, %{updated_player | can_raise: false})
      |> apply_raise_reopen_rules(seat, full_raise?, hand.min_raise, raise_size)

    queue = queue_after_aggression(players, seat)

    {:ok,
     %{
       hand
       | players: players,
         to_call: amount,
         min_raise: new_min_raise,
         pot: hand.pot + committed,
         action_queue: queue,
         acting_seat: List.first(queue),
         events: hand.events ++ [%{type: :action, seat: seat, action: :raise, amount: amount}]
     }}
  end

  defp apply_raise_reopen_rules(players, actor_seat, true, _old_min_raise, raise_size) do
    reopened_players =
      players
      |> Enum.map(fn {seat, player} ->
        can_raise_now = can_act?(player) and seat != actor_seat
        {seat, %{player | can_raise: can_raise_now}}
      end)
      |> Map.new()

    {reopened_players, raise_size}
  end

  defp apply_raise_reopen_rules(players, _actor_seat, false, old_min_raise, _raise_size) do
    {players, old_min_raise}
  end

  defp advance_until_action_or_complete(%__MODULE__{hand: nil} = table), do: table

  defp advance_until_action_or_complete(%__MODULE__{hand: %Hand{} = hand} = table) do
    contenders = contender_seats(hand.players)

    cond do
      length(contenders) == 1 ->
        finish_uncontested(table, hd(contenders))

      showdown_ready?(hand) ->
        finish_showdown(table)

      hand.action_queue == [] and hand.street == :river ->
        finish_showdown(table)

      hand.action_queue == [] ->
        table
        |> advance_street()
        |> advance_until_action_or_complete()

      true ->
        updated_hand = %{hand | acting_seat: hd(hand.action_queue)}
        %{table | hand: updated_hand}
    end
  end

  defp finish_uncontested(%__MODULE__{hand: %Hand{} = hand} = table, winner_seat) do
    winner = Map.fetch!(hand.players, winner_seat)
    players = Map.put(hand.players, winner_seat, %{winner | stack: winner.stack + hand.pot})

    result = %{
      hand_id: hand.id,
      board: Enum.map(hand.board, &Card.to_short_string/1),
      winners: %{winner_seat => hand.pot},
      pots: [%{amount: hand.pot, eligible_seats: [winner_seat]}],
      ended_by: :fold
    }

    finalize_hand(table, players, hand, result)
  end

  defp advance_street(%__MODULE__{hand: %Hand{} = hand} = table) do
    {next_street, draw_count} = next_street_info(hand.street)

    with {:ok, deck_after_burn, _burned} <- burn_for_street(hand.deck),
         {:ok, cards, deck_after_draw} <- Deck.deal(deck_after_burn, draw_count) do
      players = reset_round_state(hand.players)
      board = hand.board ++ cards
      first_actor = postflop_first_actor(players, hand.button_seat)
      queue = build_queue(players, first_actor)

      updated_hand = %{
        hand
        | street: next_street,
          board: board,
          deck: deck_after_draw,
          to_call: 0,
          min_raise: table.big_blind,
          players: players,
          action_queue: queue,
          acting_seat: List.first(queue),
          events: hand.events ++ [%{type: :street_changed, street: next_street, board: board}]
      }

      %{table | hand: updated_hand}
    else
      _ -> raise "deck exhausted while advancing street"
    end
  end

  defp finish_showdown(%__MODULE__{hand: %Hand{} = hand} = table) do
    showdown_hand = runout_to_river(hand)
    side_pots = build_side_pots(showdown_hand.players)
    {winnings, ranked_hands} = distribute_side_pots(showdown_hand, side_pots)

    final_players =
      Enum.reduce(winnings, showdown_hand.players, fn {seat, won}, players ->
        player = Map.fetch!(players, seat)
        Map.put(players, seat, %{player | stack: player.stack + won})
      end)

    result = %{
      hand_id: showdown_hand.id,
      board: Enum.map(showdown_hand.board, &Card.to_short_string/1),
      winners: winnings,
      pots:
        Enum.map(side_pots, fn pot ->
          %{amount: pot.amount, eligible_seats: pot.eligible_seats}
        end),
      showdown:
        Enum.into(ranked_hands, %{}, fn {seat, rank} ->
          player = Map.fetch!(showdown_hand.players, seat)

          {seat,
           %{
             category: rank.category,
             tiebreaker: rank.tiebreaker,
             hole_cards: Enum.map(player.hole_cards, &Card.to_short_string/1)
           }}
        end),
      ended_by: :showdown
    }

    finalize_hand(table, final_players, showdown_hand, result)
  end

  defp finalize_hand(table, final_players, _hand, result) do
    updated_seats =
      Enum.reduce(final_players, table.seats, fn {seat, hand_player}, seats ->
        seat_player = Map.fetch!(seats, seat)

        status =
          cond do
            hand_player.stack == 0 -> :busted
            seat_player.status == :sitting_out -> :sitting_out
            true -> :active
          end

        Map.put(seats, seat, %{seat_player | stack: hand_player.stack, status: status})
      end)

    %{
      table
      | seats: updated_seats,
        hand: nil,
        last_hand_result: result
    }
  end

  defp runout_to_river(%Hand{} = hand) do
    needed_cards = 5 - length(hand.board)

    if needed_cards <= 0 do
      %{hand | street: :river}
    else
      draw_plan =
        case hand.street do
          :preflop -> [3, 1, 1]
          :flop -> [1, 1]
          :turn -> [1]
          :river -> []
        end

      Enum.reduce(draw_plan, hand, fn count, acc ->
        if count == 0 or length(acc.board) == 5 do
          acc
        else
          {:ok, _burned, after_burn} = Deck.burn(acc.deck)
          {:ok, cards, after_draw} = Deck.deal(after_burn, count)
          %{acc | deck: after_draw, board: acc.board ++ cards}
        end
      end)
      |> Map.put(:street, :river)
      |> Map.put(:action_queue, [])
      |> Map.put(:acting_seat, nil)
    end
  end

  defp distribute_side_pots(%Hand{} = hand, side_pots) do
    eligible_seats =
      hand.players
      |> Enum.filter(fn {_seat, player} -> not player.folded end)
      |> Enum.map(&elem(&1, 0))

    ranked_hands =
      Enum.into(eligible_seats, %{}, fn seat ->
        player = Map.fetch!(hand.players, seat)
        {:ok, rank} = HandRank.evaluate(player.hole_cards ++ hand.board)
        {seat, rank}
      end)

    winnings =
      Enum.reduce(side_pots, %{}, fn pot, acc ->
        winners = winning_seats_for_pot(pot, ranked_hands)
        split = split_pot(pot.amount, winners, hand.button_seat)

        Enum.reduce(split, acc, fn {seat, amount}, winnings_acc ->
          Map.update(winnings_acc, seat, amount, &(&1 + amount))
        end)
      end)

    {winnings, ranked_hands}
  end

  defp winning_seats_for_pot(%SidePot{eligible_seats: eligible}, ranked_hands) do
    [first | rest] = eligible
    first_rank = Map.fetch!(ranked_hands, first)

    {winners, _best_rank} =
      Enum.reduce(rest, {[first], first_rank}, fn seat, {current_winners, best_rank} ->
        rank = Map.fetch!(ranked_hands, seat)

        case HandRank.compare(rank, best_rank) do
          :gt -> {[seat], rank}
          :eq -> {[seat | current_winners], best_rank}
          :lt -> {current_winners, best_rank}
        end
      end)

    Enum.sort(winners)
  end

  defp split_pot(amount, winners, button_seat) do
    share = div(amount, length(winners))
    remainder = rem(amount, length(winners))
    ordered = order_for_remainder(winners, button_seat)

    ordered
    |> Enum.with_index()
    |> Enum.map(fn {seat, index} ->
      bonus = if index < remainder, do: 1, else: 0
      {seat, share + bonus}
    end)
  end

  defp order_for_remainder(winners, button_seat) do
    sorted = Enum.sort(winners)
    first = next_in_ring(sorted, button_seat)
    rotate_from(sorted, first)
  end

  defp build_side_pots(players) do
    contributions =
      Enum.into(players, %{}, fn {seat, player} -> {seat, player.committed_total} end)

    do_build_side_pots(players, contributions, [])
  end

  defp do_build_side_pots(players, contributions, acc) do
    positive = Enum.filter(contributions, fn {_seat, chips} -> chips > 0 end)

    if positive == [] do
      Enum.reverse(acc)
    else
      {level, _} = Enum.min_by(positive, fn {_seat, chips} -> chips end)
      step = Map.fetch!(contributions, level)
      participants = Enum.map(positive, &elem(&1, 0))
      pot_amount = step * length(participants)

      eligible =
        Enum.filter(participants, fn seat ->
          player = Map.fetch!(players, seat)
          not player.folded
        end)

      next_contrib =
        Enum.into(contributions, %{}, fn {seat, chips} ->
          if seat in participants do
            {seat, chips - step}
          else
            {seat, chips}
          end
        end)

      do_build_side_pots(players, next_contrib, [
        %SidePot{amount: pot_amount, eligible_seats: eligible} | acc
      ])
    end
  end

  defp showdown_ready?(%Hand{} = hand) do
    length(contender_seats(hand.players)) > 1 and actable_seats(hand.players) == []
  end

  defp next_street_info(:preflop), do: {:flop, 3}
  defp next_street_info(:flop), do: {:turn, 1}
  defp next_street_info(:turn), do: {:river, 1}
  defp next_street_info(:river), do: {:river, 0}

  defp burn_for_street(deck) do
    with {:ok, burned, rest} <- Deck.burn(deck) do
      {:ok, rest, burned}
    end
  end

  defp reset_round_state(players) do
    Enum.into(players, %{}, fn {seat, player} ->
      can_raise = can_act?(player)
      {seat, %{player | committed_round: 0, can_raise: can_raise}}
    end)
  end

  defp queue_after_aggression(players, actor_seat) do
    seats = players |> Map.keys() |> Enum.sort()
    first = next_in_ring(seats, actor_seat)

    seats
    |> rotate_from(first)
    |> Enum.reject(&(&1 == actor_seat))
    |> Enum.filter(fn seat -> can_act?(Map.fetch!(players, seat)) end)
  end

  defp trim_queue(queue, players) do
    queue
    |> Enum.filter(fn seat -> can_act?(Map.fetch!(players, seat)) end)
  end

  defp tl_or_empty([]), do: []
  defp tl_or_empty([_ | rest]), do: rest

  defp update_player!(players, seat, fun) do
    Map.update!(players, seat, fun)
  end

  defp commit_chips(player, requested) do
    amount = min(requested, player.stack)
    stack = player.stack - amount

    updated = %{
      player
      | stack: stack,
        committed_round: player.committed_round + amount,
        committed_total: player.committed_total + amount,
        all_in: stack == 0
    }

    {updated, amount}
  end

  defp active_seats(table) do
    table.seats
    |> Enum.filter(fn {_seat, player} -> player.status == :active and player.stack > 0 end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp contender_seats(players) do
    players
    |> Enum.filter(fn {_seat, player} -> not player.folded end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp actable_seats(players) do
    players
    |> Enum.filter(fn {_seat, player} -> can_act?(player) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp can_act?(%HandPlayer{} = player) do
    not player.folded and not player.all_in and player.stack > 0
  end

  defp next_button_seat(nil, seats), do: hd(seats)
  defp next_button_seat(current_button, seats), do: next_in_ring(seats, current_button)

  defp blind_seats(active_seats, button) do
    if length(active_seats) == 2 do
      small_blind = button
      big_blind = next_in_ring(active_seats, button)
      {small_blind, big_blind}
    else
      small_blind = next_in_ring(active_seats, button)
      big_blind = next_in_ring(active_seats, small_blind)
      {small_blind, big_blind}
    end
  end

  defp preflop_first_actor(active_seats, big_blind_seat, players) do
    first = next_in_ring(active_seats, big_blind_seat)
    queue = build_queue(players, first)
    List.first(queue)
  end

  defp postflop_first_actor(players, button_seat) do
    seats = players |> Map.keys() |> Enum.sort()

    seats
    |> rotate_from(next_in_ring(seats, button_seat))
    |> Enum.find(fn seat -> can_act?(Map.fetch!(players, seat)) end)
  end

  defp build_queue(_players, nil), do: []

  defp build_queue(players, first_seat) do
    seats = players |> Map.keys() |> Enum.sort()

    seats
    |> rotate_from(first_seat)
    |> Enum.filter(fn seat -> can_act?(Map.fetch!(players, seat)) end)
  end

  defp rotate_from([], _first), do: []

  defp rotate_from(list, first) do
    case Enum.find_index(list, &(&1 == first)) do
      nil ->
        list

      index ->
        Enum.drop(list, index) ++ Enum.take(list, index)
    end
  end

  defp next_in_ring([], _seat), do: nil

  defp next_in_ring(sorted_seats, seat) do
    Enum.find(sorted_seats, &(&1 > seat)) || hd(sorted_seats)
  end

  defp post_blinds(players, sb_seat, sb_amount, bb_seat, bb_amount) do
    {players, sb_posted} = post_blind(players, sb_seat, sb_amount)
    {players, bb_posted} = post_blind(players, bb_seat, bb_amount)
    {players, sb_posted + bb_posted, sb_posted, bb_posted}
  end

  defp post_blind(players, seat, amount) do
    player = Map.fetch!(players, seat)
    {updated, posted} = commit_chips(player, amount)
    {Map.put(players, seat, updated), posted}
  end

  defp deal_hole_cards(table, active_seats, first_deal_seat, deck) do
    players =
      Enum.into(active_seats, %{}, fn seat ->
        seat_player = Map.fetch!(table.seats, seat)

        hand_player = %HandPlayer{
          seat: seat,
          player_id: seat_player.player_id,
          stack: seat_player.stack,
          hole_cards: [],
          committed_round: 0,
          committed_total: 0,
          folded: false,
          all_in: false,
          can_raise: true
        }

        {seat, hand_player}
      end)

    deal_order = rotate_from(active_seats, first_deal_seat)

    Enum.reduce_while(1..2, {:ok, players, deck}, fn _round,
                                                     {:ok, current_players, current_deck} ->
      Enum.reduce_while(deal_order, {:ok, current_players, current_deck}, fn seat,
                                                                             {:ok, players_acc,
                                                                              deck_acc} ->
        case Deck.deal(deck_acc, 1) do
          {:ok, [card], rest} ->
            updated_players =
              update_player!(players_acc, seat, fn player ->
                %{player | hole_cards: player.hole_cards ++ [card]}
              end)

            {:cont, {:ok, updated_players, rest}}

          {:error, :not_enough_cards} ->
            {:halt, {:error, :not_enough_cards}}
        end
      end)
      |> case do
        {:ok, _players, _deck} = ok -> {:cont, ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_deck(opts) do
    case Keyword.get(opts, :deck) do
      nil ->
        {:ok, Deck.shuffle(Deck.new(), seed: Keyword.get(opts, :seed))}

      deck when is_list(deck) ->
        if Deck.valid?(deck), do: {:ok, deck}, else: {:error, :invalid_deck}

      _ ->
        {:error, :invalid_deck}
    end
  end

  defp maybe_add(list, value, true), do: list ++ [value]
  defp maybe_add(list, _value, false), do: list
end
