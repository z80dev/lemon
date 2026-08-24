defmodule CodingAgent.PythonRepl.SupervisorTest do
  @moduledoc """
  Supervision-topology tests for `CodingAgent.PythonRepl.Supervisor`.

  The real `SessionSupervisor`/`Registry` children are built in sibling
  slices, so these tests exercise the topology with injectable stand-ins
  (a real `DynamicSupervisor` in the SessionSupervisor slot, a minimal
  named GenServer in the Registry slot) under isolated names, mirroring
  the injectable-mod convention of `PythonRepl.Session`. They verify:

    * child start order and wiring (the session supervisor is up and
      registered before the registry starts, and the registry is pointed
      at its sibling), and
    * the `:one_for_all` contract: a registry crash tears down and
      restarts both children, and a live temporary `PythonRepl.Session`
      worker never survives as an orphan.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.PythonRepl.Session
  alias CodingAgent.PythonRepl.Supervisor, as: ReplSupervisor

  @sup_name __MODULE__.Sup
  @dyn_name __MODULE__.SessionSupervisor
  @registry_name __MODULE__.Registry

  defmodule StandInRegistry do
    @moduledoc false
    # Minimal registry stand-in: a plain named GenServer that records the
    # opts it was started with, plus whether its sibling session
    # supervisor was already registered when it booted (the observable
    # consequence of child start order).
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def state(server), do: GenServer.call(server, :state)

    @impl true
    def init(opts) do
      sibling = Keyword.get(opts, :session_supervisor)

      {:ok,
       %{
         opts: opts,
         sibling_alive_at_start: sibling != nil and GenServer.whereis(sibling) != nil
       }}
    end

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
  end

  defmodule StaticProcess do
    @moduledoc false
    # Worker process-boundary fake: starts, stays alive, cleans up cleanly.
    def start(_opts), do: {:ok, %{port: make_ref()}}
    def port(proc), do: proc.port
    def write(_proc, _data), do: :ok
    def interrupt(_proc), do: :ok
    def terminate_tree(_proc), do: :ok
    def alive?(_proc), do: true
  end

  defmodule StaticProtocol do
    @moduledoc false
    def new, do: {:ok, %{}, []}
    def feed(_proto, _data), do: {:ok, %{}, []}
  end

  defmodule StaticOutput do
    @moduledoc false
    def new(max_bytes), do: %{max: max_bytes, chunks: []}

    def append(out, _stream, data), do: %{out | chunks: [data | out.chunks]}

    def finish(out) do
      joined = out.chunks |> Enum.reverse() |> IO.iodata_to_binary()

      %{
        output: joined,
        truncated: false,
        total_bytes: byte_size(joined),
        stdout_bytes: 0,
        stderr_bytes: 0,
        full_output_path: nil
      }
    end
  end

  defp start_tree(opts \\ []) do
    defaults = [
      name: @sup_name,
      session_supervisor_mod: DynamicSupervisor,
      session_supervisor_opts: [name: @dyn_name, strategy: :one_for_one],
      registry_mod: StandInRegistry,
      registry_opts: [name: @registry_name]
    ]

    {:ok, sup} = ReplSupervisor.start_link(defaults ++ opts)

    on_exit(fn -> stop_test_tree() end)

    sup
  end

  defp stop_test_tree do
    case Process.whereis(@sup_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} ->
              :ok
          after
            0 ->
              Supervisor.stop(pid)
          end
        catch
          :exit, _reason ->
            :ok
        after
          Process.demonitor(ref, [:flush])
        end
    end
  end

  # Starts a real temporary Session worker under the stand-in session
  # supervisor, exactly the way the registry starts workers.
  defp start_session_child(ctx) do
    child_spec = %{
      id: {Session, System.unique_integer([:positive])},
      start:
        {Session, :start_link,
         [
           [
             key: {:scope, "supervisor-test"},
             cwd: System.tmp_dir!(),
             interpreter: "python3",
             runner_path: ctx.runner,
             startup_timeout_ms: 30_000,
             process_mod: StaticProcess,
             protocol_mod: StaticProtocol,
             output_mod: StaticOutput
           ]
         ]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(@dyn_name, child_spec)
    pid
  end

  # OTP gives no ordering guarantee for which_children; index by id.
  defp children_by_id(sup) do
    Supervisor.which_children(sup)
    |> Map.new(fn {id, pid, type, modules} -> {id, {pid, type, modules}} end)
  end

  setup do
    runner =
      Path.join(
        System.tmp_dir!(),
        "supervisor-test-runner-#{System.unique_integer([:positive])}.py"
      )

    File.write!(runner, "# supervisor test runner stub\n")
    on_exit(fn -> File.rm(runner) end)
    {:ok, runner: runner}
  end

  test "starts SessionSupervisor before Registry as one coherent tree" do
    start_tree()

    by_id = children_by_id(@sup_name)

    # A real DynamicSupervisor child reports its name as the child id.
    assert {dyn, :supervisor, [DynamicSupervisor]} = by_id[@dyn_name]
    assert {reg, :worker, [StandInRegistry]} = by_id[StandInRegistry]

    assert dyn == Process.whereis(@dyn_name)
    assert reg == Process.whereis(@registry_name)

    # Start order, observed where it matters: the registry boots only
    # after its sibling session supervisor is already registered, and is
    # wired to it by default.
    state = StandInRegistry.state(@registry_name)
    assert state.sibling_alive_at_start
    assert state.opts[:session_supervisor] == @dyn_name
  end

  test "a registry crash tears down and restarts both children" do
    start_tree()

    old_dyn = Process.whereis(@dyn_name)
    old_reg = Process.whereis(@registry_name)
    ref_dyn = Process.monitor(old_dyn)
    ref_reg = Process.monitor(old_reg)

    Process.exit(old_reg, :kill)

    assert_receive {:DOWN, ^ref_reg, :process, ^old_reg, :killed}
    # :one_for_all takes the session supervisor down with the registry.
    assert_receive {:DOWN, ^ref_dyn, :process, ^old_dyn, _}, 2_000

    # Both children return under fresh pids, re-registered by name.
    wait_until(fn ->
      new_dyn = Process.whereis(@dyn_name)
      new_reg = Process.whereis(@registry_name)
      is_pid(new_dyn) and new_dyn != old_dyn and is_pid(new_reg) and new_reg != old_reg
    end)

    by_id = children_by_id(@sup_name)

    assert {new_dyn, :supervisor, [DynamicSupervisor]} = by_id[@dyn_name]
    assert {new_reg, :worker, [StandInRegistry]} = by_id[StandInRegistry]

    assert new_dyn == Process.whereis(@dyn_name)
    assert new_reg == Process.whereis(@registry_name)

    # The restarted registry is wired to the restarted sibling.
    state = StandInRegistry.state(@registry_name)
    assert state.sibling_alive_at_start
    assert state.opts[:session_supervisor] == @dyn_name
  end

  test "a registry crash leaves no orphan Session worker", ctx do
    start_tree()
    old_dyn = Process.whereis(@dyn_name)

    session = start_session_child(ctx)
    assert Process.alive?(session)
    ref = Process.monitor(session)

    Process.exit(Process.whereis(@registry_name), :kill)

    assert_receive {:DOWN, ^ref, :process, ^session, _}, 2_000

    # The restarted session supervisor comes back empty: the worker (a
    # temporary child) was torn down with the subsystem, not restarted.
    wait_until(fn ->
      new_dyn = Process.whereis(@dyn_name)
      is_pid(new_dyn) and new_dyn != old_dyn
    end)

    counts = DynamicSupervisor.count_children(@dyn_name)
    assert counts.active == 0
    assert counts.specs == 0
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(fun, deadline, timeout)
  end

  defp wait_loop(fun, deadline, timeout) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition was not met within #{timeout}ms")
      else
        Process.sleep(10)
        wait_loop(fun, deadline, timeout)
      end
    end
  end
end
