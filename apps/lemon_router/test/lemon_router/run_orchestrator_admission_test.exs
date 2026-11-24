defmodule LemonRouter.RunOrchestratorAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunRequest
  alias LemonRouter.RunOrchestrator

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
end
