defmodule CodingAgent.Tools.Task.RunSlotsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{BackgroundRun, TaskStore}
  alias CodingAgent.Parallel.Semaphore
  alias CodingAgent.Tools.Task
  alias CodingAgent.Tools.Task.Result
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  test "a depth-2 child chain whose children join their descendants completes with one slot" do
    semaphore = start_supervised!({Semaphore, max: 1})

    leaf = fn _on_update, _signal, _lifecycle -> completed("leaf answer") end

    middle = fn _on_update, signal, lifecycle ->
      # The middle child blocks on its own child while holding the lineage slot.
      case launch(lifecycle.run_id, 1, semaphore, leaf, signal) do
        %AgentToolResult{} = result ->
          completed("middle saw " <> Result.visible_output_text(result))

        error ->
          error
      end
    end

    root = Elixir.Task.async(fn -> launch("slots-root-run", 0, semaphore, middle, nil) end)

    assert %AgentToolResult{} = result = Elixir.Task.await(root, 10_000)
    assert Result.visible_output_text(result) =~ "middle saw leaf answer"
    assert Semaphore.available(semaphore) == 1
  end

  test "eight idle background runs do not block a new task" do
    owner = self()

    runner = fn _opts, prompt, _signal, _timeout ->
      send(owner, {:background_started, prompt, self()})

      receive do
        :finish -> {:ok, prompt}
      end
    end

    background =
      for n <- 1..8 do
        assert {:ok, %{id: id}} = BackgroundRun.start("idle #{n}", runner: runner)
        assert_receive {:background_started, _prompt, pid}, 5_000
        {id, pid}
      end

    on_exit(fn -> for {_id, pid} <- background, do: send(pid, :finish) end)

    result =
      Task.execute(
        "slots-after-background",
        %{"description" => "After background", "prompt" => "Answer", "async" => false},
        nil,
        nil,
        "/tmp",
        run_override: fn _on_update, _signal -> completed("not blocked") end
      )

    assert Result.visible_output_text(result) =~ "not blocked"
  end

  test "a join with no explicit timeout yields at the configured default deadline" do
    previous = Application.get_env(:coding_agent, :task_join_timeout_ms)
    Application.put_env(:coding_agent, :task_join_timeout_ms, 100)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:coding_agent, :task_join_timeout_ms, previous),
        else: Application.delete_env(:coding_agent, :task_join_timeout_ms)
    end)

    test = self()

    receipt =
      Task.execute(
        "slots-join-deadline",
        %{"description" => "Never finishes", "prompt" => "Wait", "async" => true},
        nil,
        nil,
        "/tmp",
        run_override: fn _on_update, _signal ->
          send(test, {:started, self()})

          receive do
            :finish -> completed("late")
          end
        end
      )

    task_id = receipt.details.task_id
    assert_receive {:started, worker}, 5_000
    on_exit(fn -> send(worker, :finish) end)

    {elapsed_us, result} = :timer.tc(fn -> Result.do_join(%{"task_ids" => [task_id]}) end)

    assert %AgentToolResult{details: %{timed_out: true, status: "running"}} = result
    assert elapsed_us < 5_000_000
    assert {:ok, %{status: :running}} = TaskStore.get_record(task_id)
  end

  defp launch(parent_run_id, depth, semaphore, run_override, signal) do
    Task.execute(
      "slots-#{depth}-#{System.unique_integer([:positive])}",
      %{"description" => "Depth #{depth + 1}", "prompt" => "Work", "async" => false},
      signal,
      nil,
      "/tmp",
      parent_run_id: parent_run_id,
      task_depth: depth,
      task_semaphore: semaphore,
      run_override: run_override
    )
  end

  defp completed(text) do
    %AgentToolResult{content: [%TextContent{text: text}], details: %{status: "completed"}}
  end
end
