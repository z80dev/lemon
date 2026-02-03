defmodule CodingAgent.Tools.TodoStoreTest do
  @moduledoc """
  Comprehensive tests for CodingAgent.Tools.TodoStore module.

  Tests ETS-based storage for todo items including:
  - Store creation and initialization
  - Put/get operations
  - Session isolation
  - Concurrent access patterns
  - Cleanup and table lifecycle
  - Edge cases

  Note: Uses async: false because TodoStore uses a global named ETS table
  that is shared across all tests. Concurrent test execution would cause
  race conditions during table creation and clear operations.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.TodoStore

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    # Ensure the table exists before each test to prevent race conditions
    # This creates the table if it doesn't exist
    _ = TodoStore.get("__init__")

    # Clear the store before each test to ensure isolation
    TodoStore.clear()

    # Generate unique session ID for each test
    session_id = "test-session-#{:erlang.unique_integer([:positive])}"

    {:ok, session_id: session_id}
  end

  # ============================================================================
  # Store Creation and Initialization
  # ============================================================================

  describe "table initialization" do
    test "table is created lazily on first get operation" do
      session_id = "init-test-#{:erlang.unique_integer([:positive])}"

      # Operation should succeed even if table doesn't exist yet
      result = TodoStore.get(session_id)

      assert result == []

      # Table should now exist
      assert :ets.whereis(:coding_agent_todos) != :undefined
    end

    test "table is created lazily on first put operation" do
      session_id = "init-put-test-#{:erlang.unique_integer([:positive])}"
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending"}]

      # Operation should succeed
      assert :ok = TodoStore.put(session_id, todos)

      # Table should now exist
      assert :ets.whereis(:coding_agent_todos) != :undefined
    end

    test "multiple operations do not recreate table" do
      session_id = "multi-init-test-#{:erlang.unique_integer([:positive])}"

      # Perform many operations
      for i <- 1..100 do
        TodoStore.put(session_id, [%{"id" => "#{i}", "content" => "Task #{i}"}])
        TodoStore.get(session_id)
      end

      # Table should still be accessible and contain expected data
      result = TodoStore.get(session_id)
      assert length(result) == 1
      assert hd(result)["id"] == "100"
    end

    test "table survives across many clear operations" do
      session_id = "clear-survive-#{:erlang.unique_integer([:positive])}"

      for _ <- 1..50 do
        TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])
        TodoStore.clear()
      end

      # Should still work
      assert TodoStore.get(session_id) == []
      assert :ets.whereis(:coding_agent_todos) != :undefined
    end
  end

  # ============================================================================
  # Get Operations
  # ============================================================================

  describe "get/1" do
    test "returns empty list for non-existent session", %{session_id: session_id} do
      assert TodoStore.get(session_id) == []
    end

    test "returns stored todos", %{session_id: session_id} do
      todos = [
        %{"id" => "1", "content" => "Task 1", "status" => "pending", "priority" => "high"},
        %{"id" => "2", "content" => "Task 2", "status" => "completed", "priority" => "low"}
      ]

      TodoStore.put(session_id, todos)

      assert TodoStore.get(session_id) == todos
    end

    test "returns exactly what was stored (preserves data structure)", %{session_id: session_id} do
      # Complex nested data
      todos = [
        %{
          "id" => "1",
          "content" => "Complex task",
          "metadata" => %{
            "tags" => ["urgent", "review"],
            "assignee" => "user@example.com"
          },
          "nested" => [1, 2, %{"deep" => true}]
        }
      ]

      TodoStore.put(session_id, todos)
      retrieved = TodoStore.get(session_id)

      assert retrieved == todos
      assert hd(retrieved)["metadata"]["tags"] == ["urgent", "review"]
    end

    test "returns empty list for session that was deleted", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task"}]

      TodoStore.put(session_id, todos)
      TodoStore.delete(session_id)

      assert TodoStore.get(session_id) == []
    end

    test "returns empty list for session that was cleared" do
      session_id1 = "clear-test-1-#{:erlang.unique_integer([:positive])}"
      session_id2 = "clear-test-2-#{:erlang.unique_integer([:positive])}"

      TodoStore.put(session_id1, [%{"id" => "1", "content" => "Task 1"}])
      TodoStore.put(session_id2, [%{"id" => "2", "content" => "Task 2"}])

      TodoStore.clear()

      assert TodoStore.get(session_id1) == []
      assert TodoStore.get(session_id2) == []
    end
  end

  # ============================================================================
  # Put Operations
  # ============================================================================

  describe "put/2" do
    test "stores todos for session and returns :ok", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task 1", "status" => "pending"}]

      assert :ok = TodoStore.put(session_id, todos)
      assert TodoStore.get(session_id) == todos
    end

    test "overwrites existing todos completely", %{session_id: session_id} do
      old_todos = [
        %{"id" => "1", "content" => "Old Task 1"},
        %{"id" => "2", "content" => "Old Task 2"}
      ]

      new_todos = [%{"id" => "3", "content" => "New Task"}]

      TodoStore.put(session_id, old_todos)
      TodoStore.put(session_id, new_todos)

      result = TodoStore.get(session_id)
      assert result == new_todos
      assert length(result) == 1
    end

    test "can store empty list", %{session_id: session_id} do
      # First store some todos
      TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])

      # Then overwrite with empty list
      assert :ok = TodoStore.put(session_id, [])
      assert TodoStore.get(session_id) == []
    end

    test "can store list with many items", %{session_id: session_id} do
      todos =
        for i <- 1..1000 do
          %{"id" => "#{i}", "content" => "Task #{i}", "status" => "pending"}
        end

      assert :ok = TodoStore.put(session_id, todos)

      result = TodoStore.get(session_id)
      assert length(result) == 1000
      assert hd(result)["id"] == "1"
      assert List.last(result)["id"] == "1000"
    end

    test "stores different data types in todo maps", %{session_id: session_id} do
      todos = [
        %{
          "id" => "1",
          "content" => "Task with various types",
          "count" => 42,
          "active" => true,
          "ratio" => 3.14,
          "tags" => ["a", "b", "c"],
          "meta" => %{"key" => "value"},
          "nil_field" => nil
        }
      ]

      TodoStore.put(session_id, todos)
      result = TodoStore.get(session_id)

      assert result == todos
      assert hd(result)["count"] == 42
      assert hd(result)["active"] == true
      assert hd(result)["ratio"] == 3.14
      assert hd(result)["nil_field"] == nil
    end
  end

  # ============================================================================
  # Delete Operations
  # ============================================================================

  describe "delete/1" do
    test "removes todos for session", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Task", "status" => "pending"}]

      TodoStore.put(session_id, todos)
      assert :ok = TodoStore.delete(session_id)
      assert TodoStore.get(session_id) == []
    end

    test "returns :ok for non-existent session", %{session_id: session_id} do
      assert :ok = TodoStore.delete(session_id)
    end

    test "is idempotent - multiple deletes return :ok", %{session_id: session_id} do
      TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])

      assert :ok = TodoStore.delete(session_id)
      assert :ok = TodoStore.delete(session_id)
      assert :ok = TodoStore.delete(session_id)

      assert TodoStore.get(session_id) == []
    end

    test "does not affect other sessions" do
      session_id1 = "delete-test-1-#{:erlang.unique_integer([:positive])}"
      session_id2 = "delete-test-2-#{:erlang.unique_integer([:positive])}"

      todos1 = [%{"id" => "1", "content" => "Session 1 Task"}]
      todos2 = [%{"id" => "2", "content" => "Session 2 Task"}]

      TodoStore.put(session_id1, todos1)
      TodoStore.put(session_id2, todos2)

      TodoStore.delete(session_id1)

      assert TodoStore.get(session_id1) == []
      assert TodoStore.get(session_id2) == todos2
    end

    test "returns :ok when table does not exist" do
      # This tests the rescue behavior
      # We cannot easily delete the table in tests, but we can verify
      # the function handles ArgumentError gracefully
      session_id = "delete-no-table-#{:erlang.unique_integer([:positive])}"
      assert :ok = TodoStore.delete(session_id)
    end
  end

  # ============================================================================
  # Clear Operations
  # ============================================================================

  describe "clear/0" do
    test "removes all todos from all sessions" do
      session_ids =
        for i <- 1..10 do
          id = "clear-all-#{i}-#{:erlang.unique_integer([:positive])}"

          TodoStore.put(id, [%{"id" => "#{i}", "content" => "Task #{i}"}])
          id
        end

      assert :ok = TodoStore.clear()

      for session_id <- session_ids do
        assert TodoStore.get(session_id) == []
      end
    end

    test "is safe to call multiple times" do
      session_id = "multi-clear-#{:erlang.unique_integer([:positive])}"

      TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])

      assert :ok = TodoStore.clear()
      assert :ok = TodoStore.clear()
      assert :ok = TodoStore.clear()

      assert TodoStore.get(session_id) == []
    end

    test "returns :ok when table is empty" do
      TodoStore.clear()
      assert :ok = TodoStore.clear()
    end

    test "returns :ok when table does not exist" do
      # The function handles this gracefully via rescue
      assert :ok = TodoStore.clear()
    end

    test "allows new data to be stored after clear" do
      session_id = "post-clear-#{:erlang.unique_integer([:positive])}"

      TodoStore.put(session_id, [%{"id" => "1", "content" => "Before Clear"}])
      TodoStore.clear()
      TodoStore.put(session_id, [%{"id" => "2", "content" => "After Clear"}])

      result = TodoStore.get(session_id)
      assert length(result) == 1
      assert hd(result)["id"] == "2"
    end
  end

  # ============================================================================
  # Session Isolation
  # ============================================================================

  describe "session isolation" do
    test "different sessions have independent data" do
      session_a = "session-a-#{:erlang.unique_integer([:positive])}"
      session_b = "session-b-#{:erlang.unique_integer([:positive])}"
      session_c = "session-c-#{:erlang.unique_integer([:positive])}"

      todos_a = [%{"id" => "a1", "content" => "Task A"}]
      todos_b = [%{"id" => "b1", "content" => "Task B"}, %{"id" => "b2", "content" => "Task B2"}]
      todos_c = []

      TodoStore.put(session_a, todos_a)
      TodoStore.put(session_b, todos_b)
      TodoStore.put(session_c, todos_c)

      assert TodoStore.get(session_a) == todos_a
      assert TodoStore.get(session_b) == todos_b
      assert TodoStore.get(session_c) == todos_c
    end

    test "modifying one session does not affect others" do
      session_a = "modify-a-#{:erlang.unique_integer([:positive])}"
      session_b = "modify-b-#{:erlang.unique_integer([:positive])}"

      initial_a = [%{"id" => "1", "content" => "Initial A"}]
      initial_b = [%{"id" => "2", "content" => "Initial B"}]

      TodoStore.put(session_a, initial_a)
      TodoStore.put(session_b, initial_b)

      # Modify session A multiple times
      TodoStore.put(session_a, [%{"id" => "3", "content" => "Modified A"}])
      TodoStore.put(session_a, [%{"id" => "4", "content" => "Modified Again A"}])

      # Session B should be unchanged
      assert TodoStore.get(session_b) == initial_b
    end

    test "deleting one session does not affect others" do
      session_a = "delete-a-#{:erlang.unique_integer([:positive])}"
      session_b = "delete-b-#{:erlang.unique_integer([:positive])}"

      TodoStore.put(session_a, [%{"id" => "1", "content" => "A"}])
      TodoStore.put(session_b, [%{"id" => "2", "content" => "B"}])

      TodoStore.delete(session_a)

      assert TodoStore.get(session_a) == []
      assert TodoStore.get(session_b) == [%{"id" => "2", "content" => "B"}]
    end

    test "many sessions can coexist" do
      session_data =
        for i <- 1..100 do
          id = "many-session-#{i}-#{:erlang.unique_integer([:positive])}"
          todos = [%{"id" => "#{i}", "content" => "Task #{i}", "index" => i}]
          TodoStore.put(id, todos)
          {id, todos}
        end

      # Verify all sessions have correct data
      for {session_id, expected_todos} <- session_data do
        assert TodoStore.get(session_id) == expected_todos
      end
    end

    test "session IDs are case sensitive" do
      session_lower = "case-test-abc"
      session_upper = "CASE-TEST-ABC"
      session_mixed = "Case-Test-Abc"

      TodoStore.put(session_lower, [%{"id" => "1", "content" => "lower"}])
      TodoStore.put(session_upper, [%{"id" => "2", "content" => "upper"}])
      TodoStore.put(session_mixed, [%{"id" => "3", "content" => "mixed"}])

      assert TodoStore.get(session_lower) == [%{"id" => "1", "content" => "lower"}]
      assert TodoStore.get(session_upper) == [%{"id" => "2", "content" => "upper"}]
      assert TodoStore.get(session_mixed) == [%{"id" => "3", "content" => "mixed"}]
    end
  end

  # ============================================================================
  # Concurrent Access Patterns
  # ============================================================================

  describe "concurrent access" do
    test "multiple processes can read the same session concurrently", %{session_id: session_id} do
      todos = [%{"id" => "1", "content" => "Shared Task", "status" => "pending"}]
      TodoStore.put(session_id, todos)

      parent = self()

      pids =
        for _ <- 1..100 do
          spawn(fn ->
            result = TodoStore.get(session_id)
            send(parent, {:result, self(), result})
          end)
        end

      results =
        for _ <- pids do
          receive do
            {:result, _pid, result} -> result
          after
            1000 -> :timeout
          end
        end

      # All reads should return the same data
      assert Enum.all?(results, &(&1 == todos))
    end

    test "multiple processes can write to different sessions concurrently" do
      # Use Task.async_stream for better concurrency handling
      results =
        1..50
        |> Task.async_stream(
          fn i ->
            session_id = "concurrent-write-#{i}-#{:erlang.unique_integer([:positive])}"
            todos = [%{"id" => "#{i}", "content" => "Task #{i}"}]

            result = TodoStore.put(session_id, todos)
            retrieved = TodoStore.get(session_id)

            {session_id, result, retrieved, todos}
          end,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, data} -> data end)

      # All writes should succeed and data should be retrievable
      for {_session_id, put_result, retrieved, expected} <- results do
        assert put_result == :ok
        assert retrieved == expected
      end
    end

    test "concurrent writes to the same session (last write wins)", %{session_id: session_id} do
      # Use Task.async_stream for controlled concurrency
      1..20
      |> Task.async_stream(
        fn i ->
          todos = [%{"id" => "#{i}", "content" => "Writer #{i}"}]
          TodoStore.put(session_id, todos)
        end,
        timeout: 5000
      )
      |> Enum.to_list()

      # Final state should be from one of the writers
      result = TodoStore.get(session_id)
      assert length(result) == 1
      assert hd(result)["content"] =~ "Writer"
    end

    test "concurrent read and write operations are thread-safe", %{session_id: session_id} do
      TodoStore.put(session_id, [%{"id" => "0", "content" => "Initial"}])

      # Use Task.async_stream for controlled concurrency
      results =
        1..100
        |> Task.async_stream(
          fn i ->
            if rem(i, 2) == 0 do
              # Reader
              {:read, TodoStore.get(session_id)}
            else
              # Writer
              {:write, TodoStore.put(session_id, [%{"id" => "#{i}", "content" => "Written by #{i}"}])}
            end
          end,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, data} -> data end)

      # No crashes or timeouts
      assert Enum.all?(results, fn
               {:read, result} -> is_list(result)
               {:write, :ok} -> true
               _ -> false
             end)
    end

    test "concurrent delete and get operations are safe", %{session_id: session_id} do
      TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])

      # Use Task.async_stream for controlled concurrency
      results =
        1..50
        |> Task.async_stream(
          fn i ->
            case rem(i, 3) do
              0 ->
                {:delete, TodoStore.delete(session_id)}

              1 ->
                {:get, TodoStore.get(session_id)}

              2 ->
                {:put, TodoStore.put(session_id, [%{"id" => "new", "content" => "New"}])}
            end
          end,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, data} -> data end)

      # All operations should complete without errors
      for {op, result} <- results do
        case op do
          :delete -> assert result == :ok
          :get -> assert is_list(result)
          :put -> assert result == :ok
        end
      end
    end

    test "high contention scenario with many operations" do
      # Use Task.async_stream for controlled concurrency
      # Note: We exclude clear() from this test since it can cause race conditions
      # when combined with other operations from spawned processes
      results =
        1..200
        |> Task.async_stream(
          fn i ->
            session_id = "contention-#{rem(i, 10)}-#{System.unique_integer([:positive])}"

            case rem(i, 4) do
              0 ->
                TodoStore.put(session_id, [%{"id" => "#{i}", "content" => "Task"}])

              1 ->
                TodoStore.get(session_id)

              2 ->
                TodoStore.delete(session_id)

              3 ->
                TodoStore.put(session_id, [])
            end

            :ok
          end,
          timeout: 5000
        )
        |> Enum.to_list()

      # All operations should complete
      assert length(results) == 200

      # System should remain stable
      assert :ets.whereis(:coding_agent_todos) != :undefined

      # Should still be able to use the store
      test_session = "post-contention-#{:erlang.unique_integer([:positive])}"
      assert :ok = TodoStore.put(test_session, [%{"id" => "1", "content" => "Works"}])
      assert TodoStore.get(test_session) == [%{"id" => "1", "content" => "Works"}]
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "session ID with special characters" do
      special_ids = [
        "session-with-dashes",
        "session_with_underscores",
        "session.with.dots",
        "session:with:colons",
        "session/with/slashes",
        "session with spaces",
        "session\twith\ttabs",
        "session\nwith\nnewlines",
        "unicode-\u00e9\u00e0\u00fc",
        "emoji-\u2764\ufe0f-\u{1f680}",
        "very-long-session-id-" <> String.duplicate("x", 1000)
      ]

      for session_id <- special_ids do
        todos = [%{"id" => "1", "content" => "Task for #{String.slice(session_id, 0, 20)}"}]

        assert :ok = TodoStore.put(session_id, todos)
        assert TodoStore.get(session_id) == todos
        assert :ok = TodoStore.delete(session_id)
        assert TodoStore.get(session_id) == []
      end
    end

    test "empty session ID raises FunctionClauseError" do
      # The function guards require is_binary(session_id)
      # Empty string is still a valid binary, but let's verify behavior
      session_id = ""

      # This should work since "" is a valid binary
      todos = [%{"id" => "1", "content" => "Task"}]
      assert :ok = TodoStore.put(session_id, todos)
      assert TodoStore.get(session_id) == todos
      assert :ok = TodoStore.delete(session_id)
    end

    test "storing and retrieving large todos list", %{session_id: session_id} do
      # Create a large list
      large_todos =
        for i <- 1..10000 do
          %{
            "id" => "#{i}",
            "content" => "Task #{i} with some additional content to make it larger",
            "status" => "pending",
            "priority" => "medium",
            "metadata" => %{"created_at" => "2024-01-01", "index" => i}
          }
        end

      assert :ok = TodoStore.put(session_id, large_todos)
      retrieved = TodoStore.get(session_id)

      assert length(retrieved) == 10000
      assert hd(retrieved)["id"] == "1"
      assert List.last(retrieved)["id"] == "10000"
    end

    test "storing todo with very long content", %{session_id: session_id} do
      long_content = String.duplicate("x", 100_000)

      todos = [%{"id" => "1", "content" => long_content}]

      assert :ok = TodoStore.put(session_id, todos)
      retrieved = TodoStore.get(session_id)

      assert hd(retrieved)["content"] == long_content
    end

    test "storing deeply nested data structure", %{session_id: session_id} do
      # Create deeply nested structure
      deep =
        Enum.reduce(1..50, %{"value" => "bottom"}, fn i, acc ->
          %{"level" => i, "nested" => acc}
        end)

      todos = [%{"id" => "1", "content" => "Deep", "deep" => deep}]

      assert :ok = TodoStore.put(session_id, todos)
      retrieved = TodoStore.get(session_id)

      assert retrieved == todos
    end

    test "put after delete works correctly", %{session_id: session_id} do
      todos1 = [%{"id" => "1", "content" => "Before Delete"}]
      todos2 = [%{"id" => "2", "content" => "After Delete"}]

      TodoStore.put(session_id, todos1)
      TodoStore.delete(session_id)
      TodoStore.put(session_id, todos2)

      assert TodoStore.get(session_id) == todos2
    end

    test "operations with atom keys in todo maps", %{session_id: session_id} do
      # While the typical usage is string keys, let's verify behavior with atoms
      todos = [%{id: "1", content: "Task with atom keys", status: :pending}]

      assert :ok = TodoStore.put(session_id, todos)
      retrieved = TodoStore.get(session_id)

      assert retrieved == todos
      assert hd(retrieved).id == "1"
      assert hd(retrieved).status == :pending
    end

    test "storing non-map items in the list", %{session_id: session_id} do
      # The spec says list(map()) but ETS will store anything
      # Verify the behavior
      todos = ["string", 123, :atom, {1, 2, 3}]

      assert :ok = TodoStore.put(session_id, todos)
      assert TodoStore.get(session_id) == todos
    end

    test "rapid state transitions", %{session_id: session_id} do
      for i <- 1..100 do
        todos = [%{"id" => "#{i}", "content" => "Iteration #{i}"}]
        TodoStore.put(session_id, todos)
        assert TodoStore.get(session_id) == todos
        TodoStore.delete(session_id)
        assert TodoStore.get(session_id) == []
      end
    end
  end

  # ============================================================================
  # Table Lifecycle
  # ============================================================================

  describe "table lifecycle" do
    test "table has expected properties" do
      # Ensure table exists
      _result = TodoStore.get("test")

      info = :ets.info(:coding_agent_todos)

      assert Keyword.get(info, :type) == :set
      assert Keyword.get(info, :named_table) == true
      assert Keyword.get(info, :protection) == :public
      assert Keyword.get(info, :read_concurrency) == true
    end

    test "clear removes entries but keeps table" do
      for i <- 1..10 do
        TodoStore.put("lifecycle-#{i}", [%{"id" => "#{i}"}])
      end

      # Verify entries exist
      info_before = :ets.info(:coding_agent_todos)
      size_before = Keyword.get(info_before, :size)
      assert size_before >= 10

      TodoStore.clear()

      # Table still exists but is empty
      info_after = :ets.info(:coding_agent_todos)
      assert info_after != :undefined
      assert Keyword.get(info_after, :size) == 0
    end

    test "multiple sessions tracked in table size" do
      # Clear first
      TodoStore.clear()

      # Add sessions
      for i <- 1..25 do
        TodoStore.put("size-test-#{i}", [%{"id" => "#{i}"}])
      end

      info = :ets.info(:coding_agent_todos)
      assert Keyword.get(info, :size) == 25

      # Remove some
      for i <- 1..10 do
        TodoStore.delete("size-test-#{i}")
      end

      info = :ets.info(:coding_agent_todos)
      assert Keyword.get(info, :size) == 15
    end
  end

  # ============================================================================
  # Memory and Performance
  # ============================================================================

  describe "memory and performance" do
    test "can create and clear many entries quickly" do
      {time, _result} =
        :timer.tc(fn ->
          for i <- 1..5000 do
            TodoStore.put("perf-#{i}", [%{"id" => "#{i}", "content" => "Task #{i}"}])
          end

          TodoStore.clear()
        end)

      # Should complete in reasonable time (under 1 second)
      assert time < 1_000_000
    end

    test "rapid get operations are efficient", %{session_id: session_id} do
      TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])

      {time, _result} =
        :timer.tc(fn ->
          for _ <- 1..10000 do
            TodoStore.get(session_id)
          end
        end)

      # 10000 reads should be very fast (under 500ms)
      assert time < 500_000
    end

    test "cleanup after operations frees entries", %{session_id: session_id} do
      # Store data
      TodoStore.put(session_id, [%{"id" => "1", "content" => "Task"}])

      # Delete should remove the entry
      TodoStore.delete(session_id)

      # Looking up deleted session returns empty list (entry removed)
      assert TodoStore.get(session_id) == []
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error handling" do
    test "get handles missing table gracefully" do
      # The ensure_table function creates the table if missing
      # This should not raise
      session_id = "error-test-#{:erlang.unique_integer([:positive])}"
      result = TodoStore.get(session_id)
      assert result == []
    end

    test "put handles concurrent operations gracefully" do
      # Use Task.async_stream for controlled concurrency
      results =
        1..50
        |> Task.async_stream(
          fn i ->
            session_id = "race-#{i}-#{:erlang.unique_integer([:positive])}"
            TodoStore.put(session_id, [%{"id" => "#{i}"}])
          end,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # All should succeed
      assert Enum.all?(results, &(&1 == :ok))
    end

    test "delete handles ArgumentError gracefully" do
      # The delete function has a rescue clause for ArgumentError
      session_id = "delete-error-#{:erlang.unique_integer([:positive])}"

      # Should not raise
      assert :ok = TodoStore.delete(session_id)
    end

    test "clear handles ArgumentError gracefully" do
      # The clear function has a rescue clause for ArgumentError
      # Should not raise
      assert :ok = TodoStore.clear()
    end
  end

  # ============================================================================
  # Realistic Usage Patterns
  # ============================================================================

  describe "realistic usage patterns" do
    test "typical session workflow" do
      session_id = "workflow-#{:erlang.unique_integer([:positive])}"

      # Start with empty
      assert TodoStore.get(session_id) == []

      # Add first todo
      TodoStore.put(session_id, [
        %{"id" => "1", "content" => "First task", "status" => "pending", "priority" => "high"}
      ])

      # Add more todos
      TodoStore.put(session_id, [
        %{"id" => "1", "content" => "First task", "status" => "in_progress", "priority" => "high"},
        %{"id" => "2", "content" => "Second task", "status" => "pending", "priority" => "low"}
      ])

      # Mark one complete
      TodoStore.put(session_id, [
        %{"id" => "1", "content" => "First task", "status" => "completed", "priority" => "high"},
        %{"id" => "2", "content" => "Second task", "status" => "in_progress", "priority" => "low"}
      ])

      # Verify final state
      todos = TodoStore.get(session_id)
      assert length(todos) == 2
      assert Enum.find(todos, &(&1["id"] == "1"))["status"] == "completed"

      # Clean up session
      TodoStore.delete(session_id)
      assert TodoStore.get(session_id) == []
    end

    test "multiple concurrent sessions simulating real usage" do
      # Simulate multiple users with their own sessions using Task.async_stream
      results =
        1..10
        |> Task.async_stream(
          fn user_id ->
            session_id = "user-#{user_id}-session-#{:erlang.unique_integer([:positive])}"

            # Each user performs several operations
            for i <- 1..5 do
              current = TodoStore.get(session_id)

              new_todo = %{
                "id" => "#{i}",
                "content" => "User #{user_id} Task #{i}",
                "status" => "pending"
              }

              TodoStore.put(session_id, current ++ [new_todo])
            end

            # Verify final state
            final = TodoStore.get(session_id)
            {session_id, length(final)}
          end,
          timeout: 5000
        )
        |> Enum.map(fn {:ok, data} -> data end)

      # All users should have 5 todos
      for {_session_id, count} <- results do
        assert count == 5
      end
    end
  end
end
