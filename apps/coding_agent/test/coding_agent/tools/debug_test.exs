defmodule CodingAgent.Tools.DebugTest do
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

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
      "child-fake" => %{
        command: @python || "python3",
        args: [@fake_adapter, log],
        launch_defaults: %{"stopOnEntry" => true, "fakeMode" => "reverse"}
      },
      "fake" => %{
        command: @python || "python3",
        args: [@fake_adapter, log],
        file_types: [".fake"],
        launch_defaults: %{"stopOnEntry" => true}
      },
      "no-capabilities" => %{
        command: @python || "python3",
        args: [@fake_adapter, log, "--no-capabilities"],
        launch_defaults: %{"stopOnEntry" => true}
      },
      "socket-fake" => %{
        command: @python || "python3",
        args: [@fake_adapter, log, "--listen", "{port}"],
        connect_mode: :socket_server,
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
    %{tool: tool, cwd: tmp_dir, log: log, session_id: session_id}
  end

  defp run(tool, params), do: tool.execute.("call", params, nil, nil)

  defp text(%AgentToolResult{content: content}), do: Enum.map_join(content, "\n", & &1.text)

  test "lists child session ids and routes tool actions to the selected child", %{tool: tool} do
    assert %AgentToolResult{is_error: false} =
             run(tool, %{
               "action" => "launch",
               "program" => "prog.fake",
               "adapter" => "child-fake"
             })

    assert_eventually(fn ->
      result = run(tool, %{"action" => "sessions"})
      text(result) =~ "Child session debug-1-1-1"
    end)

    result = run(tool, %{"action" => "step_over", "debug_session_id" => "debug-1-1-1"})
    assert %AgentToolResult{is_error: false} = result
    assert text(result) =~ "step"
    result = run(tool, %{"action" => "status", "debug_session_id" => "debug-1-1-1"})
    assert text(result) =~ "Session debug-1-1-1"
    assert %AgentToolResult{is_error: false} = run(tool, %{"action" => "terminate"})
  end

  test "validates parameters before touching an adapter", %{tool: tool} do
    assert {:error, "action is required"} = run(tool, %{})
    assert {:error, "Unsupported debug action: nope" <> _} = run(tool, %{"action" => "nope"})
    assert {:error, "program is required for launch"} = run(tool, %{"action" => "launch"})

    assert {:error, "launch program not found: missing.bin"} =
             run(tool, %{"action" => "launch", "program" => "missing.bin"})

    assert {:error, "attach requires pid or port"} = run(tool, %{"action" => "attach"})

    for target <- [
          %{"adapter" => "fake"},
          %{"pid" => 0},
          %{"port" => 65_536},
          %{"pid" => 12, "port" => 5678}
        ] do
      assert {:error, _} = run(tool, Map.put(target, "action", "attach"))
    end

    assert {:error, "set_breakpoint requires file+line or function"} =
             run(tool, %{"action" => "set_breakpoint", "file" => "main.c"})
  end

  test "missing adapters report an install hint", %{tool: tool} do
    assert {:error, "debug adapter 'absent' is not available: install absent-dap"} =
             run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => "absent"})

    assert {:error, "unknown debug adapter 'zzz'" <> _} =
             run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => "zzz"})
  end

  test "advanced requests forward DAP fields, clamp reads and reject oversized responses", %{
    tool: tool,
    log: log
  } do
    assert %AgentToolResult{is_error: false} =
             run(tool, %{
               "action" => "launch",
               "program" => "prog.fake",
               "adapter" => "socket-fake"
             })

    assert %AgentToolResult{is_error: false} =
             run(tool, %{
               "action" => "set_breakpoint",
               "file" => "main.c",
               "line" => 2,
               "log_message" => "value={value}"
             })

    requests = File.read!(log) |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    breakpoint = Enum.find(requests, &(&1["request"] == "setBreakpoints"))
    assert hd(breakpoint["arguments"]["breakpoints"])["logMessage"] == "value={value}"

    info =
      run(tool, %{
        "action" => "data_breakpoint_info",
        "arguments" => %{"name" => "value", "variablesReference" => 1}
      })

    assert info.details.body["dataId"] == "data-1"

    data =
      run(tool, %{
        "action" => "set_data_breakpoints",
        "arguments" => %{"breakpoints" => [%{"dataId" => "data-1", "accessType" => "write"}]}
      })

    assert hd(data.details.body["breakpoints"])["verified"]

    instruction =
      run(tool, %{
        "action" => "set_instruction_breakpoints",
        "arguments" => %{"breakpoints" => [%{"instructionReference" => "0x10"}]}
      })

    assert hd(instruction.details.body["breakpoints"])["verified"]

    memory =
      run(tool, %{
        "action" => "read_memory",
        "arguments" => %{"memoryReference" => "0x10", "count" => 999_999}
      })

    assert memory.details.body["data"] == "AQID"
    assert memory.details.body["requestedCount"] == 128 * 1024

    disassembly =
      run(tool, %{
        "action" => "disassemble",
        "arguments" => %{"memoryReference" => "0x10", "instructionCount" => 999_999}
      })

    assert hd(disassembly.details.body["instructions"])["instruction"] == "nop"
    assert disassembly.details.body["requestedCount"] == 128 * 1024

    assert {:error, message} =
             run(tool, %{
               "action" => "disassemble",
               "arguments" => %{"memoryReference" => "oversized", "instructionCount" => 1}
             })

    assert message =~ "128 KB limit"
  end

  test "advanced operations require advertised capabilities", %{tool: tool, log: log} do
    run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => "no-capabilities"})

    for action <- [
          "data_breakpoint_info",
          "set_data_breakpoints",
          "set_instruction_breakpoints",
          "read_memory",
          "disassemble"
        ] do
      assert {:error, message} = run(tool, %{"action" => action, "arguments" => %{}})
      assert message =~ "does not advertise"
    end

    assert {:error, message} =
             run(tool, %{
               "action" => "set_breakpoint",
               "file" => "main.c",
               "line" => 2,
               "log_message" => "hello"
             })

    assert message =~ "supportsLogPoints"
    refute File.read!(log) =~ "readMemory"
    refute File.read!(log) =~ "setBreakpoints"
  end

  test "tool deadlines clamp to five through three hundred seconds", %{
    tool: tool,
    session_id: key
  } do
    run(tool, %{"action" => "set_breakpoint", "file" => "main.c", "line" => 2})
    server = SessionServer.whereis(key)
    :erlang.trace(server, true, [:receive])
    on_exit(fn -> if Process.alive?(server), do: :erlang.trace(server, false, [:receive]) end)

    for {input, expected} <- [{-1, 5_000}, {1_000, 300_000}] do
      run(tool, %{"action" => "status", "timeout" => input})

      assert_receive {:trace, ^server, :receive,
                      {:"$gen_call", _, {:op, %{action: "status"}, %{timeout_ms: ^expected}}}}
    end
  end

  test "status without a session is not an error", %{tool: tool} do
    result = run(tool, %{"action" => "status"})
    assert text(result) == "No debug sessions."
    assert {:error, "No active debug session" <> _} = run(tool, %{"action" => "continue"})
  end
end
