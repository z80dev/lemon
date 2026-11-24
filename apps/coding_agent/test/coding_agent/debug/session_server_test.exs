defmodule CodingAgent.Debug.SessionServerTest do
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Debug.Client
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
    _ = DynamicSupervisor.terminate_child(CodingAgent.Debug.Supervisor, pid)

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

  for kind <- ["launch", "attach"] do
    @child_kind kind
    test "startDebugging creates and routes to a #{@child_kind} child, cleaned up with parent",
         ctx do
      kind = @child_kind
      assert {:ok, _} = launch(ctx, %{"fakeMode" => "reverse", "childRequest" => kind})

      assert_eventually(fn ->
        {:ok, %{snapshot: snapshot}} = call(ctx.key, %{action: "sessions"})
        match?([%{status: :stopped}], snapshot.children)
      end)

      {:ok, %{snapshot: %{id: parent_id, children: [child]}}} =
        call(ctx.key, %{action: "sessions"})

      assert child.parent_id == parent_id
      assert child.kind == String.to_existing_atom(kind)
      assert child.program == "child"
      child_server = SessionServer.whereis({ctx.key, String.replace_suffix(child.id, "-1", "")})
      assert is_pid(child_server)
      monitor = Process.monitor(child_server)

      assert {:ok, %{snapshot: %{id: child_id}}} =
               call(ctx.key, %{action: "status", debug_session_id: child.id})

      assert child_id == child.id

      assert {:ok, _} =
               call(ctx.key, %{action: "step_over", debug_session_id: child.id})

      assert {:ok, %{snapshot: %{stop_reason: "step"}}} =
               call(ctx.key, %{action: "status", debug_session_id: child.id})

      assert {:ok, %{snapshot: %{stop_reason: "entry"}}} =
               call(ctx.key, %{action: "status"})

      entries =
        ctx.log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(
               entries,
               &match?(%{"reverse_response" => "startDebugging", "success" => true}, &1)
             )

      assert {^kind, %{"__pendingTargetId" => "target-42", "program" => "child"}} =
               Enum.find(commands(ctx.log), fn {command, args} ->
                 command == kind and args["program"] == "child"
               end)

      assert {:error, "Unknown debug session: missing"} =
               call(ctx.key, %{action: "status", debug_session_id: "missing"})

      assert {:ok, _} = call(ctx.key, %{action: "terminate"})
      assert_receive {:DOWN, ^monitor, :process, ^child_server, _}, 5_000
      assert {:ok, %{snapshot: %{children: []}}} = call(ctx.key, %{action: "sessions"})
    end
  end

  test "server adapters connect children to the existing listener", ctx do
    adapter =
      adapter(ctx.log, %{"fakeMode" => "reverse"})
      |> Map.merge(%{
        connect_mode: :socket_server,
        args: [@fake_adapter, ctx.log, "--listen", "{port}"]
      })

    assert {:ok, _} =
             call(ctx.key, %{
               action: "launch",
               adapter: adapter,
               program: "parent",
               cwd: ctx.cwd,
               args: [],
               launch_overrides: %{}
             })

    assert_eventually(fn ->
      {:ok, %{snapshot: snapshot}} = call(ctx.key, %{action: "sessions"})
      match?([%{status: :stopped}], snapshot.children)
    end)

    {_, %{children: children}} = :sys.get_state(SessionServer.whereis(ctx.key))
    [child] = Map.values(children)
    {_, %{session: %{adapter: child_adapter}}} = :sys.get_state(child)
    assert child_adapter.connect_mode == :remote
    assert child_adapter.host == "127.0.0.1"
    assert is_integer(child_adapter.port)
    assert {:ok, _} = call(ctx.key, %{action: "terminate"})
  end

  test "invalid startDebugging requests are rejected without creating children", ctx do
    assert {:ok, _} = launch(ctx, %{"fakeMode" => "reverse", "childRequest" => "invalid"})

    assert_eventually(fn ->
      ctx.log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.any?(&match?(%{"reverse_response" => "startDebugging", "success" => false}, &1))
    end)

    assert {:ok, %{snapshot: %{children: []}}} = call(ctx.key, %{action: "sessions"})
  end

  test "parent adapter exit tears down children", ctx do
    assert {:ok, _} = launch(ctx, %{"fakeMode" => "reverse"})
    parent = SessionServer.whereis(ctx.key)

    assert_eventually(fn ->
      {_, state} = :sys.get_state(parent)
      map_size(state.children) == 1
    end)

    {_, state} = :sys.get_state(parent)
    [child] = Map.values(state.children)
    ref = Process.monitor(child)
    Client.stop(state.session.client)
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 15_000
    assert {:ok, %{snapshot: %{children: []}}} = call(ctx.key, %{action: "sessions"})
  end

  test "child handshake errors remain visible in sessions", ctx do
    assert {:ok, _} =
             launch(ctx, %{
               "fakeMode" => "reverse",
               "childConfiguration" => %{"fakeMode" => "fail_launch", "program" => "child"}
             })

    assert_eventually(fn ->
      {:ok, %{snapshot: snapshot}} = call(ctx.key, %{action: "sessions"})
      match?([%{status: :terminated, error: "cannot launch: boom"}], snapshot.children)
    end)
  end

  test "parent termination also stops a child stuck in its initialize handshake", ctx do
    assert {:ok, _} =
             launch(ctx, %{
               "fakeMode" => "reverse",
               "childConfiguration" => %{"fakeMode" => "no_initialized", "program" => "child"}
             })

    parent = SessionServer.whereis(ctx.key)
    {_, %{children: children}} = :sys.get_state(parent)
    [child] = Map.values(children)
    ref = Process.monitor(child)
    assert {:ok, _} = call(ctx.key, %{action: "terminate"})
    assert_receive {:DOWN, ^ref, :process, ^child, _}, 5_000
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

  test "the owner exiting during post-termination disposal stops the server", ctx do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, %{state: :stopped}} =
             launch(ctx, %{"fakeMode" => "hold_disconnect"}, owner: owner)

    server = SessionServer.whereis(ctx.key)
    ref = Process.monitor(server)

    # The program runs to completion; disposal then waits on a disconnect the
    # adapter never answers, and the owner exits inside that wait.
    task = Task.async(fn -> call(ctx.key, %{action: "continue"}, owner: owner) end)

    assert_eventually(fn -> Enum.any?(commands(ctx.log), &match?({"disconnect", _}, &1)) end,
      timeout: 5_000
    )

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 5_000
    assert {:ok, %{state: :terminated}} = Task.await(task, 5_000)

    # No lease is left behind: a later turn starts its own session.
    assert_eventually(fn -> SessionServer.whereis(ctx.key) == nil end, timeout: 5_000)
    next_owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> send(next_owner, :stop) end)
    assert {:ok, %{state: :stopped}} = launch(ctx, %{}, owner: next_owner)
  end

  test "continue reports a timeout while the program keeps running, then pause stops it", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx, %{"fakeMode" => "hang"})

    assert {:ok, %{state: :running, timed_out: true, snapshot: %{status: :running}}} =
             call(ctx.key, %{action: "continue"}, timeout_ms: 300)

    assert {:ok, %{state: :stopped, snapshot: %{stop_reason: "pause"}}} =
             call(ctx.key, %{action: "pause"})
  end

  test "an aborted wait returns promptly and keeps the session", ctx do
    assert {:ok, %{state: :stopped, snapshot: %{id: id, process_id: debuggee}}} =
             launch(ctx, %{"fakeMode" => "hang"})

    signal = AbortSignal.new()
    server = SessionServer.whereis(ctx.key)
    :erlang.trace(server, true, [:receive, {:tracer, self()}])

    task =
      Task.async(fn ->
        call(ctx.key, %{action: "continue"}, timeout_ms: 30_000, signal: signal)
      end)

    assert_receive {:trace, ^server, :receive,
                    {:dap, _client, {:response, _seq, %{"command" => "continue"}}}},
                   5_000

    :erlang.trace(server, false, [:receive])
    AbortSignal.abort(signal)

    assert {:aborted, _message} = Task.await(task, 5_000)

    assert {:ok, %{snapshot: %{id: ^id, process_id: ^debuggee}}} =
             call(ctx.key, %{action: "status"})
  end

  test "an abort notification wakes the DAP wait without waiting for its deadline", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx, %{"fakeMode" => "hang"})
    signal = AbortSignal.new()
    server = SessionServer.whereis(ctx.key)
    :erlang.trace(server, true, [:receive, {:tracer, self()}])

    task =
      Task.async(fn ->
        call(ctx.key, %{action: "continue"}, timeout_ms: 30_000, signal: signal)
      end)

    assert_receive {:trace, ^server, :receive,
                    {:dap, _client, {:response, _seq, %{"command" => "continue"}}}},
                   5_000

    :erlang.trace(server, false, [:receive])
    send(server, {:lemon_abort, signal, :abort})

    assert {:aborted, _message} = Task.await(task, 5_000)
    refute AbortSignal.aborted?(signal)
    assert {:ok, %{snapshot: %{status: :running}}} = call(ctx.key, %{action: "status"})
  end

  test "the invocation caller is monitored until its blocked operation ends", ctx do
    assert {:ok, %{state: :stopped}} = launch(ctx, %{"fakeMode" => "hang"})
    server = SessionServer.whereis(ctx.key)
    :erlang.trace(server, true, [:receive, {:tracer, self()}])

    caller =
      spawn(fn ->
        call(ctx.key, %{action: "continue"}, timeout_ms: 30_000)
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)

    assert_receive {:trace, ^server, :receive,
                    {:dap, _client, {:response, _seq, %{"command" => "continue"}}}},
                   5_000

    :erlang.trace(server, false, [:receive])
    assert {:monitors, monitors} = Process.info(server, :monitors)
    assert {:process, caller} in monitors

    Process.exit(caller, :kill)

    assert {:ok, %{snapshot: %{status: :running}}} =
             call(ctx.key, %{action: "status"}, timeout_ms: 500)

    # Status no longer waits for the cancelled mutating operation to unwind.
    # The next mutating action is the barrier for its monitor cleanup.
    assert {:ok, %{state: :stopped}} = call(ctx.key, %{action: "pause"})
    assert {:monitors, monitors} = Process.info(server, :monitors)
    refute {:process, caller} in monitors
  end

  test "a WASM host deadline releases a blocked debug server without cancelling siblings", ctx do
    alias CodingAgent.Session.WasmBridge
    alias LemonAgent.Types.AgentTool

    # Match the Session GenServer that owns these linked host workers.
    Process.flag(:trap_exit, true)

    assert {:ok, %{state: :stopped}} = launch(ctx, %{"fakeMode" => "hang"})
    parent = AbortSignal.new()
    test_pid = self()

    tool = %AgentTool{
      name: "debug",
      description: "debug fixture",
      parameters: %{},
      execute: fn _, _, signal, _ ->
        send(test_pid, {:invocation_signal, signal})
        call(ctx.key, %{action: "continue"}, timeout_ms: 30_000, signal: signal)
      end
    }

    state = %{
      wasm_host_calls: %{},
      wasm_tool_names: [],
      tool_catalog: %{"debug" => %{tool: tool, source: :native}},
      session_manager: CodingAgent.SessionManager.new(ctx.cwd),
      plan_gate: CodingAgent.Session.Planning.new_gate(),
      cwd: ctx.cwd,
      run_id: nil,
      session_key: nil,
      agent_id: nil,
      approval_context: %{}
    }

    tag = make_ref()

    context = %{
      owner: self(),
      signal: parent,
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

    assert {:noreply, state} =
             WasmBridge.start_host_call(state, {self(), tag}, "debug", "{}", context)

    assert_receive {:invocation_signal, signal}, 1_000
    assert_eventually(fn -> Enum.any?(commands(ctx.log), &match?({"continue", _}, &1)) end)
    [{ref, request}] = Map.to_list(state.wasm_host_calls)
    Process.cancel_timer(request.timer)
    request = %{request | deadline: System.monotonic_time(:millisecond) - 1}
    state = %{state | wasm_host_calls: %{ref => request}}
    assert %{wasm_host_calls: calls} = WasmBridge.check_host_call(state, ref)
    assert calls == %{}
    assert_receive {^tag, {:error, :timeout}}, 1_000
    refute AbortSignal.aborted?(parent)
    assert AbortSignal.aborted?(signal)

    # The independently supervised server must not keep waiting for 30 seconds
    # after the host worker exits and its invocation signal is cancelled.
    assert {:ok, %{snapshot: %{status: :running}}} =
             call(ctx.key, %{action: "status"}, timeout_ms: 500, signal: parent)

    assert {:ok, %{state: :stopped}} =
             call(ctx.key, %{action: "pause"}, timeout_ms: 500, signal: parent)
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
    assert_eventually(fn -> not os_alive?(debuggee) end, timeout: 5_000)
    assert {"disconnect", %{"terminateDebuggee" => true}} = List.last(commands(ctx.log))

    assert {:ok, %{snapshot: %{breakpoints: [%{line: 4}]}}} = call(ctx.key, %{action: "status"})

    # A fresh launch reuses the persisted breakpoints.
    assert {:ok, %{state: :stopped, snapshot: %{line: 4}}} = launch(ctx)
  end

  test "the owning coding session exiting kills the adapter and debuggee", ctx do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    assert {:ok, %{snapshot: %{process_id: debuggee}}} = launch(ctx, %{}, owner: owner)
    server = SessionServer.whereis(ctx.key)
    ref = Process.monitor(server)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^ref, :process, ^server, _}, 5_000
    assert_eventually(fn -> not os_alive?(debuggee) end, timeout: 5_000)
  end

  test "adapter crash kills a launched debuggee even after reparenting", ctx do
    assert {:ok, %{snapshot: %{process_id: debuggee}}} = launch(ctx)
    assert os_alive?(debuggee)
    assert {:error, _} = call(ctx.key, %{action: "custom_request", command: "crash"})
    assert_eventually(fn -> not os_alive?(debuggee) end, timeout: 5_000)
    assert {:ok, %{snapshot: %{status: :terminated}}} = call(ctx.key, %{action: "status"})
  end

  test "an adapter-reported pid is never signalled when the adapter dies", ctx do
    # A foreign process leading its own process group, unrelated to the adapter.
    # Port children already lead their own session (and group); Linux refuses
    # `setpgrp()` to a session leader with EPERM.
    script = """
    import os, time
    if os.getpgrp() != os.getpid():
        os.setpgrp()
    print('ready', flush=True)
    time.sleep(300)
    """

    foreign_port = Port.open({:spawn_executable, @python}, [:binary, args: ["-c", script]])

    assert_receive {^foreign_port, {:data, "ready" <> _}}, 5_000
    {:os_pid, foreign} = Port.info(foreign_port, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(foreign)]) end)

    assert {:ok, %{snapshot: %{process_id: ^foreign}}} =
             launch(ctx, %{"reportedPid" => foreign})

    assert {:error, _} = call(ctx.key, %{action: "custom_request", command: "crash"})
    assert {:ok, %{snapshot: %{status: :terminated}}} = call(ctx.key, %{action: "status"})
    Process.sleep(300)
    assert os_alive?(foreign)
  end

  test "adapter-requested descendants share one budget per root across generations", ctx do
    grandchild = %{"program" => "grandchild", "stopOnEntry" => true}

    child = %{
      "program" => "child",
      "stopOnEntry" => true,
      "fakeMode" => "reverse",
      "childCount" => 10,
      "childConfiguration" => grandchild
    }

    assert {:ok, _} =
             launch(ctx, %{
               "fakeMode" => "reverse",
               "childCount" => 4,
               "childConfiguration" => child
             })

    responses = fn ->
      ctx.log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(&match?(%{"reverse_response" => "startDebugging"}, &1))
    end

    # Root: 4 requests; each accepted child: 10 more (44 in total).
    assert_eventually(fn -> length(responses.()) == 44 end, timeout: 15_000)
    {accepted, rejected} = Enum.split_with(responses.(), & &1["success"])
    assert length(accepted) == 16
    assert length(rejected) == 28

    assert {:ok, _} = call(ctx.key, %{action: "terminate"})

    # Tearing the tree down returns the budget.
    {_, %{descendants: budget}} = :sys.get_state(SessionServer.whereis(ctx.key))
    assert_eventually(fn -> Enum.all?(1..16, &(:atomics.get(budget, &1) == 0)) end)
  end

  test "a descendant slot is released once: child death, then parent cleanup", ctx do
    child = %{
      "program" => "child",
      "stopOnEntry" => true,
      "fakeMode" => "reverse",
      "childCount" => 2,
      "childConfiguration" => %{"program" => "grandchild", "stopOnEntry" => true}
    }

    assert {:ok, _} =
             launch(ctx, %{
               "fakeMode" => "reverse",
               "childCount" => 2,
               "childConfiguration" => child
             })

    root = SessionServer.whereis(ctx.key)
    {_, %{descendants: budget}} = :sys.get_state(root)

    in_use = fn -> Enum.count(1..16, &(:atomics.get(budget, &1) != 0)) end

    assert_eventually(fn -> in_use.() == 6 end, timeout: 15_000)

    {_, %{children: root_children}} = :sys.get_state(root)
    [branch | _] = root_children |> Map.values() |> Enum.sort()
    assert_eventually(fn -> map_size(elem(:sys.get_state(branch), 1).children) == 2 end)
    {_, %{children: grandchildren, session: %{client: client}}} = :sys.get_state(branch)
    [doomed | _] = Map.values(grandchildren)

    # The grandchild dies on its own, then its parent's adapter exits.
    :ok = :gen_statem.stop(doomed)
    assert in_use.() == 5
    Client.stop(client)
    assert_eventually(fn -> map_size(elem(:sys.get_state(branch), 1).children) == 0 end)

    # Two children plus the other branch's two grandchildren remain.
    assert_eventually(fn -> in_use.() == 4 end)
    Process.sleep(200)
    assert in_use.() == 4
  end

  test "a killed child's slot is released by parent cleanup and reused", ctx do
    child = %{
      "program" => "child",
      "stopOnEntry" => true,
      "fakeMode" => "reverse",
      "childCount" => 2,
      "childConfiguration" => %{"program" => "grandchild", "stopOnEntry" => true}
    }

    assert {:ok, _} =
             launch(ctx, %{
               "fakeMode" => "reverse",
               "childCount" => 2,
               "childConfiguration" => child
             })

    root = SessionServer.whereis(ctx.key)
    {_, %{descendants: budget}} = :sys.get_state(root)
    in_use = fn -> Enum.count(1..16, &(:atomics.get(budget, &1) != 0)) end
    assert_eventually(fn -> in_use.() == 6 end, timeout: 15_000)

    {_, %{children: root_children}} = :sys.get_state(root)
    [branch | _] = root_children |> Map.values() |> Enum.sort()
    assert_eventually(fn -> map_size(elem(:sys.get_state(branch), 1).children) == 2 end)
    {_, %{children: grandchildren, session: %{client: client}}} = :sys.get_state(branch)
    [doomed | _] = Map.values(grandchildren)

    # Forced termination: the grandchild never runs terminate/3.
    ref = Process.monitor(doomed)
    Process.exit(doomed, :kill)
    assert_receive {:DOWN, ^ref, _, _, :killed}
    assert in_use.() == 6

    Client.stop(client)
    assert_eventually(fn -> in_use.() == 4 end)

    assert {:ok, _} = call(ctx.key, %{action: "terminate"})
    assert_eventually(fn -> in_use.() == 0 end)

    # The full budget is available again.
    File.write!(ctx.log, "")
    assert {:ok, _} = launch(ctx, %{"fakeMode" => "reverse", "childCount" => 16})

    assert_eventually(fn ->
      ctx.log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.count(&match?(%{"reverse_response" => "startDebugging", "success" => true}, &1))
      |> Kernel.==(16)
    end)
  end

  test "the global debug supervisor has a finite child limit" do
    assert %{max_children: limit} = :sys.get_state(CodingAgent.Debug.Supervisor)
    assert is_integer(limit) and limit > 0
  end

  test "an idle server stops and kills its adapter", ctx do
    assert {:ok, %{snapshot: %{process_id: debuggee}}} = launch(ctx, %{}, idle_timeout_ms: 300)
    server = SessionServer.whereis(ctx.key)
    ref = Process.monitor(server)

    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 5_000
    assert_eventually(fn -> not os_alive?(debuggee) end, timeout: 5_000)
  end

  test "read-only actions without a server do not start one", ctx do
    assert {:none, _} = call(ctx.key, %{action: "status"})
    assert {:none, message} = call(ctx.key, %{action: "stack_trace"})
    assert message =~ "No active debug session"
    assert SessionServer.whereis(ctx.key) == nil
  end
end
