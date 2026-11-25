defmodule CodingAgent.Tools.Task.RuntimeCompletionTest do
  use ExUnit.Case, async: false

  import LemonPlatformTest.Testing.AsyncHelpers

  alias CodingAgent.{TaskRuntime, TaskRuntimeHelpers, TaskStore}
  alias CodingAgent.Tools.Task
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  defmodule Recorder do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:enqueue, _context, {text, entry}}, _from, owner) do
      send(owner, {:followup, text, entry})
      {:reply, :ok, owner}
    end
  end

  test "the followup is delivered exactly once while the owner cannot take the completion" do
    recorder = start_supervised!({Recorder, self()})
    test = self()

    result =
      Task.execute(
        "call_followup_once",
        %{
          "description" => "Followup once",
          "prompt" => "Finish",
          "async" => true,
          "auto_followup" => true
        },
        nil,
        nil,
        "/tmp",
        run_override: fn _on_update, _signal ->
          send(test, {:started, self()})

          receive do
            :release -> :ok
          end

          %AgentToolResult{
            content: [%TextContent{text: "child answer"}],
            details: %{status: "completed"}
          }
        end,
        async_followup_server: recorder,
        session_key: "agent:main:main",
        agent_id: "main"
      )

    id = result.details.task_id
    assert_receive {:started, worker}, 2_000
    owner = TaskRuntime.whereis(id)
    on_exit(fn -> TaskRuntimeHelpers.stop(id) end)

    # The owner cannot answer any completion handshake while suspended.
    :ok = :sys.suspend(owner)
    send(worker, :release)

    assert_receive {:followup, text, %{task_id: ^id}}, 2_000
    assert text =~ "completed"
    assert text =~ "child answer"
    assert {:ok, %{status: :completed}} = TaskStore.get_record(id)

    :ok = :sys.resume(owner)
    assert_eventually(fn -> match?({:completed, _}, TaskRuntimeHelpers.state(id)) end)
    refute_receive {:followup, _text, _entry}, 300
  end
end
