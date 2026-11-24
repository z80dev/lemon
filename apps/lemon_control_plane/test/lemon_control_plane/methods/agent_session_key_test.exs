defmodule LemonControlPlane.Methods.AgentSessionKeyTest do
  # Reads the application's registered run orchestrator and admission table.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.Agent
  alias LemonRouter.RunOrchestrator

  # #646: a malformed session key is a definite 4xx-style refusal at the method
  # boundary; nothing reaches admission and the orchestrator keeps running.
  test "an empty or malformed session key is refused before any admission" do
    orchestrator = Process.whereis(RunOrchestrator)
    assert is_pid(orchestrator)
    {:ok, before} = LemonCore.Store.fetch_all(RunOrchestrator.admission_table())

    for key <- ["", "   ", "agent:default:main\n", 123, String.duplicate("k", 1025)] do
      assert {:error, {:invalid_params, message}} =
               Agent.handle(%{"prompt" => "hello", "session_key" => key}, %{})

      assert message =~ "session_key must be a nonblank string"
    end

    {:ok, after_rows} = LemonCore.Store.fetch_all(RunOrchestrator.admission_table())

    refute Enum.any?(after_rows -- before, fn {_run_id, row} ->
             get_in(row, [:scope, :session_key]) in ["", "   "]
           end)

    assert Process.whereis(RunOrchestrator) == orchestrator
    assert Process.alive?(orchestrator)
  end
end
