defmodule LemonCore.SupervisionTest do
  use ExUnit.Case, async: true

  alias LemonCore.Supervision

  defmodule Manager do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      registry = Keyword.fetch!(opts, :registry)
      dynamic = Keyword.fetch!(opts, :dynamic)
      observer = Keyword.fetch!(opts, :observer)
      registry_pid = Process.whereis(registry)
      dynamic_pid = Process.whereis(dynamic)
      [] = DynamicSupervisor.which_children(dynamic_pid)
      {:ok, _} = Registry.register(registry, :manager, nil)
      send(observer, {:manager_started, self(), registry_pid, dynamic_pid})
      {:ok, nil}
    end
  end

  test "registry loss restarts its dynamic supervisor before its manager, not sibling groups" do
    registry = __MODULE__.Registry
    dynamic = __MODULE__.Dynamic
    name = __MODULE__.Tree

    spec =
      Supervision.subtree(name, [
        {Registry, keys: :unique, name: registry},
        {DynamicSupervisor, strategy: :one_for_one, name: dynamic},
        {Manager, registry: registry, dynamic: dynamic, observer: self()}
      ])

    root =
      start_supervised!(%{
        id: __MODULE__.Root,
        start:
          {Supervisor, :start_link,
           [[spec, {Agent, fn -> :unrelated end}], [strategy: :one_for_one]]},
        type: :supervisor
      })

    assert_receive {:manager_started, manager, registry_pid, dynamic_pid}, 1_000
    children = Supervisor.which_children(root)
    {Agent, sibling, :worker, _} = List.keyfind(children, Agent, 0)
    {^name, subtree, :supervisor, _} = List.keyfind(children, name, 0)

    # A temporary dynamic child must stop, never replay, on dependency loss.
    {:ok, worker} =
      DynamicSupervisor.start_child(
        dynamic_pid,
        Supervisor.child_spec({Agent, fn -> :temporary end}, restart: :temporary)
      )

    manager_ref = Process.monitor(manager)
    dynamic_ref = Process.monitor(dynamic_pid)
    sibling_ref = Process.monitor(sibling)
    worker_ref = Process.monitor(worker)

    partitions =
      Enum.map(Supervisor.which_children(registry_pid), fn {_id, pid, _type, _modules} ->
        {pid, Process.monitor(pid)}
      end)

    # Hold restart handling until the brutally killed registry's named partitions
    # have exited. This schedules a deterministic failure without sleep-based
    # races against partition-name cleanup and OTP's restart-intensity budget.
    :ok = :sys.suspend(subtree)

    try do
      Process.exit(registry_pid, :kill)

      for {pid, ref} <- partitions do
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
      end
    after
      :sys.resume(subtree)
    end

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, _}, 1_000
    assert_receive {:DOWN, ^dynamic_ref, :process, ^dynamic_pid, _}, 1_000
    assert_receive {:manager_started, next_manager, next_registry, next_dynamic}, 1_000
    refute next_manager == manager
    refute next_registry == registry_pid
    refute next_dynamic == dynamic_pid
    assert [{^next_manager, nil}] = Registry.lookup(registry, :manager)
    assert [] == DynamicSupervisor.which_children(next_dynamic)
    refute_received {:DOWN, ^sibling_ref, :process, ^sibling, _}

    assert {Agent, ^sibling, :worker, _} =
             List.keyfind(Supervisor.which_children(root), Agent, 0)

    assert Agent.get(sibling, & &1) == :unrelated
    assert Process.whereis(name) == subtree
  end

  test "each subtree declares its own restart intensity" do
    assert %{start: {Supervisor, :start_link, [[], opts]}} =
             Supervision.subtree(__MODULE__.Defaults, [])

    assert opts[:strategy] == :rest_for_one
    assert opts[:max_restarts] == 10
    assert opts[:max_seconds] == 5

    assert %{start: {Supervisor, :start_link, [[], custom_opts]}} =
             Supervision.subtree(__MODULE__.Custom, [], max_restarts: 2, max_seconds: 30)

    assert custom_opts[:max_restarts] == 2
    assert custom_opts[:max_seconds] == 30
  end
end
