defmodule LemonPoker.MatchRunner do
  @moduledoc false

  alias LemonPoker.{
    AgentRunner,
    Card,
    HeadsUpMatch,
    MatchControl,
    Persona,
    Table,
    TableTalkPolicy,
    View
  }

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
  @default_agent_id "poker_default"
  @pause_poll_ms 150
  @talk_history_limit 80
  @recent_talk_limit 24
  @recent_self_talk_limit 4
  @topic_suggestion_count 16
  @no_tools_allow_token "__poker_no_tools__"
  @conversation_topics [
    "best city for a long weekend",
    "favorite breakfast spot",
    "best late-night snack",
    "most overrated food trend",
    "most underrated comfort food",
    "go-to coffee order",
    "tea vs coffee preferences",
    "favorite pizza toppings",
    "best road-trip playlist genre",
    "favorite live concert memory",
    "music artist on repeat lately",
    "movie worth rewatching",
    "best comedy series recommendation",
    "favorite documentary recently",
    "great sci-fi recommendation",
    "best book read this year",
    "a book you always recommend",
    "podcast recommendation",
    "favorite interview show",
    "morning person or night owl",
    "ideal weekend routine",
    "favorite way to unwind",
    "hobby you picked up recently",
    "hobby you want to learn",
    "favorite board game at home",
    "favorite co-op video game",
    "best retro game memory",
    "favorite arcade game",
    "best travel story",
    "most beautiful place visited",
    "dream destination",
    "favorite airline snack",
    "window seat or aisle seat",
    "carry-on packing strategy",
    "favorite national park",
    "favorite beach destination",
    "best mountain town",
    "favorite city walk",
    "best local festival",
    "favorite museum experience",
    "favorite rainy-day activity",
    "favorite sunny-day activity",
    "favorite sport to watch",
    "favorite team chant or tradition",
    "best underdog story in sports",
    "favorite halftime show",
    "most memorable live game attended",
    "best gym playlist style",
    "favorite way to stay active",
    "favorite outdoor workout",
    "best recovery routine",
    "favorite running route",
    "favorite bike trail",
    "favorite home-cooked meal",
    "best one-pan dinner idea",
    "favorite spicy dish",
    "favorite dessert",
    "favorite street food",
    "best burger place",
    "favorite noodle dish",
    "favorite sandwich",
    "favorite city for food",
    "best cheap meal in your city",
    "favorite local bakery",
    "best brunch order",
    "favorite midnight snack",
    "favorite ice cream flavor",
    "best movie theater snack",
    "favorite app on your phone",
    "most useful travel app",
    "favorite note-taking tool",
    "favorite keyboard shortcut",
    "favorite productivity habit",
    "most helpful daily routine",
    "favorite desk setup tip",
    "favorite pen or notebook",
    "favorite weather",
    "favorite season and why",
    "favorite storm memory",
    "favorite smell in a city",
    "favorite cafe atmosphere",
    "favorite airport for layovers",
    "favorite hotel perk",
    "most relaxing place you know",
    "favorite neighborhood to explore",
    "favorite late-night city",
    "favorite skyline view",
    "best sunset spot",
    "favorite podcast host",
    "favorite radio voice",
    "favorite quote from a film",
    "favorite quote from a book",
    "favorite daily ritual",
    "best advice ever received",
    "funniest travel mishap",
    "best birthday celebration idea",
    "favorite holiday tradition",
    "best gift you have received",
    "favorite souvenir to bring home",
    "favorite way to meet new people",
    "favorite low-key night out",
    "favorite high-energy night out",
    "best city for live music",
    "favorite meal after midnight",
    "best comfort TV show",
    "favorite guilty-pleasure snack",
    "favorite Sunday activity",
    "favorite weekday reset",
    "favorite fast breakfast",
    "favorite tiny luxury",
    "favorite creative outlet",
    "favorite underrated city",
    "favorite small town",
    "best scenic train ride",
    "favorite language phrase to learn on trips",
    "favorite road-trip stop",
    "favorite convenience-store snack",
    "favorite park bench activity",
    "favorite people-watching location",
    "favorite old-school gadget",
    "favorite tiny kitchen hack",
    "favorite home playlist mood",
    "favorite evening routine",
    "favorite way to start a conversation",
    "best poker room atmosphere in the world",
    "favorite poker city to visit",
    "most iconic televised poker moment",
    "favorite poker documentary",
    "best poker memoir or book",
    "most entertaining poker commentator duo",
    "favorite poker stream production style",
    "best tournament venue vibe",
    "favorite cardroom snack",
    "best casino coffee spot",
    "favorite late-night diner near a casino",
    "funniest table character ever seen",
    "wildest harmless prop-bet story",
    "best cardroom superstition you have heard",
    "favorite railbird memory",
    "most memorable dealer one-liner",
    "favorite player walk-on song idea",
    "best city for food after midnight",
    "favorite tournament series destination",
    "favorite poker room architecture",
    "best tournament break routine",
    "favorite table soundtrack genre",
    "favorite card protector object",
    "best seat in a casino lounge",
    "favorite lucky charm story",
    "most stylish poker table setup",
    "favorite hoodie or hat game-day vibe",
    "best hand-history told as comedy",
    "favorite chips and felt aesthetic",
    "most photogenic casino skyline",
    "favorite poker podcast episode",
    "favorite poker movie cameo",
    "favorite old-school poker show",
    "best destination for a mixed vacation and poker trip",
    "favorite city for walking between sessions",
    "favorite pre-session meal",
    "favorite post-session dessert",
    "best song for a comeback mood",
    "favorite quote about patience",
    "best advice from an elder player",
    "favorite road-trip companion snack",
    "best airport for people-watching",
    "favorite rain-soaked city memory",
    "best sunrise after a long night",
    "favorite table-friendly joke format",
    "favorite harmless table ritual",
    "best place to reset mentally mid-session",
    "favorite observation about human behavior at tables",
    "funniest harmless misread of a social cue",
    "favorite way to bounce back from a rough hour",
    "favorite celebration meal",
    "best comfort breakfast before a long day",
    "favorite city neighborhood for late food",
    "best underrated road city",
    "favorite city public transit story",
    "favorite place to read between events",
    "favorite hotel lobby people-watching story",
    "best street musician memory",
    "favorite venue lighting vibe",
    "favorite old neon sign",
    "best travel backpack setup",
    "favorite carry-on essential",
    "favorite travel mistake that became a story",
    "best bus or train conversation memory",
    "favorite way to meet locals while traveling",
    "favorite city market to explore",
    "best local breakfast in a new city",
    "favorite regional dish discovered on a trip",
    "favorite coffee shop to sit and think",
    "favorite place to decompress after noise",
    "best way to keep energy steady late night",
    "favorite table-side compliment style",
    "best way to keep banter inclusive",
    "favorite sports underdog run",
    "favorite clutch playoff memory",
    "favorite stadium food",
    "best rivalry in sports entertainment",
    "favorite locker-room style pep talk line",
    "favorite comedy special recently",
    "favorite improvised joke moment",
    "best crowd-work performer",
    "favorite podcast laugh-out-loud moment",
    "favorite comfort rewatch before bed",
    "best rainy-day movie pick",
    "favorite soundtrack for city nights",
    "favorite jazz bar memory",
    "best rooftop bar view",
    "favorite boardwalk or strip memory",
    "best arcades still worth visiting",
    "favorite tabletop game for big groups",
    "favorite social deduction game",
    "best collaborative game night snack",
    "favorite low-stakes fun competition",
    "favorite creative hobby outside screens",
    "best camera roll memory from last trip",
    "favorite tiny moment that made a trip great",
    "favorite local phrase from another region",
    "best city for spontaneous plans",
    "favorite all-time comeback story outside poker",
    "favorite mentor lesson",
    "best reminder to stay level-headed",
    "favorite daily reset habit",
    "best walk to clear your head",
    "favorite book chapter that stuck with you",
    "favorite documentary scene",
    "best conversation starter at a new table",
    "favorite way to include quiet people in a group",
    "best people-watching archetype",
    "favorite harmless conspiracy or superstition story",
    "best casino interior design era",
    "favorite cardroom nickname you have heard",
    "favorite tournament city weather",
    "best poker-room seat draw luck story",
    "favorite rail spot at a final table",
    "favorite commentator catchphrase style",
    "best no-context funny line from a table",
    "favorite calm-down technique under pressure",
    "best midweek reset activity",
    "favorite Sunday-night ritual"
  ]

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
               decide_action(table, legal, seat_cfg, state.talk_history, state.hand_index, opts),
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

  defp decide_action(table, legal, seat_cfg, talk_history, hand_index, opts) do
    attempts = Keyword.get(opts, :decision_attempts, @default_decision_attempts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    prompt = build_prompt(table, legal, seat_cfg, talk_history, hand_index, opts)

    agent_meta =
      %{
        poker: %{
          table_id: table.id,
          hand_id: table.hand.id,
          seat: legal.seat
        }
      }
      |> maybe_put_system_prompt(opts, seat_cfg)
      |> maybe_put_model(opts, seat_cfg)

    Enum.reduce_while(1..attempts, nil, fn _attempt, _acc ->
      case AgentRunner.run_prompt(seat_cfg.session_key, prompt,
             agent_id: seat_cfg.agent_id,
             timeout_ms: timeout_ms,
             meta: agent_meta,
             cwd: poker_agent_cwd(opts),
             tool_policy: poker_tool_policy(opts)
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

  defp build_prompt(table, legal, seat_cfg, talk_history, hand_index, opts) do
    hand = table.hand
    actor = Map.fetch!(hand.players, legal.seat)
    recent_talk = format_recent_talk(talk_history)
    reply_targets = format_reply_targets(talk_history, legal.seat)
    conversation_flow = format_conversation_flow(talk_history, legal.seat, table, hand_index)

    persona_turn_style =
      format_persona_turn_style(seat_cfg, table, legal.seat, hand_index, talk_history)

    self_recent_talk = format_recent_self_talk(talk_history, legal.seat)
    banter_inspiration = build_banter_inspiration(seat_cfg, table, hand_index, talk_history)
    conversation_topics = format_conversation_topics(table, legal.seat, hand_index, talk_history)
    persona_assignment = format_persona_assignment(seat_cfg)

    talk_block =
      if table_talk_enabled?(opts) do
        """
        Optional second line:
        TALK: <short table-talk message>

        Conversation quality rules:
        - Treat TALK like an ongoing conversation, not a random one-liner.
        - Put your own spin on the persona voice each time; do not recycle canned catchphrases.
        - Do not dogpile one comment with repetitive "same/me too" replies.
        - Mix it up: sometimes reply, sometimes pivot, sometimes stay brief or silent.
        - Prefer adding a new angle over repeating agreement.
        - If someone addressed you, answer them briefly in-character.
        - Keep TALK concise (one short sentence is ideal).

        Table-talk safety rules:
        - TALK is for social banter and light conversation with other players.
        - Do not use TALK to comment on ongoing decisions, betting lines, odds, ranges, or strategy.
        - Do not explain or justify your own action choice in TALK.
        - Never reveal your hole cards (ranks or suits) while this hand is live.
        - This applies even if you folded.
        - Avoid strategy keywords in TALK (bet, check, call, raise, fold, odds, range, pot, flop/turn/river/showdown).

        Recent table talk (latest last):
        #{recent_talk}

        Recent comments from other players you can reply to:
        #{reply_targets}

        Conversation flow directive for this turn:
        #{conversation_flow}

        Persona style directive for this turn:
        #{persona_turn_style}

        Your own recent TALK lines (avoid repeating these):
        #{self_recent_talk}

        Banter inspiration (paraphrase; do not copy verbatim):
        #{banter_inspiration}

        Optional fresh social topics (pick at most one; adapt naturally):
        #{conversation_topics}
        """
      else
        ""
      end

    """
    You are playing multi-player no-limit Texas Hold'em.
    You are seat #{legal.seat} (#{seat_cfg.label}).
    #{persona_assignment}

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

  defp maybe_put_model(meta, opts, seat_cfg) do
    case Map.get(seat_cfg, :model) do
      model when is_binary(model) and model != "" ->
        Map.put(meta, :model, model)

      _ ->
        case Keyword.get(opts, :model) do
          model when is_binary(model) and model != "" ->
            Map.put(meta, :model, model)

          _ ->
            meta
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

          [
            %{hand_index: state.hand_index, seat: seat, actor: seat_cfg.label, text: trimmed}
            | state.talk_history
          ]
          |> Enum.take(@talk_history_limit)

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
      agent_id: Keyword.get(opts, :agent_id, @default_agent_id),
      model: Keyword.get(opts, :model),
      player_models: Keyword.get(opts, :player_models),
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
    default_agent_id = Keyword.get(opts, :agent_id, @default_agent_id)

    # Pre-load all personas and banter once
    banter = Persona.load_banter()
    personas = load_personas_for_seats(opts, player_count)
    models = load_models_for_seats(opts, player_count)

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
      prompt = Enum.at(prompts, seat - 1)
      persona_name = Enum.at(personas, seat - 1)
      persona = if persona_name, do: Persona.load(persona_name), else: nil
      model = Enum.at(models, seat - 1)

      # Build persona-enhanced system prompt
      base_prompt = prompt || default_system_prompt(label)
      system_prompt = Persona.build_system_prompt(base_prompt, persona)

      {seat,
       %{
         label: ensure_seat_label(label, seat),
         agent_id: Enum.at(agent_ids, seat - 1) || default_agent_id,
         session_key: "poker:#{table_id}:seat:#{seat}",
         system_prompt: system_prompt,
         persona: persona_name,
         model: model,
         banter: banter
       }}
    end)
  end

  defp load_personas_for_seats(opts, player_count) do
    available = Persona.list()
    available_by_key = Map.new(available, &{String.downcase(&1), &1})

    selected =
      normalize_optional_string_list(Keyword.get(opts, :player_personas, []), player_count)

    0..(player_count - 1)
    |> Enum.map(fn index ->
      fallback = fallback_persona_for_seat(available, index + 1)

      case Enum.at(selected, index) do
        value when is_binary(value) ->
          resolve_persona_choice(value, available, available_by_key, fallback)

        _ ->
          fallback
      end
    end)
  end

  defp load_models_for_seats(opts, player_count) do
    selected =
      normalize_optional_string_list(Keyword.get(opts, :player_models, []), player_count)

    global_model = normalize_optional_string(Keyword.get(opts, :model))

    0..(player_count - 1)
    |> Enum.map(fn index ->
      case Enum.at(selected, index) do
        value when is_binary(value) and value != "" -> value
        _ -> global_model
      end
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

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_value), do: nil

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

  defp format_recent_talk([]), do: "(none yet)"

  defp format_recent_talk(talk_history) do
    talk_history
    |> Enum.take(@recent_talk_limit)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn talk ->
      hand_tag =
        case Map.get(talk, :hand_index) do
          hand_index when is_integer(hand_index) -> "H#{hand_index} "
          _ -> ""
        end

      "- #{hand_tag}#{talk.actor} (seat #{talk.seat}): #{talk.text}"
    end)
  end

  defp format_reply_targets(talk_history, acting_seat) do
    talk_history
    |> Enum.filter(&(Map.get(&1, :seat) != acting_seat))
    |> Enum.take(3)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn talk ->
      "- #{talk.actor}: #{talk.text}"
    end)
    |> case do
      "" -> "(none)"
      text -> text
    end
  end

  defp format_conversation_flow(talk_history, acting_seat, table, hand_index) do
    recent_other =
      talk_history
      |> Enum.filter(&(Map.get(&1, :seat) != acting_seat))
      |> Enum.take(10)

    mode = conversation_mode(table, hand_index, acting_seat, talk_history)
    latest_other = List.first(recent_other)
    preferred_target = preferred_reply_target(recent_other, latest_other, table, hand_index)

    mode_line =
      case mode do
        :reply ->
          "- Mode: reply to one player briefly, then add a small new angle."

        :pivot ->
          "- Mode: pivot; do not just echo the latest message."

        :callback ->
          "- Mode: callback; reference an older thread or a different speaker."

        :quiet ->
          "- Mode: quiet; skipping TALK is acceptable unless directly addressed."

        _ ->
          "- Mode: mixed; keep it natural and varied."
      end

    latest_line =
      case latest_other do
        %{actor: actor, seat: seat} ->
          "- Latest speaker was #{actor} (seat #{seat}); avoid a dogpile unless you add something genuinely new."

        _ ->
          "- No immediate speaker pressure; you can start a fresh social thread."
      end

    target_line =
      case preferred_target do
        %{actor: actor, seat: seat, text: text} ->
          "- Preferred variety target: #{actor} (seat #{seat}) said \"#{truncate_for_prompt(text, 90)}\"."

        _ ->
          "- Preferred variety target: none; either pivot to a fresh topic or stay brief."
      end

    [mode_line, latest_line, target_line]
    |> Enum.join("\n")
  end

  defp conversation_mode(table, hand_index, acting_seat, talk_history) do
    if talk_history == [] do
      :pivot
    else
      roll =
        :erlang.phash2(
          {table.id, table.hand_id, hand_index, acting_seat, length(talk_history), :talk_mode},
          100
        )

      cond do
        roll < 35 -> :reply
        roll < 65 -> :pivot
        roll < 85 -> :callback
        true -> :quiet
      end
    end
  end

  defp preferred_reply_target([], _latest_other, _table, _hand_index), do: nil

  defp preferred_reply_target(recent_other, latest_other, table, hand_index) do
    candidates =
      recent_other
      |> Enum.reverse()
      |> Enum.uniq_by(&Map.get(&1, :seat))

    candidates =
      case latest_other do
        %{seat: latest_seat} ->
          if length(candidates) > 1 do
            Enum.reject(candidates, &(Map.get(&1, :seat) == latest_seat))
          else
            candidates
          end

        _ ->
          candidates
      end

    case candidates do
      [] ->
        nil

      list ->
        index =
          rem(:erlang.phash2({table.id, table.hand_id, hand_index, :reply_target}), length(list))

        Enum.at(list, index)
    end
  end

  defp truncate_for_prompt(text, limit)
       when is_binary(text) and is_integer(limit) and limit > 0 do
    if String.length(text) <= limit do
      text
    else
      String.slice(text, 0, limit - 1) <> "..."
    end
  end

  defp format_recent_self_talk(talk_history, acting_seat) do
    talk_history
    |> Enum.filter(&(Map.get(&1, :seat) == acting_seat))
    |> Enum.take(@recent_self_talk_limit)
    |> Enum.reverse()
    |> Enum.map_join("\n", fn talk -> "- #{talk.text}" end)
    |> case do
      "" -> "(none)"
      text -> text
    end
  end

  defp build_banter_inspiration(seat_cfg, table, hand_index, talk_history) do
    banter = Map.get(seat_cfg, :banter, %{})
    context = prompt_banter_context(table, hand_index, talk_history)

    banter
    |> Persona.build_banter_prompt(context)
    |> String.trim()
    |> case do
      "" -> "(none)"
      text -> text
    end
  end

  defp format_conversation_topics(table, acting_seat, hand_index, talk_history) do
    topic_count = length(@conversation_topics)

    if topic_count == 0 do
      "(none)"
    else
      seed =
        :erlang.phash2(
          {table.id, table.hand_id, hand_index, acting_seat, length(talk_history), topic_count}
        )

      offset = rem(seed, topic_count)

      @conversation_topics
      |> rotate_list(offset)
      |> Enum.take(@topic_suggestion_count)
      |> Enum.map_join("\n", &"- #{&1}")
    end
  end

  defp format_persona_assignment(seat_cfg) do
    case Map.get(seat_cfg, :persona) do
      persona when is_binary(persona) and persona != "" ->
        "Assigned conversation persona for this seat: #{persona}."

      _ ->
        "Assigned conversation persona for this seat: default."
    end
  end

  defp format_persona_turn_style(seat_cfg, table, acting_seat, hand_index, talk_history) do
    persona =
      case Map.get(seat_cfg, :persona) do
        value when is_binary(value) -> String.trim(String.downcase(value))
        _ -> ""
      end

    base_lines =
      case persona do
        "friendly" ->
          [
            "- Voice: warm, welcoming, curious.",
            "- Pattern: acknowledge one player, then add one short follow-up.",
            "- Avoid: flat generic agreement with no new detail."
          ]

        "aggro" ->
          [
            "- Voice: confident, punchy, playful rivalry.",
            "- Pattern: one sharp line with momentum; keep it fun, not hostile.",
            "- Avoid: copying another player's wording."
          ]

        "grinder" ->
          [
            "- Voice: dry veteran calm, understated wit.",
            "- Pattern: compact observational line; low drama.",
            "- Avoid: overhyped slang and repeated proverbs."
          ]

        "silent" ->
          [
            "- Voice: sparse, deliberate, low-verbosity.",
            "- Pattern: brief reaction (often 1-5 words); ACTION-only is fine when not addressed.",
            "- Avoid: long chatter and unnecessary follow-ups."
          ]

        "tourist" ->
          [
            "- Voice: enthusiastic, colorful, social-night energy.",
            "- Pattern: short vivid detail from travel/food/music/nightlife, then move on.",
            "- Avoid: repeating Vegas or buffet references unless relevant."
          ]

        "showman" ->
          [
            "- Voice: TV-table charisma, theatrical but sharp.",
            "- Pattern: punchy line with stage presence, then quick handoff to another player.",
            "- Avoid: making every line about yourself."
          ]

        "professor" ->
          [
            "- Voice: thoughtful, articulate, quietly nerdy.",
            "- Pattern: one concise observation about people, then a curious follow-up.",
            "- Avoid: lecture mode or heavy jargon dumps."
          ]

        "road_dog" ->
          [
            "- Voice: road-tested traveler with cardroom stories.",
            "- Pattern: short city/circuit anecdote tied to current table mood.",
            "- Avoid: repeating the same city reference every turn."
          ]

        "dealer_friend" ->
          [
            "- Voice: polished, social, etiquette-aware insider.",
            "- Pattern: keep conversation smooth and inclusive with crisp phrasing.",
            "- Avoid: sounding like a rulebook or floor announcement."
          ]

        "homegame_legend" ->
          [
            "- Voice: neighborhood storyteller, playful and relatable.",
            "- Pattern: family/friends home-game flavor in one compact beat.",
            "- Avoid: turning every line into a long story."
          ]

        _ ->
          [
            "- Voice: distinct, human, and seat-specific.",
            "- Pattern: add a fresh angle instead of echoing the latest line.",
            "- Avoid: generic filler that any seat could have said."
          ]
      end

    anchor =
      persona_tone_anchor(persona, table, acting_seat, hand_index, talk_history, seat_cfg.label)

    (base_lines ++ ["- Tone anchor for this turn: #{anchor}."])
    |> Enum.join("\n")
  end

  defp persona_tone_anchor(persona, table, acting_seat, hand_index, talk_history, label) do
    anchors =
      case persona do
        "friendly" ->
          [
            "host mode",
            "easygoing check-in",
            "inclusive vibe",
            "encouraging nod",
            "light curiosity"
          ]

        "aggro" ->
          [
            "competitive spark",
            "table-energy surge",
            "playful challenge",
            "confident jab",
            "tempo pressure"
          ]

        "grinder" ->
          [
            "old-room patience",
            "dry one-liner",
            "steady pulse",
            "seen-it-all calm",
            "quiet edge"
          ]

        "silent" ->
          [
            "minimal signal",
            "quiet read",
            "short acknowledgment",
            "tight reaction",
            "cool restraint"
          ]

        "tourist" ->
          [
            "night-out excitement",
            "travel-story spark",
            "food-scene energy",
            "event-night buzz",
            "wide-eyed fun"
          ]

        "showman" ->
          [
            "TV-table spotlight",
            "showtime delivery",
            "headline moment",
            "mic'd-up energy",
            "stagecraft charm"
          ]

        "professor" ->
          [
            "behavioral note",
            "curious frame",
            "quiet analysis of vibe",
            "thoughtful callback",
            "elegant brevity"
          ]

        "road_dog" ->
          [
            "circuit-life realism",
            "airport-to-cardroom grind",
            "city-hop anecdote",
            "late-night traveler calm",
            "road wisdom"
          ]

        "dealer_friend" ->
          [
            "table flow stewardship",
            "room etiquette warmth",
            "dealer-box perspective",
            "clean social tempo",
            "smooth crowd handling"
          ]

        "homegame_legend" ->
          [
            "garage-table nostalgia",
            "kitchen-table chaos",
            "friendly rivalry story",
            "community-night warmth",
            "old-friends cadence"
          ]

        _ ->
          [
            "fresh angle",
            "varied delivery",
            "human cadence",
            "non-repetitive style",
            "social realism"
          ]
      end

    index =
      rem(
        :erlang.phash2(
          {table.id, table.hand_id, acting_seat, hand_index, length(talk_history), label, persona}
        ),
        length(anchors)
      )

    Enum.at(anchors, index)
  end

  defp prompt_banter_context(table, hand_index, talk_history) do
    base_context =
      Persona.detect_banter_context(%{
        hand_index: hand_index,
        last_hand_result: table.last_hand_result,
        pot: table.hand && table.hand.pot,
        big_blind: table.big_blind
      })

    cond do
      is_binary(base_context) ->
        base_context

      talk_history != [] ->
        "reaction"

      true ->
        "idle"
    end
  end

  defp fallback_persona_for_seat([], _seat), do: nil

  defp fallback_persona_for_seat(personas, seat) when is_list(personas) and is_integer(seat) do
    Enum.at(personas, rem(max(seat - 1, 0), length(personas)))
  end

  defp resolve_persona_choice(value, available, available_by_key, fallback)
       when is_binary(value) and is_list(available) and is_map(available_by_key) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        fallback

      trimmed in available ->
        trimmed

      true ->
        Map.get(available_by_key, String.downcase(trimmed), fallback)
    end
  end

  defp rotate_list(list, offset) when is_list(list) and is_integer(offset) and offset > 0 do
    Enum.drop(list, offset) ++ Enum.take(list, offset)
  end

  defp rotate_list(list, _offset), do: list

  defp default_system_prompt(label) do
    """
    You are #{label}, a poker agent focused only on legal NLHE play.
    Follow format exactly: ACTION line required; TALK line optional.
    Use only legal actions and legal bet/raise totals from the prompt; if raising, respect min-raise and stack constraints.
    TALK quality bar:
    - Keep it conversational and in-character, not random ad-lib fragments.
    - Preserve a distinct voice for your assigned persona; do not drift into generic table chatter.
    - Add your own spin each time; avoid repeating the same catchphrases.
    - Avoid pile-on behavior where everyone echoes the same comment.
    - Alternate between replies, pivots, callbacks, and occasional silence.
    - Use wording and rhythm that could only belong to your persona.
    - Keep TALK brief, natural, and social.
    TALK is social banter only; never discuss live strategy, betting decisions, hand strength, ranges, odds, cards, or your action rationale.
    """
  end

  defp poker_agent_cwd(opts) do
    case Keyword.get(opts, :agent_cwd) do
      cwd when is_binary(cwd) and cwd != "" ->
        Path.expand(cwd)

      _ ->
        LemonPoker.RuntimeConfig.poker_agent_cwd()
    end
  end

  defp poker_tool_policy(opts) do
    case Keyword.get(opts, :tool_policy) do
      policy when is_map(policy) and map_size(policy) > 0 ->
        policy

      _ ->
        %{
          allow: [@no_tools_allow_token],
          deny: [],
          require_approval: [],
          approvals: %{},
          no_reply: false
        }
    end
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
