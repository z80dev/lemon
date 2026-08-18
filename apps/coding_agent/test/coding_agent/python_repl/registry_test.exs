defmodule CodingAgent.PythonRepl.RegistryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.PythonRepl
  alias CodingAgent.PythonRepl.{Key, Registry, SessionSupervisor}

  defmodule Director do
    def reset do
      if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)

      {:ok, _pid} =
        Agent.start_link(
          fn -> %{starts: [], fail?: false, shutdowns: []} end,
          name: __MODULE__
        )
    end

    def record(pid, opts),
      do: Agent.update(__MODULE__, &%{&1 | starts: [{pid, opts} | &1.starts]})

    def record_shutdown(pid),
      do: Agent.update(__MODULE__, &%{&1 | shutdowns: [pid | &1.shutdowns]})

    def starts, do: Agent.get(__MODULE__, &Enum.reverse(&1.starts))
    def shutdowns, do: Agent.get(__MODULE__, &Enum.reverse(&1.shutdowns))
    def fail_start(value), do: Agent.update(__MODULE__, &%{&1 | fail?: value})
    def fail?, do: Agent.get(__MODULE__, & &1.fail?)
  end

  defmodule FakeSession do
    use GenServer

    def start_link(opts) do
      if Director.fail?() do
        {:error, {:shutdown, {:startup_failed, :configured}}}
      else
        GenServer.start_link(__MODULE__, opts)
      end
    end

    def status(pid), do: GenServer.call(pid, :status)
    def execute(pid, request, timeout), do: GenServer.call(pid, {:execute, request, timeout})
    def shutdown(pid, _timeout), do: GenServer.stop(pid, :shutdown)

    def set_status(pid, phase, queue_depth \\ 0, active_request_id \\ nil),
      do:
        update_status(pid, %{
          phase: phase,
          queue_depth: queue_depth,
          active_request_id: active_request_id
        })

    def update_status(pid, updates) when is_map(updates),
      do: GenServer.call(pid, {:set_status, updates})

    def init(opts) do
      Director.record(self(), opts)

      {:ok,
       %{
         phase: :starting,
         generation: Keyword.fetch!(opts, :generation),
         key: Keyword.fetch!(opts, :key),
         queue_depth: 0,
         active_request_id: nil,
         cells_completed: 0,
         process_alive: true
       }}
    end

    def handle_call(:status, _from, state), do: {:reply, state, state}

    def handle_call({:set_status, updates}, _from, state),
      do: {:reply, :ok, Map.merge(state, updates)}

    def handle_call({:execute, request, timeout}, _from, state) do
      result = %{
        request_id: "fake-cell",
        state_retained: true,
        duration_ms: 1,
        request: request,
        timeout: timeout
      }

      {:reply, {:ok, result}, state}
    end
  end

  defmodule StubbornSession do
    def shutdown(pid, _timeout) do
      Director.record_shutdown(pid)
      :ok
    end
  end

  setup do
    Director.reset()
    sup = String.to_atom("repl_registry_sup_#{System.unique_integer([:positive])}")
    registry = String.to_atom("repl_registry_#{System.unique_integer([:positive])}")
    start_supervised!({SessionSupervisor, name: sup})

    start_supervised!(
      {Registry,
       name: registry,
       session_supervisor: sup,
       session_mod: FakeSession,
       idle_timeout_ms: :infinity}
    )

    %{registry: registry, sup: sup, key: key(), owner: owner()}
  end

  test "coalesces concurrent first use and retains all owners", %{
    registry: registry,
    key: key
  } do
    owners = Enum.map(1..8, fn _ -> owner() end)

    allocations =
      owners
      |> Task.async_stream(&Registry.acquire(registry, key, &1), ordered: false)
      |> Enum.map(fn {:ok, {:ok, allocation}} -> allocation end)

    assert length(Director.starts()) == 1
    assert Enum.count(allocations, &(not &1.reused?)) == 1
    assert allocations |> Enum.uniq_by(& &1.pid) |> length() == 1
    assert Registry.snapshot(registry).owners == 8
    Enum.each(allocations, &release(registry, &1))
  end

  test "sole-owner reset invalidates before the next generation", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    {:ok, first} = Registry.acquire(registry, key, owner)
    worker_ref = Process.monitor(first.pid)

    assert {:ok, %{reset_performed: true, forked: false}} =
             Registry.reset(registry, key, owner)

    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}
    {:ok, second} = Registry.acquire(registry, key, owner)
    assert second.generation == 2
    release(registry, second)
  end

  test "co-owner reset creates a sticky full-key fork only when preservation is safe", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    sibling = owner()
    {:ok, base} = Registry.acquire(registry, key, owner)
    {:ok, sibling_checkout} = Registry.acquire(registry, key, sibling)
    release(registry, base)
    release(registry, sibling_checkout)
    FakeSession.set_status(base.pid, :idle)

    assert {:ok, %{forked: true}} = Registry.reset(registry, key, owner)
    assert Process.alive?(base.pid)

    {:ok, fork} = Registry.acquire(registry, key, owner)
    assert fork.pid != base.pid
    release(registry, fork)

    assert {:ok, again} = Registry.acquire(registry, key, owner)
    assert again.pid == fork.pid
    release(registry, again)

    assert :ok = Registry.detach_owner(registry, owner)
    assert {:ok, rejoined} = Registry.acquire(registry, key, owner)
    assert rejoined.pid == base.pid
    release(registry, rejoined)
  end

  test "reset cannot preserve a shared worker across acquire-to-execute checkout", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    sibling = owner()
    {:ok, base} = Registry.acquire(registry, key, sibling)
    release(registry, base)
    FakeSession.set_status(base.pid, :idle)
    parent = self()

    caller =
      spawn(fn ->
        {:ok, allocation} = Registry.acquire(registry, key, owner)
        send(parent, {:acquired, self(), allocation})

        receive do
          :execute ->
            result =
              try do
                FakeSession.execute(allocation.pid, %{code: "stale"}, 1_000)
              catch
                :exit, _reason -> :worker_unavailable
              end

            send(parent, {:executed, self(), result})
        end
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:acquired, ^caller, allocation}
    assert allocation.pid == base.pid
    worker_ref = Process.monitor(base.pid)

    assert {:ok, %{reset_performed: true, forked: true}} =
             Registry.reset(registry, key, owner)

    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}
    send(caller, :execute)
    assert_receive {:executed, ^caller, :worker_unavailable}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  test "stale worker DOWN cannot erase a replacement", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    {:ok, first} = Registry.acquire(registry, key, owner)
    old_ref = :sys.get_state(registry).entries[key].ref
    assert {:ok, _result} = Registry.reset(registry, key, owner)
    {:ok, replacement} = Registry.acquire(registry, key, owner)

    send(registry, {:DOWN, make_ref(), :process, first.pid, :normal})
    send(registry, {:DOWN, old_ref, :process, first.pid, :normal})
    _ = Registry.snapshot(registry)

    assert {:ok, same} = Registry.acquire(registry, key, owner)
    assert same.pid == replacement.pid
    release(registry, replacement)
    release(registry, same)
  end

  test "owner death stops ownerless workers and clears all monitor bookkeeping", %{
    registry: registry,
    key: key
  } do
    doomed = owner()
    {:ok, allocation} = Registry.acquire(registry, key, doomed)
    worker_ref = Process.monitor(allocation.pid)
    Process.exit(doomed, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}
    state = :sys.get_state(registry)
    assert state.owner_refs == %{}
    assert state.owner_entries == %{}
    assert state.worker_refs == %{}
    assert state.lease_refs == %{}
  end

  test "lease caller DOWN releases checkout without detaching its stable owner", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, allocation} = Registry.acquire(registry, key, owner)
        send(parent, {:checkout, self(), allocation})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:checkout, ^caller, allocation}
    assert Process.alive?(allocation.pid)
    registry_pid = Process.whereis(registry)
    :erlang.trace(registry_pid, true, [:receive])
    caller_ref = Process.monitor(caller)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}

    assert_receive {:trace, ^registry_pid, :receive,
                    {:DOWN, _lease_ref, :process, ^caller, :killed}}

    :erlang.trace(registry_pid, false, [:receive])
    state = :sys.get_state(registry)
    assert state.lease_refs == %{}
    assert MapSet.size(state.entries[key].leases) == 0
    assert Process.alive?(allocation.pid)
  end

  test "a departing owner preserves only an exactly quiescent shared worker", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    sibling = owner()
    {:ok, idle} = Registry.acquire(registry, key, owner)
    {:ok, sibling_checkout} = Registry.acquire(registry, key, sibling)
    release(registry, idle)
    release(registry, sibling_checkout)
    FakeSession.set_status(idle.pid, :idle)

    assert :ok = Registry.detach_owner(registry, owner)
    assert Process.alive?(idle.pid)

    {:ok, checkout} = Registry.acquire(registry, key, owner)
    release(registry, checkout)
    FakeSession.set_status(idle.pid, :running, 1, "active")
    worker_ref = Process.monitor(idle.pid)

    assert :ok = Registry.detach_owner(registry, owner)
    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}
  end

  test "strict capacity protects an idle checked-out worker until release", %{
    sup: sup,
    key: key,
    owner: owner
  } do
    registry = String.to_atom("repl_lease_cap_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Registry,
       name: registry,
       session_supervisor: sup,
       session_mod: FakeSession,
       max_live_kernels: 1,
       idle_timeout_ms: :infinity},
      id: registry
    )

    {:ok, first} = Registry.acquire(registry, key, owner)
    FakeSession.set_status(first.pid, :idle)

    assert {:error, :capacity_exhausted} =
             Registry.acquire(registry, key("other"), owner())

    release(registry, first)
    worker_ref = Process.monitor(first.pid)
    {:ok, second} = Registry.acquire(registry, key("other"), owner())
    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}
    assert second.generation == 2
    release(registry, second)
  end

  test "stale lease release cannot unreserve a replacement generation", %{
    sup: sup,
    key: key,
    owner: owner
  } do
    registry = String.to_atom("repl_stale_lease_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Registry,
       name: registry,
       session_supervisor: sup,
       session_mod: FakeSession,
       max_live_kernels: 1,
       idle_timeout_ms: :infinity},
      id: registry
    )

    {:ok, stale} = Registry.acquire(registry, key, owner)
    assert {:ok, _result} = Registry.reset(registry, key, owner)
    {:ok, current} = Registry.acquire(registry, key, owner)
    FakeSession.set_status(current.pid, :idle)

    assert :ok = Registry.release(registry, stale.lease)

    assert {:error, :capacity_exhausted} =
             Registry.acquire(registry, key("blocked"), owner())

    release(registry, current)
    {:ok, admitted} = Registry.acquire(registry, key("admitted"), owner())
    assert admitted.generation == 3
    release(registry, admitted)
  end

  test "idle reaping requires no lease and exact quiescence", %{
    sup: sup,
    key: key,
    owner: owner
  } do
    clock = start_clock(1_000)
    registry = String.to_atom("repl_reaper_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Registry,
       name: registry,
       session_supervisor: sup,
       session_mod: FakeSession,
       idle_timeout_ms: 1,
       reap_interval_ms: 60_000,
       now_ms: fn -> clock_now(clock) end},
      id: registry
    )

    {:ok, allocation} = Registry.acquire(registry, key, owner)
    FakeSession.set_status(allocation.pid, :idle)
    advance_clock(clock, 1)
    send(registry, :reap_idle)
    _ = Registry.snapshot(registry)
    assert Process.alive?(allocation.pid)

    release(registry, allocation)
    assert :sys.get_state(registry).entries[key].last_use_ms == clock_now(clock)

    worker_ref = Process.monitor(allocation.pid)
    send(registry, :reap_idle)
    _ = Registry.snapshot(registry)
    assert Process.alive?(allocation.pid)

    advance_clock(clock, 1)
    send(registry, :reap_idle)
    _ = Registry.snapshot(registry)
    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}
  end

  test "malformed, dead, generation-mismatched, and key-mismatched status is replaced", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    wrong_key = key("wrong-status-key")
    {:ok, initial} = Registry.acquire(registry, key, owner)

    mutations = [
      fn _allocation -> %{process_alive: false} end,
      fn allocation -> %{generation: allocation.generation + 100} end,
      fn _allocation -> %{key: wrong_key} end,
      fn _allocation -> %{phase: :idle, queue_depth: 1, active_request_id: nil} end,
      fn _allocation -> %{cells_completed: :malformed} end
    ]

    final =
      Enum.reduce(mutations, initial, fn mutation, current ->
        release(registry, current)
        FakeSession.update_status(current.pid, mutation.(current))
        old_pid = current.pid
        old_ref = Process.monitor(old_pid)
        {:ok, replacement} = Registry.acquire(registry, key, owner)
        assert_receive {:DOWN, ^old_ref, :process, ^old_pid, _reason}
        assert replacement.pid != old_pid
        assert replacement.generation > current.generation
        replacement
      end)

    release(registry, final)
  end

  test "confirmed orphan stop tries cleanup then waits for forced death", %{sup: sup} do
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    worker_ref = Process.monitor(pid)

    assert :ok =
             SessionSupervisor.stop_session(sup, StubbornSession, pid, worker_ref, 1_000)

    assert Director.shutdowns() == [pid]
    refute Process.alive?(pid)
    refute_receive {:DOWN, ^worker_ref, :process, ^pid, _reason}
  end

  test "generation is registry-wide monotonic and failed starts do not consume it", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    {:ok, first} = Registry.acquire(registry, key, owner)
    release(registry, first)
    assert {:ok, _result} = Registry.reset(registry, key, owner)

    other_key = key("generation-other")
    {:ok, second} = Registry.acquire(registry, other_key, owner)
    release(registry, second)
    assert {:ok, _result} = Registry.reset(registry, other_key, owner)

    Director.fail_start(true)

    assert {:error, {:startup_failed, :configured}} =
             Registry.acquire(registry, key("failed-generation"), owner)

    Director.fail_start(false)
    third_key = key("third-generation")
    {:ok, third} = Registry.acquire(registry, third_key, owner)
    release(registry, third)
    assert {:ok, _result} = Registry.reset(registry, third_key, owner)

    {:ok, fourth} = Registry.acquire(registry, key, owner)

    assert [first.generation, second.generation, third.generation, fourth.generation] ==
             [1, 2, 3, 4]

    release(registry, fourth)
  end

  test "release advances last use after the checked-out execution window", %{
    sup: sup,
    key: key,
    owner: owner
  } do
    clock = start_clock(1_000)
    registry = String.to_atom("repl_release_clock_#{System.unique_integer([:positive])}")

    start_supervised!(
      {Registry,
       name: registry,
       session_supervisor: sup,
       session_mod: FakeSession,
       idle_timeout_ms: :infinity,
       now_ms: fn -> clock_now(clock) end},
      id: registry
    )

    {:ok, allocation} = Registry.acquire(registry, key, owner)
    state_before = :sys.get_state(registry)
    assert state_before.entries[key].last_use_ms == 1_000
    assert advance_clock(clock, 1) == 1_001

    assert :ok = Registry.release(registry, allocation.lease)
    state_after = :sys.get_state(registry)
    assert state_after.entries[key].last_use_ms == 1_001
    assert MapSet.size(state_after.entries[key].leases) == 0
  end

  test "facade always releases its lease and publishes reused under one field", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    assert {:ok, %{kernel_reused: false}} =
             PythonRepl.execute(%{
               key: key,
               owner_pid: owner,
               code: "1",
               registry: registry
             })

    assert :sys.get_state(registry).lease_refs == %{}

    assert {:ok, %{kernel_reused: true}} =
             PythonRepl.execute(%{
               key: key,
               owner_pid: owner,
               code: "2",
               registry: registry
             })

    assert :sys.get_state(registry).lease_refs == %{}
  end

  test "crashes are replaced and facade maps only pre-start failures", %{
    registry: registry,
    key: key,
    owner: owner
  } do
    {:ok, first} = Registry.acquire(registry, key, owner)
    worker_ref = Process.monitor(first.pid)
    Process.exit(first.pid, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, _pid, _reason}

    {:ok, replacement} = Registry.acquire(registry, key, owner)
    assert replacement.generation == 2
    release(registry, replacement)

    assert {:error, %{reason: :invalid_key}} =
             PythonRepl.execute(%{key: :bad, owner_pid: owner, code: "1"})

    Director.fail_start(true)

    assert {:error, %{reason: :startup_failed}} =
             PythonRepl.execute(%{
               key: key("failure"),
               owner_pid: owner(),
               code: "1",
               registry: registry
             })
  end

  defp release(registry, allocation) do
    assert :ok = Registry.release(registry, allocation.lease)
  end

  defp start_clock(now_ms) do
    start_supervised!({Agent, fn -> now_ms end}, id: make_ref())
  end

  defp clock_now(clock), do: Agent.get(clock, & &1)

  defp advance_clock(clock, elapsed_ms) do
    Agent.get_and_update(clock, fn now_ms ->
      next = now_ms + elapsed_ms
      {next, next}
    end)
  end

  defp key(suffix \\ "default") do
    {:ok, key} =
      Key.new(%{
        scope_id: "registry-#{suffix}-#{System.unique_integer([:positive])}",
        agent_id: "agent",
        cwd: System.tmp_dir!(),
        interpreter: "/bin/true",
        helpers: [],
        protocol_version: 1
      })

    key
  end

  defp owner do
    parent = self()

    spawn(fn ->
      parent_ref = Process.monitor(parent)

      receive do
        {:DOWN, ^parent_ref, :process, ^parent, _reason} -> :ok
      end
    end)
  end
end
