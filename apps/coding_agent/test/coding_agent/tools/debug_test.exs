defmodule CodingAgent.Tools.DebugTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.SessionServer
  alias CodingAgent.ToolRegistry
  alias LemonAgent.Types.AgentToolResult

  @fake_adapter Path.expand("../../support/fake_dap_adapter.py", __DIR__)
  @python System.find_executable("python3")

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    session_id = "debug-tool-test-#{System.unique_integer([:positive])}"
    log = Path.join(tmp_dir, "requests.jsonl")
    File.write!(Path.join(tmp_dir, "main.c"), Enum.map_join(1..20, "\n", &"line #{&1};"))
    File.write!(Path.join(tmp_dir, "prog.fake"), "")

    adapters = %{
      "fake" => %{
        command: @python || "python3",
        args: [@fake_adapter, log],
        file_types: [".fake"],
        launch_defaults: %{"stopOnEntry" => true}
      },
      "absent" => %{command: "/nonexistent/absent-dap", install_hint: "install absent-dap"}
    }

    opts = [
      session_id: session_id,
      debug_adapters: adapters,
      include_extensions: false,
      include_mcp: false
    ]

    on_exit(fn ->
      if pid = SessionServer.whereis(session_id) do
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          5_000 -> :ok
        end
      end
    end)

    {:ok, tool} = ToolRegistry.get_tool(tmp_dir, "debug", opts)
    %{tool: tool, cwd: tmp_dir}
  end

  defp run(tool, params), do: tool.execute.("call", params, nil, nil)

  defp text(%AgentToolResult{content: content}), do: Enum.map_join(content, "\n", & &1.text)

  test "validates parameters before touching an adapter", %{tool: tool} do
    assert {:error, "action is required"} = run(tool, %{})
    assert {:error, "Unsupported debug action: nope" <> _} = run(tool, %{"action" => "nope"})
    assert {:error, "program is required for launch"} = run(tool, %{"action" => "launch"})

    assert {:error, "launch program not found: missing.bin"} =
             run(tool, %{"action" => "launch", "program" => "missing.bin"})

    assert {:error, "attach requires pid or port"} = run(tool, %{"action" => "attach"})

    assert {:error, "set_breakpoint requires file+line or function"} =
             run(tool, %{"action" => "set_breakpoint", "file" => "main.c"})
  end

  test "missing adapters report an install hint", %{tool: tool} do
    assert {:error, "debug adapter 'absent' is not available: install absent-dap"} =
             run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => "absent"})

    assert {:error, "unknown debug adapter 'zzz'" <> _} =
             run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => "zzz"})
  end

  test "status without a session is not an error", %{tool: tool} do
    result = run(tool, %{"action" => "status"})
    assert text(result) == "No debug sessions."
    assert {:error, "No active debug session" <> _} = run(tool, %{"action" => "continue"})
  end

  @tag skip: if(is_nil(@python), do: "python3 is required for the fake DAP adapter", else: false)
  test "drives a full breakpoint, inspect, step and continue cycle", %{tool: tool} do
    launched =
      run(tool, %{"action" => "launch", "program" => "prog.fake", "file" => "main.c", "line" => 5})

    launch_text = text(launched)
    assert launched.trust == :untrusted
    assert launch_text =~ "Launched prog.fake with fake (session debug-1)."
    assert launch_text =~ "Stopped: breakpoint at main.c:5 in main (thread 1)"
    assert launch_text =~ "> 5 | line 5;"
    assert launch_text =~ "  4 | line 4;"
    assert launch_text =~ "- main.c:5 verified"
    assert launched.details.state == :stopped
    assert launched.details.snapshot.line == 5

    stack = text(run(tool, %{"action" => "stack_trace"}))
    assert stack =~ "#0 main main.c:5 (frame_id 100)"
    assert stack =~ "#1 start <no source> (frame_id 101)"

    assert text(run(tool, %{"action" => "scopes"})) =~ "Locals [scope_id 10]"

    variables = text(run(tool, %{"action" => "variables", "scope_id" => 10}))
    assert variables =~ "x = 40 (int)"
    assert variables =~ "p = {a=1} (struct point) [ref 11]"

    evaluated = run(tool, %{"action" => "evaluate", "expression" => "x", "context" => "watch"})
    assert text(evaluated) =~ "Result: eval:x frame=100 ctx=watch\nType: string"

    stepped = text(run(tool, %{"action" => "step_over"}))
    assert stepped =~ "Stopped: step at main.c:6 in main (thread 1)"
    assert stepped =~ "> 6 | line 6;"

    finished = run(tool, %{"action" => "continue"})
    assert text(finished) =~ "Program terminated with exit code 7."
    assert finished.details.state == :terminated

    assert text(run(tool, %{"action" => "output"})) =~ "hello from debuggee\nbye\n"

    status = text(run(tool, %{"action" => "status"}))
    assert status =~ "Session debug-1 (fake): terminated"
    assert status =~ "Exit code: 7"

    assert text(run(tool, %{"action" => "terminate"})) =~ "Debug session debug-1 terminated."
  end

  @tag skip: if(is_nil(@python), do: "python3 is required for the fake DAP adapter", else: false)
  test "set_breakpoint with function sets a function breakpoint on the live session", %{
    tool: tool
  } do
    assert text(run(tool, %{"action" => "launch", "program" => "prog.fake"})) =~ "Stopped: entry"

    result =
      run(tool, %{"action" => "set_breakpoint", "function" => "add", "condition" => "a > 1"})

    assert text(result) =~ "Function breakpoints:\n- add: verified if a > 1"

    removed = run(tool, %{"action" => "remove_breakpoint", "function" => "add"})
    assert text(removed) =~ "Function breakpoints:\n(none)"

    assert text(
             run(tool, %{
               "action" => "custom_request",
               "command" => "echo",
               "arguments" => %{"k" => "v"}
             })
           ) =~
             ~s("k": "v")
  end
end
