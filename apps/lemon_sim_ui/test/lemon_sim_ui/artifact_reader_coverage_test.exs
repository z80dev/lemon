defmodule LemonSimUi.ArtifactReaderCoverageTest do
  # Mutates the global :suite_roots app env, so cannot run async.
  use ExUnit.Case, async: false

  alias LemonSimUi.ArtifactReader

  setup do
    original_roots = Application.get_env(:lemon_sim_ui, :suite_roots)

    on_exit(fn ->
      if is_nil(original_roots) do
        Application.delete_env(:lemon_sim_ui, :suite_roots)
      else
        Application.put_env(:lemon_sim_ui, :suite_roots, original_roots)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "lists direct and nested suites without leaking filesystem paths", %{tmp_dir: tmp_dir} do
    direct = Path.join(tmp_dir, "suite.json")
    nested_dir = Path.join(tmp_dir, "nested")
    File.mkdir_p!(nested_dir)
    nested = Path.join(nested_dir, "suite.json")
    malformed = Path.join(tmp_dir, "bad")
    File.mkdir_p!(malformed)
    File.write!(Path.join(malformed, "suite.json"), "{")

    File.write!(direct, Jason.encode!(suite("2026-01-01T00:00:00Z", "baseline", ["model-a"])))
    File.write!(nested, Jason.encode!(suite("2026-01-02T00:00:00Z", "pressure", ["model-b"])))

    Application.put_env(:lemon_sim_ui, :suite_roots, [tmp_dir, 123])

    suites = ArtifactReader.list_suites()

    assert Enum.map(suites, & &1.preset) == ["pressure", "baseline"]
    assert Enum.map(suites, & &1.competitors) == [["model-b"], ["model-a"]]
    assert Enum.all?(suites, &(byte_size(&1.id) == 12))
    assert Enum.map(suites, & &1.dir_label) == ["nested", Path.basename(tmp_dir)]
  end

  @tag :tmp_dir
  test "reads usage artifacts and tolerates missing or malformed files", %{tmp_dir: tmp_dir} do
    usage = %{
      "schema" => "lemon_sim.usage.v1",
      "input_tokens" => 1_000,
      "output_tokens" => 250,
      "cache_read_tokens" => 10,
      "cache_write_tokens" => 5,
      "total_cost_usd" => 0.125,
      "actors" => %{"operator" => %{"input_tokens" => 100}}
    }

    File.write!(Path.join(tmp_dir, "usage.json"), Jason.encode!(usage))

    assert ArtifactReader.read_usage(tmp_dir)["actors"] == usage["actors"]
    assert ArtifactReader.total_tokens(usage) == 1_265
    assert ArtifactReader.format_cost(usage["total_cost_usd"]) == "$0.13"
    assert ArtifactReader.format_integer(123_456.4) == "123,456"
    assert ArtifactReader.format_number(12.3) == "12.3"

    missing_dir = Path.join(tmp_dir, "missing")
    File.mkdir_p!(missing_dir)
    assert ArtifactReader.read_usage(missing_dir) == nil

    File.write!(Path.join(tmp_dir, "usage.json"), Jason.encode!(%{"schema" => "wrong"}))
    assert ArtifactReader.read_usage(tmp_dir) == nil
  end

  defp suite(created_at, preset, competitors) do
    %{
      "schema_version" => "lemon_sim.suite.v1",
      "metadata" => %{"created_at" => created_at},
      "spec" => %{
        "scenario" => "vending",
        "preset" => preset,
        "competitors" => Enum.map(competitors, &%{"model" => &1})
      }
    }
  end
end
