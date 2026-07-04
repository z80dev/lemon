defmodule LemonSimUi.VendingBenchLaunchControllerTest do
  use LemonSimUi.ConnCase

  setup do
    original = Application.get_env(:lemon_sim_ui, :public_vending_launcher)
    original_presets = Application.get_env(:lemon_sim_ui, :vending_launcher_presets, :__unset__)
    original_zai_key = System.get_env("llm_zai_api_key")

    Application.put_env(:lemon_sim_ui, :public_vending_launcher, false)
    Application.delete_env(:lemon_sim_ui, :vending_launcher_presets)

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :public_vending_launcher, original)
      restore_presets(original_presets)
      restore_env("llm_zai_api_key", original_zai_key)
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

  test "launches a configured public preset", %{conn: conn} do
    System.put_env("llm_zai_api_key", "test-zai-key")

    Application.put_env(:lemon_sim_ui, :public_vending_launcher, true)

    Application.put_env(:lemon_sim_ui, :vending_launcher_presets, [
      %{
        id: "short_glm",
        label: "Short GLM",
        model: "zai:glm-5.1",
        worker_model: "zai:glm-5.1",
        max_days: 2,
        max_turns: 1
      }
    ])

    conn = post(conn, "/vending_bench/start", %{"model_preset" => "short_glm"})

    assert redirected = redirected_to(conn)
    assert redirected =~ ~r|^/watch/vb_short_glm_\d{8}_\d{6}$|

    sim_id = String.replace_prefix(redirected, "/watch/", "")
    state = LemonSim.Kernel.Store.get_state(sim_id)

    assert LemonCore.MapHelpers.get_key(state.world, :max_days) == 2

    LemonSimUi.SimManager.stop_sim(sim_id)
    LemonSim.Kernel.Store.delete_state(sim_id)
  end

  defp restore_presets(:__unset__),
    do: Application.delete_env(:lemon_sim_ui, :vending_launcher_presets)

  defp restore_presets(value),
    do: Application.put_env(:lemon_sim_ui, :vending_launcher_presets, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
