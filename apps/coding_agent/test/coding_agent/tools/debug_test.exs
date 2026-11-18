defmodule CodingAgent.Tools.DebugTest do
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Debug.SessionServer
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools.Debug
  alias LemonAgent.Types.AgentToolResult

  @fake_adapter Path.expand("../../support/fake_dap_adapter.py", __DIR__)
  @python System.find_executable("python3")

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    session_id = "debug-tool-test-#{System.unique_integer([:positive])}"
    log = Path.join(tmp_dir, "requests.jsonl")
    File.write!(Path.join(tmp_dir, "main.c"), Enum.map_join(1..20, "\n", &"line #{&1};"))
    File.write!(Path.join(tmp_dir, "prog.fake"), "")

    outside =
      Path.join(System.tmp_dir!(), "debug-outside-#{System.unique_integer([:positive])}.txt")

    File.write!(outside, Enum.map_join(1..5, "\n", &"OUTSIDE-SECRET-#{&1}"))
    File.ln_s!(outside, Path.join(tmp_dir, "link.c"))
    on_exit(fn -> File.rm(outside) end)

    source_fake = fn source ->
      %{
        command: @python || "python3",
        args: [@fake_adapter, log],
        launch_defaults: %{"stopOnEntry" => true, "reportedSource" => source}
      }
    end

    adapters = %{
      "outside-fake" => source_fake.(outside),
      "link-fake" => source_fake.(Path.join(tmp_dir, "link.c")),
      "inside-fake" => source_fake.(Path.join(tmp_dir, "main.c")),
      "big-output" => %{
        command: @python || "python3",
        args: [@fake_adapter, log],
        launch_defaults: %{"stopOnEntry" => true, "bigOutput" => 40_000}
      },
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
      tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(tmp_dir),
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
    %{tool: tool, cwd: tmp_dir, log: log, session_id: session_id, opts: opts}
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

  test "excerpts never read adapter-reported sources outside the workspace", %{tool: tool} do
    for adapter <- ["outside-fake", "link-fake"] do
      result =
        run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => adapter})

      assert %AgentToolResult{is_error: false} = result
      refute text(result) =~ "OUTSIDE-SECRET"
      assert %AgentToolResult{is_error: false} = run(tool, %{"action" => "terminate"})
    end

    result =
      run(tool, %{"action" => "launch", "program" => "prog.fake", "adapter" => "inside-fake"})

    assert text(result) =~ "> 1 | line 1;"
  end

  defp outside_tree(name) do
    outside = Path.join(System.tmp_dir!(), "debug-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(outside, "c"))
    File.write!(Path.join(outside, "f.c"), "OUTSIDE-SECRET")
    File.write!(Path.join([outside, "c", "f.c"]), "OUTSIDE-SECRET")
    on_exit(fn -> File.rm_rf(outside) end)
    outside
  end

  test "workspace reads refuse symlinks, hard links and FIFOs", %{cwd: cwd} do
    outside = outside_tree("static")
    File.mkdir_p!(Path.join(cwd, "sub"))
    File.write!(Path.join(cwd, "sub/ok.c"), "inside")
    assert {:ok, "inside"} = Debug.read_workspace_file("sub/ok.c", cwd)

    File.ln_s!(Path.join(outside, "f.c"), Path.join(cwd, "leaf.c"))
    File.ln_s!(outside, Path.join(cwd, "dir"))
    File.ln!(Path.join(cwd, "sub/ok.c"), Path.join(cwd, "hard.c"))
    {_, 0} = System.cmd("mkfifo", [Path.join(cwd, "fifo.c")])

    for path <- ["leaf.c", "dir/f.c", "hard.c", "fifo.c", "../#{Path.basename(outside)}/f.c"] do
      assert :error = Debug.read_workspace_file(path, cwd), path
    end
  end

  for {step, expected} <- [{0, :error}, {1, {:ok, "inside"}}] do
    @step step
    @expected expected
    test "an ancestor swapped for an outside symlink mid-walk (after component #{step}) never leaks",
         %{cwd: cwd} do
      outside = outside_tree("walk")
      File.mkdir_p!(Path.join(cwd, "a/b/c"))
      File.write!(Path.join(cwd, "a/b/c/f.c"), "inside")
      sync = Path.join(cwd, "sync")
      File.mkdir_p!(sync)

      reader =
        Task.async(fn ->
          Debug.read_workspace_file("a/b/c/f.c", cwd, sync_dir: sync, timeout_ms: 20_000)
        end)

      steps = if @expected == :error, do: [0], else: [0, 1, 2]

      for index <- steps do
        assert_eventually(fn -> File.exists?(Path.join(sync, "step-#{index}")) end)

        if index == @step do
          # "a" (step 0) or "a/b" (step 1) is already held as a descriptor.
          File.rename!(Path.join(cwd, "a/b"), Path.join(cwd, "moved"))
          File.ln_s!(outside, Path.join(cwd, "a/b"))
        end

        File.write!(Path.join(sync, "go-#{index}"), "")
      end

      assert Task.await(reader, 20_000) == @expected
    end
  end

  test "oversized output spills only to an exclusive session artifact", ctx do
    assert %AgentToolResult{is_error: false} =
             run(ctx.tool, %{
               "action" => "launch",
               "program" => "prog.fake",
               "adapter" => "big-output"
             })

    result = run(ctx.tool, %{"action" => "output"})
    assert text(result) =~ ~r/full buffer saved to artifact:\/\/\S+/
    assert %{truncated: true, artifact_uri: "artifact://" <> _} = result.details
    refute Map.has_key?(result.details, :full_output_path)
    assert %AgentToolResult{is_error: false} = run(ctx.tool, %{"action" => "terminate"})

    # Without session storage there is no shared-tmp fallback.
    {:ok, tool} =
      ToolRegistry.get_tool(ctx.cwd, "debug", Keyword.put(ctx.opts, :session_id, nil))

    before = File.ls(Path.join(System.tmp_dir!(), "lemon-debug"))

    assert %AgentToolResult{is_error: false} =
             run(tool, %{
               "action" => "launch",
               "program" => "prog.fake",
               "adapter" => "big-output"
             })

    result = run(tool, %{"action" => "output"})
    refute text(result) =~ "saved to"
    assert File.ls(Path.join(System.tmp_dir!(), "lemon-debug")) == before
    run(tool, %{"action" => "terminate"})
  end

  test "non-loopback attach hosts require the explicit opt-in", %{tool: tool, cwd: cwd} = ctx do
    for host <- ["10.0.0.1", "example.invalid", "::ffff:10.0.0.1"] do
      assert {:error, "attach host " <> message} =
               run(tool, %{"action" => "attach", "port" => 5678, "host" => host})

      assert message =~ "debug_allow_remote_attach"
    end

    opts = Keyword.put(ctx.opts, :debug_allow_remote_attach, true)
    {:ok, opted_in} = ToolRegistry.get_tool(cwd, "debug", opts)

    result =
      run(opted_in, %{
        "action" => "attach",
        "port" => 5678,
        "host" => "example.invalid",
        "timeout" => 5
      })

    refute match?({:error, "attach host " <> _}, result)
  end

  test "status without a session is not an error", %{tool: tool} do
    result = run(tool, %{"action" => "status"})
    assert text(result) == "No debug sessions."
    assert {:error, "No active debug session" <> _} = run(tool, %{"action" => "continue"})
  end
end
