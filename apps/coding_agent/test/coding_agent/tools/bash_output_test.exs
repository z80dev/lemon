defmodule CodingAgent.Tools.BashOutputTest do
  use ExUnit.Case, async: false
  alias CodingAgent.{ProcessManager, ProcessSession, ProcessStore}
  alias CodingAgent.Tools.BashOutput
  alias LemonAgent.Types.AgentToolResult
  @moduletag :tmp_dir

  test "peek returns recent output without consuming running or stored output", %{tmp_dir: cwd} do
    {:ok, id} =
      ProcessManager.exec(command: "echo one; read line; echo two", cwd: cwd, owner: "peek-test")

    on_exit(fn ->
      ProcessManager.kill(id, :sigkill)
      if ProcessSession.alive?(id), do: ProcessSession.stop(id)
      ProcessStore.delete(id)
    end)

    await(id, fn result -> "one" in result.logs end)
    assert text(read(id, cwd, true)) =~ "one"
    assert text(read(id, cwd, true)) =~ "one"
    assert text(read(id, cwd, false)) =~ "one"
    assert text(read(id, cwd, false)) =~ "(no new output)"
    assert text(read(id, cwd, true)) =~ "one"
    :ok = ProcessManager.write(id, "go\n")
    await(id, &(&1.status == :completed))
    ProcessSession.stop(id)
    peek = text(read(id, cwd, true))
    assert peek =~ "one"
    assert peek =~ "two"
    consumed = text(read(id, cwd, false))
    assert consumed =~ "two"
    refute consumed =~ "one"
    assert text(read(id, cwd, false)) =~ "(no new output)"
    assert text(read(id, cwd, true)) =~ "two"
  end

  defp read(id, cwd, peek) do
    assert %AgentToolResult{} =
             result =
             BashOutput.execute("read", %{"process_id" => id, "peek" => peek}, nil, nil, cwd,
               session_id: "peek-test"
             )

    result
  end

  defp text(result), do: Enum.map_join(result.content, "\n", & &1.text)
  defp await(id, predicate, tries \\ 100)
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
