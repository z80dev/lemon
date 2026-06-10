defmodule LemonSimUi.LobbyLiveTest do
  use LemonSimUi.ConnCase

  import Phoenix.LiveViewTest

  @artifact_registry Path.join(System.tmp_dir!(), "lemon_vending_bench_artifact_registry.json")

  setup do
    original = Application.get_env(:lemon_sim_ui, :public_vending_launcher)

    on_exit(fn ->
      Application.put_env(:lemon_sim_ui, :public_vending_launcher, original)
    end)

    :ok
  end

  test "hides public VendingBench launcher by default", %{conn: conn} do
    Application.put_env(:lemon_sim_ui, :public_vending_launcher, false)

    {:ok, _view, html} = live(conn, "/")

    refute html =~ "Start a New Run"
    refute html =~ "GPT 5.5"
  end

  test "shows fixed public VendingBench launcher when enabled", %{conn: conn} do
    Application.put_env(:lemon_sim_ui, :public_vending_launcher, true)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Start a New Run"
    assert html =~ "GLM 5.1"
    assert html =~ "Z.AI credentials"
    assert html =~ "GPT 5.5"
    assert html =~ "Codex OAuth"
    assert html =~ ~s(href="/vending_bench/start/zai_glm_5_1")
    assert html =~ ~s(href="/vending_bench/start/codex_gpt_5_5")
  end

  test "lists running VendingBench sims from checkpoint artifacts", %{conn: conn} do
    sim_id = "test_lobby_vb_artifact_#{System.unique_integer([:positive])}"
    artifact_dir = Path.join(System.tmp_dir!(), sim_id)
    original_registry = File.read(@artifact_registry)

    on_exit(fn ->
      File.rm_rf!(artifact_dir)
      restore_registry(original_registry)
    end)

    File.rm_rf!(artifact_dir)
    File.mkdir_p!(artifact_dir)

    world =
      LemonSim.Examples.VendingBench.initial_state(sim_id: sim_id, max_days: 365).world
      |> Jason.encode!(pretty: true)

    File.write!(Path.join(artifact_dir, "final_world.json"), world)
    File.write!(Path.join(artifact_dir, "events.jsonl"), "")
    write_registry_entry(sim_id, artifact_dir)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ sim_id
    assert html =~ "Vending Bench"
    refute html =~ "No Games Currently Live"
  end

  test "lists completed VendingBench arena artifacts as replays", %{conn: conn} do
    sim_id = "test_lobby_vb_arena_artifact_#{System.unique_integer([:positive])}"
    artifact_dir = Path.join(System.tmp_dir!(), sim_id)
    original_registry = File.read(@artifact_registry)

    on_exit(fn ->
      File.rm_rf!(artifact_dir)
      restore_registry(original_registry)
    end)

    File.rm_rf!(artifact_dir)
    File.mkdir_p!(artifact_dir)

    {:ok, arena} =
      LemonSim.Examples.VendingBench.Arena.run_offline_strategy("baseline",
        sim_id: sim_id,
        max_days: 3,
        artifact_dir: artifact_dir,
        arena_agents: 2
      )

    world = Jason.encode!(arena.world, pretty: true)

    File.write!(Path.join(artifact_dir, "final_world.json"), world)
    write_registry_entry(sim_id, artifact_dir)

    {:ok, _view, html} = live(conn, "/")

    assert html =~ sim_id
    assert html =~ "Vending Bench"
    assert html =~ "REPLAY"
    refute html =~ "No Games Currently Live"
  end

  defp write_registry_entry(sim_id, artifact_dir) do
    registry =
      case File.read(@artifact_registry) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    File.write!(@artifact_registry, Jason.encode!(Map.put(registry, sim_id, artifact_dir)))
  end

  defp restore_registry({:ok, body}), do: File.write!(@artifact_registry, body)
  defp restore_registry({:error, _reason}), do: File.rm(@artifact_registry)
end
