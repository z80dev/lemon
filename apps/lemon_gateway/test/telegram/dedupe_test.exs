defmodule LemonGateway.Telegram.DedupeTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Telegram.Dedupe

  # The Dedupe module uses a named ETS table, so we cannot run tests async.
  # We need to ensure the table is properly initialized before each test.

  @table :lemon_gateway_telegram_dedupe

  setup do
    # Ensure we own the table for this test process.
    #
    # The table name is global across the node, and other tests (or supervised apps)
    # may create it under a different owner process. If that owner stops during this
    # test, ETS will delete the table out from under us. Recreate it here so the
    # current test process owns it.
    if :ets.info(@table) != :undefined do
      :ets.delete(@table)
    end

    :ok = Dedupe.init()

    :ok
  end

  # ============================================================================
  # Table Initialization
  # ============================================================================

  describe "init/0" do
    test "creates the ETS table if it doesn't exist" do
      # Delete table if it exists to test creation
      if :ets.info(@table) != :undefined do
        :ets.delete(@table)
      end

      assert Dedupe.init() == :ok
      assert :ets.info(@table) != :undefined
    end

    test "returns :ok if table already exists" do
      # Table should already exist from setup
      assert :ets.info(@table) != :undefined
      assert Dedupe.init() == :ok
    end

    test "is idempotent - multiple calls do not raise" do
      assert Dedupe.init() == :ok
      assert Dedupe.init() == :ok
      assert Dedupe.init() == :ok
    end

    test "table is public and named" do
      info = :ets.info(@table)
      assert info[:named_table] == true
      assert info[:protection] == :public
      assert info[:type] == :set
    end
  end

  # ============================================================================
  # Marking Keys
  # ============================================================================

  describe "mark/1" do
    test "returns :ok for a new key" do
      assert Dedupe.mark("key1") == :ok
    end

    test "stores the key in the ETS table" do
      Dedupe.mark("key1")
      assert [{_, _ts}] = :ets.lookup(@table, "key1")
    end

    test "stores timestamp with the key" do
      before = System.monotonic_time(:millisecond)
      Dedupe.mark("key1")
      after_mark = System.monotonic_time(:millisecond)

      [{_, ts}] = :ets.lookup(@table, "key1")
      assert ts >= before
      assert ts <= after_mark
    end

    test "can mark multiple different keys" do
      assert Dedupe.mark("key1") == :ok
      assert Dedupe.mark("key2") == :ok
      assert Dedupe.mark("key3") == :ok

      assert length(:ets.tab2list(@table)) == 3
    end

    test "updates timestamp when marking an existing key" do
      Dedupe.mark("key1")
      [{_, ts1}] = :ets.lookup(@table, "key1")

      Process.sleep(2)

      Dedupe.mark("key1")
      [{_, ts2}] = :ets.lookup(@table, "key1")

      assert ts2 > ts1
    end

    test "handles integer keys" do
      assert Dedupe.mark(12345) == :ok
      assert [{12345, _ts}] = :ets.lookup(@table, 12345)
    end

    test "handles tuple keys" do
      key = {:chat, 123, :msg, 456}
      assert Dedupe.mark(key) == :ok
      assert [{^key, _ts}] = :ets.lookup(@table, key)
    end

    test "handles atom keys" do
      assert Dedupe.mark(:test_key) == :ok
      assert [{:test_key, _ts}] = :ets.lookup(@table, :test_key)
    end
  end

  # ============================================================================
  # Checking for Seen Keys
  # ============================================================================

  describe "seen?/2" do
    test "returns false for a key that was never marked" do
      refute Dedupe.seen?("unknown_key", 5000)
    end

    test "returns true for a recently marked key within TTL" do
      Dedupe.mark("key1")
      assert Dedupe.seen?("key1", 5000)
    end

    test "returns false for a key that has expired past TTL" do
      Dedupe.mark("key1")
      # Sleep longer than TTL
      Process.sleep(50)
      refute Dedupe.seen?("key1", 10)
    end

    test "deletes expired entries from the table" do
      Dedupe.mark("key1")
      Process.sleep(50)

      # Should return false and delete the entry
      refute Dedupe.seen?("key1", 10)

      # Entry should be gone
      assert :ets.lookup(@table, "key1") == []
    end

    test "does not delete entries that are still within TTL" do
      Dedupe.mark("key1")

      # Should return true and keep the entry
      assert Dedupe.seen?("key1", 5000)

      # Entry should still exist
      assert [{_, _ts}] = :ets.lookup(@table, "key1")
    end

    test "handles very short TTL" do
      Dedupe.mark("key1")
      Process.sleep(2)
      refute Dedupe.seen?("key1", 1)
    end

    test "handles very long TTL" do
      Dedupe.mark("key1")
      Process.sleep(10)
      assert Dedupe.seen?("key1", 1_000_000)
    end

    test "handles zero TTL" do
      Dedupe.mark("key1")
      # With TTL of 0, even immediate check should fail
      # because now - ts > 0 (unless exactly same millisecond)
      Process.sleep(1)
      refute Dedupe.seen?("key1", 0)
    end

    test "returns false for nil key" do
      refute Dedupe.seen?(nil, 5000)
    end

    test "can check different keys independently" do
      Dedupe.mark("key1")
      Process.sleep(50)
      Dedupe.mark("key2")

      # key1 expired, key2 still valid
      refute Dedupe.seen?("key1", 10)
      assert Dedupe.seen?("key2", 5000)
    end
  end

  # ============================================================================
  # Check and Mark (Combined Operation)
  # ============================================================================

  describe "check_and_mark/2" do
    test "returns :new for a key that was never seen" do
      assert Dedupe.check_and_mark("key1", 5000) == :new
    end

    test "marks the key when returning :new" do
      Dedupe.check_and_mark("key1", 5000)
      assert [{_, _ts}] = :ets.lookup(@table, "key1")
    end

    test "returns :seen for a key that was already marked within TTL" do
      Dedupe.mark("key1")
      assert Dedupe.check_and_mark("key1", 5000) == :seen
    end

    test "returns :new for a key that has expired" do
      Dedupe.mark("key1")
      Process.sleep(50)
      assert Dedupe.check_and_mark("key1", 10) == :new
    end

    test "updates timestamp when key has expired and is re-marked" do
      Dedupe.mark("key1")
      [{_, ts1}] = :ets.lookup(@table, "key1")

      Process.sleep(50)

      # Key has expired, should return :new and update
      assert Dedupe.check_and_mark("key1", 10) == :new

      [{_, ts2}] = :ets.lookup(@table, "key1")
      assert ts2 > ts1
    end

    test "does not update timestamp when returning :seen" do
      Dedupe.mark("key1")
      [{_, ts1}] = :ets.lookup(@table, "key1")

      # Key is still valid, should return :seen
      assert Dedupe.check_and_mark("key1", 5000) == :seen

      [{_, ts2}] = :ets.lookup(@table, "key1")
      # Timestamp should be unchanged (same entry)
      assert ts1 == ts2
    end

    test "handles rapid sequential calls for the same key" do
      # First call should mark as new
      assert Dedupe.check_and_mark("key1", 5000) == :new

      # Subsequent calls should be seen
      assert Dedupe.check_and_mark("key1", 5000) == :seen
      assert Dedupe.check_and_mark("key1", 5000) == :seen
      assert Dedupe.check_and_mark("key1", 5000) == :seen
    end

    test "handles different keys independently" do
      assert Dedupe.check_and_mark("key1", 5000) == :new
      assert Dedupe.check_and_mark("key2", 5000) == :new
      assert Dedupe.check_and_mark("key3", 5000) == :new

      assert Dedupe.check_and_mark("key1", 5000) == :seen
      assert Dedupe.check_and_mark("key2", 5000) == :seen
      assert Dedupe.check_and_mark("key3", 5000) == :seen
    end
  end

  # ============================================================================
  # TTL Expiration Behavior
  # ============================================================================

  describe "TTL expiration" do
    test "key becomes expired exactly at TTL boundary" do
      Dedupe.mark("key1")

      # Within TTL
      Process.sleep(50)
      assert Dedupe.seen?("key1", 100)

      # Just past TTL (with some buffer for timing)
      Process.sleep(100)
      refute Dedupe.seen?("key1", 100)
    end

    test "multiple keys with different expiration times" do
      Dedupe.mark("key1")
      Process.sleep(30)
      Dedupe.mark("key2")
      Process.sleep(30)
      Dedupe.mark("key3")

      # At this point (60ms total):
      # key1 was marked 60ms ago
      # key2 was marked 30ms ago
      # key3 was marked 0ms ago

      # With 50ms TTL, key1 should be expired
      refute Dedupe.seen?("key1", 50)
      assert Dedupe.seen?("key2", 50)
      assert Dedupe.seen?("key3", 50)
    end

    test "expired key can be re-marked successfully" do
      Dedupe.mark("key1")
      Process.sleep(50)

      # Should be expired
      refute Dedupe.seen?("key1", 10)

      # Re-mark it
      Dedupe.mark("key1")

      # Should be valid again
      assert Dedupe.seen?("key1", 5000)
    end

    test "TTL is calculated from mark time, not check time" do
      Dedupe.mark("key1")

      # Multiple checks should not reset the TTL
      for _ <- 1..5 do
        Process.sleep(10)
        Dedupe.seen?("key1", 100)
      end

      # After 50ms of checks, the key should still expire based on original mark time
      Process.sleep(60)
      refute Dedupe.seen?("key1", 100)
    end
  end

  # ============================================================================
  # Concurrent Access
  # ============================================================================

  describe "concurrent access" do
    test "multiple processes can mark different keys concurrently" do
      parent = self()

      pids =
        for i <- 1..100 do
          spawn(fn ->
            key = "key_#{i}"
            result = Dedupe.mark(key)
            send(parent, {:done, self(), key, result})
          end)
        end

      results =
        for _ <- pids do
          receive do
            {:done, _pid, key, result} -> {key, result}
          after
            1000 -> :timeout
          end
        end

      # All should succeed
      assert Enum.all?(results, fn {_key, result} -> result == :ok end)

      # All keys should be in the table
      assert length(:ets.tab2list(@table)) == 100
    end

    test "multiple processes can check the same key concurrently" do
      Dedupe.mark("shared_key")
      parent = self()

      pids =
        for _ <- 1..100 do
          spawn(fn ->
            result = Dedupe.seen?("shared_key", 5000)
            send(parent, {:done, self(), result})
          end)
        end

      results =
        for _ <- pids do
          receive do
            {:done, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      # All should see the key
      assert Enum.all?(results, &(&1 == true))
    end

    test "concurrent check_and_mark for the same key" do
      parent = self()

      # Multiple processes trying to check_and_mark the same key
      pids =
        for _ <- 1..50 do
          spawn(fn ->
            result = Dedupe.check_and_mark("race_key", 5000)
            send(parent, {:done, self(), result})
          end)
        end

      results =
        for _ <- pids do
          receive do
            {:done, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      # At least one should be :new (first one to mark)
      # The rest should be :seen (or some could be :new due to race condition)
      new_count = Enum.count(results, &(&1 == :new))
      seen_count = Enum.count(results, &(&1 == :seen))

      # Due to race condition, multiple processes might see :new
      # But we should have a mix of results
      assert new_count >= 1
      assert new_count + seen_count == 50
    end

    test "concurrent mark and seen operations are thread-safe" do
      parent = self()

      # Some processes mark, some check
      pids =
        for i <- 1..100 do
          spawn(fn ->
            key = "concurrent_key"

            if rem(i, 2) == 0 do
              result = Dedupe.mark(key)
              send(parent, {:mark, self(), result})
            else
              # Small delay to let some marks happen first
              Process.sleep(rem(i, 5))
              result = Dedupe.seen?(key, 5000)
              send(parent, {:seen, self(), result})
            end
          end)
        end

      # Collect results
      for _ <- pids do
        receive do
          {:mark, _pid, result} ->
            assert result == :ok

          {:seen, _pid, result} ->
            # Result could be true or false depending on timing
            assert is_boolean(result)
        after
          1000 -> flunk("Timeout waiting for process")
        end
      end
    end

    test "high contention scenario" do
      parent = self()

      # Many processes doing various operations on same keys
      pids =
        for i <- 1..200 do
          spawn(fn ->
            key = "key_#{rem(i, 10)}"

            case rem(i, 4) do
              0 -> Dedupe.mark(key)
              1 -> Dedupe.seen?(key, 5000)
              2 -> Dedupe.check_and_mark(key, 5000)
              3 -> Dedupe.seen?(key, 1)
            end

            send(parent, {:done, self()})
          end)
        end

      # Wait for all to complete
      for _ <- pids do
        receive do
          {:done, _pid} -> :ok
        after
          2000 -> flunk("Timeout waiting for process")
        end
      end

      # System should remain stable - verify we can still use it
      assert Dedupe.mark("stability_check") == :ok
      assert Dedupe.seen?("stability_check", 5000) == true
    end
  end

  # ============================================================================
  # ETS Table Lifecycle
  # ============================================================================

  describe "ETS table lifecycle" do
    test "table survives across many operations" do
      for i <- 1..1000 do
        Dedupe.mark("key_#{i}")
        Dedupe.seen?("key_#{i}", 5000)
      end

      # Table should still be accessible
      assert :ets.info(@table) != :undefined
    end

    test "can handle large number of entries" do
      for i <- 1..10_000 do
        Dedupe.mark("key_#{i}")
      end

      assert length(:ets.tab2list(@table)) == 10_000
    end

    test "table info returns correct properties" do
      info = :ets.info(@table)

      assert info[:type] == :set
      assert info[:named_table] == true
      assert info[:protection] == :public
    end

    test "init does not clear existing entries" do
      Dedupe.mark("existing_key")

      # Call init again
      Dedupe.init()

      # Entry should still exist
      assert [{_, _ts}] = :ets.lookup(@table, "existing_key")
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles nil key for mark" do
      # mark with nil should work (nil is a valid ETS key)
      assert Dedupe.mark(nil) == :ok
      assert [{nil, _ts}] = :ets.lookup(@table, nil)
    end

    test "handles empty string key" do
      assert Dedupe.mark("") == :ok
      assert Dedupe.seen?("", 5000) == true
    end

    test "handles very long string key" do
      long_key = String.duplicate("a", 10_000)
      assert Dedupe.mark(long_key) == :ok
      assert Dedupe.seen?(long_key, 5000) == true
    end

    test "handles unicode keys" do
      unicode_key = "key_\u{1F600}_emoji_test"
      assert Dedupe.mark(unicode_key) == :ok
      assert Dedupe.seen?(unicode_key, 5000) == true
    end

    test "handles binary keys with null bytes" do
      binary_key = <<0, 1, 2, 3, 0, 0, 255>>
      assert Dedupe.mark(binary_key) == :ok
      assert Dedupe.seen?(binary_key, 5000) == true
    end

    test "handles complex tuple keys" do
      complex_key = {:chat_id, 123, :message_id, 456, :from, "user@example.com"}
      assert Dedupe.mark(complex_key) == :ok
      assert Dedupe.seen?(complex_key, 5000) == true
    end

    test "handles map keys" do
      map_key = %{chat_id: 123, message_id: 456}
      assert Dedupe.mark(map_key) == :ok
      assert Dedupe.seen?(map_key, 5000) == true
    end

    test "handles pid keys" do
      pid_key = self()
      assert Dedupe.mark(pid_key) == :ok
      assert Dedupe.seen?(pid_key, 5000) == true
    end

    test "handles reference keys" do
      ref_key = make_ref()
      assert Dedupe.mark(ref_key) == :ok
      assert Dedupe.seen?(ref_key, 5000) == true
    end

    test "handles negative TTL gracefully" do
      Dedupe.mark("key1")
      # Negative TTL should mean the key is always expired
      refute Dedupe.seen?("key1", -1)
    end

    test "handles large TTL values" do
      Dedupe.mark("key1")
      # Very large TTL (effectively infinite)
      assert Dedupe.seen?("key1", 999_999_999_999)
    end
  end

  # ============================================================================
  # Realistic Usage Patterns
  # ============================================================================

  describe "realistic usage patterns" do
    test "telegram message deduplication pattern" do
      # Simulate typical Telegram update deduplication
      update_ids = [1001, 1002, 1003, 1001, 1002, 1004, 1001]

      results =
        Enum.map(update_ids, fn id ->
          key = {:telegram_update, id}
          Dedupe.check_and_mark(key, 60_000)
        end)

      # First occurrences should be :new, duplicates should be :seen
      assert results == [:new, :new, :new, :seen, :seen, :new, :seen]
    end

    test "multi-chat deduplication" do
      # Different chat_ids should be tracked separately
      chats = [100, 200, 100, 300, 200, 100]
      msg_id = 1

      results =
        Enum.map(chats, fn chat_id ->
          key = {:chat, chat_id, :msg, msg_id}
          Dedupe.check_and_mark(key, 60_000)
        end)

      # Each chat_id first occurrence should be :new
      assert results == [:new, :new, :seen, :new, :seen, :seen]
    end

    test "webhook retry deduplication" do
      # Simulate webhook retries with same message
      webhook_id = "webhook_abc123"

      # First delivery attempt
      assert Dedupe.check_and_mark(webhook_id, 5000) == :new

      # Retry attempts within TTL should be seen
      Process.sleep(10)
      assert Dedupe.check_and_mark(webhook_id, 5000) == :seen

      Process.sleep(10)
      assert Dedupe.check_and_mark(webhook_id, 5000) == :seen

      # After TTL expires, should be new again (allowing reprocessing)
      Process.sleep(100)
      assert Dedupe.check_and_mark(webhook_id, 50) == :new
    end

    test "burst of rapid duplicate messages" do
      # Simulate rapid-fire duplicate messages (e.g., double-tap send)
      message_key = {:msg, "chat_123", "msg_456"}

      results =
        for _ <- 1..10 do
          Dedupe.check_and_mark(message_key, 5000)
        end

      # First should be :new, rest should be :seen
      assert hd(results) == :new
      assert Enum.all?(tl(results), &(&1 == :seen))
    end
  end

  # ============================================================================
  # Memory and Cleanup
  # ============================================================================

  describe "memory and cleanup" do
    test "table can be manually cleared" do
      for i <- 1..100 do
        Dedupe.mark("key_#{i}")
      end

      assert length(:ets.tab2list(@table)) == 100

      :ets.delete_all_objects(@table)

      assert length(:ets.tab2list(@table)) == 0
    end

    test "expired entries are cleaned up on access" do
      # Mark several keys
      for i <- 1..10 do
        Dedupe.mark("key_#{i}")
      end

      Process.sleep(50)

      # Check each key with short TTL - should clean them up
      for i <- 1..10 do
        refute Dedupe.seen?("key_#{i}", 10)
      end

      # Table should be empty now
      assert length(:ets.tab2list(@table)) == 0
    end

    test "only expired entries are cleaned up" do
      Dedupe.mark("old_key")
      Process.sleep(50)
      Dedupe.mark("new_key")

      # Check old key - should expire and be cleaned
      refute Dedupe.seen?("old_key", 10)

      # New key should still exist
      assert Dedupe.seen?("new_key", 5000)

      # Table should have only the new key
      entries = :ets.tab2list(@table)
      assert length(entries) == 1
      assert [{"new_key", _ts}] = entries
    end
  end
end
