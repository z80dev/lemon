defmodule LemonSimUi.HostedGameTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store
  alias LemonSimUi.HostedGame
  alias LemonSimUi.HostedGame.Replay

  alias LemonAi.Types.{AssistantMessage, Model, ToolCall}

  @werewolf_actions ~w(
    anonymous_message
    cast_vote
    choose_victim
    investigate_player
    make_accusation
    make_last_words
    make_statement
    meeting_message
    night_wander
    protect_player
    request_meeting
    sleep
    use_item
    wolf_chat
  )

  setup do
    previous_enabled = Application.get_env(:lemon_sim_ui, :hosted_rooms_enabled)
    previous_ai_opts = Application.get_env(:lemon_sim_ui, :hosted_ai_opts)
    Application.put_env(:lemon_sim_ui, :hosted_rooms_enabled, true)
    Application.delete_env(:lemon_sim_ui, :hosted_ai_opts)

    on_exit(fn ->
      if is_nil(previous_enabled) do
        Application.delete_env(:lemon_sim_ui, :hosted_rooms_enabled)
      else
        Application.put_env(:lemon_sim_ui, :hosted_rooms_enabled, previous_enabled)
      end

      restore_env(:hosted_ai_opts, previous_ai_opts)
    end)

    :ok
  end

  test "creates a private room, authenticates distinct surfaces, and claims seats" do
    room = create_room(%{player_count: 5, turn_timeout_seconds: 30})

    assert room.join_code =~ ~r/^[A-Z2-9]{10}$/
    assert {:error, :unauthorized} = HostedGame.host_view(room.room_id, "wrong")
    assert {:error, :private_room} = HostedGame.public_view(room.room_id)

    assert {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)
    assert host.status == "lobby"
    assert host.game.status == "waiting"
    assert is_nil(host.game.phase)
    assert is_nil(host.game.day_number)
    assert length(host.seats) == 5
    refute Map.has_key?(host, :game_state)
    refute inspect(host) =~ "werewolf_partners"

    seat = Enum.find(host.seats, &(&1.kind == "human"))

    assert {:ok, claim} = HostedGame.claim_seat(room.join_code, seat.id, "Mara")
    assert claim.room_id == room.room_id
    assert claim.player_token != room.host_token
    assert {:error, :seat_taken} = HostedGame.claim_seat(room.join_code, seat.id, "Other")

    assert {:ok, player} = HostedGame.player_view(room.room_id, claim.player_token)
    assert player["seat"]["id"] == seat.id
    assert player["seat"]["display_name"] == "Mara"
    assert player["role_info"]["your_role"] == "sealed"
    assert player["world"]["status"] == "waiting"
    assert is_nil(player["world"]["phase"])
    assert is_nil(player["world"]["day_number"])
    assert is_nil(player["world"]["active_player"])
    refute Map.has_key?(player, "game_state")

    persisted = HostedGame.raw_room(room.room_id)
    refute persisted.host_token_hash == room.host_token
    refute persisted.seats[seat.id].token_hash == claim.player_token

    cleanup_room(room.room_id, room.join_code)
  end

  test "starts only with claimed humans and accepts idempotent server-built commands" do
    room = create_room(%{player_count: 5, visibility: "public_safe", turn_timeout_seconds: 30})
    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)

    assert {:error, :seats_unclaimed} =
             HostedGame.control(room.room_id, room.host_token, "start")

    tokens =
      Map.new(host.seats, fn seat ->
        {:ok, claim} = HostedGame.claim_seat(room.join_code, seat.id, "Player #{seat.id}")
        {seat.id, claim.player_token}
      end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")
    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)
    assert is_nil(host.game.active_actor_id)
    actor_id = HostedGame.raw_room(room.room_id).game_state.world.active_actor_id
    actor_token = Map.fetch!(tokens, actor_id)
    other_token = tokens |> Map.delete(actor_id) |> Map.values() |> hd()

    assert {:ok, player} = HostedGame.player_view(room.room_id, actor_token)
    [action | _] = player["legal_actions"]
    params = valid_params(action)
    match_number = player["room"]["match_number"]
    version = player["version"]

    assert {:error, :not_active_actor} =
             HostedGame.submit_command(
               room.room_id,
               other_token,
               "command-other-1",
               match_number,
               version,
               action["name"],
               params
             )

    assert {:ok, %{status: :accepted, version: next_version}} =
             HostedGame.submit_command(
               room.room_id,
               actor_token,
               "command-actor-1",
               match_number,
               version,
               action["name"],
               params
             )

    assert next_version > version

    assert {:ok, %{status: :duplicate, version: ^next_version}} =
             HostedGame.submit_command(
               room.room_id,
               actor_token,
               "command-actor-1",
               match_number,
               version,
               action["name"],
               params
             )

    assert {:error, :stale_state} =
             HostedGame.submit_command(
               room.room_id,
               Map.fetch!(
                 tokens,
                 HostedGame.raw_room(room.room_id).game_state.world.active_actor_id
               ),
               "command-stale-1",
               match_number,
               version,
               action["name"],
               params
             )

    assert {:ok, public} = HostedGame.public_view(room.room_id)
    refute Map.has_key?(public, "role_info")
    assert public["final_roles"] == %{}
    refute inspect(public) =~ "wolf_chat_transcript"

    cleanup_room(room.room_id, room.join_code)
  end

  test "cancelling an unstarted lobby keeps every role sealed" do
    room =
      create_room(%{player_count: 5, visibility: "public_safe", turn_timeout_seconds: 30})

    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)
    seat = List.first(host.seats)
    {:ok, claim} = HostedGame.claim_seat(room.join_code, seat.id, "Cancelled player")

    assert :ok = HostedGame.control(room.room_id, room.host_token, "cancel")

    assert {:ok, cancelled_host} = HostedGame.host_view(room.room_id, room.host_token)
    assert cancelled_host.status == "stopped"
    assert cancelled_host.terminal_reason == "host_cancelled"
    assert cancelled_host.game.status == "waiting"
    assert is_nil(cancelled_host.game.phase)
    assert is_nil(cancelled_host.game.day_number)

    assert {:ok, cancelled_player} =
             HostedGame.player_view(room.room_id, claim.player_token)

    assert cancelled_player["role_info"]["your_role"] == "sealed"
    assert cancelled_player["world"]["status"] == "waiting"
    assert cancelled_player["recent_events"] == []
    assert cancelled_player["legal_actions"] == []
    assert cancelled_player["final_roles"] == %{}
    assert Enum.all?(cancelled_player["world"]["players"], &(not Map.has_key?(&1, "role")))

    assert {:ok, public} = HostedGame.public_view(room.room_id)
    assert public["world"]["status"] == "waiting"
    assert public["final_roles"] == %{}
    assert Enum.all?(public["world"]["players"], &(not Map.has_key?(&1, "role")))
  end

  test "pause, restart recovery, stop, export, and rematch preserve credentials" do
    room = create_room(%{player_count: 5, ai_seats: 0, turn_timeout_seconds: 30})
    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)

    Enum.each(host.seats, fn seat ->
      assert {:ok, _claim} =
               HostedGame.claim_seat(room.join_code, seat.id, "Recovery #{seat.id}")
    end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "pause")

    assert {:ok, paused} = HostedGame.host_view(room.room_id, room.host_token)
    assert paused.status == "paused"

    pid = room_pid(room.room_id)
    assert :ok = DynamicSupervisor.terminate_child(LemonSimUi.HostedGame.RoomSupervisor, pid)

    assert {:ok, recovered} = HostedGame.host_view(room.room_id, room.host_token)
    assert recovered.status == "paused"
    assert recovered.match_number == 1

    assert :ok = HostedGame.control(room.room_id, room.host_token, "resume")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
    assert {:ok, export} = HostedGame.export_replay(room.room_id, room.host_token)
    assert export.schema == "lemon.hosted_werewolf.replay.v1"
    assert export.final_state.sim_id =~ room.room_id
    refute inspect(export.seats) =~ "token_hash"

    assert :ok = HostedGame.control(room.room_id, room.host_token, "rematch", %{seed: 9191})
    assert {:ok, rematch} = HostedGame.host_view(room.room_id, room.host_token)
    assert rematch.status == "lobby"
    assert rematch.match_number == 2
    assert rematch.config.seed == 9191
    assert rematch.can_start
    assert Enum.map(rematch.seats, & &1.id) == Enum.map(recovered.seats, & &1.id)

    assert MapSet.new(Map.keys(HostedGame.raw_room(room.room_id).game_state.world.players)) ==
             MapSet.new(Enum.map(rematch.seats, & &1.id))

    cleanup_room(room.room_id, room.join_code)
  end

  test "configured AI seats advance through the same durable room command path" do
    previous_opts = Application.get_env(:lemon_sim_ui, :hosted_ai_opts)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "hosted-ai-call",
             name: "wolf_chat",
             arguments: %{
               "message" => "I favor a quiet opening.",
               "thought" => "PRIVATE_AI_THOUGHT_SENTINEL"
             }
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    Application.put_env(:lemon_sim_ui, :hosted_ai_opts,
      model: fake_model(),
      stream_options: %{},
      complete_fn: complete_fn
    )

    on_exit(fn -> restore_env(:hosted_ai_opts, previous_opts) end)

    room = create_room(%{player_count: 5, ai_seats: 5, turn_timeout_seconds: 30})
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    wait_until(fn -> HostedGame.raw_room(room.room_id).command_seq >= 1 end)
    persisted = HostedGame.raw_room(room.room_id)
    assert persisted.command_seq >= 1
    assert Enum.any?(persisted.replay, &(&1.kind == "command" and &1.data.source == "ai"))

    assert :ok = HostedGame.control(room.room_id, room.host_token, "pause")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
    assert {:ok, export} = HostedGame.export_replay(room.room_id, room.host_token)

    assert :binary.match(
             :erlang.term_to_binary(export),
             "PRIVATE_AI_THOUGHT_SENTINEL"
           ) == :nomatch

    assert {:ok, _verification} = Replay.verify(export)
  end

  test "provider randomness cannot perturb authoritative game RNG or replay verification" do
    previous_opts = Application.get_env(:lemon_sim_ui, :hosted_ai_opts)

    complete_fn = fn _model, context, _stream_opts ->
      _ = :rand.uniform()
      tool = Enum.find(context.tools, &(&1.name in @werewolf_actions))

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: [
           %ToolCall{
             type: :tool_call,
             id: "hosted-ai-rng-#{System.unique_integer([:positive])}",
             name: tool.name,
             arguments: required_tool_params(tool.parameters)
           }
         ],
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    Application.put_env(:lemon_sim_ui, :hosted_ai_opts,
      model: fake_model(),
      stream_options: %{},
      complete_fn: complete_fn
    )

    on_exit(fn -> restore_env(:hosted_ai_opts, previous_opts) end)

    room =
      create_room(%{
        player_count: 5,
        ai_seats: 5,
        seed: 4_242,
        rules_preset: "classic",
        turn_timeout_seconds: 30
      })

    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")
    wait_until(fn -> HostedGame.raw_room(room.room_id).status == "completed" end, 1_500)

    assert {:ok, export} = HostedGame.export_replay(room.room_id, room.host_token)
    assert export.command_seq > 1
    assert {:ok, %{commands: commands}} = Replay.verify(export)
    assert commands == export.command_seq
  end

  test "secret phases conceal actor identity and private rooms remain private after stopping" do
    room = create_room(%{player_count: 5, visibility: "private", turn_timeout_seconds: 30})
    tokens = claim_all(room, "Private")

    Enum.each(tokens, fn {_seat_id, token} ->
      assert {:ok, lobby} = HostedGame.player_view(room.room_id, token)
      assert lobby["role_info"]["your_role"] == "sealed"
      assert is_nil(lobby["world"]["active_player"])
    end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")
    persisted = HostedGame.raw_room(room.room_id)
    active_actor = persisted.game_state.world.active_actor_id

    assert {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)
    assert is_nil(host.game.active_actor_id)
    assert {:error, :private_room} = HostedGame.public_view(room.room_id)

    Enum.each(persisted.game_state.world.players, fn {seat_id, player} ->
      assert {:ok, projection} = HostedGame.player_view(room.room_id, tokens[seat_id])

      if player.role == "werewolf" do
        assert projection["world"]["active_player"] == active_actor
      else
        assert is_nil(projection["world"]["active_player"])
      end
    end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
    assert {:error, :private_room} = HostedGame.public_view(room.room_id)
    assert {:ok, stopped_host} = HostedGame.host_view(room.room_id, room.host_token)
    assert stopped_host.terminal_reason == "host_stopped"
    assert {:ok, stopped_player} = HostedGame.player_view(room.room_id, tokens[active_actor])
    assert stopped_player["room"]["terminal_reason"] == "host_stopped"
  end

  test "abnormal room restarts reload the latest durable transition" do
    room = create_room(%{player_count: 5, turn_timeout_seconds: 30})
    tokens = claim_all(room, "Crash")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    persisted = HostedGame.raw_room(room.room_id)
    actor_id = persisted.game_state.world.active_actor_id
    {:ok, player} = HostedGame.player_view(room.room_id, tokens[actor_id])
    [action | _] = player["legal_actions"]

    assert {:ok, %{status: :accepted}} =
             HostedGame.submit_command(
               room.room_id,
               tokens[actor_id],
               "before-crash",
               player["room"]["match_number"],
               player["version"],
               action["name"],
               valid_params(action)
             )

    durable = HostedGame.raw_room(room.room_id)
    old_pid = room_pid(room.room_id)
    Process.exit(old_pid, :kill)

    wait_until(fn ->
      case Registry.lookup(LemonSimUi.HostedGame.Registry, room.room_id) do
        [{pid, _}] -> pid != old_pid
        [] -> false
      end
    end)

    recovered = HostedGame.raw_room(room.room_id)
    assert recovered.command_seq == durable.command_seq
    assert recovered.game_state.version == durable.game_state.version
    assert {:ok, %{status: "running"}} = HostedGame.host_view(room.room_id, room.host_token)
    assert :ok = HostedGame.control(room.room_id, room.host_token, "pause")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
  end

  test "command epochs and namespaces reject delayed rematch commands without stalling timeouts" do
    room = create_room(%{player_count: 5, turn_timeout_seconds: 30})
    tokens = claim_all(room, "Epoch")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    persisted = HostedGame.raw_room(room.room_id)
    actor_id = persisted.game_state.world.active_actor_id
    {:ok, player} = HostedGame.player_view(room.room_id, tokens[actor_id])
    [action | _] = player["legal_actions"]
    params = valid_params(action)
    predicted_timeout_id = "timeout-1-#{player["version"]}-#{actor_id}"

    assert {:ok, %{status: :accepted}} =
             HostedGame.submit_command(
               room.room_id,
               tokens[actor_id],
               predicted_timeout_id,
               1,
               player["version"],
               action["name"],
               params
             )

    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
    assert {:ok, export} = HostedGame.export_replay(room.room_id, room.host_token)
    assert {:ok, _verification} = Replay.verify(export)
    assert :ok = HostedGame.control(room.room_id, room.host_token, "rematch", %{seed: 8181})
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    assert {:error, :stale_match} =
             HostedGame.submit_command(
               room.room_id,
               tokens[actor_id],
               "delayed-match-one",
               1,
               player["version"],
               action["name"],
               params
             )

    assert {:error, :invalid_parameters} =
             HostedGame.submit_command(
               room.room_id,
               tokens[actor_id],
               "malformed",
               2,
               0,
               action["name"],
               "not-a-map"
             )

    assert Process.alive?(room_pid(room.room_id))
    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
  end

  test "persisted turn timers ignore stale messages and apply a deterministic legal default" do
    room = create_room(%{player_count: 5, turn_timeout_seconds: 30})
    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)

    Enum.each(host.seats, fn seat ->
      assert {:ok, _claim} =
               HostedGame.claim_seat(room.join_code, seat.id, "Timer #{seat.id}")
    end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")
    pid = room_pid(room.room_id)
    persisted = HostedGame.raw_room(room.room_id)
    assert persisted.command_seq == 0
    assert Enum.all?(persisted.seats, fn {_seat_id, seat} -> seat.kind == "human" end)
    actor_id = persisted.game_state.world.active_actor_id
    version = persisted.game_state.version
    deadline = System.system_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{state | room: %{state.room | deadline_at_ms: deadline}}
    end)

    send(pid, {:turn_timeout, persisted.match_number, version + 1, actor_id, deadline})
    Process.sleep(20)
    assert HostedGame.raw_room(room.room_id).command_seq == 0

    send(pid, {:turn_timeout, persisted.match_number, version, actor_id, deadline})
    wait_until(fn -> HostedGame.raw_room(room.room_id).command_seq == 1 end)

    timed_out = HostedGame.raw_room(room.room_id)

    assert Enum.any?(timed_out.replay, fn entry ->
             entry.kind == "command" and entry.data.source == "timeout"
           end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "pause")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
  end

  test "expired human and AI decisions cannot beat the authoritative timeout" do
    room = create_room(%{player_count: 5, turn_timeout_seconds: 30})
    tokens = claim_all(room, "Deadline")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    pid = room_pid(room.room_id)
    persisted = HostedGame.raw_room(room.room_id)
    actor_id = persisted.game_state.world.active_actor_id
    {:ok, player} = HostedGame.player_view(room.room_id, tokens[actor_id])
    [action | _] = player["legal_actions"]
    expired_at = System.system_time(:millisecond) - 1_000

    :sys.replace_state(pid, fn state ->
      %{state | room: %{state.room | deadline_at_ms: expired_at}}
    end)

    assert {:error, :turn_expired} =
             HostedGame.submit_command(
               room.room_id,
               tokens[actor_id],
               "late-human-command",
               player["room"]["match_number"],
               player["version"],
               action["name"],
               valid_params(action)
             )

    wait_until(fn -> HostedGame.raw_room(room.room_id).command_seq == 1 end)
    after_human_timeout = HostedGame.raw_room(room.room_id)

    assert List.last(after_human_timeout.replay).data.source == "timeout"

    next_actor = after_human_timeout.game_state.world.active_actor_id
    generation = make_ref()
    task_pid = spawn(fn -> Process.sleep(:infinity) end)
    ref = Process.monitor(task_pid)
    next_expired_at = System.system_time(:millisecond) - 1_000

    :sys.replace_state(pid, fn state ->
      %{
        state
        | room: %{state.room | deadline_at_ms: next_expired_at},
          ai_pending: %{
            pid: task_pid,
            ref: ref,
            generation: generation,
            actor_id: next_actor,
            version: after_human_timeout.game_state.version
          }
      }
    end)

    send(
      pid,
      {:ai_result, generation, room.room_id, after_human_timeout.match_number,
       after_human_timeout.game_state.version, next_actor, :late_result}
    )

    wait_until(fn -> HostedGame.raw_room(room.room_id).command_seq == 2 end)
    after_ai_timeout = HostedGame.raw_room(room.room_id)
    assert List.last(after_ai_timeout.replay).data.source == "timeout"
    refute Enum.any?(after_ai_timeout.replay, &(&1.kind == "command" and &1.data.source == "ai"))

    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
  end

  test "runtime terminalization is projected separately from a host stop" do
    room =
      create_room(%{player_count: 5, visibility: "public_safe", turn_timeout_seconds: 30})

    tokens = claim_all(room, "Failure")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    pid = room_pid(room.room_id)
    persisted = HostedGame.raw_room(room.room_id)
    expired_at = System.system_time(:millisecond) - 1_000

    :sys.replace_state(pid, fn state ->
      game_state = %{
        state.room.game_state
        | world: Map.put(state.room.game_state.world, :active_actor_id, "missing-actor")
      }

      %{state | room: %{state.room | game_state: game_state, deadline_at_ms: expired_at}}
    end)

    send(
      pid,
      {:turn_timeout, persisted.match_number, persisted.game_state.version, "missing-actor",
       expired_at}
    )

    wait_until(fn -> HostedGame.raw_room(room.room_id).status == "stopped" end)
    assert HostedGame.raw_room(room.room_id).terminal_reason == "runtime_failure"

    assert {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)
    assert host.terminal_reason == "runtime_failure"

    assert {:ok, player} = HostedGame.player_view(room.room_id, tokens |> Map.values() |> hd())
    assert player["room"]["terminal_reason"] == "runtime_failure"

    assert {:ok, public} = HostedGame.public_view(room.room_id)
    assert public["room"]["terminal_reason"] == "runtime_failure"
  end

  test "hosted kill switch blocks operations and timer advancement" do
    room = create_room(%{player_count: 5, turn_timeout_seconds: 30})
    _tokens = claim_all(room, "Disabled")
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    persisted = HostedGame.raw_room(room.room_id)
    pid = room_pid(room.room_id)
    deadline = System.system_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      %{state | room: %{state.room | deadline_at_ms: deadline}}
    end)

    Application.put_env(:lemon_sim_ui, :hosted_rooms_enabled, false)

    send(
      pid,
      {:turn_timeout, persisted.match_number, persisted.game_state.version,
       persisted.game_state.world.active_actor_id, deadline}
    )

    Process.sleep(20)
    assert HostedGame.raw_room(room.room_id).command_seq == 0
    assert {:error, :hosted_rooms_disabled} = HostedGame.host_view(room.room_id, room.host_token)
    assert {:error, :hosted_rooms_disabled} = HostedGame.join_view(room.join_code)

    Application.put_env(:lemon_sim_ui, :hosted_rooms_enabled, true)
    assert :ok = HostedGame.control(room.room_id, room.host_token, "stop")
  end

  test "room failure telemetry is counted without raw error details" do
    before_count = LemonSimUi.Telemetry.snapshot().counters[:room_failed] || 0

    HostedGame.emit(:room_failed, %{count: 1}, %{
      room_id: "telemetry-room",
      error_class: "persistence_failed",
      reason: "secret provider response"
    })

    wait_until(fn ->
      (LemonSimUi.Telemetry.snapshot().counters[:room_failed] || 0) == before_count + 1
    end)

    snapshot = LemonSimUi.Telemetry.snapshot()
    assert hd(snapshot.recent).metadata.error_class == "persistence_failed"
    refute inspect(snapshot.recent) =~ "secret provider response"
  end

  defp create_room(attrs) do
    assert {:ok, room} = HostedGame.create_room(attrs)
    on_exit(fn -> cleanup_room(room.room_id, room.join_code) end)
    room
  end

  defp claim_all(room, prefix) do
    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)

    Map.new(host.seats, fn seat ->
      {:ok, claim} = HostedGame.claim_seat(room.join_code, seat.id, "#{prefix} #{seat.id}")
      {seat.id, claim.player_token}
    end)
  end

  defp cleanup_room(room_id, join_code) do
    case Registry.lookup(LemonSimUi.HostedGame.Registry, room_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(LemonSimUi.HostedGame.RoomSupervisor, pid)
      [] -> :ok
    end

    Store.delete(HostedGame.room_table(), room_id)
    Store.delete(HostedGame.join_table(), join_code)
  end

  defp room_pid(room_id) do
    [{pid, _}] = Registry.lookup(LemonSimUi.HostedGame.Registry, room_id)
    pid
  end

  defp valid_params(action) do
    action["parameters"]
    |> Map.get("properties", %{})
    |> Enum.reduce(%{}, fn {key, schema}, params ->
      cond do
        key == "thought" ->
          params

        values = Map.get(schema, "enum") ->
          Map.put(params, key, List.first(values))

        key in ["statement", "message", "reason"] ->
          Map.put(params, key, "A concise test response.")

        true ->
          params
      end
    end)
  end

  defp required_tool_params(schema) do
    properties = Map.get(schema, "properties", %{})

    schema
    |> Map.get("required", [])
    |> Map.new(fn key ->
      property = Map.fetch!(properties, key)

      value =
        case Map.get(property, "enum") do
          [first | _] -> first
          _ -> "A concise deterministic test response."
        end

      {key, value}
    end)
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp fake_model do
    %Model{
      id: "hosted-test-model",
      name: "Hosted Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_sim_ui, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_sim_ui, key, value)
end
