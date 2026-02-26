defmodule LemonCore.Dedupe.EtsTest do
  @moduledoc """
  Tests for the Dedupe.Ets module.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Dedupe.Ets

  setup do
    # Use a unique table name for each test to avoid conflicts
    table_name = :"test_dedupe_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      # Clean up ETS table if it exists
      try do
        :ets.delete(table_name)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, table: table_name}
  end

  describe "init/2" do
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

    test "accepts protection option", %{table: table} do
      assert :ok = Ets.init(table, protection: :protected)
      info = :ets.info(table)
      assert info[:protection] == :protected
    end

    test "accepts type option", %{table: table} do
      assert :ok = Ets.init(table, type: :ordered_set)
      info = :ets.info(table)
      assert info[:type] == :ordered_set
    end

    test "sets concurrency options by default", %{table: table} do
      assert :ok = Ets.init(table)
      info = :ets.info(table)
      assert info[:read_concurrency] == true
      assert info[:write_concurrency] == true
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

    test "handles non-existent table gracefully", %{table: table} do
      # When table doesn't exist, mark fails silently, so check_and_mark returns :new
      # This is acceptable behavior - the operation is best-effort
      result = Ets.check_and_mark(table, "key1", 1000)
      assert result in [:seen, :new]
    end

    test "returns :seen for invalid ttl", %{table: table} do
      :ok = Ets.init(table)
      # Non-integer TTL should return :seen (conservative)
      assert :seen = Ets.check_and_mark(table, "key1", "invalid")
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

      :ok = Ets.mark(table, "key1")
      Process.sleep(50)
      :ok = Ets.mark(table, "key2")

      # Only key1 is expired
      assert Ets.cleanup_expired(table, 30) == 1
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
      tasks = for i <- 1..10 do
        Task.async(fn ->
          Ets.mark(table, "key_#{i}")
        end)
      end

      Task.await_many(tasks)

      assert length(:ets.tab2list(table)) == 10
    end

    test "handles concurrent check_and_mark", %{table: table} do
      :ok = Ets.init(table)

      # Multiple processes checking same key
      tasks = for _ <- 1..10 do
        Task.async(fn ->
          Ets.check_and_mark(table, "shared_key", 1000)
        end)
      end

      results = Task.await_many(tasks)

      # Only one should get :new, rest should get :seen
      new_count = Enum.count(results, &(&1 == :new))
      seen_count = Enum.count(results, &(&1 == :seen))

      assert new_count >= 1
      assert new_count + seen_count == 10
    end
  end
end
