defmodule LemonSimUi.AdminSimControllerTest do
  use LemonSimUi.ConnCase

  alias LemonSim.{Store, State}

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
    assert body["admin_url"] =~ "/sims/#{sim_id}"
    assert body["watch_url"] == nil
    assert %State{} = Store.get_state(sim_id)
  end

  test "stop stops a running sim with bearer auth", %{conn: conn} do
    sim_id = "api_stop_test"
    runner = spawn(fn -> Process.sleep(5_000) end)
    original_manager_state = :sys.get_state(LemonSimUi.SimManager)

    on_exit(fn ->
      if Process.alive?(runner), do: Process.exit(runner, :kill)
      :sys.replace_state(LemonSimUi.SimManager, fn _ -> original_manager_state end)
    end)

    :sys.replace_state(LemonSimUi.SimManager, fn sim_manager_state ->
      put_in(sim_manager_state.runners[sim_id], %{ref: runner, domain: :tic_tac_toe})
    end)

    conn =
      conn
      |> put_req_header("authorization", "Bearer test-sim-ui-token")
      |> post("/api/admin/sims/#{sim_id}/stop")

    assert json_response(conn, 200) == %{"sim_id" => sim_id, "status" => "stopped"}
  end
end
