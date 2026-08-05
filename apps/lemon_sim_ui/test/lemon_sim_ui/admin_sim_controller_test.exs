defmodule LemonSimUi.AdminSimControllerTest do
  use LemonSimUi.ConnCase

  alias LemonSim.Kernel.{Store, State}

  setup do
    original = Application.get_env(:lemon_sim_ui, :access_token)
    Application.put_env(:lemon_sim_ui, :access_token, "test-sim-ui-token")

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :access_token, original)
    end)

    :ok
  end

  test "create requires authentication", %{conn: conn} do
    conn = post(conn, "/api/admin/sims", %{"domain" => "tic_tac_toe"})
    assert response(conn, 401) == "Unauthorized"
  end

  test "admin API accepts bearer credentials only", %{conn: conn} do
    login = get(conn, "/admin?token=test-sim-ui-token")
    assert redirected_to(login, 303) == "/admin/login"

    session_conn = login |> recycle() |> post("/api/admin/sims", %{"domain" => "werewolf"})
    assert response(session_conn, 401) == "Unauthorized"

    query_conn = post(conn, "/api/admin/sims?token=test-sim-ui-token", %{"domain" => "werewolf"})
    assert response(query_conn, 401) == "Unauthorized"
  end

  test "werewolf create rejects invalid counts, ids, and model lineups", %{conn: conn} do
    invalid_payloads = [
      {%{"domain" => "werewolf", "player_count" => 4}, "invalid_player_count"},
      {%{"domain" => "werewolf", "player_count" => "many"}, "invalid_player_count"},
      {%{"domain" => "werewolf", "sim_id" => "not/a/valid/id"}, "invalid_sim_id"},
      {%{"domain" => "werewolf", "model_specs" => ["missing-provider-separator"]},
       "invalid_model_specs"},
      {%{
         "domain" => "werewolf",
         "player_count" => 5,
         "model_specs" => ["anthropic:model"]
       }, "invalid_model_count"}
    ]

    for {payload, expected_error} <- invalid_payloads do
      response =
        conn
        |> recycle()
        |> put_req_header("authorization", "Bearer test-sim-ui-token")
        |> post("/api/admin/sims", payload)
        |> json_response(422)

      assert response["error"] == expected_error
    end
  end

  test "create starts a sim with bearer auth", %{conn: conn} do
    sim_id = "api_ttt_test"

    on_exit(fn ->
      _ = LemonSimUi.SimManager.stop_sim(sim_id)
      Store.delete_state(sim_id)
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims", %{
        "domain" => "tic_tac_toe",
        "sim_id" => sim_id,
        "max_turns" => 1
      })

    body = json_response(conn, 201)

    assert body["sim_id"] == sim_id
    assert body["domain"] == "tic_tac_toe"
    assert body["admin_url"] =~ "/admin/sims/#{sim_id}"
    assert body["watch_url"] == nil
    assert %State{} = Store.get_state(sim_id)
  end

  test "create refuses to overwrite an existing persisted simulation", %{conn: conn} do
    sim_id = "ww_existing_test"

    on_exit(fn -> Store.delete_state(sim_id) end)
    assert :ok = Store.put_state(State.new(sim_id: sim_id, world: %{status: "game_over"}))

    response =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims", %{"domain" => "werewolf", "sim_id" => sim_id})
      |> json_response(409)

    assert response == %{"error" => "already_exists"}
  end

  test "create returns 429 when runner capacity is exhausted", %{conn: conn} do
    original_manager_state = :sys.get_state(LemonSimUi.SimManager)

    on_exit(fn ->
      :sys.replace_state(LemonSimUi.SimManager, fn _ -> original_manager_state end)
    end)

    :sys.replace_state(LemonSimUi.SimManager, fn state ->
      %{state | max_concurrent_runners: map_size(state.runners)}
    end)

    response =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims", %{"domain" => "tic_tac_toe", "sim_id" => "capacity_test"})
      |> json_response(429)

    assert response == %{"error" => "capacity_exceeded"}
  end

  test "create starts a TCG Shop sim with public watch URL", %{conn: conn} do
    sim_id = "api_tcg_shop_test"

    on_exit(fn ->
      _ = LemonSimUi.SimManager.stop_sim(sim_id)
      Store.delete_state(sim_id)
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims", %{
        "domain" => "tcg_shop",
        "sim_id" => sim_id,
        "max_days" => 2,
        "max_turns" => 0
      })

    body = json_response(conn, 201)

    assert body["sim_id"] == sim_id
    assert body["domain"] == "tcg_shop"
    assert body["watch_url"] =~ "/watch/#{sim_id}"
    assert %State{} = Store.get_state(sim_id)
  end

  test "create returns public watch URL for VendingBench", %{conn: conn} do
    sim_id = "api_vending_bench_test"

    on_exit(fn ->
      _ = LemonSimUi.SimManager.stop_sim(sim_id)
      Store.delete_state(sim_id)
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims", %{
        "domain" => "vending_bench",
        "sim_id" => sim_id,
        "max_days" => 2,
        "max_turns" => 0
      })

    body = json_response(conn, 201)

    assert body["sim_id"] == sim_id
    assert body["domain"] == "vending_bench"
    assert body["watch_url"] =~ "/watch/#{sim_id}"
    assert %State{} = Store.get_state(sim_id)
  end

  test "stop stops a running sim with bearer auth", %{conn: conn} do
    sim_id = "api_stop_test"
    runner = spawn(fn -> Process.sleep(5_000) end)
    original_manager_state = :sys.get_state(LemonSimUi.SimManager)
    :ok = Store.put_state(State.new(sim_id: sim_id, world: %{status: "in_progress"}))

    on_exit(fn ->
      if Process.alive?(runner), do: Process.exit(runner, :kill)
      :sys.replace_state(LemonSimUi.SimManager, fn _ -> original_manager_state end)
      Store.delete_state(sim_id)
    end)

    :sys.replace_state(LemonSimUi.SimManager, fn sim_manager_state ->
      put_in(sim_manager_state.runners[sim_id], %{ref: runner, domain: :tic_tac_toe})
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims/#{sim_id}/stop")

    assert json_response(conn, 200) == %{"sim_id" => sim_id, "status" => "stopped"}
    assert Store.get_state(sim_id).meta.run.status == "stopped"
    refute Store.get_state(sim_id).meta.run.resumable
  end
end
