defmodule LemonPoker.HeadsUpMatch do
  @moduledoc """
  Match runner that drives agent sessions through a no-limit hold'em hand flow.
  """

  alias LemonPoker.{AgentRunner, Card, Table}

  @default_stack 1_000
  @default_small_blind 50
  @default_big_blind 100
  @default_hands 1
  @default_players 2
  @min_players 2
  @max_players 9
  @default_timeout_ms 90_000
  @default_max_decisions 200
  @default_agent_id "poker_default"

  @type action ::
          :fold
          | :check
          | :call
          | {:bet, non_neg_integer()}
          | {:raise, non_neg_integer()}

  @type match_result ::
          {:ok, Table.t()}
          | {:error, :start_hand_failed | :max_decisions | :invalid_actor | :invalid_action,
             Table.t()}

  @spec play(keyword()) :: match_result()
  def play(opts \\ []) do
    table_id = Keyword.get(opts, :table_id, default_table_id())
    hands = Keyword.get(opts, :hands, @default_hands)
    player_count = player_count(opts)
    max_decisions = Keyword.get(opts, :max_decisions, @default_max_decisions)

    table = build_initial_table(table_id, opts, player_count)
    seats = seat_configs(table_id, opts, player_count)

    IO.puts("Starting poker match table=#{table_id} hands=#{hands} players=#{player_count}")

    seats
    |> Enum.sort_by(fn {seat, _cfg} -> seat end)
    |> Enum.each(fn {seat, cfg} ->
      IO.puts("Seat #{seat} -> agent_id=#{cfg.agent_id} session_key=#{cfg.session_key}")
    end)

    play_hands(table, seats, 1, hands, max_decisions, opts)
  end

  @doc """
  Parse a model answer into a poker action.
  """
  @spec parse_action(String.t()) :: {:ok, action()} | {:error, :invalid_format}
  def parse_action(answer) when is_binary(answer) do
    normalized =
      answer
      |> strip_code_fences()
      |> pick_action_line()
      |> String.downcase()
      |> String.trim()

    cond do
      Regex.match?(~r/^fold\b/, normalized) ->
        {:ok, :fold}

      Regex.match?(~r/^check\b/, normalized) ->
        {:ok, :check}

      Regex.match?(~r/^call\b/, normalized) ->
        {:ok, :call}

      match = Regex.run(~r/^bet\b[^0-9]*([0-9]+)/, normalized) ->
        {:ok, {:bet, to_integer!(match)}}

      match = Regex.run(~r/^raise\b[^0-9]*([0-9]+)/, normalized) ->
        {:ok, {:raise, to_integer!(match)}}

      true ->
        {:error, :invalid_format}
    end
  end

  def parse_action(_), do: {:error, :invalid_format}

  defp play_hands(table, _seats, hand_index, max_hands, _max_decisions, _opts)
       when hand_index > max_hands do
    {:ok, table}
  end

  defp play_hands(table, seats, hand_index, max_hands, max_decisions, opts) do
    if active_seat_count(table) < 2 do
      {:ok, table}
    else
      hand_seed = hand_seed(Keyword.get(opts, :seed), hand_index)
      start_opts = if is_nil(hand_seed), do: [], else: [seed: hand_seed]

      case Table.start_hand(table, start_opts) do
        {:ok, started_table} ->
          print_hand_start(started_table, hand_index, seats)

          case play_one_hand(started_table, seats, max_decisions, opts) do
            {:ok, finished_table} ->
              print_hand_result(finished_table)
              play_hands(finished_table, seats, hand_index + 1, max_hands, max_decisions, opts)

            {:error, reason, partial_table} ->
              {:error, reason, partial_table}
          end

        {:error, _} ->
          {:error, :start_hand_failed, table}
      end
    end
  end

  defp play_one_hand(%Table{hand: nil} = table, _seats, _remaining, _opts), do: {:ok, table}
  defp play_one_hand(table, _seats, 0, _opts), do: {:error, :max_decisions, table}

  defp play_one_hand(%Table{} = table, seats, remaining, opts) do
    with {:ok, legal} <- Table.legal_actions(table),
         {:ok, seat_cfg} <- fetch_seat_config(seats, legal.seat),
         {action, source, raw_answer} <- decide_action(table, legal, seat_cfg, opts),
         true <- legal_action?(action, legal) do
      previous_street = table.hand.street
      {:ok, next_table} = Table.act(table, legal.seat, action)

      print_action(legal.seat, seat_cfg, action, source, raw_answer)
      print_street_transition(previous_street, next_table)

      play_one_hand(next_table, seats, remaining - 1, opts)
    else
      false ->
        {:error, :invalid_action, table}

      _ ->
        {:error, :invalid_actor, table}
    end
  end

  defp decide_action(table, legal, seat_cfg, opts) do
    attempts = Keyword.get(opts, :decision_attempts, 2)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    prompt = build_prompt(table, legal, seat_cfg)

    agent_meta =
      %{
        poker: %{
          table_id: table.id,
          hand_id: table.hand.id,
          seat: legal.seat
        }
      }
      |> maybe_put_system_prompt(opts, seat_cfg)

    Enum.reduce_while(1..attempts, nil, fn _attempt, _acc ->
      case AgentRunner.run_prompt(seat_cfg.session_key, prompt,
             agent_id: seat_cfg.agent_id,
             timeout_ms: timeout_ms,
             meta: agent_meta
           ) do
        {:ok, %{answer: answer}} ->
          case parse_action(answer) do
            {:ok, action} ->
              if legal_action?(action, legal) do
                {:halt, {action, :agent, answer}}
              else
                {:cont, nil}
              end

            _ ->
              {:cont, nil}
          end

        _ ->
          {:cont, nil}
      end
    end) || {fallback_action(legal), :fallback, ""}
  end

  defp fetch_seat_config(seats, seat) when is_map(seats) do
    case Map.fetch(seats, seat) do
      {:ok, cfg} -> {:ok, cfg}
      :error -> {:error, :unknown_seat}
    end
  end

  defp build_prompt(table, legal, seat_cfg) do
    hand = table.hand
    actor = Map.fetch!(hand.players, legal.seat)

    """
    You are playing multi-player no-limit Texas Hold'em.
    You are seat #{legal.seat} (#{seat_cfg.label}).

    Respond with exactly one line:
    ACTION: <fold|check|call|bet N|raise N>

    Betting amount rule:
    - For bet/raise, N is the total committed amount for this street (not the increment).
    - Only choose legal actions shown below.

    State:
    - hand_id: #{hand.id}
    - street: #{hand.street}
    - pot: #{hand.pot}
    - board: #{format_cards(hand.board)}
    - your_hole_cards: #{format_cards(actor.hole_cards)}
    - your_stack: #{actor.stack}
    - players: #{format_player_states(hand.players)}
    - to_call: #{legal.to_call}
    - legal_options: #{format_options(legal)}
    """
  end

  defp legal_action?(:fold, legal), do: :fold in legal.options
  defp legal_action?(:check, legal), do: :check in legal.options
  defp legal_action?(:call, legal), do: :call in legal.options

  defp legal_action?({:bet, amount}, legal) when is_integer(amount) and amount >= 0 do
    is_map(legal.bet) and :bet in legal.options and amount >= legal.bet.min and
      amount <= legal.bet.max
  end

  defp legal_action?({:raise, amount}, legal) when is_integer(amount) and amount >= 0 do
    is_map(legal.raise) and :raise in legal.options and amount >= legal.raise.min and
      amount <= legal.raise.max
  end

  defp legal_action?(_, _), do: false

  defp fallback_action(legal) do
    cond do
      :check in legal.options -> :check
      :call in legal.options -> :call
      :fold in legal.options -> :fold
      :bet in legal.options and is_map(legal.bet) -> {:bet, legal.bet.min}
      :raise in legal.options and is_map(legal.raise) -> {:raise, legal.raise.min}
      true -> :fold
    end
  end

  defp format_action(:fold), do: "fold"
  defp format_action(:check), do: "check"
  defp format_action(:call), do: "call"
  defp format_action({:bet, amount}), do: "bet #{amount}"
  defp format_action({:raise, amount}), do: "raise #{amount}"

  defp format_cards(cards) when is_list(cards) do
    cards
    |> Enum.map(&Card.to_short_string/1)
    |> Enum.join(" ")
    |> case do
      "" -> "(none)"
      text -> text
    end
  end

  defp format_options(legal) do
    base = Enum.map_join(legal.options, ", ", &to_string/1)

    base =
      if is_map(legal.bet) do
        base <> " | bet_range=#{legal.bet.min}-#{legal.bet.max}"
      else
        base
      end

    if is_map(legal.raise) do
      base <> " | raise_range=#{legal.raise.min}-#{legal.raise.max}"
    else
      base
    end
  end

  defp print_hand_start(table, hand_index, seats) do
    hand = table.hand
    IO.puts("")
    IO.puts("=== Hand #{hand_index} (engine hand_id=#{hand.id}) ===")
    IO.puts("button=#{hand.button_seat} sb=#{hand.small_blind_seat} bb=#{hand.big_blind_seat}")

    hand.players
    |> Enum.sort_by(fn {seat, _player} -> seat end)
    |> Enum.each(fn {seat, player} ->
      seat_label = seat_label(seats, seat)
      IO.puts("dealt seat #{seat} (#{seat_label}) -> #{format_cards(player.hole_cards)}")
    end)
  end

  defp print_action(seat, seat_cfg, action, :agent, _raw_answer) do
    IO.puts("seat #{seat} (#{seat_cfg.label}) -> #{format_action(action)}")
  end

  defp print_action(seat, seat_cfg, action, :fallback, _raw_answer) do
    IO.puts("seat #{seat} (#{seat_cfg.label}) -> #{format_action(action)} [fallback]")
  end

  defp print_street_transition(_previous_street, %Table{hand: nil}), do: :ok

  defp print_street_transition(previous_street, %Table{hand: hand}) do
    if hand.street != previous_street do
      IO.puts("street -> #{hand.street}; board=#{format_cards(hand.board)}")
    end
  end

  defp print_hand_result(%Table{last_hand_result: nil}), do: :ok

  defp print_hand_result(%Table{last_hand_result: result}) do
    winners =
      result.winners
      |> Enum.sort_by(fn {seat, _amount} -> seat end)
      |> Enum.map_join(", ", fn {seat, amount} -> "seat #{seat}: +#{amount}" end)

    IO.puts("result: ended_by=#{result.ended_by} winners=[#{winners}]")
  end

  defp build_initial_table(table_id, opts, player_count) do
    stack = Keyword.get(opts, :stack, @default_stack)
    small_blind = Keyword.get(opts, :small_blind, @default_small_blind)
    big_blind = Keyword.get(opts, :big_blind, @default_big_blind)

    table =
      Table.new(table_id, max_seats: player_count, small_blind: small_blind, big_blind: big_blind)

    Enum.reduce(1..player_count, table, fn seat, acc ->
      seat_player!(acc, seat, "seat-#{seat}", stack)
    end)
  end

  defp seat_configs(table_id, opts, player_count) do
    agent_id = Keyword.get(opts, :agent_id, @default_agent_id)

    Enum.into(1..player_count, %{}, fn seat ->
      {seat,
       %{
         label: "agent-#{seat}",
         agent_id: agent_id,
         session_key: "poker:#{table_id}:seat:#{seat}"
       }}
    end)
  end

  defp hand_seed(nil, _hand_index), do: nil
  defp hand_seed(seed, hand_index) when is_integer(seed), do: seed + hand_index - 1
  defp hand_seed(seed, hand_index), do: :erlang.phash2({seed, hand_index})

  defp default_table_id do
    "poker-" <> Integer.to_string(System.system_time(:second))
  end

  defp active_seat_count(table) do
    table.seats
    |> Enum.count(fn {_seat, player} -> player.status == :active and player.stack > 0 end)
  end

  defp seat_player!(table, seat, player_id, stack) do
    {:ok, table} = Table.seat_player(table, seat, player_id, stack)
    table
  end

  defp player_count(opts) do
    value = Keyword.get(opts, :players, @default_players)

    cond do
      not is_integer(value) ->
        raise ArgumentError,
              "players must be an integer between #{@min_players} and #{@max_players}"

      value < @min_players or value > @max_players ->
        raise ArgumentError,
              "players must be between #{@min_players} and #{@max_players}, got: #{value}"

      true ->
        value
    end
  end

  defp strip_code_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```[a-zA-Z0-9_-]*\s*/, "")
    |> String.replace(~r/\s*```$/, "")
  end

  defp pick_action_line(text) do
    lines =
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    action_line =
      Enum.find(lines, fn line ->
        String.starts_with?(String.downcase(line), "action:")
      end) || List.first(lines) || ""

    String.replace_prefix(action_line, "ACTION:", "")
    |> String.replace_prefix("action:", "")
    |> String.trim()
  end

  defp to_integer!(match) do
    match
    |> List.last()
    |> String.to_integer()
  end

  defp seat_label(seats, seat) do
    case Map.fetch(seats, seat) do
      {:ok, %{label: label}} -> label
      _ -> "seat-#{seat}"
    end
  end

  defp format_player_states(players) do
    players
    |> Enum.sort_by(fn {seat, _player} -> seat end)
    |> Enum.map_join(" | ", fn {seat, player} ->
      "seat #{seat}: stack=#{player.stack}, committed=#{player.committed_round}, state=#{player_state(player)}"
    end)
  end

  defp player_state(%{folded: true}), do: "folded"
  defp player_state(%{all_in: true}), do: "all-in"
  defp player_state(_), do: "active"

  defp maybe_put_system_prompt(meta, opts, seat_cfg) do
    case Keyword.get(opts, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" ->
        Map.put(meta, :system_prompt, prompt)

      _ ->
        Map.put(meta, :system_prompt, default_system_prompt(seat_cfg.label))
    end
  end

  defp default_system_prompt(label) do
    "You are #{label}, a poker agent. Be concise. Follow response format exactly."
  end
end
