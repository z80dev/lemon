defmodule CodingAgent.Tools.KillProcessTest do
  use ExUnit.Case, async: false
  alias CodingAgent.{ProcessManager, ProcessSession, ProcessStore}
  alias CodingAgent.Tools.KillProcess
  alias LemonAgent.Types.AgentToolResult
  @moduletag :tmp_dir

  test "default TERM allows cleanup", %{tmp_dir: cwd} do
    id = start("trap 'echo cleaned; exit 0' TERM; echo ready; while :; do sleep 0.05; done", cwd)
    await(id, fn output -> "ready" in output.logs end)
    assert %AgentToolResult{} = kill(id, %{}, cwd)
    result = await(id, &(&1.status == :killed))
    assert "cleaned" in result.logs
  end

  test "TERM escalates after two seconds when ignored", %{tmp_dir: cwd} do
    id = start("trap '' TERM; echo ready; while :; do sleep 0.05; done", cwd)
    await(id, fn output -> "ready" in output.logs end)
    before = System.monotonic_time(:millisecond)
    assert %AgentToolResult{} = kill(id, %{}, cwd)
    await(id, &(&1.status == :killed))
    assert System.monotonic_time(:millisecond) - before >= 1_900
  end

  test "kill skips TERM and invalid signals are rejected", %{tmp_dir: cwd} do
    id = start("trap 'echo cleaned' TERM; echo ready; while :; do sleep 0.05; done", cwd)
    await(id, fn output -> "ready" in output.logs end)
    assert {:error, "signal must be term or kill"} = kill(id, %{"signal" => "hup"}, cwd)
    assert %AgentToolResult{} = kill(id, %{"signal" => "kill"}, cwd)
    result = await(id, &(&1.status == :killed))
    refute "cleaned" in result.logs
    assert {:error, message} = kill(id, %{}, cwd)
    assert message =~ "not running"
  end

  defp kill(id, params, cwd),
    do:
      KillProcess.execute("kill", Map.put(params, "process_id", id), nil, nil, cwd,
        session_id: "kill-test"
      )

  defp start(command, cwd) do
    {:ok, id} = ProcessManager.exec(command: command, cwd: cwd, owner: "kill-test")

    on_exit(fn ->
      ProcessManager.kill(id, :sigkill)
      if ProcessSession.alive?(id), do: ProcessSession.stop(id)
      ProcessStore.delete(id)
    end)

    id
  end

  defp await(id, predicate, tries \\ 120)
  defp await(_id, _predicate, 0), do: flunk("process did not reach expected state")

  defp await(id, predicate, tries) do
    {:ok, output} = ProcessManager.poll(id, lines: 100)

    if predicate.(output),
      do: output,
      else:
        (
          Process.sleep(50)
          await(id, predicate, tries - 1)
        )
  end
end
