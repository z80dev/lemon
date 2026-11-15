defmodule Mix.Tasks.Lemon.Eval.TaskActionsTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lemon.Eval.TaskActions

  @tag :tmp_dir
  test "command writes offline counts without booting applications", %{tmp_dir: dir} do
    input = Path.join(dir, "actions.jsonl")
    output = Path.join(dir, "report.json")
    File.write!(input, "")
    running = Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    TaskActions.run(["--input", input, "--output", output])

    assert %{"schema_version" => 1, "event_count" => 0, "total_dispatches" => 0} =
             output |> File.read!() |> Jason.decode!()

    assert running == Application.started_applications() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  test "command requires an explicit telemetry input" do
    assert_raise Mix.Error, ~r/Usage:/, fn -> TaskActions.run([]) end
  end
end
