defmodule CodingAgent.Debug.LldbDapIntegrationTest do
  @moduledoc false
  # Drives the real `lldb-dap` adapter against a tiny C program. The app helper
  # excludes :lldb_dap only when the adapter or a C compiler is unavailable.
  use ExUnit.Case, async: false

  alias CodingAgent.Debug.SessionServer
  alias CodingAgent.Tools.Debug

  @clang System.find_executable("clang") || System.find_executable("cc")

  @moduletag :lldb_dap

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  @source """
  #include <stdio.h>

  int add(int a, int b) {
    int sum = a + b;
    return sum;
  }

  int main(void) {
    int x = 40;
    int y = 2;
    int total = add(x, y);
    printf("total=%d\\n", total);
    return total == 42 ? 0 : 1;
  }
  """

  setup %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "main.c"), @source)

    {_, 0} =
      System.cmd(@clang, ["-g", "-O0", "-o", "main", "main.c"],
        cd: tmp_dir,
        stderr_to_stdout: true
      )

    session_id = "lldb-dap-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = SessionServer.whereis(session_id), do: GenServer.stop(pid, :normal, 10_000)
    end)

    %{tool: Debug.tool(tmp_dir, session_id: session_id)}
  end

  defp run(tool, params) do
    case tool.execute.("call", Map.put_new(params, "timeout", 60), nil, nil) do
      %{content: content} = result -> {Enum.map_join(content, "\n", & &1.text), result}
      {:error, message} -> flunk("#{params["action"]} failed: #{message}")
    end
  end

  test "breakpoint, inspect, step and continue against lldb-dap", %{tool: tool} do
    {text, _} = run(tool, %{"action" => "set_breakpoint", "file" => "main.c", "line" => 11})
    assert text =~ "pending"

    {text, launched} =
      run(tool, %{"action" => "launch", "program" => "main", "adapter" => "lldb-dap"})

    assert launched.details.state == :stopped
    assert text =~ ~r/Stopped: breakpoint .*at main\.c:11 in main/
    assert text =~ "> 11 |   int total = add(x, y);"

    {text, _} = run(tool, %{"action" => "stack_trace"})
    assert text =~ ~r/#0 main main\.c:11/

    {_, scopes} = run(tool, %{"action" => "scopes"})
    locals = Enum.find(scopes.details.scopes, &(&1["name"] == "Locals"))
    assert locals

    {text, _} = run(tool, %{"action" => "variables", "scope_id" => locals["variablesReference"]})
    assert text =~ "x = 40 (int)"
    assert text =~ "y = 2 (int)"

    {text, _} =
      run(tool, %{"action" => "evaluate", "expression" => "x + y", "context" => "watch"})

    assert text =~ "Result: 42"

    {text, _} = run(tool, %{"action" => "step_in"})
    assert text =~ ~r/Stopped: step.* at main\.c:4 in add/

    {text, _} = run(tool, %{"action" => "step_out"})
    assert text =~ ~r/Stopped: step.* at main\.c:11 in main/

    {text, _} = run(tool, %{"action" => "step_over"})
    assert text =~ ~r/at main\.c:12 in main/

    {text, finished} = run(tool, %{"action" => "continue"})
    assert finished.details.state == :terminated
    assert text =~ "Program terminated with exit code 0."

    {text, _} = run(tool, %{"action" => "output"})
    assert text =~ "total=42"
  end
end
