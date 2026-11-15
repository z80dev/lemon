defmodule LemonEvals.TaskActionsTest do
  use ExUnit.Case, async: false

  alias LemonEvals.TaskActions

  @event [:coding_agent, :task, :action]

  @tag :tmp_dir
  test "recorder exports only allowlisted telemetry and report counts each action per run", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "actions.jsonl")
    recorder = start_supervised!({TaskActions, path})

    for {run, action, kind, outcome, model, depth} <- [
          {"eval-1", "run", :dispatch, :ok, "provider/model", 0},
          {"eval-1", "run", :dispatch, :error, "provider/model", 0},
          {"eval-1", "batch", :feature, :ok, "provider/model", 0},
          {"arena-1", "swarm", :dispatch, :ok, "provider/other", 1},
          {"arena-1", "steps", :feature, :ok, "provider/other", 1},
          {"arena-1", "speculative_launch", :launch, :ok, "provider/other", 1}
        ] do
      :telemetry.execute(@event, %{count: 1, prompt: "private"}, %{
        run_id: run,
        action: action,
        kind: kind,
        outcome: outcome,
        model: model,
        depth: depth,
        prompt: "private",
        error: "private"
      })
    end

    :ok = TaskActions.flush(recorder)
    refute File.read!(path) =~ "private"
    assert {:ok, %{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    report = TaskActions.report(path)
    assert report.total_dispatches == 3
    assert report.event_count == 6
    assert Enum.find(report.per_action, &(&1.action == "run")).count == 2
    assert Enum.find(report.per_action, &(&1.action == "speculative_launch")).count == 1
    assert Enum.find(report.per_run, &(&1.run_id == "eval-1")).event_count == 3
    assert Enum.find(report.per_run, &(&1.run_id == "arena-1")).event_count == 3

    assert Enum.any?(
             report.breakdown,
             &(&1.action == "run" and &1.outcome == "error" and &1.count == 1)
           )

    :ok = stop_supervised(TaskActions)
    assert :telemetry.list_handlers(@event) |> Enum.all?(&(&1.id != {TaskActions, recorder}))
  end

  @tag :tmp_dir
  test "empty data and unattributed events do not manufacture observed runs", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.jsonl")
    File.write!(path, "")

    assert %{event_count: 0, total_dispatches: 0, per_run: [], breakdown: []} =
             TaskActions.report(path)

    row = %{
      event: @event,
      measurements: %{count: 1},
      metadata: %{
        action: "wait",
        kind: :dispatch,
        outcome: :aborted,
        model: nil,
        depth: nil,
        run_id: nil
      }
    }

    File.write!(path, Jason.encode!(row) <> "\n" <> Jason.encode!(%{event: ["other"]}) <> "\n")
    assert %{event_count: 1, per_run: [%{run_id: nil}]} = TaskActions.report(path)
  end

  @tag :tmp_dir
  test "malformed task telemetry fails instead of silently undercounting", %{tmp_dir: dir} do
    path = Path.join(dir, "bad.jsonl")

    for input <- [
          "not json\n",
          Jason.encode!(%{event: @event, measurements: %{count: -1}, metadata: %{}}),
          Jason.encode!(%{event: @event, measurements: %{count: 1}, metadata: %{}})
        ] do
      File.write!(path, input)

      assert_raise ArgumentError, ~r/Invalid task action telemetry at line 1/, fn ->
        TaskActions.report(path)
      end
    end
  end

  @tag :tmp_dir
  test "recorder stops on a file write error", %{tmp_dir: dir} do
    {:ok, file} = File.open(Path.join(dir, "closed.jsonl"), [:write, :binary])
    :ok = File.close(file)
    state = %{file: file}

    assert {:stop, {:write_failed, _reason}, ^state} =
             TaskActions.handle_cast({:record, %{event: @event}}, state)
  end

  @tag :tmp_dir
  test "recorder refuses to overwrite an existing artifact", %{tmp_dir: dir} do
    path = Path.join(dir, "existing.jsonl")
    File.write!(path, "retained evidence")
    owner = self()

    {starter, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        result = TaskActions.start_link(path)
        send(owner, {:recorder_start, self(), result})
      end)

    assert_receive {:recorder_start, ^starter, {:error, {:open_failed, :eexist}}}
    assert_receive {:DOWN, ^monitor, :process, ^starter, :normal}
    assert File.read!(path) == "retained evidence"
  end
end
