defmodule LemonSimUi.HostedGame.RoomServer do
  @moduledoc false

  use GenServer

  require Logger

  alias LemonCore.MapHelpers
  alias LemonCore.Store
  alias LemonSim.Examples.Werewolf
  alias LemonSim.Examples.Werewolf.{ActionSpace, RulesConfig}
  alias LemonSim.Kernel.DecisionAdapters.ToolResultEvents
  alias LemonSim.Kernel.{Runner, State}
  alias LemonSim.LLM.GameHelpers.Config, as: GameConfig
  alias LemonSimUi.HostedGame
  alias LemonSimUi.HostedGame.Replay
  alias LemonSimUi.HostedGame.Room

  @max_command_ids 512
  @max_replay_entries 2_000

  def start_link(room_id) when is_binary(room_id) do
    case Store.get(HostedGame.room_table(), room_id) |> Room.normalize() do
      %Room{} = room -> GenServer.start_link(__MODULE__, room, name: via(room_id))
      _ -> {:error, :room_not_found}
    end
  end

  def via(room_id), do: {:via, Registry, {LemonSimUi.HostedGame.Registry, room_id}}

  def claim_seat(room_id, seat_id, display_name),
    do: GenServer.call(via(room_id), {:claim_seat, seat_id, display_name})

  def join_view(room_id), do: GenServer.call(via(room_id), :join_view)
  def host_view(room_id, token), do: GenServer.call(via(room_id), {:host_view, token})
  def player_view(room_id, token), do: GenServer.call(via(room_id), {:player_view, token})

  def public_view(room_id, credential),
    do: GenServer.call(via(room_id), {:public_view, credential})

  def control(room_id, token, action, params),
    do: GenServer.call(via(room_id), {:control, token, action, params}, 15_000)

  def configure_seat(room_id, token, seat_id, kind),
    do: GenServer.call(via(room_id), {:configure_seat, token, seat_id, kind})

  def release_seat(room_id, token, seat_id),
    do: GenServer.call(via(room_id), {:release_seat, token, seat_id})

  def submit_command(
        room_id,
        token,
        command_id,
        expected_match_number,
        expected_version,
        action,
        params
      ) do
    GenServer.call(
      via(room_id),
      {:submit_command, token, command_id, expected_match_number, expected_version, action,
       params},
      15_000
    )
  end

  def connect_player(room_id, token, pid),
    do: GenServer.call(via(room_id), {:connect_player, token, pid})

  def export_replay(room_id, token),
    do: GenServer.call(via(room_id), {:export_replay, token}, 15_000)

  def prune(room_id, expected_status, expected_updated_at_ms),
    do: GenServer.cast(via(room_id), {:prune, expected_status, expected_updated_at_ms})

  @impl true
  def init(%Room{} = room) do
    restore_rng(room.rng_state)

    state = %{
      room: room,
      timer_ref: nil,
      ai_pending: nil,
      ai_retry_ref: nil,
      timeout_retry_count: 0,
      terminal_retry_ref: nil,
      pending_terminal_room: nil,
      connections: %{},
      monitor_refs: %{}
    }

    {:ok, state, {:continue, :restore_runtime}}
  end

  @impl true
  def handle_continue(:restore_runtime, state), do: {:noreply, schedule_runtime(state)}

  @impl true
  def handle_call(:join_view, _from, state) do
    room = state.room

    view = %{
      room_id: room.id,
      join_code: room.join_code,
      status: room.status,
      seats:
        room.seats
        |> Enum.filter(fn {_seat_id, seat} -> seat.kind == "human" end)
        |> Enum.sort_by(fn {seat_id, _seat} -> seat_id end)
        |> Enum.map(fn {seat_id, seat} ->
          %{id: seat_id, available: is_nil(seat.token_hash), display_name: seat.display_name}
        end)
    }

    {:reply, {:ok, view}, state}
  end

  def handle_call({:host_view, token}, _from, state) do
    if host_authorized?(state.room, token) do
      {:reply, {:ok, host_projection(state)}, state}
    else
      {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call({:player_view, token}, _from, state) do
    with {:ok, actor_id} <- authenticate_player(state.room, token),
         {:ok, projection} <- player_projection(state.room, actor_id) do
      {:reply, {:ok, projection}, state}
    else
      _ -> {:reply, {:error, :unauthorized}, state}
    end
  end

  def handle_call({:public_view, credential}, _from, state) do
    room = state.room

    authorized? =
      room.config.visibility == "public_safe" or valid_host_credential?(room, credential)

    if authorized? do
      {:reply, {:ok, public_projection(room)}, state}
    else
      {:reply, {:error, :private_room}, state}
    end
  end

  def handle_call({:claim_seat, seat_id, display_name}, _from, state) do
    with :ok <- require_status(state.room, ["lobby", "paused"]),
         :ok <- validate_display_name(display_name),
         {:ok, seat} <- fetch_human_seat(state.room, seat_id),
         true <- is_nil(seat.token_hash) do
      token = random_token()
      now = now_ms()

      seat = %{
        seat
        | token_hash: HostedGame.hash_token(token),
          display_name: String.trim(display_name),
          claimed_at_ms: now
      }

      room =
        state.room
        |> Map.put(:seats, Map.put(state.room.seats, seat_id, seat))
        |> touch(now)
        |> append_replay("seat_claimed", seat_id, %{display_name: seat.display_name})

      case persist(room) do
        :ok ->
          state = %{state | room: room}
          broadcast(room)
          HostedGame.emit(:seat_claimed, %{count: 1}, %{room_id: room.id, seat_id: seat_id})
          {:reply, {:ok, %{room_id: room.id, player_token: token, seat_id: seat_id}}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      false -> {:reply, {:error, :seat_taken}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :invalid_seat}, state}
    end
  end

  def handle_call({:configure_seat, token, seat_id, kind}, _from, state) do
    with :ok <- authorize_host(state.room, token),
         :ok <- require_status(state.room, ["lobby", "paused"]),
         true <- kind in ["human", "ai"],
         :ok <- ensure_ai_kind_ready(kind, state.room.config.ai_model),
         {:ok, seat} <- fetch_seat(state.room, seat_id) do
      updated = %{
        seat
        | kind: kind,
          display_name: if(kind == "ai", do: "AI · #{seat_id}", else: nil),
          token_hash: nil,
          claimed_at_ms: nil
      }

      seats = Map.put(state.room.seats, seat_id, updated)
      ai_seats = Enum.count(seats, fn {_id, configured} -> configured.kind == "ai" end)

      room =
        state.room
        |> Map.put(:seats, seats)
        |> Map.put(:config, Map.put(state.room.config, :ai_seats, ai_seats))
        |> touch()
        |> append_replay("seat_configured", nil, %{seat_id: seat_id, kind: kind})

      case persist(room) do
        :ok ->
          state = state |> disconnect_seat(seat_id) |> Map.put(:room, room)
          broadcast(room)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      false -> {:reply, {:error, :invalid_seat_kind}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :invalid_seat}, state}
    end
  end

  def handle_call({:release_seat, token, seat_id}, _from, state) do
    with :ok <- authorize_host(state.room, token),
         :ok <- require_status(state.room, ["lobby", "paused"]),
         {:ok, seat} <- fetch_human_seat(state.room, seat_id) do
      updated = %{seat | display_name: nil, token_hash: nil, claimed_at_ms: nil}

      room =
        state.room
        |> Map.put(:seats, Map.put(state.room.seats, seat_id, updated))
        |> touch()
        |> append_replay("seat_released", nil, %{seat_id: seat_id})

      case persist(room) do
        :ok ->
          state = disconnect_seat(%{state | room: room}, seat_id)
          broadcast(room)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:control, token, action, params}, _from, state) do
    case authorize_host(state.room, token) do
      :ok ->
        if state.pending_terminal_room do
          {:reply, {:error, :persistence_pending}, state}
        else
          handle_host_control(action, params, state)
        end

      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:submit_command, token, command_id, expected_match_number, expected_version, action,
         params},
        _from,
        state
      ) do
    case authenticate_player(state.room, token) do
      {:ok, actor_id} ->
        case apply_player_command(
               state,
               actor_id,
               command_id,
               expected_match_number,
               expected_version,
               action,
               params,
               "player"
             ) do
          {:ok, next_state, result} -> {:reply, {:ok, result}, next_state}
          {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
        end

      {:error, reason} ->
        HostedGame.emit(:command_rejected, %{count: 1}, %{
          room_id: state.room.id,
          error_class: HostedGame.error_class(reason)
        })

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:connect_player, token, pid}, _from, state) when is_pid(pid) do
    case authenticate_player(state.room, token) do
      {:ok, actor_id} ->
        ref = Process.monitor(pid)

        connections =
          Map.update(state.connections, actor_id, MapSet.new([pid]), &MapSet.put(&1, pid))

        monitor_refs = Map.put(state.monitor_refs, ref, {actor_id, pid})
        state = %{state | connections: connections, monitor_refs: monitor_refs}
        broadcast(state.room)

        HostedGame.emit(:player_connected, %{count: 1}, %{room_id: state.room.id, seat_id: actor_id})

        {:reply, {:ok, actor_id}, state}

      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:export_replay, token}, _from, state) do
    room = state.room

    with :ok <- authorize_host(room, token),
         true <- is_nil(state.pending_terminal_room),
         true <- room.status in ["completed", "stopped"] do
      export = %{
        schema: "lemon.hosted_werewolf.replay.v1",
        room_id: room.id,
        match_number: room.match_number,
        config: room.config,
        player_ids: room.seats |> Map.keys() |> Enum.sort(),
        seats: redact_seats(room.seats),
        seed: room.config.seed,
        command_seq: room.command_seq,
        replay: room.replay,
        previous_matches: room.match_archives,
        final_state: sanitize_final_state(room.game_state),
        final_state_hash: replay_state_hash(room.game_state),
        started_at_ms: room.started_at_ms,
        finished_at_ms: room.finished_at_ms
      }

      {:reply, {:ok, export}, state}
    else
      false -> {:reply, {:error, :game_in_progress}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:prune, expected_status, expected_updated_at_ms}, state) do
    room = state.room

    if room.status == expected_status and room.updated_at_ms == expected_updated_at_ms and
         room.status in ["lobby", "paused", "completed", "stopped"] do
      with :ok <- Store.delete(HostedGame.join_table(), room.join_code),
           :ok <- Store.delete(HostedGame.room_table(), room.id) do
        {:stop, :normal, state}
      else
        {:error, reason} ->
          _ = Store.put_new(HostedGame.join_table(), room.join_code, room.id)

          Logger.warning(
            "Hosted Werewolf prune persistence failed: #{HostedGame.error_class(reason)}"
          )

          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:turn_timeout, match_number, version, actor_id, deadline_at_ms}, state) do
    room = state.room

    if HostedGame.enabled?() and room.status == "running" and room.match_number == match_number and
         room.game_state.version == version and active_actor(room) == actor_id and
         room.deadline_at_ms == deadline_at_ms do
      command_id = "timeout-#{match_number}-#{version}-#{actor_id}"

      case default_action(room.game_state, actor_id) do
        {:ok, action, params} ->
          case apply_player_command(
                 %{state | timer_ref: nil},
                 actor_id,
                 command_id,
                 match_number,
                 version,
                 action,
                 params,
                 "timeout"
               ) do
            {:ok, next_state, _result} ->
              HostedGame.emit(:turn_timeout, %{count: 1}, %{room_id: room.id, seat_id: actor_id})
              {:noreply, next_state}

            {:error, reason, next_state} ->
              Logger.error(
                "Hosted Werewolf timeout failed for #{room.id}: #{HostedGame.error_class(reason)}"
              )

              message = {:turn_timeout, match_number, version, actor_id, deadline_at_ms}

              if match?({:persistence_failed, _}, reason) do
                {:noreply, retry_timeout(next_state, message, reason)}
              else
                {:noreply, fail_room(next_state, {:timeout_action_failed, reason})}
              end
          end

        {:error, reason} ->
          Logger.error(
            "Hosted Werewolf has no legal timeout action for #{room.id}: #{HostedGame.error_class(reason)}"
          )

          {:noreply, fail_room(%{state | timer_ref: nil}, {:no_timeout_action, reason})}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:ai_result, generation, room_id, match_number, version, actor_id, result},
        state
      ) do
    room = state.room

    cond do
      current_ai_result?(state, generation, room_id, match_number, version, actor_id) and
          deadline_expired?(room) ->
        state = clear_ai_pending(state)
        enqueue_turn_timeout(room)
        {:noreply, state}

      matching_ai_result?(state, generation, room_id, match_number, version, actor_id) ->
        state = clear_ai_pending(state)

        case result do
          {:ok, %{state: %State{} = game_state, events: events}, rng_state} ->
            if rejected_state?(game_state, room.game_state) do
              HostedGame.emit(:ai_error, %{count: 1}, %{
                room_id: room.id,
                error_class: "rejected"
              })

              {:noreply, state}
            else
              command_id = "ai-#{match_number}-#{version}-#{actor_id}"

              case commit_transition(
                     state,
                     actor_id,
                     command_id,
                     "ai_decision",
                     %{events: summarize_events(events)},
                     events,
                     game_state,
                     rng_state,
                     "ai"
                   ) do
                {:ok, next_state, _result} -> {:noreply, next_state}
                {:error, _reason, next_state} -> {:noreply, next_state}
              end
            end

          {:error, reason, _rng_state} ->
            error_class = HostedGame.error_class(reason)
            Logger.warning("Hosted Werewolf AI step failed for #{room.id}: #{error_class}")
            HostedGame.emit(:ai_error, %{count: 1}, %{room_id: room.id, error_class: error_class})
            {:noreply, state}
        end

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_ai, room_id, match_number, version, actor_id}, state) do
    room = state.room
    state = %{state | ai_retry_ref: nil}

    if HostedGame.enabled?() and room.id == room_id and room.status == "running" and
         room.match_number == match_number and room.game_state.version == version and
         active_actor(room) == actor_id and ai_seat?(room, actor_id) do
      {:noreply, start_ai_step(state, actor_id)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:persist_terminal, attempt}, state) do
    case state.pending_terminal_room do
      %Room{} = room ->
        case persist(room) do
          :ok ->
            HostedGame.terminalization_complete(room.id)
            broadcast(room)
            {:noreply, %{state | room: room, pending_terminal_room: nil, terminal_retry_ref: nil}}

          {:error, _reason} ->
            delay = min(30_000, trunc(500 * :math.pow(2, min(attempt, 6))))
            ref = Process.send_after(self(), {:persist_terminal, attempt + 1}, delay)
            {:noreply, %{state | terminal_retry_ref: ref}}
        end

      nil ->
        {:noreply, %{state | terminal_retry_ref: nil}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      state.ai_pending && state.ai_pending.ref == ref ->
        {:noreply, %{state | ai_pending: nil}}

      Map.has_key?(state.monitor_refs, ref) ->
        {actor_id, pid} = Map.fetch!(state.monitor_refs, ref)
        monitor_refs = Map.delete(state.monitor_refs, ref)

        connections =
          Map.update(state.connections, actor_id, MapSet.new(), fn pids ->
            MapSet.delete(pids, pid)
          end)

        state = %{state | connections: connections, monitor_refs: monitor_refs}
        broadcast(state.room)

        HostedGame.emit(:player_disconnected, %{count: 1}, %{
          room_id: state.room.id,
          seat_id: actor_id
        })

        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = state |> cancel_timer() |> clear_ai_pending()
    if state.terminal_retry_ref, do: Process.cancel_timer(state.terminal_retry_ref)
    Enum.each(Map.keys(state.monitor_refs), &Process.demonitor(&1, [:flush]))
    :ok
  end

  defp handle_host_control("start", _params, state) do
    room = state.room

    with :ok <- require_status(room, ["lobby"]),
         :ok <- ensure_all_humans_claimed(room),
         :ok <- validate_room_ai(room) do
      now = now_ms()

      room =
        room
        |> Map.merge(%{
          status: "running",
          terminal_reason: nil,
          started_at_ms: now,
          finished_at_ms: nil,
          paused_remaining_ms: nil,
          paused_at_ms: nil,
          phase_started_at_ms: now
        })
        |> touch(now)
        |> append_replay("game_started", nil, %{}, now)
        |> set_deadline(now)

      case persist(room) do
        :ok ->
          HostedGame.emit(:game_started, %{count: 1}, %{room_id: room.id})
          state = state |> cancel_timer() |> Map.put(:room, room) |> schedule_runtime()
          broadcast(room)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_host_control("pause", _params, state) do
    room = state.room

    case require_status(room, ["running"]) do
      :ok ->
        remaining = max((room.deadline_at_ms || now_ms()) - now_ms(), 0)
        now = now_ms()

        room =
          room
          |> Map.merge(%{
            status: "paused",
            paused_remaining_ms: remaining,
            paused_at_ms: now,
            deadline_at_ms: nil
          })
          |> touch()
          |> append_replay("game_paused", nil, %{remaining_ms: remaining})

        case persist(room) do
          :ok ->
            state = state |> cancel_timer() |> clear_ai_pending() |> Map.put(:room, room)
            broadcast(room)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_host_control("resume", _params, state) do
    room = state.room

    with :ok <- require_status(room, ["paused"]),
         :ok <- ensure_all_humans_claimed(room),
         :ok <- validate_room_ai(room) do
      now = now_ms()
      remaining = room.paused_remaining_ms || timeout_ms(room)
      paused_duration = max(now - (room.paused_at_ms || now), 0)

      room =
        room
        |> Map.merge(%{
          status: "running",
          deadline_at_ms: now + remaining,
          paused_remaining_ms: nil,
          paused_at_ms: nil,
          phase_started_at_ms: (room.phase_started_at_ms || now) + paused_duration
        })
        |> touch(now)
        |> append_replay("game_resumed", nil, %{remaining_ms: remaining}, now)

      case persist(room) do
        :ok ->
          state = %{state | room: room} |> schedule_runtime()
          broadcast(room)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_host_control("cancel", params, state),
    do: handle_host_control("stop", params, state)

  defp handle_host_control("stop", _params, state) do
    room = state.room

    case require_status(room, ["lobby", "running", "paused"]) do
      :ok ->
        now = now_ms()
        replay_kind = if room.status == "lobby", do: "room_cancelled", else: "game_stopped"

        room =
          room
          |> Map.merge(%{
            status: "stopped",
            terminal_reason: if(room.status == "lobby", do: "host_cancelled", else: "host_stopped"),
            deadline_at_ms: nil,
            paused_remaining_ms: nil,
            paused_at_ms: nil,
            finished_at_ms: now
          })
          |> touch(now)
          |> append_replay(replay_kind, nil, %{}, now)

        case persist(room) do
          :ok ->
            HostedGame.emit(:game_stopped, %{count: 1}, %{room_id: room.id})
            state = state |> cancel_timer() |> clear_ai_pending() |> Map.put(:room, room)
            broadcast(room)
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_host_control("rematch", params, state) do
    room = state.room

    with :ok <- require_status(room, ["completed", "stopped"]),
         :ok <- validate_room_ai(room),
         :ok <- HostedGame.reserve_active_slot(room.id) do
      seed = parse_rematch_seed(params) || random_seed()
      config = %{room.config | seed: seed}

      {game_state, rng_state} =
        new_game_state(room.id, config, room.match_number + 1, Map.keys(room.seats))

      now = now_ms()
      match_archives = Enum.take(room.match_archives ++ [replay_archive(room)], -10)

      room = %{
        room
        | status: "lobby",
          terminal_reason: nil,
          config: config,
          game_state: game_state,
          rng_state: rng_state,
          command_seq: 0,
          command_ids: [],
          replay: [HostedGame.replay_entry("rematch_created", nil, %{seed: seed}, now)],
          match_archives: match_archives,
          deadline_at_ms: nil,
          paused_remaining_ms: nil,
          paused_at_ms: nil,
          match_number: room.match_number + 1,
          updated_at_ms: now,
          phase_started_at_ms: now,
          started_at_ms: nil,
          finished_at_ms: nil
      }

      case persist(room) do
        :ok ->
          HostedGame.release_active_slot(room.id)
          state = state |> cancel_timer() |> clear_ai_pending() |> Map.put(:room, room)
          broadcast(room)
          {:reply, :ok, state}

        {:error, reason} ->
          HostedGame.release_active_slot(room.id)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_host_control(_action, _params, state),
    do: {:reply, {:error, :invalid_control}, state}

  defp apply_player_command(
         state,
         actor_id,
         command_id,
         expected_match_number,
         expected_version,
         action,
         params,
         source
       ) do
    room = state.room

    invalid_envelope? =
      source == "player" and
        (not is_integer(expected_match_number) or not is_integer(expected_version) or
           not is_binary(action))

    stored_command_id =
      if invalid_envelope? or (source == "player" and not valid_command_id?(command_id)) do
        nil
      else
        command_key(source, expected_match_number, actor_id, command_id)
      end

    cond do
      not is_map(params) ->
        reject_command(state, :invalid_parameters)

      invalid_envelope? ->
        reject_command(state, :invalid_parameters)

      source == "player" and not valid_command_id?(command_id) ->
        reject_command(state, :invalid_command_id)

      room.match_number != expected_match_number ->
        reject_command(state, :stale_match)

      not is_nil(stored_command_id) and stored_command_id in room.command_ids ->
        {:ok, state, %{status: :duplicate, version: room.game_state.version}}

      room.status != "running" ->
        reject_command(state, :game_not_running)

      source == "player" and deadline_expired?(room) ->
        enqueue_turn_timeout(room)
        reject_command(state, :turn_expired)

      room.game_state.version != expected_version ->
        reject_command(state, :stale_state)

      active_actor(room) != actor_id ->
        reject_command(state, :not_active_actor)

      true ->
        restore_rng(room.rng_state)

        params = if source == "player", do: Map.delete(params, "thought"), else: params

        with {:ok, event} <- ActionSpace.execute_action(room.game_state, actor_id, action, params),
             {:ok, next_game_state, _signal} <-
               Runner.ingest_events(room.game_state, [event], Werewolf.Updater, []),
             false <- rejected_state?(next_game_state, room.game_state) do
          rng_state = :rand.export_seed()

          commit_transition(
            state,
            actor_id,
            stored_command_id,
            action,
            redact_command_params(params),
            [event],
            next_game_state,
            rng_state,
            source
          )
        else
          true -> reject_command(state, :action_rejected)
          {:error, reason} -> reject_command(state, reason)
        end
    end
  end

  defp commit_transition(
         state,
         actor_id,
         command_id,
         action,
         params,
         applied_events,
         game_state,
         rng_state,
         source
       ) do
    room = state.room
    now = now_ms()
    terminal? = MapHelpers.get_key(game_state.world, :status) == "game_over"
    previous_phase = MapHelpers.get_key(room.game_state.world, :phase)
    next_phase = MapHelpers.get_key(game_state.world, :phase)
    phase_changed? = previous_phase != next_phase
    phase_duration_ms = max(now - (room.phase_started_at_ms || now), 0)

    room =
      %{
        room
        | game_state: game_state,
          rng_state: rng_state,
          command_seq: room.command_seq + 1,
          command_ids: Enum.take([command_id | room.command_ids], @max_command_ids),
          status: if(terminal?, do: "completed", else: "running"),
          deadline_at_ms: if(terminal?, do: nil, else: now + timeout_ms(room)),
          finished_at_ms: if(terminal?, do: now, else: nil),
          phase_started_at_ms: if(phase_changed?, do: now, else: room.phase_started_at_ms),
          updated_at_ms: now
      }
      |> append_replay("command", actor_id, %{
        command_id: command_id,
        sequence: room.command_seq + 1,
        action: action,
        params: params,
        events: replay_events(applied_events),
        state_hash: replay_state_hash(game_state),
        source: source,
        state_version: game_state.version
      })

    case persist(room) do
      :ok ->
        state = state |> cancel_timer() |> clear_ai_pending() |> Map.put(:room, room)
        state = if terminal?, do: state, else: schedule_runtime(state)
        broadcast(room)

        if phase_changed? do
          HostedGame.emit(
            :phase_completed,
            %{duration_ms: phase_duration_ms, count: 1},
            %{room_id: room.id, phase: previous_phase, next_phase: next_phase}
          )
        end

        HostedGame.emit(:command_accepted, %{count: 1}, %{
          room_id: room.id,
          seat_id: actor_id,
          source: source,
          phase: MapHelpers.get_key(game_state.world, :phase)
        })

        if terminal? do
          HostedGame.emit(:game_completed, %{count: 1}, %{
            room_id: room.id,
            winner: MapHelpers.get_key(game_state.world, :winner)
          })
        end

        {:ok, state, %{status: :accepted, version: game_state.version}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp reject_command(state, reason) do
    HostedGame.emit(:command_rejected, %{count: 1}, %{
      room_id: state.room.id,
      error_class: HostedGame.error_class(reason)
    })

    {:error, reason, state}
  end

  defp command_key("player", match_number, actor_id, command_id),
    do: "player/#{match_number}/#{actor_id}/#{command_id}"

  defp command_key(source, match_number, actor_id, command_id),
    do: "system/#{source}/#{match_number}/#{actor_id}/#{command_id}"

  defp schedule_runtime(state) do
    state = %{cancel_timer(state) | timeout_retry_count: 0}
    room = state.room

    if HostedGame.enabled?() and room.status == "running" do
      actor_id = active_actor(room)
      deadline = room.deadline_at_ms || now_ms() + timeout_ms(room)
      delay = max(deadline - now_ms(), 0)

      timer_ref =
        Process.send_after(
          self(),
          {:turn_timeout, room.match_number, room.game_state.version, actor_id, deadline},
          delay
        )

      room = if room.deadline_at_ms, do: room, else: %{room | deadline_at_ms: deadline}
      state = %{state | room: room, timer_ref: timer_ref}

      if ai_seat?(room, actor_id), do: start_ai_step(state, actor_id), else: state
    else
      state
    end
  end

  defp start_ai_step(%{ai_pending: pending} = state, _actor_id) when not is_nil(pending),
    do: state

  defp start_ai_step(%{ai_retry_ref: retry_ref} = state, _actor_id)
       when not is_nil(retry_ref),
       do: state

  defp start_ai_step(state, actor_id) do
    room = state.room
    parent = self()
    version = room.game_state.version
    match_number = room.match_number
    rng_state = room.rng_state
    game_state = room.game_state
    ai_model = room.config.ai_model
    generation = make_ref()

    case Task.Supervisor.start_child(LemonSimUi.HostedGame.AiTaskSupervisor, fn ->
           result = run_ai_step(game_state, rng_state, ai_model)

           send(
             parent,
             {:ai_result, generation, room.id, match_number, version, actor_id, result}
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        %{
          state
          | ai_pending: %{
              pid: pid,
              ref: ref,
              generation: generation,
              actor_id: actor_id,
              version: version
            }
        }

      {:error, :max_children} ->
        retry_ref =
          Process.send_after(
            self(),
            {:retry_ai, room.id, match_number, version, actor_id},
            250
          )

        %{state | ai_retry_ref: retry_ref}

      {:error, reason} ->
        Logger.error("Failed to start hosted Werewolf AI task: #{HostedGame.error_class(reason)}")
        state
    end
  end

  defp run_ai_step(game_state, rng_state, ai_model) do
    started_at = System.monotonic_time(:millisecond)
    result = do_run_ai_step(game_state, rng_state, ai_model)
    duration_ms = max(System.monotonic_time(:millisecond) - started_at, 0)
    status = if match?({:ok, _, _}, result), do: :ok, else: :error

    HostedGame.emit(
      :provider_request,
      %{count: 1, duration_ms: duration_ms},
      %{
        status: status,
        model: Application.get_env(:lemon_sim_ui, :hosted_ai_model, "default")
      }
    )

    result
  end

  defp do_run_ai_step(game_state, rng_state, ai_model) do
    restore_rng(rng_state)

    opts =
      hosted_ai_overrides(ai_model)
      |> Werewolf.default_opts()
      |> Keyword.put(:persist?, false)

    with {:ok, decision, _state} <- Runner.decide_once(game_state, Werewolf.modules(), opts),
         {:ok, events} <- ToolResultEvents.to_events(decision, game_state, opts) do
      restore_rng(rng_state)

      case Runner.ingest_events(
             game_state,
             events,
             Werewolf.Updater,
             halt_on_decide?: false
           ) do
        {:ok, next_state, signal} ->
          {:ok, %{decision: decision, events: events, state: next_state, signal: signal},
           :rand.export_seed()}

        {:error, reason} ->
          {:error, reason, rng_state}
      end
    else
      {:error, reason} ->
        {:error, reason, rng_state}
    end
  rescue
    error -> {:error, Exception.message(error), rng_state}
  catch
    kind, reason -> {:error, {kind, reason}, rng_state}
  end

  defp hosted_ai_overrides(model_spec) do
    overrides = Application.get_env(:lemon_sim_ui, :hosted_ai_opts, [])

    case model_spec do
      spec when is_binary(spec) and spec != "" ->
        config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

        model =
          GameConfig.resolve_model_spec(nil, spec) ||
            raise ArgumentError, "Unknown hosted Werewolf AI model: #{spec}"

        model = GameConfig.apply_provider_base_url(model, config)
        api_key = GameConfig.resolve_provider_api_key!(model.provider, config, "hosted werewolf")

        overrides
        |> Keyword.put(:model, model)
        |> Keyword.put(:stream_options, %{api_key: api_key})

      _ ->
        overrides
    end
  end

  defp default_action(game_state, actor_id) do
    case ActionSpace.available_actions(game_state, actor_id) do
      {:ok, [action | _]} ->
        params =
          action["parameters"]
          |> Map.get("properties", %{})
          |> Enum.reduce(%{}, fn {key, schema}, acc ->
            cond do
              key == "thought" ->
                acc

              values = Map.get(schema, "enum") ->
                Map.put(acc, key, values |> Enum.sort() |> List.first())

              key in ["statement", "message", "reason"] ->
                Map.put(acc, key, "Time ran out before I could answer.")

              true ->
                acc
            end
          end)

        {:ok, action["name"], params}

      _ -> {:error, :no_legal_action}
    end
  end

  defp host_projection(state) do
    room = state.room

    %{
      id: room.id,
      join_code: room.join_code,
      status: room.status,
      terminal_reason: room.terminal_reason,
      config: room.config,
      seats:
        room.seats
        |> Enum.sort_by(fn {seat_id, _seat} -> seat_id end)
        |> Enum.map(fn {seat_id, seat} ->
          %{
            id: seat_id,
            kind: seat.kind,
            display_name: seat.display_name,
            claimed: is_binary(seat.token_hash),
            connected: connected?(state, seat_id)
          }
        end),
      game: public_game_summary(room),
      deadline_at_ms: room.deadline_at_ms,
      match_number: room.match_number,
      command_seq: room.command_seq,
      can_start: room.status == "lobby" and all_humans_claimed?(room),
      can_resume: room.status == "paused" and all_humans_claimed?(room),
      can_export: room.status in ["completed", "stopped"] and is_nil(state.pending_terminal_room),
      persistence_pending: not is_nil(state.pending_terminal_room)
    }
  end

  defp player_projection(room, actor_id) do
    with {:ok, projection} <- Werewolf.player_projection(room.game_state, actor_id) do
      seat = Map.fetch!(room.seats, actor_id)

      projection =
        if sealed_waiting_room?(room) do
          description =
            if room.status == "lobby" do
              "Your role is sealed until the host starts the match."
            else
              "This room was cancelled before roles were revealed."
            end

          Map.merge(projection, %{
            "role_info" => %{
              "your_name" => actor_id,
              "your_role" => "sealed",
              "description" => description
            },
            "world" => lobby_world(projection["world"]),
            "recent_events" => [],
            "final_roles" => %{},
            "legal_actions" => []
          })
        else
          projection
        end

      {:ok,
       Map.merge(projection, %{
         "room" => %{
           "id" => room.id,
           "status" => room.status,
           "terminal_reason" => room.terminal_reason,
           "match_number" => room.match_number,
           "deadline_at_ms" => room.deadline_at_ms,
           "turn_timeout_seconds" => room.config.turn_timeout_seconds,
           "visibility" => room.config.visibility
         },
         "seat" => %{
           "id" => actor_id,
           "display_name" => seat.display_name,
           "connected" => true
         },
         "seats" => safe_seats(room.seats),
         "version" => room.game_state.version
       })}
    end
  end

  defp public_projection(room) do
    {:ok, projection} = Werewolf.public_projection(room.game_state)

    projection =
      if sealed_waiting_room?(room) do
        Map.merge(projection, %{
          "world" => lobby_world(projection["world"]),
          "recent_events" => [],
          "final_roles" => %{}
        })
      else
        projection
      end

    Map.merge(projection, %{
      "room" => %{
        "id" => room.id,
        "status" => room.status,
        "terminal_reason" => room.terminal_reason,
        "match_number" => room.match_number,
        "deadline_at_ms" => room.deadline_at_ms
      },
      "seats" => safe_seats(room.seats)
    })
  end

  defp safe_seats(seats) do
    Map.new(seats, fn {seat_id, seat} ->
      {seat_id, %{"display_name" => seat.display_name, "kind" => seat.kind}}
    end)
  end

  defp public_game_summary(%Room{status: "lobby", game_state: game_state}) do
    waiting_game_summary(game_state)
  end

  defp public_game_summary(%Room{
         status: "stopped",
         terminal_reason: "host_cancelled",
         started_at_ms: nil,
         game_state: game_state
       }) do
    waiting_game_summary(game_state)
  end

  defp public_game_summary(%Room{game_state: game_state}) do
    phase = MapHelpers.get_key(game_state.world, :phase)

    %{
      phase: phase,
      day_number: MapHelpers.get_key(game_state.world, :day_number),
      active_actor_id:
        if(phase in ["wolf_discussion", "night", "private_meeting"],
          do: nil,
          else: MapHelpers.get_key(game_state.world, :active_actor_id)
        ),
      status: MapHelpers.get_key(game_state.world, :status),
      winner: MapHelpers.get_key(game_state.world, :winner),
      version: game_state.version
    }
  end

  defp waiting_game_summary(game_state) do
    %{
      phase: nil,
      day_number: nil,
      active_actor_id: nil,
      status: "waiting",
      winner: nil,
      version: game_state.version
    }
  end

  defp sealed_waiting_room?(%Room{status: "lobby"}), do: true

  defp sealed_waiting_room?(%Room{
         status: "stopped",
         terminal_reason: "host_cancelled",
         started_at_ms: nil
       }),
       do: true

  defp sealed_waiting_room?(_room), do: false

  defp lobby_world(world) do
    Map.merge(world, %{
      "status" => "waiting",
      "winner" => nil,
      "phase" => nil,
      "day_number" => nil,
      "active_player" => nil
    })
  end

  defp new_game_state(room_id, config, match_number, player_ids) do
    previous_seed = :rand.export_seed()
    :rand.seed(:exsss, {config.seed, config.seed + 1, config.seed + 2})

    state =
      Werewolf.initial_state(
        sim_id: "hosted_#{room_id}_m#{match_number}",
        player_count: config.player_count,
        player_ids: Enum.sort(player_ids),
        generate_lore?: false
      )

    state =
      put_in(
        state.world[:rules],
        config.rules_preset
        |> RulesConfig.for_preset()
        |> Map.put(:turn_timeout_seconds, config.turn_timeout_seconds)
      )

    rng_state = :rand.export_seed()
    restore_rng(previous_seed)
    {state, rng_state}
  end

  defp authorize_host(room, token) do
    if host_authorized?(room, token), do: :ok, else: {:error, :unauthorized}
  end

  defp host_authorized?(room, token),
    do: HostedGame.secure_token?(token, room.host_token_hash)

  defp valid_host_credential?(room, {:host, token}), do: host_authorized?(room, token)
  defp valid_host_credential?(_room, _credential), do: false

  defp authenticate_player(room, token) when is_binary(token) do
    room.seats
    |> Enum.find_value({:error, :unauthorized}, fn {seat_id, seat} ->
      if HostedGame.secure_token?(token, seat.token_hash), do: {:ok, seat_id}
    end)
  end

  defp authenticate_player(_room, _token), do: {:error, :unauthorized}

  defp fetch_seat(room, seat_id) when is_binary(seat_id) do
    case Map.fetch(room.seats, seat_id) do
      {:ok, seat} -> {:ok, seat}
      :error -> {:error, :invalid_seat}
    end
  end

  defp fetch_seat(_room, _seat_id), do: {:error, :invalid_seat}

  defp fetch_human_seat(room, seat_id) do
    with {:ok, seat} <- fetch_seat(room, seat_id),
         true <- seat.kind == "human" do
      {:ok, seat}
    else
      false -> {:error, :seat_not_joinable}
      error -> error
    end
  end

  defp require_status(room, statuses) do
    if room.status in statuses, do: :ok, else: {:error, :invalid_room_status}
  end

  defp ensure_ai_kind_ready("ai", model_spec), do: HostedGame.ai_ready?(model_spec)
  defp ensure_ai_kind_ready("human", _model_spec), do: :ok

  defp validate_room_ai(room) do
    if Enum.any?(room.seats, fn {_seat_id, seat} -> seat.kind == "ai" end) do
      HostedGame.ai_ready?(room.config.ai_model)
    else
      :ok
    end
  end

  defp ensure_all_humans_claimed(room) do
    if all_humans_claimed?(room), do: :ok, else: {:error, :seats_unclaimed}
  end

  defp all_humans_claimed?(room) do
    Enum.all?(room.seats, fn {_id, seat} ->
      seat.kind == "ai" or is_binary(seat.token_hash)
    end)
  end

  defp validate_display_name(name) when is_binary(name) do
    trimmed = String.trim(name)

    if String.valid?(trimmed) and byte_size(trimmed) in 1..40,
      do: :ok,
      else: {:error, :invalid_display_name}
  end

  defp validate_display_name(_name), do: {:error, :invalid_display_name}

  defp valid_command_id?(id) when is_binary(id) and byte_size(id) in 8..100,
    do: String.valid?(id) and id =~ ~r/^[A-Za-z0-9._:-]+$/

  defp valid_command_id?(_id), do: false

  defp rejected_state?(next_state, previous_state) do
    case List.last(next_state.recent_events) do
      %{kind: "action_rejected"} when next_state.version > previous_state.version -> true
      _ -> false
    end
  end

  defp redact_command_params(params) when is_map(params), do: Map.delete(params, "thought")
  defp redact_command_params(_params), do: %{}

  defp summarize_events(events) do
    events
    |> List.wrap()
    |> Enum.map(fn event -> Map.get(event, :kind, Map.get(event, "kind", "event")) end)
  end

  defp replay_events(events) do
    Enum.map(List.wrap(events), fn event ->
      %{
        kind: Map.get(event, :kind, Map.get(event, "kind", "event")),
        payload:
          event
          |> Map.get(:payload, Map.get(event, "payload", %{}))
          |> strip_private_replay_fields()
      }
    end)
  end

  defp strip_private_replay_fields(value) when is_struct(value) do
    value |> Map.from_struct() |> strip_private_replay_fields()
  end

  defp strip_private_replay_fields(value) when is_map(value) do
    Map.new(value, fn {key, item} ->
      if to_string(key) in ["thought", "private_note"] do
        {key, "[redacted]"}
      else
        {key, strip_private_replay_fields(item)}
      end
    end)
  end

  defp strip_private_replay_fields(value) when is_list(value),
    do: Enum.map(value, &strip_private_replay_fields/1)

  defp strip_private_replay_fields(value), do: value

  defp replay_state_hash(%State{} = game_state) do
    Replay.state_hash(game_state)
  end

  defp sanitize_final_state(%State{} = state) do
    world =
      state.world
      |> Map.delete(:journals)
      |> Map.delete("journals")
      |> Map.delete(:plan_history)
      |> Map.delete("plan_history")

    %{
      state
      | world: world,
        recent_events: strip_private_replay_fields(state.recent_events),
        intent: nil,
        plan_history: [],
        memory_index_path: nil,
        meta: %{}
    }
  end

  defp replay_archive(room) do
    %{
      match_number: room.match_number,
      config: room.config,
      player_ids: room.seats |> Map.keys() |> Enum.sort(),
      seats: redact_seats(room.seats),
      command_seq: room.command_seq,
      replay: room.replay,
      final_state_hash: replay_state_hash(room.game_state),
      started_at_ms: room.started_at_ms,
      finished_at_ms: room.finished_at_ms
    }
  end

  defp redact_seats(seats) do
    Map.new(seats, fn {seat_id, seat} ->
      {seat_id, Map.drop(seat, [:token_hash])}
    end)
  end

  defp parse_rematch_seed(params) when is_map(params) do
    value = Map.get(params, :seed, Map.get(params, "seed"))

    case value do
      integer when is_integer(integer) and integer in 1..2_147_483_647 ->
        integer

      binary when is_binary(binary) ->
        case Integer.parse(binary) do
          {integer, ""} when integer in 1..2_147_483_647 -> integer
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_rematch_seed(_params), do: nil

  defp active_actor(room), do: MapHelpers.get_key(room.game_state.world, :active_actor_id)

  defp ai_seat?(room, actor_id) do
    case Map.get(room.seats, actor_id) do
      %{kind: "ai"} -> true
      _ -> false
    end
  end

  defp connected?(state, actor_id) do
    state.connections |> Map.get(actor_id, MapSet.new()) |> MapSet.size() > 0
  end

  defp disconnect_seat(state, seat_id) do
    pids = Map.get(state.connections, seat_id, MapSet.new())

    monitor_refs =
      Enum.reduce(state.monitor_refs, state.monitor_refs, fn {ref, {actor_id, pid}}, acc ->
        if actor_id == seat_id and MapSet.member?(pids, pid) do
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)
        else
          acc
        end
      end)

    %{state | connections: Map.delete(state.connections, seat_id), monitor_refs: monitor_refs}
  end

  defp persist(room) do
    case Store.put(HostedGame.room_table(), room.id, room) do
      :ok ->
        :ok

      {:error, reason} ->
        HostedGame.emit(:persistence_error, %{count: 1}, %{
          room_id: room.id,
          error_class: HostedGame.error_class(reason)
        })

        {:error, {:persistence_failed, reason}}
    end
  end

  defp append_replay(room, kind, actor, data, at_ms \\ now_ms()) do
    entry = HostedGame.replay_entry(kind, actor, data, at_ms)
    %{room | replay: Enum.take(room.replay ++ [entry], -@max_replay_entries)}
  end

  defp touch(room, now \\ now_ms()), do: %{room | updated_at_ms: now}

  defp set_deadline(room, now), do: %{room | deadline_at_ms: now + timeout_ms(room)}
  defp timeout_ms(room), do: room.config.turn_timeout_seconds * 1_000
  defp now_ms, do: System.system_time(:millisecond)

  defp random_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp random_seed do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(2_147_483_646)
    |> Kernel.+(1)
  end

  defp restore_rng(nil), do: :rand.seed(:default)
  defp restore_rng(:undefined), do: :rand.seed(:default)
  defp restore_rng(seed), do: :rand.seed(seed)

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp clear_ai_pending(state) do
    if state.ai_retry_ref, do: Process.cancel_timer(state.ai_retry_ref)

    if state.ai_pending do
      if Process.alive?(state.ai_pending.pid), do: Process.exit(state.ai_pending.pid, :shutdown)
      Process.demonitor(state.ai_pending.ref, [:flush])
    end

    %{state | ai_pending: nil, ai_retry_ref: nil}
  end

  defp matching_ai_result?(state, generation, room_id, match_number, version, actor_id) do
    current_ai_result?(state, generation, room_id, match_number, version, actor_id) and
      not deadline_expired?(state.room)
  end

  defp current_ai_result?(state, generation, room_id, match_number, version, actor_id) do
    room = state.room
    pending = state.ai_pending

    ((HostedGame.enabled?() and pending) && pending.generation == generation) and
      room.id == room_id and
      room.status == "running" and room.match_number == match_number and
      room.game_state.version == version and active_actor(room) == actor_id
  end

  defp deadline_expired?(%Room{deadline_at_ms: deadline}) when is_integer(deadline),
    do: now_ms() > deadline

  defp deadline_expired?(_room), do: false

  defp enqueue_turn_timeout(room) do
    send(
      self(),
      {:turn_timeout, room.match_number, room.game_state.version, active_actor(room),
       room.deadline_at_ms}
    )
  end

  defp retry_timeout(state, message, reason) do
    if state.timeout_retry_count < 3 do
      delay = trunc(250 * :math.pow(2, state.timeout_retry_count))

      %{
        state
        | timer_ref: Process.send_after(self(), message, delay),
          timeout_retry_count: state.timeout_retry_count + 1
      }
    else
      fail_room(state, {:timeout_retry_exhausted, reason})
    end
  end

  defp fail_room(state, reason) do
    now = now_ms()

    room =
      state.room
      |> Map.merge(%{
        status: "stopped",
        terminal_reason: "runtime_failure",
        deadline_at_ms: nil,
        paused_remaining_ms: nil,
        paused_at_ms: nil,
        finished_at_ms: now
      })
      |> touch(now)
      |> append_replay("runtime_failed", nil, %{error_class: HostedGame.error_class(reason)}, now)

    case persist(room) do
      :ok ->
        next_state = state |> cancel_timer() |> clear_ai_pending() |> Map.put(:room, room)
        broadcast(room)

        HostedGame.emit(:room_failed, %{count: 1}, %{
          room_id: room.id,
          error_class: HostedGame.error_class(reason)
        })

        next_state

      {:error, _persist_reason} ->
        HostedGame.terminalization_pending(room.id)
        ref = Process.send_after(self(), {:persist_terminal, 1}, 500)

        state
        |> cancel_timer()
        |> clear_ai_pending()
        |> Map.merge(%{
          room: room,
          pending_terminal_room: room,
          terminal_retry_ref: ref
        })
    end
  end

  defp broadcast(room) do
    event =
      LemonCore.Event.new(:hosted_werewolf_updated, %{room_id: room.id}, %{room_id: room.id})

    LemonCore.Bus.broadcast(HostedGame.topic(room.id), event)
  end
end
