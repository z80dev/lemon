defmodule CodingAgent.Debug.SessionServerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.SessionServer
  alias LemonAgent.AbortSignal

  @fake_adapter Path.expand("../../support/fake_dap_adapter.py", __DIR__)
  @python System.find_executable("python3")

  if is_nil(@python), do: @moduletag(skip: "python3 is required for the fake DAP adapter")

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "requests.jsonl")
    source = Path.join(tmp_dir, "main.c")
    File.write!(source, Enum.map_join(1..20, "\n", &"line #{&1};"))
    key = "debug-server-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if pid = SessionServer.whereis(key), do: stop_quietly(pid)
    end)

    %{log: log, source: source, key: key, cwd: tmp_dir}
  end

  defp adapter(log, launch_defaults) do
    %{
      name: "fake",
      command: @python,
      args: [@fake_adapter, log],
      connect_mode: :stdio,
      launch_defaults: Map.merge(%{"stopOnEntry" => true}, launch_defaults),
      attach_defaults: %{}
    }
  end

  defp launch(ctx, launch_defaults \\ %{}, opts \\ []) do
    request = %{
      action: "launch",
      adapter: adapter(ctx.log, launch_defaults),
      program: Path.join(ctx.cwd, "prog"),
      cwd: ctx.cwd,
      args: ["--flag"],
      launch_overrides: %{}
    }

    call(ctx.key, request, opts)
  end

  defp call(key, request, opts \\ []) do
    SessionServer.call(key, request, Keyword.merge([timeout_ms: 5_000], opts))
  end

  defp commands(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
    |> Enum.flat_map(fn
      %{"request" => command, "arguments" => args} -> [{command, args}]
      _ -> []
    end)
  end

  defp stop_quietly(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> :ok
    end
  end

  # A killed debuggee reparented to init stays a zombie until reaped.
  defp os_alive?(pid) when is_integer(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {stat, 0} -> not String.starts_with?(String.trim(stat), "Z")
      _ -> false
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end

  test "handshake sends pending breakpoints between initialized and configurationDone", ctx do
    assert {:ok, %{pending: true}} =
             call(ctx.key, %{action: "set_breakpoint", file: ctx.source, line: 5})

    assert {:ok, %{pending: true}} =
             call(ctx.key, %{action: "set_function_breakpoint", function: "add"})

    assert {:ok, %{state: :stopped, snapshot: snapshot}} = launch(ctx)

    assert [
             {"initialize", init},
             {"launch", launch_args},
             {"setBreakpoints", bp_args},
             {"setFunctionBreakpoints", fn_args},
             {"configurationDone", _},
             {"stackTrace", %{"levels" => 1, "threadId" => 1}}
           ] = commands(ctx.log)

    assert init["clientID"] == "lemon"
    assert init["linesStartAt1"] == true and init["columnsStartAt1"] == true
    assert init["pathFormat"] == "path"
    assert init["supportsRunInTerminalRequest"] == false

    # Pending breakpoints disable the stop at program entry.
    assert launch_args["stopOnEntry"] == false
    assert launch_args["args"] == ["--flag"]
    assert bp_args["source"]["path"] == ctx.source
    assert bp_args["breakpoints"] == [%{"line" => 5}]
    assert fn_args["breakpoints"] == [%{"name" => "add"}]

    assert snapshot.stop_reason == "breakpoint"
    assert snapshot.source_path == ctx.source
    assert snapshot.line == 5
    assert snapshot.frame_id == 100
    assert snapshot.thread_id == 1
    assert [%{line: 5, verified: true, file: file}] = snapshot.breakpoints
    assert file == ctx.source
    assert is_integer(snapshot.process_id)
  end

  test "setting a breakpoint re-sends the file's full sorted list", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx)

    assert {:ok, %{breakpoints: [_]}} =
             call(ctx.key, %{action: "set_breakpoint", file: ctx.source, line: 9})

    assert {:ok, %{breakpoints: breakpoints, pending: false}} =
             call(ctx.key, %{
               action: "set_breakpoint",
               file: ctx.source,
               line: 3,
               condition: "x > 1",
               hit_condition: "2"
             })

    assert [%{line: 3, verified: true, condition: "x > 1"}, %{line: 9, verified: true}] =
             breakpoints

    assert {"setBreakpoints", %{"breakpoints" => sent}} =
             ctx.log
             |> commands()
             |> Enum.filter(&match?({"setBreakpoints", _}, &1))
             |> List.last()

    assert sent == [%{"line" => 3, "condition" => "x > 1", "hitCondition" => "2"}, %{"line" => 9}]

    assert {:ok, %{breakpoints: [%{line: 3}]}} =
             call(ctx.key, %{action: "remove_breakpoint", file: ctx.source, line: 9})

    assert {:ok,
            %{
              breakpoints: [%{line: 3}, %{line: 999, verified: false, message: "no code at line"}]
            }} =
             call(ctx.key, %{action: "set_breakpoint", file: ctx.source, line: 999})
  end

  test "execution actions wait for the next stopped or terminated event", ctx do
    assert {:ok, %{state: :stopped, snapshot: %{stop_reason: "entry"}}} = launch(ctx)

    assert {:ok, %{state: :stopped, snapshot: step}} = call(ctx.key, %{action: "step_over"})
    assert step.stop_reason == "step"
    assert step.line == 2

    assert {:ok, %{stack_frames: [%{"id" => 100}, %{"id" => 101}]}} =
             call(ctx.key, %{action: "stack_trace"})

    assert {:ok, %{scopes: [%{"variablesReference" => 10}], frame_id: 100}} =
             call(ctx.key, %{action: "scopes"})

    assert {:ok, %{variables: [%{"name" => "x"}, %{"name" => "p"}]}} =
             call(ctx.key, %{action: "variables", variable_ref: 10})

    assert {:ok, %{evaluation: %{"result" => "eval:x frame=100 ctx=repl"}}} =
             call(ctx.key, %{action: "evaluate", expression: "x"})

    assert {:error, "cannot evaluate"} = call(ctx.key, %{action: "evaluate", expression: "fail"})

    assert {:ok, %{threads: [%{"id" => 1}, %{"id" => 2}]}} = call(ctx.key, %{action: "threads"})

    assert {:ok, %{body: %{"echo" => %{"a" => 1}}}} =
             call(ctx.key, %{action: "custom_request", command: "echo", arguments: %{"a" => 1}})

    assert {:ok, %{state: :terminated, snapshot: done}} = call(ctx.key, %{action: "continue"})
    assert done.exit_code == 7
    assert done.status == :terminated

    assert {:ok, %{output: output}} = call(ctx.key, %{action: "output"})
    assert output =~ "bye\n"

    assert {:error, message} = call(ctx.key, %{action: "step_over"})
    assert message =~ "has terminated"
  end

  test "continue reports a timeout while the program keeps running, then pause stops it", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx, %{"fakeMode" => "hang"})

    assert {:ok, %{state: :running, timed_out: true, snapshot: %{status: :running}}} =
             call(ctx.key, %{action: "continue"}, timeout_ms: 300)

    assert {:ok, %{state: :stopped, snapshot: %{stop_reason: "pause"}}} =
             call(ctx.key, %{action: "pause"})
  end

  test "an aborted wait returns promptly and keeps the session", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx, %{"fakeMode" => "hang"})
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        call(ctx.key, %{action: "continue"}, timeout_ms: 30_000, signal: signal)
      end)

    Process.sleep(200)
    AbortSignal.abort(signal)

    assert {:aborted, message} = Task.await(task, 5_000)
    assert message =~ "cancelled"
    assert {:ok, %{snapshot: %{status: :running}}} = call(ctx.key, %{action: "status"})
  end

  test "a missing initialized event times out and kills the adapter", ctx do
    assert {:error, message} = launch(ctx, %{"fakeMode" => "no_initialized"}, timeout_ms: 500)
    assert message =~ "initialized"
    assert {:ok, %{snapshot: %{status: :none}}} = call(ctx.key, %{action: "status"})
  end

  test "launch failures surface the adapter error and dispose the session", ctx do
    assert {:error, "cannot launch: boom"} = launch(ctx, %{"fakeMode" => "fail_launch"})
    assert {:ok, %{snapshot: %{status: :none}}} = call(ctx.key, %{action: "status"})
  end

  test "a second launch is refused while a session is active", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx)
    assert {:error, message} = launch(ctx)
    assert message =~ "still active"
  end

  test "terminate disconnects and kills the debuggee; breakpoints persist", ctx do
    assert {:ok, _} = call(ctx.key, %{action: "set_breakpoint", file: ctx.source, line: 4})
    assert {:ok, %{snapshot: %{process_id: debuggee}}} = launch(ctx)
    assert os_alive?(debuggee)

    assert {:ok, %{snapshot: %{status: :terminated}}} = call(ctx.key, %{action: "terminate"})
    assert eventually(fn -> not os_alive?(debuggee) end)
    assert {"disconnect", %{"terminateDebuggee" => true}} = List.last(commands(ctx.log))

    assert {:ok, %{snapshot: %{breakpoints: [%{line: 4}]}}} = call(ctx.key, %{action: "status"})

    # A fresh launch reuses the persisted breakpoints.
    assert {:ok, %{state: :stopped, snapshot: %{line: 4}}} = launch(ctx)
  end

  test "the owning coding session exiting kills the adapter and debuggee", ctx do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, %{snapshot: %{process_id: debuggee}}} = launch(ctx, %{}, owner: owner)
    server = SessionServer.whereis(ctx.key)
    ref = Process.monitor(server)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^server, _}, 5_000
    assert eventually(fn -> not os_alive?(debuggee) end)
  end

  test "an idle server stops and kills its adapter", ctx do
    assert {:ok, %{snapshot: %{process_id: debuggee}}} = launch(ctx, %{}, idle_timeout_ms: 300)
    server = SessionServer.whereis(ctx.key)
    ref = Process.monitor(server)

    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 5_000
    assert eventually(fn -> not os_alive?(debuggee) end)
  end

  test "read-only actions without a server do not start one", ctx do
    assert {:none, _} = call(ctx.key, %{action: "status"})
    assert {:none, message} = call(ctx.key, %{action: "stack_trace"})
    assert message =~ "No active debug session"
    assert SessionServer.whereis(ctx.key) == nil
  end
end
