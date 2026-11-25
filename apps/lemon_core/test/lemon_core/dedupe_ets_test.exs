defmodule LemonCore.Dedupe.EtsTest do
  @moduledoc """
  Tests for the Dedupe.Ets module.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Dedupe.Ets

  import LemonPlatformTest.Testing.AsyncHelpers, only: [assert_eventually: 1]

  setup do
    # Use a unique table name for each test to avoid conflicts
    table_name = :"test_dedupe_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      case :ets.info(table_name, :owner) do
        owner when is_pid(owner) ->
          DynamicSupervisor.terminate_child(LemonCore.Dedupe.Supervisor, owner)

        :undefined ->
          :ok
      end
    end)

    {:ok, table: table_name}
  end

  describe "init/1" do
    test "outlives the first caller and has a supervised owner", %{table: table} do
      {caller, monitor} =
        spawn_monitor(fn ->
          :ok = Ets.init(table)
          :ok = Ets.mark(table, :retained)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
      owner = :ets.info(table, :owner)
      assert is_pid(owner)
      refute owner == caller

      assert Enum.any?(DynamicSupervisor.which_children(LemonCore.Dedupe.Supervisor), fn
               {_, ^owner, :worker, _} -> true
               _ -> false
             end)

      assert Ets.seen?(table, :retained, 60_000)
    end

    test "serializes concurrent first callers", %{table: table} do
      parent = self()

      tasks =
        for _ <- 1..16 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :initialize -> Ets.init(table)
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _pid})
      for task <- tasks, do: send(task.pid, :initialize)

      assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
      assert is_pid(:ets.info(table, :owner))
    end

    test "supervision recreates an empty table after owner failure", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, :old)
      owner = :ets.info(table, :owner)
      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

      assert_eventually(fn ->
        replacement = :ets.info(table, :owner)
        is_pid(replacement) and replacement != owner
      end)

      children = DynamicSupervisor.which_children(LemonCore.Dedupe.Supervisor)
      assert Enum.any?(children, fn {_, pid, _, _} -> pid == :ets.info(table, :owner) end)
      refute Ets.seen?(table, :old, 60_000)
      assert :ok = Ets.mark(table, :new)
      assert Ets.seen?(table, :new, 60_000)
    end

    test "creates a new ETS table", %{table: table} do
      assert :ok = Ets.init(table)
      assert :ets.info(table) != :undefined
    end

    test "is idempotent - returns :ok if table already exists", %{table: table} do
      assert :ok = Ets.init(table)
      assert :ok = Ets.init(table)
      assert :ok = Ets.init(table)
    end

    test "creates named table when given an atom", %{table: table} do
      assert :ok = Ets.init(table)
      info = :ets.info(table)
      assert info[:named_table] == true
    end

    test "sets concurrency options by default", %{table: table} do
      assert :ok = Ets.init(table)
      info = :ets.info(table)

      # ETS reports these flags according to the VM (e.g. write_concurrency is
      # not reported on a single-scheduler VM), so compare against a table
      # created with the options requested explicitly. The test process owns
      # the reference table, so it disappears with the test; on_exit runs in
      # another process and must not touch it.
      reference =
        :ets.new(:dedupe_concurrency_reference, read_concurrency: true, write_concurrency: true)

      assert info[:read_concurrency] == :ets.info(reference, :read_concurrency)
      assert info[:write_concurrency] == :ets.info(reference, :write_concurrency)
    end
  end

  describe "mark/2" do
    test "marks a key as seen", %{table: table} do
      :ok = Ets.init(table)
      assert :ok = Ets.mark(table, "key1")

      # Verify it was inserted
      assert [{"key1", _ts}] = :ets.lookup(table, "key1")
    end

    test "updates timestamp when marking same key again", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")
      [{_, ts1}] = :ets.lookup(table, "key1")

      Process.sleep(10)

      :ok = Ets.mark(table, "key1")
      [{_, ts2}] = :ets.lookup(table, "key1")

      assert ts2 > ts1
    end

    test "handles non-existent table gracefully", %{table: table} do
      # Should not crash
      assert :ok = Ets.mark(table, "key1")
    end

    test "marks multiple different keys", %{table: table} do
      :ok = Ets.init(table)
      assert :ok = Ets.mark(table, "key1")
      assert :ok = Ets.mark(table, "key2")
      assert :ok = Ets.mark(table, "key3")

      assert length(:ets.tab2list(table)) == 3
    end
  end

  describe "seen?/3" do
    test "returns false for unseen key", %{table: table} do
      :ok = Ets.init(table)
      assert Ets.seen?(table, "key1", 1000) == false
    end

    test "returns true for recently seen key", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")
      assert Ets.seen?(table, "key1", 1000) == true
    end

    test "returns false for expired key and deletes it", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")

      # Wait for expiration
      Process.sleep(50)

      assert Ets.seen?(table, "key1", 10) == false
      # Should be deleted
      assert :ets.lookup(table, "key1") == []
    end

    test "returns true for non-expired key", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")

      # Check before expiration
      assert Ets.seen?(table, "key1", 1000) == true
      # Should still exist
      assert :ets.lookup(table, "key1") != []
    end

    test "handles non-existent table gracefully", %{table: table} do
      assert Ets.seen?(table, "key1", 1000) == false
    end

    test "returns false for invalid ttl", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")

      # Non-integer TTL should return false
      assert Ets.seen?(table, "key1", "invalid") == false
    end
  end

  describe "check_and_mark/3" do
    test "returns :new and marks key for first time", %{table: table} do
      :ok = Ets.init(table)
      assert :new = Ets.check_and_mark(table, "key1", 1000)
      assert Ets.seen?(table, "key1", 1000) == true
    end

    test "returns :seen for already seen key", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")
      assert :seen = Ets.check_and_mark(table, "key1", 1000)
    end

    test "returns :new for expired key and re-marks it", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")

      Process.sleep(50)

      # Should be expired, so :new
      assert :new = Ets.check_and_mark(table, "key1", 10)
      # And should be marked again
      assert Ets.seen?(table, "key1", 1000) == true
    end

    test "fails closed when the table is unavailable", %{table: table} do
      assert :seen = Ets.check_and_mark(table, "key1", 1000)
    end

    test "returns :seen for invalid ttl", %{table: table} do
      :ok = Ets.init(table)
      # Non-integer TTL should return :seen (conservative)
      assert :seen = Ets.check_and_mark(table, "key1", "invalid")
    end
  end

  describe "retain/4" do
    test "restoring a confirmed receipt never shortens its retention", %{table: table} do
      :ok = Ets.init(table)
      assert :new = Ets.retain(table, :receipt, 120_000, 60_000)
      [{:receipt, timestamp}] = :ets.lookup(table, :receipt)

      assert :seen = Ets.retain(table, :receipt, 30_000, 60_000)
      assert [{:receipt, ^timestamp}] = :ets.lookup(table, :receipt)

      assert :seen = Ets.retain(table, :receipt, 240_000, 60_000)
      [{:receipt, extended}] = :ets.lookup(table, :receipt)
      assert extended > timestamp
      assert Ets.seen?(table, :receipt, 60_000)
    end

    test "replaces an expired receipt without retaining its old timestamp", %{table: table} do
      :ok = Ets.init(table)
      :ets.insert(table, {:receipt, System.monotonic_time(:millisecond) - 120_000})

      assert :new = Ets.retain(table, :receipt, 60_000, 60_000)
      assert Ets.seen?(table, :receipt, 60_000)
    end
  end

  describe "cleanup_expired/2" do
    test "removes expired entries and returns count", %{table: table} do
      :ok = Ets.init(table)

      # Mark some keys
      :ok = Ets.mark(table, "key1")
      :ok = Ets.mark(table, "key2")
      :ok = Ets.mark(table, "key3")

      Process.sleep(50)

      # Cleanup with short TTL
      assert Ets.cleanup_expired(table, 10) == 3
      assert :ets.tab2list(table) == []
    end

    test "does not remove non-expired entries", %{table: table} do
      :ok = Ets.init(table)

      # key1 was marked long ago; key2 is fresh. A generous TTL keeps key2 live
      # even if the test process is descheduled.
      :ets.insert(table, {"key1", System.monotonic_time(:millisecond) - 60_000})
      :ok = Ets.mark(table, "key2")

      # Only key1 is expired
      assert Ets.cleanup_expired(table, 30_000) == 1
      assert length(:ets.tab2list(table)) == 1
      assert :ets.lookup(table, "key2") != []
    end

    test "returns 0 when no entries to clean", %{table: table} do
      :ok = Ets.init(table)
      assert Ets.cleanup_expired(table, 1000) == 0
    end

    test "handles non-existent table gracefully", %{table: table} do
      assert Ets.cleanup_expired(table, 1000) == 0
    end

    test "returns 0 for invalid ttl", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")

      assert Ets.cleanup_expired(table, "invalid") == 0
    end
  end

  describe "TTL semantics" do
    test "exact boundary - key at exact TTL is still valid", %{table: table} do
      :ok = Ets.init(table)
      :ok = Ets.mark(table, "key1")

      # Should be considered seen at exact boundary
      assert Ets.seen?(table, "key1", 0) == true
    end

    test "monotonic time prevents clock skew issues", %{table: table} do
      :ok = Ets.init(table)

      # Mark multiple keys rapidly
      :ok = Ets.mark(table, "key1")
      :ok = Ets.mark(table, "key2")
      :ok = Ets.mark(table, "key3")

      # All should be seen with reasonable TTL
      assert Ets.seen?(table, "key1", 1000) == true
      assert Ets.seen?(table, "key2", 1000) == true
      assert Ets.seen?(table, "key3", 1000) == true
    end
  end

  describe "concurrent access" do
    test "handles concurrent marks", %{table: table} do
      :ok = Ets.init(table)

      # Spawn multiple processes marking keys
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Ets.mark(table, "key_#{i}")
          end)
        end

      Task.await_many(tasks)

      assert length(:ets.tab2list(table)) == 10
    end

    for initial_state <- [:absent, :expired] do
      @initial_state initial_state
      test "exactly one concurrent caller claims an #{@initial_state} key", %{table: table} do
        :ok = Ets.init(table)

        if @initial_state == :expired do
          :ets.insert(table, {"shared_key", System.monotonic_time(:millisecond) - 120_000})
        end

        parent = self()

        tasks =
          for _ <- 1..64 do
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :claim -> Ets.check_and_mark(table, "shared_key", 60_000)
              end
            end)
          end

        for task <- tasks do
          pid = task.pid
          assert_receive {:ready, ^pid}
        end

        for task <- tasks, do: send(task.pid, :claim)
        results = Task.await_many(tasks)

        assert Enum.frequencies(results) == %{new: 1, seen: 63}
        assert Ets.seen?(table, "shared_key", 60_000)
      end
    end

    test "infinite retention is released only explicitly", %{table: table} do
      :ok = Ets.init(table)
      assert :new = Ets.check_and_mark(table, :retained, :infinity)
      assert :seen = Ets.check_and_mark(table, :retained, :infinity)
      assert Ets.seen?(table, :retained, :infinity)
      assert :ok = Ets.forget(table, :retained)
      assert :new = Ets.check_and_mark(table, :retained, :infinity)
    end
  end
end
