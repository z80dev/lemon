defmodule CodingAgent.Tools.ProcessInputTest do
  use ExUnit.Case, async: false
  alias CodingAgent.{ProcessManager, ProcessSession, ProcessStore}
  alias CodingAgent.Tools.ProcessInput
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  test "writes exact bytes and EOF without discarding output", %{tmp_dir: cwd} do
    {:ok, id} =
      ProcessManager.exec(command: "cat; printf '\\nclosed\\n'", cwd: cwd, owner: "input-test")

    on_exit(fn -> cleanup(id) end)
    opts = [session_id: "input-test"]

    assert %AgentToolResult{details: %{bytes_written: 3, eof: false}} =
             ProcessInput.execute(
               "1",
               %{"process_id" => id, "input" => "abc"},
               nil,
               nil,
               cwd,
               opts
             )

    assert %AgentToolResult{details: %{bytes_written: 3, eof: true}} =
             ProcessInput.execute(
               "2",
               %{"process_id" => id, "input" => "def", "eof" => true},
               nil,
               nil,
               cwd,
               opts
             )

    assert {:ok, result} = await_completion(id, 100)
    assert result.status == :completed
    assert {:ok, output} = ProcessManager.read_output(id)
    assert output.lines == ["abcdef", "closed"]

    assert {:error, message} =
             ProcessInput.execute("3", %{"process_id" => id, "input" => "x"}, nil, nil, cwd, opts)

    assert message =~ "not running"
  end

  test "foreign ownership and invalid inputs fail clearly", %{tmp_dir: cwd} do
    {:ok, id} = ProcessManager.exec(command: "cat", cwd: cwd, owner: "input-owner")
    on_exit(fn -> cleanup(id) end)

    assert {:error, message} =
             ProcessInput.execute("1", %{"process_id" => id, "input" => "secret"}, nil, nil, cwd,
               session_id: "foreign"
             )

    assert message =~ "No background process"

    assert {:error, "input must be a string"} =
             ProcessInput.execute("2", %{"process_id" => id}, nil, nil, cwd,
               session_id: "input-owner"
             )

    assert {:error, "eof must be a boolean"} =
             ProcessInput.execute(
               "3",
               %{"process_id" => id, "input" => "", "eof" => "yes"},
               nil,
               nil,
               cwd,
               session_id: "input-owner"
             )
  end

  test "registry and approval policy expose process_input", %{tmp_dir: cwd} do
    assert {:ok, %{name: "process_input"}} =
             CodingAgent.ToolRegistry.get_tool(cwd, "process_input",
               include_extensions: false,
               include_mcp: false
             )

    assert ProcessInput.tool(cwd).parameters["required"] == ["process_id", "input"]

    for tool <- ["bash", "kill_process", "process_input"] do
      refute LemonCore.ToolPolicy.allowed?(:safe_mode, tool)
      assert LemonCore.ToolPolicy.allowed?(:full_access, tool)
    end
  end

  defp await_completion(_id, 0), do: flunk("process did not complete")

  defp await_completion(id, attempts) do
    case ProcessManager.poll(id, lines: 0) do
      {:ok, %{status: status}} = result when status in [:completed, :error, :killed] ->
        result

      _ ->
        Process.sleep(50)
        await_completion(id, attempts - 1)
    end
  end

  defp cleanup(id) do
    ProcessManager.kill(id, :sigkill)
    if ProcessSession.alive?(id), do: ProcessSession.stop(id)
    ProcessStore.delete(id)
  end
end
