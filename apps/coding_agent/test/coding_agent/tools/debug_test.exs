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

  test "status without a session is not an error", %{tool: tool} do
    result = run(tool, %{"action" => "status"})
    assert text(result) == "No debug sessions."
    assert {:error, "No active debug session" <> _} = run(tool, %{"action" => "continue"})
  end
end
