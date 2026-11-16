defmodule CodingAgent.Tools.TaskTelemetryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SettingsManager
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Telemetry
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult

  setup do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:coding_agent, :task, :action], &__MODULE__.record/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  def record(_event, measurements, metadata, owner),
    do: send(owner, {:task_action, measurements, metadata})

  test "every dispatch action emits once even when validation refuses it" do
    for action <- ~w(run swarm poll join wait get message steer cancel) do
      assert {:error, _} = execute(%{"action" => action})

      assert_receive {:task_action, %{count: 1},
                      %{action: ^action, kind: :dispatch, outcome: :error}}

      refute_received {:task_action, _, _}
    end
  end

  test "unknown actions are bounded and prompt content never enters metadata" do
    secret = "private prompt, path, exception, and credential"

    assert {:error, _} =
             execute(%{"action" => secret, "prompt" => secret, "meta" => %{secret => secret}})

    assert_receive {:task_action, %{count: 1}, metadata}

    assert metadata == %{
             action: "unknown",
             kind: :dispatch,
             outcome: :error,
             model: "test-provider/test-model",
             depth: 1,
             run_id: "telemetry-run"
           }
  end

  test "batch and steps count feature use once per dispatch, including nested steps" do
    assert {:error, _} = execute(%{"tasks" => [%{"steps" => []}, %{"steps" => []}]})
    assert_receive {:task_action, _, %{action: "run", kind: :dispatch, outcome: :error}}
    assert_receive {:task_action, _, %{action: "batch", kind: :feature, outcome: :error}}
    assert_receive {:task_action, _, %{action: "steps", kind: :feature, outcome: :error}}
    refute_received {:task_action, _, _}

    assert {:error, _} = execute(%{"action" => "swarm", "tasks" => [%{"steps" => []}]})
    assert_receive {:task_action, _, %{action: "swarm", kind: :dispatch}}
    assert_receive {:task_action, _, %{action: "steps", kind: :feature}}
    refute_received {:task_action, _, _}
  end

  test "successful run and steps preserve the result and report the calling model" do
    owner = self()

    for params <- [%{"prompt" => "work"}, %{"steps" => ["first", "second"]}] do
      result = %AgentToolResult{details: %{status: "completed"}}

      assert ^result =
               execute(Map.put(params, "async", false),
                 run_override: fn _, _, context ->
                   send(owner, {:completed_task, self(), context})
                   result
                 end
               )

      assert_receive {:completed_task, worker, context}

      on_exit(fn ->
        monitor = Process.monitor(worker)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 2_000
        CodingAgent.TaskStore.delete_task(context.task_id)
        CodingAgent.RunGraph.delete_run(context.run_id)
      end)

      assert_receive {:task_action, _,
                      %{action: "run", outcome: :ok, model: "test-provider/test-model"}}

      if Map.has_key?(params, "steps"),
        do: assert_receive({:task_action, _, %{action: "steps", outcome: :ok}})
    end
  end

  test "aborted dispatch still counts and does not launch" do
    signal = AbortSignal.new()
    AbortSignal.abort(signal)
    assert {:error, "Operation aborted"} = execute(%{"prompt" => "private"}, [], signal)
    assert_receive {:task_action, _, %{action: "run", outcome: :aborted}}
  end

  test "exceptions and throws are counted without exposing reasons or changing propagation" do
    for {kind, fun} <- [{:error, fn -> raise "private" end}, {:throw, fn -> throw(:private) end}] do
      try do
        Telemetry.observe(%{}, [session_scope: :subagent], nil, fun)
        flunk("expected propagation")
      catch
        ^kind, _ -> :ok
      end

      assert_receive {:task_action, %{count: 1}, metadata}

      assert metadata == %{
               action: "run",
               kind: :dispatch,
               outcome: :exception,
               model: nil,
               depth: nil,
               run_id: nil
             }
    end
  end

  test "error results and exception-free returned errors are not counted as successes" do
    for result <- [%AgentToolResult{is_error: true}, {:error, :private}] do
      assert ^result = Telemetry.observe(%{}, [], nil, fn -> result end)
      assert_receive {:task_action, _, %{action: "run", outcome: :error, depth: 0}}
    end
  end

  defp execute(params, extra \\ [], signal \\ nil) do
    opts = [
      parent_session: "task-telemetry-#{System.unique_integer([:positive])}",
      run_id: "telemetry-run",
      task_depth: 1,
      model: %{provider: :"test-provider", id: "test-model"},
      settings_manager: %SettingsManager{}
    ]

    TaskTool.execute("telemetry-call", params, signal, nil, "/tmp", Keyword.merge(opts, extra))
  end
end
