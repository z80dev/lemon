defmodule LemonCore.Secrets.LockTest do
  # Uses the global Store's lock table.
  use ExUnit.Case, async: false

  alias LemonCore.Secrets.Lock
  alias LemonCore.Store

  @table :secrets_lock
  @key :secrets

  defmodule ObservedBackend do
    @behaviour LemonCore.Store.Backend
    alias LemonCore.Store.EtsBackend

    @impl true
    def init(opts) do
      Process.put(:lock_test_observer, Keyword.fetch!(opts, :test_pid))
      EtsBackend.init(opts)
    end

    @impl true
    def get(state, table, key) do
      if table == :secrets_lock, do: send(Process.get(:lock_test_observer), :lease_read)
      EtsBackend.get(state, table, key)
    end

    @impl true
    defdelegate put(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate put_new(state, table, key, value), to: EtsBackend
    @impl true
    defdelegate delete(state, table, key), to: EtsBackend
    @impl true
    defdelegate list(state, table), to: EtsBackend
    @impl true
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend
  end

  setup do
    case Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    Store.delete(@table, @key)
    on_exit(fn -> Store.delete(@table, @key) end)
    :ok
  end

  test "holders are mutually exclusive" do
    test_pid = self()

    holder =
      spawn(fn ->
        Lock.with_rotation_lock(fn ->
          send(test_pid, :holding)

          receive do
            :release -> :ok
          end
        end)

        send(test_pid, :released)
      end)

    assert_receive :holding
    waiter = Task.async(fn -> Lock.with_write_lock(fn -> :written end) end)
    assert Task.yield(waiter, 200) == nil

    send(holder, :release)
    assert_receive :released
    assert Task.await(waiter) == :written
  end

  test "a lease whose BEAM holder died is reclaimed" do
    test_pid = self()

    holder =
      spawn(fn ->
        Lock.with_rotation_lock(fn ->
          send(test_pid, :holding)
          Process.sleep(:infinity)
        end)
      end)

    assert_receive :holding
    Process.exit(holder, :kill)

    assert Lock.with_write_lock(fn -> :written end) == :written
  end

  test "a lease whose OS process on this host exited is reclaimed" do
    {pid, 0} = System.cmd("sh", ["-c", "echo $$"])
    :ok = Store.put(@table, @key, lease(os_pid: String.trim(pid)))

    assert Lock.with_write_lock(fn -> :written end) == :written
  end

  test "a live holder is never reclaimed, however long it holds the lease" do
    # pid 1 always exists; `kill -0` reports it as not permitted, i.e. alive.
    held = lease(os_pid: "1")
    :ok = Store.put(@table, @key, held)

    assert Lock.with_rotation_lock(fn -> flunk("acquired a live holder's lease") end) ==
             {:error, :secrets_locked}

    assert Store.get(@table, @key) == held
  end

  test "a lease from another host is reported, never reclaimed" do
    held = lease(host: "some-other-host", os_pid: "999999")
    :ok = Store.put(@table, @key, held)

    assert Lock.with_rotation_lock(fn -> flunk("acquired a foreign lease") end) ==
             {:error, {:secrets_lock_held, "some-other-host"}}

    assert Store.get(@table, @key) == held
  end

  for ending <- [:release, :death] do
    @ending ending
    test "a waiting local contender wakes on holder #{@ending}", _ctx do
      test_pid = self()

      store =
        start_supervised!(
          {Store,
           name: :observed_secrets_lock_store,
           backend: ObservedBackend,
           backend_opts: [test_pid: test_pid],
           cached_tables: []}
        )

      holder =
        spawn(fn ->
          Lock.with_write_lock(
            fn ->
              send(test_pid, :holding)

              receive do
                :release -> :ok
              end
            end,
            store
          )

          send(test_pid, :released)

          receive do
            :finish -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)
      assert_receive :holding
      waiter = Task.async(fn -> Lock.with_write_lock(fn -> :written end, store) end)

      # The second strict fetch happens only after subscription and monitoring.
      assert_receive :lease_read
      assert_receive :lease_read
      assert {:monitors, monitors} = Process.info(waiter.pid, :monitors)
      assert {:process, holder} in monitors

      case @ending do
        :release ->
          send(holder, :release)
          assert_receive :released
          assert Process.alive?(holder)

        :death ->
          Process.exit(holder, :kill)
      end

      assert Task.await(waiter) == :written
      assert Store.get(store, @table, @key) == nil
      send(holder, :finish)
    end
  end

  defp lease(overrides) do
    {:ok, host} = :inet.gethostname()

    Map.merge(
      %{owner: "test", host: List.to_string(host), os_pid: "0", holder: "<0.0.0>"},
      Map.new(overrides)
    )
  end
end
