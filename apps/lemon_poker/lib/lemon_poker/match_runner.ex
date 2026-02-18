defmodule LemonPoker.MatchRunner do
  @moduledoc false

  alias LemonPoker.{AgentRunner, Card, HeadsUpMatch, MatchControl, Table, TableTalkPolicy, View}

  @default_stack 1_000
  @default_small_blind 50
  @default_big_blind 100
  @default_hands 1
  @default_players 2
  @min_players 2
  @max_players 9
  @default_timeout_ms 90_000
  @default_max_decisions 200
  @default_decision_attempts 2
  @default_table_talk_enabled true
  @pause_poll_ms 150
  @recent_talk_limit 6

  @type result ::
          {:ok, Table.t()}
          | {:stopped, Table.t()}
          | {:error, :start_hand_failed | :max_decisions | :invalid_actor | :invalid_action,
             Table.t()}

  @type emit_fun :: (map() -> any())

  @spec run(keyword(), emit_fun(), MatchControl.t()) :: result()
  def run(opts, emit, control) when is_function(emit, 1) do
    table_id = Keyword.get(opts, :table_id, default_table_id())
    hands = Keyword.get(opts, :hands, @default_hands)
    players = player_count(opts)
    max_decisions = Keyword.get(opts, :max_decisions, @default_max_decisions)

    table = build_initial_table(table_id, opts, players)
    seats = seat_configs(table_id, opts, players)

    emit.(%{
      type: "match_started",
      status: :running,
      config: config_snapshot(opts, table_id, players, hands),
      seats: View.seat_configs_snapshot(seats),
      table: View.table_snapshot(table)
    })

    state = %{
      table: table,
      seats: seats,
      hand_index: 1,
      talk_history: []
    }

    play_hands(state, hands, max_decisions, opts, emit, control)
  end

  defp play_hands(state, max_hands, _max_decisions, _opts, emit, _control)
       when state.hand_index > max_hands do
    emit.(%{
      type: "match_completed",
      status: :completed,
      table: View.table_snapshot(state.table),
      hand_index: state.hand_index - 1
    })

    {:ok, state.table}
  end

  defp play_hands(state, max_hands, max_decisions, opts, emit, control) do
    case await_control(control) do
      :stopped ->
        emit.(%{
          type: "match_stopped",
          status: :stopped,
          table: View.table_snapshot(state.table),
          hand_index: state.hand_index - 1
        })

        {:stopped, state.table}

      :ok ->
        if active_seat_count(state.table) < 2 do
          emit.(%{
            type: "match_completed",
            status: :completed,
            reason: :not_enough_players,
            table: View.table_snapshot(state.table),
            hand_index: state.hand_index - 1
          })

          {:ok, state.table}
        else
          hand_seed = hand_seed(Keyword.get(opts, :seed), state.hand_index)
          start_opts = if is_nil(hand_seed), do: [], else: [seed: hand_seed]

          case Table.start_hand(state.table, start_opts) do
            {:ok, started_table} ->
              emit_hand_started(started_table, state, emit)

              next_state = %{state | table: started_table}

              case play_one_hand(next_state, max_decisions, opts, emit, control) do
                {:ok, finished_state} ->
                  emit_hand_result(finished_state, emit)

                  play_hands(
                    %{finished_state | hand_index: finished_state.hand_index + 1},
                    max_hands,
                    max_decisions,
                    opts,
                    emit,
                    control
                  )

                {:stopped, stopped_state} ->
                  emit.(%{
                    type: "match_stopped",
                    status: :stopped,
                    table: View.table_snapshot(stopped_state.table),
                    hand_index: stopped_state.hand_index
                  })

                  {:stopped, stopped_state.table}

                {:error, reason, errored_state} ->
                  emit.(%{
                    type: "match_error",
                    status: :error,
                    reason: reason,
                    hand_index: state.hand_index,
                    table: View.table_snapshot(errored_state.table)
                  })

                  {:error, reason, errored_state.table}
              end

            {:error, _reason} ->
              emit.(%{
                type: "match_error",
                status: :error,
                reason: :start_hand_failed,
                hand_index: state.hand_index,
                table: View.table_snapshot(state.table)
              })

              {:error, :start_hand_failed, state.table}
          end
        end
    end
  end

  defp play_one_hand(%{table: %Table{hand: nil}} = state, _remaining, _opts, _emit, _control),
    do: {:ok, state}

  defp play_one_hand(state, 0, _opts, _emit, _control), do: {:error, :max_decisions, state}

  defp play_one_hand(state, remaining, opts, emit, control) do
    case await_control(control) do
      :stopped ->
        {:stopped, state}

      :ok ->
        table = state.table
        hand_live? = not is_nil(table.hand)

        with {:ok, legal} <- Table.legal_actions(table),
             {:ok, seat_cfg} <- fetch_seat_config(state.seats, legal.seat),
             {action, source, raw_answer, talk} <-
               decide_action(table, legal, seat_cfg, state.talk_history, opts),
             true <- legal_action?(action, legal) do
          previous_street = table.hand.street
          {:ok, next_table} = Table.act(table, legal.seat, action)

          emit_action(next_table, state, legal.seat, seat_cfg, action, source, raw_answer, emit)

          talk_history =
            maybe_emit_talk(next_table, state, seat_cfg, legal.seat, talk, opts, emit, hand_live?)

          maybe_emit_street_transition(previous_street, next_table, state, emit)

          play_one_hand(
            %{state | table: next_table, talk_history: talk_history},
            remaining - 1,
            opts,
            emit,
            control
          )
        else
          false ->
            {:error, :invalid_action, state}

          _ ->
            {:error, :invalid_actor, state}
        end
    end
  end

  defp decide_action(table, legal, seat_cfg, talk_history, opts) do
    attempts = Keyword.get(opts, :decision_attempts, @default_decision_attempts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    prompt = build_prompt(table, legal, seat_cfg, talk_history, opts)

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
          case HeadsUpMatch.parse_action(answer) do
            {:ok, action} ->
              if legal_action?(action, legal) do
                {:halt, {action, :agent, answer, parse_talk(answer)}}
              else
                {:cont, nil}
              end

            _ ->
              {:cont, nil}
          end

        _ ->
          {:cont, nil}
      end
    end) || {fallback_action(legal), :fallback, "", nil}
  end

  defp build_prompt(table, legal, seat_cfg, talk_history, opts) do
    hand = table.hand
    actor = Map.fetch!(hand.players, legal.seat)

    talk_block =
      if table_talk_enabled?(opts) do
        """
        Optional second line:
        TALK: <short table-talk message>

        Table-talk safety rules:
        - TALK is for social banter and light conversation with other players.
        - Do not use TALK to comment on ongoing decisions, betting lines, odds, ranges, or strategy.
        - Do not explain or justify your own action choice in TALK.
        - Never reveal your hole cards (ranks or suits) while this hand is live.
        - This applies even if you folded.

        Recent table talk:
        #{format_recent_talk(talk_history)}
        """
      else
        ""
      end

    """
    You are playing multi-player no-limit Texas Hold'em.
    You are seat #{legal.seat} (#{seat_cfg.label}).

    Respond with exactly one line:
    ACTION: <fold|check|call|bet N|raise N>

    Betting amount rule:
    - For bet/raise, N is the total committed amount for this street (not the increment).
    - Only choose legal actions shown below.

    #{talk_block}
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

  defp maybe_put_system_prompt(meta, opts, seat_cfg) do
    case seat_cfg.system_prompt do
      prompt when is_binary(prompt) and prompt != "" ->
        Map.put(meta, :system_prompt, prompt)

      _ ->
        case Keyword.get(opts, :system_prompt) do
          prompt when is_binary(prompt) and prompt != "" ->
            Map.put(meta, :system_prompt, prompt)

          _ ->
            Map.put(meta, :system_prompt, default_system_prompt(seat_cfg.label))
        end
    end
  end

  defp maybe_emit_talk(_table, state, _seat_cfg, _seat, nil, _opts, _emit, _hand_live?),
    do: state.talk_history

  defp maybe_emit_talk(table, state, seat_cfg, seat, talk, opts, emit, hand_live?) do
    if table_talk_enabled?(opts) and is_binary(talk) and String.trim(talk) != "" do
      trimmed = String.trim(talk)

      case TableTalkPolicy.evaluate(trimmed, hand_live?) do
        :allow ->
          event = %{
            type: "table_talk",
            hand_index: state.hand_index,
            hand_id: table.hand_id,
            seat: seat,
            actor: seat_cfg.label,
            text: trimmed,
            table: View.table_snapshot(table)
          }

          emit.(event)

          [%{seat: seat, actor: seat_cfg.label, text: trimmed} | state.talk_history]
          |> Enum.take(@recent_talk_limit)

        {:block, reason} ->
          emit.(%{
            type: "table_talk_blocked",
            hand_index: state.hand_index,
            hand_id: table.hand_id,
            seat: seat,
            actor: seat_cfg.label,
            text: trimmed,
            reason: reason,
            table: View.table_snapshot(table)
          })

          state.talk_history
      end
    else
      state.talk_history
    end
  end

  defp emit_hand_started(table, state, emit) do
    hand = table.hand

    emit.(%{
      type: "hand_started",
      hand_index: state.hand_index,
      hand_id: hand.id,
      button_seat: hand.button_seat,
      small_blind_seat: hand.small_blind_seat,
      big_blind_seat: hand.big_blind_seat,
      table: View.table_snapshot(table)
    })
  end

  defp emit_action(table, state, seat, seat_cfg, action, source, raw_answer, emit) do
    emit.(%{
      type: "action_taken",
      hand_index: state.hand_index,
      hand_id: table.hand_id,
      seat: seat,
      actor: seat_cfg.label,
      action: format_action(action),
      source: source,
      raw_answer: sanitize_raw_answer(raw_answer),
      table: View.table_snapshot(table)
    })
  end

  defp maybe_emit_street_transition(_previous_street, %Table{hand: nil}, _state, _emit), do: :ok

  defp maybe_emit_street_transition(previous_street, %Table{hand: hand} = table, state, emit) do
    if hand.street != previous_street do
      emit.(%{
        type: "street_changed",
        hand_index: state.hand_index,
        hand_id: hand.id,
        street: hand.street,
        board: cards_to_strings(hand.board),
        table: View.table_snapshot(table)
      })
    end
  end

  defp emit_hand_result(%{table: %Table{last_hand_result: nil}}, _emit), do: :ok

  defp emit_hand_result(state, emit) do
    emit.(%{
      type: "hand_finished",
      hand_index: state.hand_index,
      hand_id: state.table.hand_id,
      result: View.table_snapshot(state.table).last_hand_result,
      table: View.table_snapshot(state.table)
    })
  end

  defp config_snapshot(opts, table_id, players, hands) do
    %{
      table_id: table_id,
      players: players,
      hands: hands,
      stack: Keyword.get(opts, :stack, @default_stack),
      small_blind: Keyword.get(opts, :small_blind, @default_small_blind),
      big_blind: Keyword.get(opts, :big_blind, @default_big_blind),
      agent_id: Keyword.get(opts, :agent_id, "default"),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      table_talk_enabled: table_talk_enabled?(opts)
    }
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
    default_agent_id = Keyword.get(opts, :agent_id, "default")

    agent_ids =
      normalize_string_list(
        Keyword.get(opts, :player_agent_ids, []),
        player_count,
        default_agent_id
      )

    labels =
      normalize_string_list(
        Keyword.get(opts, :player_labels, []),
        player_count,
        "agent"
      )

    prompts =
      normalize_optional_string_list(Keyword.get(opts, :player_system_prompts, []), player_count)

    Enum.into(1..player_count, %{}, fn seat ->
      label = Enum.at(labels, seat - 1) || "agent-#{seat}"

      {seat,
       %{
         label: ensure_seat_label(label, seat),
         agent_id: Enum.at(agent_ids, seat - 1) || default_agent_id,
         session_key: "poker:#{table_id}:seat:#{seat}",
         system_prompt: Enum.at(prompts, seat - 1)
       }}
    end)
  end

  defp ensure_seat_label("agent", seat), do: "agent-#{seat}"

  defp ensure_seat_label(label, seat) when is_binary(label) do
    clean = String.trim(label)
    if clean == "", do: "agent-#{seat}", else: clean
  end

  defp ensure_seat_label(_label, seat), do: "agent-#{seat}"

  defp normalize_string_list(value, player_count, fallback) when is_list(value) do
    0..(player_count - 1)
    |> Enum.map(fn index ->
      item = Enum.at(value, index)

      case item do
        text when is_binary(text) and text != "" ->
          text

        _ ->
          if fallback == "agent" do
            "agent-#{index + 1}"
          else
            fallback
          end
      end
    end)
  end

  defp normalize_string_list(_value, player_count, fallback),
    do: normalize_string_list([], player_count, fallback)

  defp normalize_optional_string_list(value, player_count) when is_list(value) do
    0..(player_count - 1)
    |> Enum.map(fn index ->
      case Enum.at(value, index) do
        text when is_binary(text) and text != "" -> text
        _ -> nil
      end
    end)
  end

  defp normalize_optional_string_list(_value, player_count),
    do: normalize_optional_string_list([], player_count)

  defp parse_talk(answer) when is_binary(answer) do
    answer
    |> strip_code_fences()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(fn line ->
      lowered = String.downcase(line)

      if String.starts_with?(lowered, "talk:") do
        line
        |> String.replace_prefix("TALK:", "")
        |> String.replace_prefix("talk:", "")
        |> String.trim()
      else
        nil
      end
    end)
  end

  defp parse_talk(_), do: nil

  defp await_control(control) do
    cond do
      MatchControl.stopped?(control) ->
        :stopped

      MatchControl.paused?(control) ->
        wait_until_resumed(control)

      true ->
        :ok
    end
  end

  defp wait_until_resumed(control) do
    cond do
      MatchControl.stopped?(control) ->
        :stopped

      MatchControl.paused?(control) ->
        Process.sleep(@pause_poll_ms)
        wait_until_resumed(control)

      true ->
        :ok
    end
  end

  defp table_talk_enabled?(opts) do
    Keyword.get(opts, :table_talk_enabled, @default_table_talk_enabled)
  end

  defp fetch_seat_config(seats, seat) when is_map(seats) do
    case Map.fetch(seats, seat) do
      {:ok, cfg} -> {:ok, cfg}
      :error -> {:error, :unknown_seat}
    end
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

  defp sanitize_raw_answer(answer) when is_binary(answer), do: String.trim(answer)
  defp sanitize_raw_answer(_), do: ""

  defp cards_to_strings(cards), do: Enum.map(cards, &Card.to_short_string/1)

  defp format_cards(cards) when is_list(cards) do
    cards
    |> cards_to_strings()
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

  defp format_recent_talk([]), do: "(none)"

  defp format_recent_talk(talk_history) do
    talk_history
    |> Enum.take(@recent_talk_limit)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn talk ->
      "- #{talk.actor} (seat #{talk.seat}): #{talk.text}"
    end)
  end

  defp default_system_prompt(label) do
    "You are #{label}, a poker agent. Be concise. Follow response format exactly. " <>
      "If you emit TALK, keep it social/banter only and never comment on live action decisions or strategy."
  end

  defp active_seat_count(table) do
    table.seats
    |> Enum.count(fn {_seat, player} -> player.status == :active and player.stack > 0 end)
  end

  defp seat_player!(table, seat, player_id, stack) do
    {:ok, table} = Table.seat_player(table, seat, player_id, stack)
    table
  end

  defp hand_seed(nil, _hand_index), do: nil
  defp hand_seed(seed, hand_index) when is_integer(seed), do: seed + hand_index - 1
  defp hand_seed(seed, hand_index), do: :erlang.phash2({seed, hand_index})

  defp default_table_id do
    "poker-" <> Integer.to_string(System.system_time(:second))
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
end
