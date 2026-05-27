defmodule LemonSimUi.LobbyLiveTest do
  use LemonSimUi.ConnCase

  import Phoenix.LiveViewTest

  @artifact_registry Path.join(System.tmp_dir!(), "lemon_vending_bench_artifact_registry.json")

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
