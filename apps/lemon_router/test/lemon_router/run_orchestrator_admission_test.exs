defmodule LemonRouter.RunOrchestratorAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonCore.{RunRequest, Store}
  alias LemonRouter.{RunOrchestrator, Submission}

  # Stands in for the orchestrator process: replies after a delay, echoes the
  # request's run ID, or dies while handling the call.
  defmodule FakeOrchestrator do
    use GenServer

    def init(mode), do: {:ok, mode}

    def handle_call(_message, _from, :crash), do: exit(:lost_reply)

    def handle_call(message, _from, {:delay, delay_ms}) do
      Process.sleep(delay_ms)
      {:reply, {:ok, elem(message, 1).run_id}, {:delay, delay_ms}}
    end
  end

  defp request(attrs) do
    RunRequest.new(
      Map.merge(
        %{
          origin: :control_plane,
          session_key: "agent:default:main:sub:admission-#{System.unique_integer([:positive])}",
          agent_id: "default",
          prompt: "admission"
        },
        attrs
      )
    )
  end

  describe "client-side admission calls (#645)" do
    test "the caller fixes the run ID before the orchestrator is called" do
      {:ok, server} = GenServer.start(FakeOrchestrator, {:delay, 0})
      on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

      assert {:ok, run_id} = RunOrchestrator.submit(server, request(%{}))
      assert is_binary(run_id) and run_id != ""

      assert {:ok, "run_fixed_by_caller"} =
               RunOrchestrator.submit(server, request(%{run_id: "run_fixed_by_caller"}))
    end

    test "a call that dies after reaching the orchestrator is outcome_unknown for that request" do
      {:ok, server} = GenServer.start(FakeOrchestrator, :crash)

      assert RunOrchestrator.submit(server, request(%{run_id: "run_lost_reply"})) ==
               {:error, :outcome_unknown}
    end

    test "a missing orchestrator is a definite rejection" do
      {:ok, server} = GenServer.start(FakeOrchestrator, {:delay, 0})
      GenServer.stop(server)

      assert RunOrchestrator.submit(server, request(%{run_id: "run_never_sent"})) ==
               {:error, :unavailable}
    end

    @tag timeout: 60_000
    test "submit waits through the serialized admission window" do
      {:ok, server} = GenServer.start(FakeOrchestrator, {:delay, 6_000})
      on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)

      assert RunOrchestrator.submit(server, request(%{run_id: "run_slow_admission"})) ==
               {:ok, "run_slow_admission"}
    end
  end

  # These use the application's registered orchestrator: the one whose crash
  # would restart the conversation supervisor.
  describe "invalid submissions (#646)" do
    setup do
      orchestrator = Process.whereis(RunOrchestrator)
      assert is_pid(orchestrator)
      %{orchestrator: orchestrator}
    end

    test "a malformed request is refused before the durable claim; the orchestrator survives",
         %{orchestrator: orchestrator} do
      monitor = Process.monitor(orchestrator)

      for {field, value} <- [
            session_key: "",
            session_key: nil,
            session_key: <<0xFF>>,
            queue_mode: :bogus,
            origin: "control_plane"
          ] do
        run_id = "run_invalid_#{field}_#{System.unique_integer([:positive])}"
        invalid = Map.put(request(%{run_id: run_id}), field, value)

        assert RunOrchestrator.submit(invalid) == {:error, :invalid_submission}
        assert Store.get(RunOrchestrator.admission_table(), run_id) == nil
      end

      refute_received {:DOWN, ^monitor, :process, _, _}
      assert Process.whereis(RunOrchestrator) == orchestrator
    end

    @tag :tmp_dir
    test "an unreadable config is a definite refusal in the caller, never inside admission",
         %{orchestrator: orchestrator, tmp_dir: dir} do
      path = Path.join(dir, "config.toml")
      File.write!(path, "[agent\ndefault_model = ")
      previous = Application.get_env(:lemon_core, :paths, [])
      Application.put_env(:lemon_core, :paths, Keyword.put(previous, :global_config, path))

      on_exit(fn ->
        Application.put_env(:lemon_core, :paths, previous)
        LemonCore.ConfigCache.invalidate()
      end)

      monitor = Process.monitor(orchestrator)
      run_id = "run_invalid_config_#{System.unique_integer([:positive])}"

      assert RunOrchestrator.submit(request(%{run_id: run_id})) == {:error, :config_unavailable}

      Application.put_env(:lemon_core, :paths, previous)
      assert Store.get(RunOrchestrator.admission_table(), run_id) == nil
      refute_received {:DOWN, ^monitor, :process, _, _}
      assert Process.whereis(RunOrchestrator) == orchestrator
    end
  end

  test "Submission.new/1 rejects a submission admission cannot own" do
    assert Submission.new(%{}) == {:error, :invalid_submission}

    command = %LemonCore.ExecutionCommand{
      run_id: "run_new",
      session_key: "",
      prompt: "never admitted",
      conversation_key: {:session, "default"}
    }

    assert Submission.new(%{execution_request: command}) == {:error, :invalid_submission}
  end
end
