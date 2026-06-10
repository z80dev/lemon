defmodule LemonSimUi.VendingBenchLaunchControllerTest do
  use LemonSimUi.ConnCase

  setup do
    original = Application.get_env(:lemon_sim_ui, :public_vending_launcher)
    Application.put_env(:lemon_sim_ui, :public_vending_launcher, false)

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :public_vending_launcher, original)
    end)

    :ok
  end

  test "redirects to the lobby when public launching is disabled", %{conn: conn} do
    conn = post(conn, "/vending_bench/start", %{"model_preset" => "zai_glm_5_1"})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "public_vending_launcher_disabled"
  end

  test "GET preset route redirects to the lobby when public launching is disabled", %{conn: conn} do
    conn = get(conn, "/vending_bench/start/zai_glm_5_1")

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "public_vending_launcher_disabled"
  end
end
