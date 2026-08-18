defmodule CodingAgent.PythonRepl.SessionTest do
  @moduledoc """
  Worker-level tests for `CodingAgent.PythonRepl.Session`.

  The process, protocol, and output boundaries are replaced by injectable
  fakes (`FakeProcess`, `FakeProtocol`, `FakeOutput`) so every safety
  property of the state machine is exercised deterministically: cell
  serialization, bounded queueing, queued vs active caller death, active
  timeout with interrupt escalation, protocol faults, the no-replay rule,
  and full cleanup of process tree and workspace.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.PythonRepl
  alias CodingAgent.PythonRepl.{Key, Registry, Session}
  alias CodingAgent.Tools.ExecuteCode.PythonShim

  defmodule FakeProcess do
    @moduledoc false
    # Records every boundary call and lets tests emit port messages and
    # flip liveness. One unlinked named Agent per test (reset in setup).
    use Agent

    def reset do
      if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
      {:ok, _} = Agent.start(fn -> %{calls: [], procs: %{}, last: nil} end, name: __MODULE__)
      :ok
    end

    ## Session-facing API

    def start(opts) do
      port = make_ref()

      Agent.update(__MODULE__, fn st ->
        %{
          st
          | calls: [{:start, opts} | st.calls],
            procs: Map.put(st.procs, port, %{dead: false}),
            last: port
        }
      end)

      {:ok, %{port: port}}
    end

    def port(proc), do: proc.port

    def write(proc, data) do
      record({:write, proc.port, IO.iodata_to_binary(data)})
      :ok
    end

    def interrupt(proc) do
      record({:interrupt, proc.port})
      :ok
    end

    def terminate_tree(proc) do
      record({:terminate_tree, proc.port})

      Agent.update(__MODULE__, fn st ->
        %{st | procs: Map.put(st.procs, proc.port, %{dead: true})}
      end)

      :ok
    end

    def alive?(proc) do
      Agent.get(__MODULE__, fn st -> get_in(st, [:procs, proc.port, :dead]) != true end)
    end

    ## Test helpers

    def proc do
      Agent.get(__MODULE__, fn st -> %{port: st.last} end)
    end

    def calls, do: Agent.get(__MODULE__, fn st -> Enum.reverse(st.calls) end)

    def writes, do: calls() |> Enum.filter(&match?({:write, _, _}, &1)) |> Enum.map(&elem(&1, 2))

    def start_opts do
      Enum.find_value(calls(), fn
        {:start, opts} -> opts
        _other -> nil
      end)
    end

    def interrupted?, do: Enum.any?(calls(), &match?({:interrupt, _}, &1))

    def terminated?, do: Enum.any?(calls(), &match?({:terminate_tree, _}, &1))

    def emit(session, proc, data), do: send(session, {proc.port, {:data, data}})

    def emit_link_exit(session, proc, reason), do: send(session, {:EXIT, proc.port, reason})

    def emit_exit(session, proc, status),
      do: send(session, {proc.port, {:exit_status, status}})

    defp record(call) do
      Agent.update(__MODULE__, fn st -> %{st | calls: [call | st.calls]} end)
    end
  end

  defmodule FakeProtocol do
    @moduledoc false
    # Scripted responses: every feed pops the next scripted response, which
    # is an {:ok, proto, frames} tuple or an {:error, reason} tuple. An empty
    # script produces no frames.
    use Agent

    def reset do
      if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
      {:ok, _} = Agent.start(fn -> [] end, name: __MODULE__)
      :ok
    end

    def script(responses) do
      Agent.update(__MODULE__, fn _ -> Enum.to_list(responses) end)
    end

    ## Session-facing API

    def new, do: {:ok, %{fake: true}, []}

    def feed(_proto, _data) do
      Agent.get_and_update(__MODULE__, fn
        [] ->
          {{:ok, %{fake: true}, []}, []}

        [{:ok, frames} | rest] ->
          {{:ok, %{fake: true}, frames}, rest}

        [{:error, reason} | rest] ->
          {{:error, reason}, rest}
      end)
    end
  end

  defmodule FakeOutput do
    @moduledoc false
    # Pure in-memory output accumulator matching the Output contract.
    def new(max_bytes), do: %{max: max_bytes, chunks: []}

    def append(out, stream, data), do: %{out | chunks: [{stream, data} | out.chunks]}

    def finish(out) do
      chunks = Enum.reverse(out.chunks)

      joined = IO.iodata_to_binary(for {_stream, data} <- chunks, do: data)
      total = byte_size(joined)
      truncated = total > out.max

      %{
        output: if(truncated, do: binary_part(joined, 0, out.max), else: joined),
        truncated: truncated,
        total_bytes: total,
        stdout_bytes: byte_size_for(chunks, :stdout),
        stderr_bytes: byte_size_for(chunks, :stderr),
        full_output_path: nil
      }
    end

    defp byte_size_for(chunks, stream) do
      chunks
      |> Enum.filter(&match?({^stream, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> IO.iodata_to_binary()
      |> byte_size()
    end
  end

  defmodule RegistrySession do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def status(pid), do: GenServer.call(pid, :status)
    def options(pid), do: GenServer.call(pid, :options)
    def set_phase(pid, phase), do: GenServer.call(pid, {:set_phase, phase})

    def execute(pid, _request, _timeout) do
      GenServer.call(pid, :execute)
    end

    def shutdown(pid, timeout), do: GenServer.stop(pid, :shutdown, timeout)

    @impl true
    def init(opts), do: {:ok, %{opts: opts, phase: :idle}}

    @impl true
    def handle_call(:status, _from, state) do
      active_request_id = if state.phase == :idle, do: nil, else: "replacement"

      {:reply,
       %{
         phase: state.phase,
         generation: Keyword.fetch!(state.opts, :generation),
         key: Keyword.fetch!(state.opts, :key),
         queue_depth: 0,
         active_request_id: active_request_id,
         cells_completed: 0,
         process_alive: true
       }, state}
    end

    def handle_call(:options, _from, state), do: {:reply, state.opts, state}

    def handle_call({:set_phase, phase}, _from, state),
      do: {:reply, :ok, %{state | phase: phase}}

    def handle_call(:execute, _from, state),
      do: {:reply, {:ok, %{state_retained: true, duration_ms: 0}}, state}
  end

  setup do
    FakeProcess.reset()
    FakeProtocol.reset()

    runner =
      Path.join(
        System.tmp_dir!(),
        "session-test-runner-#{System.unique_integer([:positive])}.py"
      )

    File.write!(runner, "# session test runner stub\n")

    on_exit(fn ->
      File.rm(runner)
      if pid = Process.whereis(FakeProcess), do: Agent.stop(pid)
      if pid = Process.whereis(FakeProtocol), do: Agent.stop(pid)
    end)

    {:ok, runner: runner, helper_source: "# session helper stub\n"}
  end

  defp start_session(ctx, opts \\ []) do
    defaults = [
      key: {:scope, "scope-1"},
      cwd: "/tmp",
      interpreter: "python3",
      runner_path: ctx.runner,
      helper_source: ctx.helper_source,
      startup_timeout_ms: 500,
      bye_timeout_ms: 150,
      interrupt_grace_ms: 100,
      process_mod: FakeProcess,
      protocol_mod: FakeProtocol,
      output_mod: FakeOutput
    ]

    {:ok, pid} = Session.start_link(Keyword.merge(defaults, opts))
    Process.unlink(pid)

    on_exit(fn ->
      ref = Process.monitor(pid)
      if Process.alive?(pid), do: spawn(fn -> Session.shutdown(pid, 2_000) end)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        2_500 -> raise "Session cleanup timed out for #{inspect(pid)}"
      end
    end)

    pid
  end

  defp bring_idle(pid) do
    FakeProtocol.script([{:ok, [%{type: :ready, pid: 42_001}]}])
    FakeProcess.emit(pid, FakeProcess.proc(), "ready")
    :idle = Session.status(pid).phase
    pid
  end

  defp active_id(pid) do
    Session.status(pid).active_request_id
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk(
          "condition was not met within #{deadline - System.monotonic_time(:millisecond) + 2_000}ms"
        )
      else
        Process.sleep(5)
        wait_loop(fun, deadline)
      end
    end
  end

  defp monitor(pid), do: Process.monitor(pid)

  defp assert_stops(pid, ref, expected_reason \\ :any) do
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 2_000

    if expected_reason != :any do
      assert reason == expected_reason
    end

    refute Process.alive?(pid)
  end

  defp pyrepl_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, "lemon-pyrepl-"))
    |> MapSet.new()
  end

  defp assert_no_workspace_leak(before) do
    leak = pyrepl_dirs() |> MapSet.difference(before)
    assert MapSet.size(leak) == 0, "leaked workspaces: #{inspect(MapSet.to_list(leak))}"
  end

  defp eval_writes_containing(code) do
    FakeProcess.writes() |> Enum.filter(&String.contains?(&1, Jason.encode!(code)))
  end

  describe "helper staging" do
    test "stages an authority-free module with owner-only permissions and removes it", ctx do
      before = pyrepl_dirs()
      source = PythonShim.render_module(["read"])

      assert PythonShim.render_prelude(["read"]) == source
      assert String.contains?(source, "_RPC_DIR = None")
      assert String.contains?(source, "_TOKEN = None")

      pid = start_session(ctx, helper_source: source)
      workspace = FakeProcess.start_opts() |> Keyword.fetch!(:cwd)
      helper_path = Path.join(workspace, "lemon_tools.py")

      assert File.read!(helper_path) == source
      assert Bitwise.band(File.stat!(workspace).mode, 0o777) == 0o700
      assert Bitwise.band(File.stat!(helper_path).mode, 0o777) == 0o600

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)

      refute File.exists?(workspace)
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
    end

    test "the real runner imports the staged module and rotates bridge authority per cell" do
      before = pyrepl_dirs()
      interpreter = System.find_executable("python3") || flunk("python3 is required")
      runner = Application.app_dir(:coding_agent, "priv/python_repl/runner.py")
      source = PythonShim.render_module(["read"])

      {:ok, pid} =
        Session.start_link(
          key: {:scope, "real-helper"},
          cwd: System.tmp_dir!(),
          interpreter: interpreter,
          runner_path: runner,
          helper_source: source,
          startup_timeout_ms: 3_000
        )

      Process.unlink(pid)

      on_exit(fn ->
        if Process.alive?(pid), do: Session.shutdown(pid, 2_000)
      end)

      first_dir = Path.join(System.tmp_dir!(), "bridge-first")
      second_dir = Path.join(System.tmp_dir!(), "bridge-second")

      first_code = """
      import lemon_tools
      assert lemon_tools._RPC_DIR == #{Jason.encode!(first_dir)}
      assert lemon_tools._TOKEN == "first-token"
      print("first")
      """

      second_code = """
      import lemon_tools
      assert lemon_tools._RPC_DIR == #{Jason.encode!(second_dir)}
      assert lemon_tools._TOKEN == "second-token"
      print("second")
      """

      assert {:ok, %{output: "first\n", cells_completed: 1}} =
               Session.execute(
                 pid,
                 %{code: first_code, bridge: %{dir: first_dir, token: "first-token"}},
                 2_000
               )

      assert {:ok, %{output: "second\n", cells_completed: 2}} =
               Session.execute(
                 pid,
                 %{code: second_code, bridge: %{dir: second_dir, token: "second-token"}},
                 2_000
               )

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)
      assert_no_workspace_leak(before)
    end

    test "facade and registry propagate helper source to a replacement worker" do
      supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

      registry =
        start_supervised!(
          {Registry,
           name: nil,
           session_supervisor: supervisor,
           session_mod: RegistrySession,
           idle_timeout_ms: :infinity}
        )

      key = %Key{
        scope_id: "scope",
        agent_id: "agent",
        cwd: System.tmp_dir!(),
        interpreter: System.find_executable("python3") || "python3",
        helpers: ["read"],
        protocol_version: 1,
        digest: "helper-source-test"
      }

      source = PythonShim.render_module(key.helpers)

      request = [
        registry: registry,
        key: key,
        owner_pid: self(),
        code: "pass",
        timeout_ms: 100,
        helper_source: source
      ]

      assert {:ok, %{kernel_reused: false}} = PythonRepl.execute(request)

      {:ok, first} = Registry.acquire(registry, key, self())
      assert Keyword.fetch!(RegistrySession.options(first.pid), :helper_source) == source
      assert :ok = Registry.release(registry, first.lease)
      assert :ok = RegistrySession.set_phase(first.pid, :stopping)

      assert {:ok, %{kernel_reused: false}} = PythonRepl.execute(request)

      {:ok, replacement} = Registry.acquire(registry, key, self())
      assert replacement.pid != first.pid
      assert Keyword.fetch!(RegistrySession.options(replacement.pid), :helper_source) == source
      assert :ok = Registry.release(registry, replacement.lease)
    end
  end

  describe "boot and serialization" do
    test "boots through ready and serializes cells in FIFO order", ctx do
      pid = start_session(ctx)

      assert %{phase: :starting, process_alive: true, queue_depth: 0} = Session.status(pid)

      assert [init] = FakeProcess.writes()
      assert String.contains?(init, ~s("type":"init"))
      assert String.contains?(init, ~s("cwd":"/tmp"))

      bring_idle(pid)

      task_a = Task.async(fn -> Session.execute(pid, %{code: "a=1"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)
      assert [_] = eval_writes_containing("a=1")

      task_b = Task.async(fn -> Session.execute(pid, %{code: "b=2"}, :infinity) end)
      wait_until(fn -> Session.status(pid).queue_depth == 1 end)
      # B stays queued: its code was never written to the interpreter.
      assert [] = eval_writes_containing("b=2")

      FakeProtocol.script([
        {:ok,
         [
           %{type: :started, id: "cell-1"},
           %{type: :stream, id: "cell-1", stream: :stdout, data: "hello "},
           %{type: :stream, id: "cell-1", stream: :stderr, data: "warn"},
           %{type: :done, id: "cell-1"}
         ]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "cell-1-frames")

      assert {:ok, result} = Task.await(task_a)
      assert result.output == "hello warn"
      assert result.state_retained == true
      assert result.truncated == false
      assert result.total_bytes == 10
      assert result.stdout_bytes == 6
      assert result.stderr_bytes == 4
      assert result.cells_completed == 1

      # B is dispatched only after A completed.
      wait_until(fn -> active_id(pid) == "cell-2" end)
      assert [_] = eval_writes_containing("b=2")

      FakeProtocol.script([
        {:ok, [%{type: :started, id: "cell-2"}, %{type: :done, id: "cell-2"}]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "cell-2-frames")

      assert {:ok, result_b} = Task.await(task_b)
      assert result_b.cells_completed == 2

      assert %{phase: :idle, cells_completed: 2, queue_depth: 0} = Session.status(pid)

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)
    end
  end

  describe "queueing" do
    test "queue full rejects the caller without disturbing the kernel", ctx do
      pid = start_session(ctx, max_queued_cells: 1) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "a=1"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      task_b = Task.async(fn -> Session.execute(pid, %{code: "b=2"}, :infinity) end)
      wait_until(fn -> Session.status(pid).queue_depth == 1 end)

      assert {:error, %{reason: :queue_full, state_retained: true}} =
               Session.execute(pid, %{code: "c=3"}, :infinity)

      assert %{phase: :running, queue_depth: 1} = Session.status(pid)

      Task.shutdown(task_b)
      Task.shutdown(task_a, :brutal_kill)

      ref = monitor(pid)
      Session.shutdown(pid)
      assert_stops(pid, ref)
    end

    test "death of a queued caller removes only its own request", ctx do
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "a=1"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([{:ok, [%{type: :started, id: "cell-1"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "started-1")

      task_b = Task.async(fn -> Session.execute(pid, %{code: "b=2"}, :infinity) end)
      wait_until(fn -> Session.status(pid).queue_depth == 1 end)

      caller_pid = task_b.pid
      Process.unlink(caller_pid)
      caller_ref = Process.monitor(caller_pid)
      Process.exit(caller_pid, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :killed}
      wait_until(fn -> Session.status(pid).queue_depth == 0 end)

      # The active cell is undisturbed and still completes normally.
      FakeProtocol.script([{:ok, [%{type: :done, id: "cell-1"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "done-1")
      assert {:ok, _} = Task.await(task_a)

      # The worker survives and serves a later cell.
      task_c = Task.async(fn -> Session.execute(pid, %{code: "c=3"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-2" end)

      FakeProtocol.script([
        {:ok, [%{type: :started, id: "cell-2"}, %{type: :done, id: "cell-2"}]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "cell-2-frames")
      assert {:ok, _} = Task.await(task_c)

      assert %{phase: :idle, cells_completed: 2} = Session.status(pid)

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)
    end
  end

  describe "active caller death" do
    test "discards the interpreter, stops the worker, and cleans up", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "loop_forever()"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([{:ok, [%{type: :started, id: "cell-1"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "started-1")

      ref = monitor(pid)
      caller_pid = task_a.pid
      Process.unlink(caller_pid)
      caller_ref = Process.monitor(caller_pid)
      Process.exit(caller_pid, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller_pid, :killed}

      # Interrupt + shutdown request go out; the runner quiesces then byes.
      wait_until(fn -> FakeProcess.interrupted?() end)

      FakeProtocol.script([
        {:ok,
         [
           %{type: :exception, id: "cell-1", kind: :interrupted, name: "KeyboardInterrupt"},
           %{type: :done, id: "cell-1"}
         ]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "quiesce")

      wait_until(fn ->
        Enum.any?(FakeProcess.writes(), &String.contains?(&1, ~s("type":"shutdown")))
      end)

      FakeProtocol.script([{:ok, [%{type: :bye}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "bye")

      assert_stops(pid, ref)
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
    end
  end

  describe "active timeout" do
    test "returns partial output, discards state, and never replays the cell", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx, interrupt_grace_ms: 100) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "slow()"}, 60) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([
        {:ok,
         [
           %{type: :started, id: "cell-1"},
           %{type: :stream, id: "cell-1", stream: :stdout, data: "partial "}
         ]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "started-1")

      ref = monitor(pid)
      assert {:error, result} = Task.await(task_a, 1_000)
      assert result.reason == :timeout
      assert result.state_retained == false
      assert result.output == "partial "

      # The code was written exactly once and is never replayed.
      assert [_] = eval_writes_containing("slow()")
      wait_until(fn -> FakeProcess.interrupted?() end)

      # Grace expires without a terminal frame: TERM/KILL tree teardown.
      assert_stops(pid, ref)
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
      assert [_] = eval_writes_containing("slow()")
    end

    test "is graceful when the interrupted cell quiesces during grace", ctx do
      pid = start_session(ctx, interrupt_grace_ms: 300, bye_timeout_ms: 200) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "slow()"}, 60) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([{:ok, [%{type: :started, id: "cell-1"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "started-1")

      ref = monitor(pid)

      assert {:error, result} = Task.await(task_a, 1_000)
      assert result.reason == :timeout

      wait_until(fn -> FakeProcess.interrupted?() end)

      FakeProtocol.script([
        {:ok,
         [
           %{type: :exception, id: "cell-1", kind: :interrupted, name: "KeyboardInterrupt"},
           %{type: :done, id: "cell-1"}
         ]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "quiesce")

      wait_until(fn ->
        Enum.any?(FakeProcess.writes(), &String.contains?(&1, ~s("type":"shutdown")))
      end)

      FakeProtocol.script([{:ok, [%{type: :bye}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "bye")

      assert_stops(pid, ref)
      assert FakeProcess.terminated?()
    end
  end

  describe "protocol faults" do
    test "feed error fails active and queued callers and destroys the worker", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "a=1"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      task_b = Task.async(fn -> Session.execute(pid, %{code: "b=2"}, :infinity) end)
      wait_until(fn -> Session.status(pid).queue_depth == 1 end)

      ref = monitor(pid)
      FakeProtocol.script([{:error, :bad_prefix}])
      FakeProcess.emit(pid, FakeProcess.proc(), "garbage")

      assert {:error, result_a} = Task.await(task_a, 1_000)
      assert result_a.reason == :protocol_fault
      assert result_a.state_retained == false

      assert {:error, result_b} = Task.await(task_b, 1_000)
      assert result_b.reason == :protocol_fault
      assert result_b.state_retained == false

      assert_stops(pid, ref)
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
      # The started code was never replayed anywhere.
      assert [_] = eval_writes_containing("a=1")
    end

    test "frames with a wrong request id are faults", ctx do
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "a=1"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      ref = monitor(pid)
      FakeProtocol.script([{:ok, [%{type: :started, id: "cell-999"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "wrong-id")

      assert {:error, result} = Task.await(task_a, 1_000)
      assert result.reason == :protocol_fault
      assert_stops(pid, ref)
    end

    test "fatal frames are faults", ctx do
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "a=1"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      ref = monitor(pid)
      FakeProtocol.script([{:ok, [%{type: :fatal, reason: "boom"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "fatal")

      assert {:error, result} = Task.await(task_a, 1_000)
      assert result.reason == :protocol_fault
      assert_stops(pid, ref)
    end
  end

  describe "port death" do
    test "fails all callers, cleans up, and never replays", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "os._exit(1)"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([{:ok, [%{type: :started, id: "cell-1"}]}])
      FakeProcess.emit(pid, FakeProcess.proc(), "started-1")

      ref = monitor(pid)
      FakeProcess.emit_exit(pid, FakeProcess.proc(), 1)

      assert {:error, result} = Task.await(task_a, 1_000)
      assert result.reason == :port_exit
      assert result.state_retained == false

      assert_stops(pid, ref)
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
      assert [_] = eval_writes_containing("os._exit(1)")
    end

    test "ignores exits unrelated to its owned port", ctx do
      pid = start_session(ctx) |> bring_idle()
      unrelated = spawn(fn -> Process.sleep(:infinity) end)
      unrelated_ref = Process.monitor(unrelated)

      send(pid, {:EXIT, unrelated, :caller_died})
      assert %{phase: :idle, process_alive: true} = Session.status(pid)

      Process.exit(unrelated, :kill)
      assert_receive {:DOWN, ^unrelated_ref, :process, ^unrelated, :killed}

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref, :shutdown)
    end

    test "an owned port link exit is fatal", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx) |> bring_idle()

      task = Task.async(fn -> Session.execute(pid, %{code: "os._exit(1)"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      ref = monitor(pid)
      FakeProcess.emit_link_exit(pid, FakeProcess.proc(), :normal)

      assert {:error, %{reason: :port_exit, state_retained: false}} = Task.await(task, 1_000)
      assert_stops(pid, ref, {:shutdown, {:port_exit, nil}})
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
      assert [_] = eval_writes_containing("os._exit(1)")
    end
  end

  describe "state retention" do
    test "ordinary exceptions retain state and keep the worker", ctx do
      pid = start_session(ctx) |> bring_idle()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "raise ValueError"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([
        {:ok,
         [
           %{type: :started, id: "cell-1"},
           %{type: :stream, id: "cell-1", stream: :stdout, data: "before "},
           %{
             type: :exception,
             id: "cell-1",
             kind: :error,
             name: "ValueError",
             message: "boom",
             traceback: "Traceback (most recent call last)"
           },
           %{type: :done, id: "cell-1"}
         ]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "cell-1-frames")

      assert {:error, result} = Task.await(task_a)
      assert result.reason == :exception
      assert result.state_retained == true
      assert result.output == "before "
      assert result.exception.name == "ValueError"
      assert result.exception.kind == :error
      assert result.exception.traceback == "Traceback (most recent call last)"

      assert %{phase: :idle, process_alive: true, cells_completed: 1} = Session.status(pid)

      # The namespace survives: the next cell runs on the same interpreter.
      task_b = Task.async(fn -> Session.execute(pid, %{code: "print(a)"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-2" end)

      FakeProtocol.script([
        {:ok, [%{type: :started, id: "cell-2"}, %{type: :done, id: "cell-2"}]}
      ])

      FakeProcess.emit(pid, FakeProcess.proc(), "cell-2-frames")
      assert {:ok, _} = Task.await(task_b)

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)
    end
  end

  describe "shutdown" do
    test "cleans process tree and workspace on an idle worker", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx) |> bring_idle()
      proc = FakeProcess.proc()

      # The runner's bye arrives while terminate/2 is waiting for it.
      FakeProtocol.script([{:ok, [%{type: :bye}]}])

      spawn(fn ->
        Process.sleep(20)
        FakeProcess.emit(pid, proc, "bye")
      end)

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)

      assert Enum.any?(FakeProcess.writes(), &String.contains?(&1, ~s("type":"shutdown")))
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
    end

    test "while running interrupts the cell, waits for quiesce, and replies interrupted", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx, interrupt_grace_ms: 300, bye_timeout_ms: 300) |> bring_idle()
      proc = FakeProcess.proc()

      task_a = Task.async(fn -> Session.execute(pid, %{code: "slow()"}, :infinity) end)
      wait_until(fn -> active_id(pid) == "cell-1" end)

      FakeProtocol.script([{:ok, [%{type: :started, id: "cell-1"}]}])
      FakeProcess.emit(pid, proc, "started-1")

      FakeProtocol.script([
        {:ok, [%{type: :exception, id: "cell-1", kind: :interrupted, name: "KeyboardInterrupt"}]},
        {:ok, [%{type: :done, id: "cell-1"}]},
        {:ok, [%{type: :bye}]}
      ])

      spawn(fn ->
        Process.sleep(15)
        FakeProcess.emit(pid, proc, "exception")
        Process.sleep(25)
        FakeProcess.emit(pid, proc, "done")
        Process.sleep(25)
        FakeProcess.emit(pid, proc, "bye")
      end)

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)

      assert {:error, result} = Task.await(task_a, 1_000)
      assert result.reason == :interrupted
      assert result.state_retained == false

      assert_stops(pid, ref)
      assert FakeProcess.interrupted?()
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
    end
  end

  describe "startup" do
    test "startup timeout fails queued callers and cleans up", ctx do
      before = pyrepl_dirs()
      pid = start_session(ctx, startup_timeout_ms: 500)

      task = Task.async(fn -> Session.execute(pid, %{code: "x=1"}, :infinity) end)

      wait_until(fn ->
        match?(%{phase: :starting, queue_depth: 1}, Session.status(pid))
      end)

      ref = monitor(pid)

      assert {:error, result} = Task.await(task, 1_000)
      assert result.reason == :startup_failed
      assert result.state_retained == false

      assert_stops(pid, ref)
      assert FakeProcess.terminated?()
      assert_no_workspace_leak(before)
    end

    test "an invalid helper source fails before process spawn and cleans the workspace", ctx do
      before = pyrepl_dirs()
      reason = {:shutdown, {:startup_failed, {:helper_stage_failed, :invalid_source}}}
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        assert {:error, ^reason} =
                 Session.start_link(
                   key: {:scope, "scope-1"},
                   cwd: "/tmp",
                   interpreter: "python3",
                   runner_path: ctx.runner,
                   helper_source: ["not", "a", "binary"],
                   startup_timeout_ms: 100,
                   process_mod: FakeProcess,
                   protocol_mod: FakeProtocol,
                   output_mod: FakeOutput
                 )
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end

      assert FakeProcess.start_opts() == nil
      assert_no_workspace_leak(before)
    end

    test "a missing runner fails the boot with startup_failed", _ctx do
      before = pyrepl_dirs()
      reason = {:shutdown, {:startup_failed, {:runner_stage_failed, :enoent}}}
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        assert {:error, ^reason} =
                 Session.start_link(
                   key: {:scope, "scope-1"},
                   cwd: "/tmp",
                   interpreter: "python3",
                   runner_path: "/nonexistent/runner.py",
                   startup_timeout_ms: 100,
                   process_mod: FakeProcess,
                   protocol_mod: FakeProtocol,
                   output_mod: FakeOutput
                 )
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end

      assert_no_workspace_leak(before)
    end
  end

  describe "request validation" do
    test "rejects invalid code and timeouts without touching the kernel", ctx do
      pid = start_session(ctx) |> bring_idle()

      assert {:error, %{reason: :invalid_request}} = Session.execute(pid, %{}, 100)
      assert {:error, %{reason: :invalid_request}} = Session.execute(pid, %{code: ""}, 100)
      assert {:error, %{reason: :invalid_request}} = Session.execute(pid, %{code: :oops}, 100)
      assert {:error, %{reason: :invalid_timeout}} = Session.execute(pid, %{code: "1"}, 0)

      assert {:error, %{reason: :invalid_request}} =
               Session.execute(pid, %{code: "1", cwd: ""}, 100)

      assert {:error, %{reason: :invalid_request}} =
               Session.execute(pid, %{code: "1", bridge: %{dir: "d"}}, 100)

      assert %{phase: :idle, cells_completed: 0} = Session.status(pid)
      assert [] = Enum.filter(FakeProcess.writes(), &String.contains?(&1, ~s("type":"eval")))

      ref = monitor(pid)
      assert :ok = Session.shutdown(pid)
      assert_stops(pid, ref)
    end
  end
end
