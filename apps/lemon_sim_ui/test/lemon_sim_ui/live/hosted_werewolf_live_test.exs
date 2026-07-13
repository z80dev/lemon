defmodule LemonSimUi.HostedWerewolfLiveTest do
  use LemonSimUi.ConnCase

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonSimUi.HostedGame

  setup do
    previous_enabled = Application.get_env(:lemon_sim_ui, :hosted_rooms_enabled)
    previous_token = Application.get_env(:lemon_sim_ui, :hosted_room_create_token)
    Application.put_env(:lemon_sim_ui, :hosted_rooms_enabled, true)
    Application.delete_env(:lemon_sim_ui, :hosted_room_create_token)

    on_exit(fn ->
      restore_env(:hosted_rooms_enabled, previous_enabled)
      restore_env(:hosted_room_create_token, previous_token)
    end)

    :ok
  end

  test "landing, create, join, host, player, and role-safe broadcast work as distinct sessions",
       %{
         conn: conn
       } do
    {:ok, _landing, landing_html} = live(conn, "/play")
    assert landing_html =~ "Host a night of"
    assert landing_html =~ "Enter a room code"

    create_conn =
      post(conn, "/rooms", %{
        "player_count" => "5",
        "ai_seats" => "0",
        "turn_timeout_seconds" => "30",
        "visibility" => "public_safe",
        "rules_preset" => "story"
      })

    host_path = redirected_to(create_conn, 302)
    [_, room_id, "host"] = String.split(host_path, "/", trim: true)
    room = HostedGame.raw_room(room_id)
    host_token = get_session(create_conn, HostedGame.host_session_key(room_id))
    on_exit(fn -> cleanup_room(room_id, room.join_code) end)

    host_conn = recycle(create_conn)
    {:ok, host_live, host_html} = live(host_conn, host_path)
    assert host_html =~ "Host console"
    assert host_html =~ room.join_code
    assert host_html =~ "Waiting"
    refute host_html =~ "Wolf discussion"
    refute host_html =~ "werewolf_partners"
    refute host_html =~ "seer_history"

    {:ok, _join_live, join_html} = live(build_conn(), "/join/#{room.join_code}")
    assert join_html =~ "Choose your name in the story"
    assert join_html =~ ~s(for="player-display-name-)
    assert join_html =~ "Display name"

    seat_id = room.seats |> Map.keys() |> Enum.sort() |> List.first()

    join_conn =
      post(build_conn(), "/rooms/join", %{
        "join_code" => room.join_code,
        "seat_id" => seat_id,
        "display_name" => "Mara"
      })

    player_path = redirected_to(join_conn, 302)
    player_token = get_session(join_conn, HostedGame.player_session_key(room_id))
    assert player_path == "/rooms/#{room_id}/play"

    {:ok, player_live, player_html} = live(recycle(join_conn), player_path)
    assert player_html =~ "Your private seat"
    assert player_html =~ "Mara"
    assert player_html =~ "Your role"
    assert player_html =~ "Waiting for the host to begin"
    refute player_html =~ "Wolf discussion"

    {:ok, _watch_live, watch_html} = live(build_conn(), "/rooms/#{room_id}/watch")
    assert watch_html =~ "Role-safe live story"
    assert watch_html =~ "Waiting for the village"
    refute watch_html =~ "Day 1"
    refute watch_html =~ "Your role"
    refute watch_html =~ "werewolf_partners"
    refute watch_html =~ "wolf_chat_transcript"

    {:ok, host_watch_live, _html} =
      live(recycle(create_conn), "/rooms/#{room_id}/watch")

    refute formatted_live_view_state(host_live) =~ host_token
    refute formatted_live_view_state(player_live) =~ player_token
    refute formatted_live_view_state(host_watch_live) =~ host_token
  end

  test "host invite is checked before room creation", %{conn: conn} do
    Application.put_env(:lemon_sim_ui, :hosted_room_create_token, String.duplicate("x", 32))

    parent = self()

    log =
      capture_log(fn ->
        denied =
          post(conn, "/rooms", %{
            "player_count" => "5",
            "ai_seats" => "0",
            "turn_timeout_seconds" => "30",
            "visibility" => "private",
            "rules_preset" => "story",
            "create_token" => "CREATE_TOKEN_SECRET_SENTINEL"
          })

        send(parent, {:denied_create, denied})
      end)

    assert_receive {:denied_create, denied}
    assert log =~ ~s("create_token" => "[FILTERED]")
    refute log =~ "CREATE_TOKEN_SECRET_SENTINEL"

    assert redirected_to(denied, 302) == "/play"
    assert Phoenix.Flash.get(denied.assigns.flash, :error) =~ "not valid"

    visible_error = denied |> recycle() |> get("/play") |> html_response(200)
    assert visible_error =~ "That host invite is not valid."
  end

  test "LiveView lifecycle logging cannot expose sessions or private commands" do
    socket = %Phoenix.LiveView.Socket{
      view: LemonSimUi.HostedPlayerLive,
      transport_pid: self()
    }

    log =
      capture_log(fn ->
        Phoenix.LiveView.Logger.lv_mount_start(
          [:phoenix, :live_view, :mount, :start],
          %{system_time: System.system_time()},
          %{
            socket: socket,
            params: %{},
            session: %{"hosted_werewolf_player:room" => "PLAYER_TOKEN_SECRET_SENTINEL"},
            uri: "http://example.test/rooms/room/play"
          },
          %{}
        )

        Phoenix.LiveView.Logger.lv_handle_event_start(
          [:phoenix, :live_view, :handle_event, :start],
          %{system_time: System.system_time()},
          %{
            socket: socket,
            event: "command",
            params: %{"params" => %{"message" => "PRIVATE_COMMAND_SECRET_SENTINEL"}}
          },
          %{}
        )
      end)

    assert LemonSimUi.HostedPlayerLive.__live__().log == false
    assert LemonSimUi.LobbyLive.__live__().log == false
    refute log =~ "PLAYER_TOKEN_SECRET_SENTINEL"
    refute log =~ "PRIVATE_COMMAND_SECRET_SENTINEL"
  end

  test "malformed hosted forms fail closed without crashing", %{conn: conn} do
    create = post(conn, "/rooms", %{"room" => "not-a-map"})
    assert redirected_to(create, 302) == "/play"

    join =
      conn
      |> recycle()
      |> post("/rooms/join", %{"player" => %{"join_code" => ["bad"]}})

    assert redirected_to(join, 302) == "/play"
  end

  test "an authenticated player submits a legal action and reconnects to the new version", %{
    conn: conn
  } do
    assert {:ok, room} =
             HostedGame.create_room(%{
               player_count: 5,
               ai_seats: 0,
               turn_timeout_seconds: 30,
               visibility: "public_safe"
             })

    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)

    tokens =
      Map.new(host.seats, fn seat ->
        {:ok, claim} = HostedGame.claim_seat(room.join_code, seat.id, "Player #{seat.id}")
        {seat.id, claim.player_token}
      end)

    on_exit(fn -> cleanup_room(room.room_id, room.join_code) end)
    assert :ok = HostedGame.control(room.room_id, room.host_token, "start")

    persisted = HostedGame.raw_room(room.room_id)
    actor_id = persisted.game_state.world.active_actor_id
    token = Map.fetch!(tokens, actor_id)
    {:ok, projection} = HostedGame.player_view(room.room_id, token)
    [action | _] = projection["legal_actions"]

    player_conn =
      init_test_session(conn, %{HostedGame.player_session_key(room.room_id) => token})

    {:ok, view, html} = live(player_conn, "/rooms/#{room.room_id}/play")
    assert html =~ "Your move"
    assert html =~ action["label"]

    render_submit(view, "command", %{
      "action" => action["name"],
      "command_id" => "live-command-1",
      "expected_match_number" => Integer.to_string(projection["room"]["match_number"]),
      "expected_version" => Integer.to_string(projection["version"]),
      "params" => valid_params(action)
    })

    assert HostedGame.raw_room(room.room_id).game_state.version > projection["version"]

    reconnect_conn =
      build_conn()
      |> init_test_session(%{HostedGame.player_session_key(room.room_id) => token})

    {:ok, _reconnected, reconnected_html} = live(reconnect_conn, "/rooms/#{room.room_id}/play")
    assert reconnected_html =~ actor_id
    assert reconnected_html =~ "Your private seat"
  end

  test "a cancelled lobby stays closed and role-sealed on every surface" do
    assert {:ok, room} =
             HostedGame.create_room(%{
               player_count: 5,
               ai_seats: 0,
               turn_timeout_seconds: 30,
               visibility: "public_safe"
             })

    {:ok, host} = HostedGame.host_view(room.room_id, room.host_token)
    seat = List.first(host.seats)
    {:ok, claim} = HostedGame.claim_seat(room.join_code, seat.id, "Cancelled player")
    on_exit(fn -> cleanup_room(room.room_id, room.join_code) end)

    assert :ok = HostedGame.control(room.room_id, room.host_token, "cancel")

    host_conn =
      build_conn()
      |> init_test_session(%{HostedGame.host_session_key(room.room_id) => room.host_token})

    player_conn =
      build_conn()
      |> init_test_session(%{
        HostedGame.player_session_key(room.room_id) => claim.player_token
      })

    {:ok, _host_live, host_html} = live(host_conn, "/rooms/#{room.room_id}/host")
    assert host_html =~ "The host cancelled this room"
    assert host_html =~ "Waiting"
    refute host_html =~ "Wolf discussion"

    {:ok, _player_live, player_html} = live(player_conn, "/rooms/#{room.room_id}/play")
    assert player_html =~ "sealed"
    assert player_html =~ "The host cancelled this room"
    refute player_html =~ "Wolf discussion"

    {:ok, _watch_live, watch_html} = live(build_conn(), "/rooms/#{room.room_id}/watch")
    assert watch_html =~ "Waiting for the village"
    assert watch_html =~ "The host cancelled this room"
    refute watch_html =~ "Day 1"

    {:ok, _join_live, join_html} = live(build_conn(), "/join/#{room.join_code}")
    assert join_html =~ "This room is closed"
    refute join_html =~ "Claim #{seat.id}"
  end

  defp cleanup_room(room_id, join_code) do
    case Registry.lookup(LemonSimUi.HostedGame.Registry, room_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(LemonSimUi.HostedGame.RoomSupervisor, pid)
      [] -> :ok
    end

    Store.delete(HostedGame.room_table(), room_id)
    Store.delete(HostedGame.join_table(), join_code)
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_sim_ui, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_sim_ui, key, value)

  defp formatted_live_view_state(view) do
    state = :sys.get_state(view.pid)
    Phoenix.LiveView.Channel.format_status(:terminate, [[], state]) |> inspect()
  end

  defp valid_params(action) do
    action["parameters"]
    |> Map.get("properties", %{})
    |> Enum.reduce(%{}, fn {key, schema}, params ->
      cond do
        key == "thought" -> params
        values = Map.get(schema, "enum") -> Map.put(params, key, List.first(values))
        key in ["statement", "message", "reason"] -> Map.put(params, key, "A clear response.")
        true -> params
      end
    end)
  end
end
