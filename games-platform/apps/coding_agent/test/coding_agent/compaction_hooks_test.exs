defmodule CodingAgent.CompactionHooksTest do
  use ExUnit.Case, async: false

  alias CodingAgent.CompactionHooks

  setup do
    # Clear hooks before each test (CompactionHooks is already started by the application)
    :ok = CompactionHooks.unregister_all_hooks("test_session")
    :ok = CompactionHooks.unregister_all_hooks("session1")
    :ok = CompactionHooks.unregister_all_hooks("session2")

    :ok
  end

  describe "register_hook/3 and unregister_hook/2" do
    test "registers and unregisters a hook" do
      hook_fn = fn -> :ok end

      assert :ok = CompactionHooks.register_hook("test_session", hook_fn, [])
      hooks = CompactionHooks.list_hooks("test_session")
      assert length(hooks) == 1

      hook_id = hd(hooks).id
      assert :ok = CompactionHooks.unregister_hook("test_session", hook_id)
      assert CompactionHooks.list_hooks("test_session") == []
    end

    test "registers multiple hooks" do
      CompactionHooks.register_hook("test_session", fn -> :ok end, [])
      CompactionHooks.register_hook("test_session", fn -> :ok end, [])

      hooks = CompactionHooks.list_hooks("test_session")
      assert length(hooks) == 2
    end

    test "registers hooks with different priorities" do
      CompactionHooks.register_hook("test_session", fn -> :ok end, priority: :high)
      CompactionHooks.register_hook("test_session", fn -> :ok end, priority: :low)
      CompactionHooks.register_hook("test_session", fn -> :ok end, priority: :normal)

      hooks = CompactionHooks.list_hooks("test_session")
      assert length(hooks) == 3

      # Verify priorities are stored
      priorities = Enum.map(hooks, & &1.priority)
      assert :high in priorities
      assert :normal in priorities
      assert :low in priorities
    end
  end

  describe "unregister_all_hooks/1" do
    test "removes all hooks for a session" do
      CompactionHooks.register_hook("test_session", fn -> :ok end, [])
      CompactionHooks.register_hook("test_session", fn -> :ok end, [])

      assert :ok = CompactionHooks.unregister_all_hooks("test_session")
      assert CompactionHooks.list_hooks("test_session") == []
    end

    test "only removes hooks for specified session" do
      CompactionHooks.register_hook("session1", fn -> :ok end, [])
      CompactionHooks.register_hook("session2", fn -> :ok end, [])

      CompactionHooks.unregister_all_hooks("session1")

      assert CompactionHooks.list_hooks("session1") == []
      assert length(CompactionHooks.list_hooks("session2")) == 1
    end
  end

  describe "execute_hooks/2" do
    test "executes hooks and returns summary" do
      test_pid = self()

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          send(test_pid, :hook_executed)
          :ok
        end,
        []
      )

      result = CompactionHooks.execute_hooks("test_session", [])

      assert result.executed == 1
      assert result.succeeded == 1
      assert result.failed == 0
      assert result.timed_out == 0

      assert_receive :hook_executed, 1000
    end

    test "executes hooks in priority order" do
      test_pid = self()

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          send(test_pid, :low_priority)
          :ok
        end,
        priority: :low
      )

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          send(test_pid, :high_priority)
          :ok
        end,
        priority: :high
      )

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          send(test_pid, :normal_priority)
          :ok
        end,
        priority: :normal
      )

      CompactionHooks.execute_hooks("test_session", [])

      # Should receive in order: high, normal, low
      assert_receive :high_priority, 1000
      assert_receive :normal_priority, 1000
      assert_receive :low_priority, 1000
    end

    test "handles hook failures gracefully" do
      CompactionHooks.register_hook(
        "test_session",
        fn ->
          raise "hook error"
        end,
        []
      )

      result = CompactionHooks.execute_hooks("test_session", [])

      assert result.executed == 1
      assert result.succeeded == 0
      assert result.failed == 1
      assert result.timed_out == 0
    end

    test "handles hook timeouts" do
      CompactionHooks.register_hook(
        "test_session",
        fn ->
          Process.sleep(10_000)
          :ok
        end,
        timeout_ms: 50
      )

      result = CompactionHooks.execute_hooks("test_session", [])

      assert result.executed == 1
      assert result.succeeded == 0
      assert result.failed == 0
      assert result.timed_out == 1
    end

    test "continues executing other hooks after failure" do
      test_pid = self()

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          raise "error"
        end,
        []
      )

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          send(test_pid, :second_hook)
          :ok
        end,
        []
      )

      result = CompactionHooks.execute_hooks("test_session", [])

      assert result.executed == 2
      assert result.succeeded == 1
      assert result.failed == 1

      assert_receive :second_hook, 1000
    end
  end

  describe "should_compact_with_hooks?/4" do
    test "returns true when compaction needed and executes hooks" do
      test_pid = self()

      CompactionHooks.register_hook(
        "test_session",
        fn ->
          send(test_pid, :pre_compaction_hook)
          :ok
        end,
        []
      )

      # Context tokens exceed window - reserve
      result =
        CompactionHooks.should_compact_with_hooks?(
          # context_tokens
          9000,
          # context_window
          10000,
          "test_session",
          %{enabled: true, reserve_tokens: 2000}
        )

      assert result == true
      assert_receive :pre_compaction_hook, 1000
    end

    test "returns false when compaction not needed" do
      result =
        CompactionHooks.should_compact_with_hooks?(
          # context_tokens
          1000,
          # context_window
          10000,
          "test_session",
          %{enabled: true, reserve_tokens: 2000}
        )

      assert result == false
    end

    test "returns false when compaction disabled" do
      result =
        CompactionHooks.should_compact_with_hooks?(
          9000,
          10000,
          "test_session",
          %{enabled: false, reserve_tokens: 2000}
        )

      assert result == false
    end
  end

  describe "list_hooks/1" do
    test "returns empty list when no hooks" do
      assert CompactionHooks.list_hooks("nonexistent_session") == []
    end

    test "returns hook details without function" do
      CompactionHooks.register_hook("test_session", fn -> :ok end,
        timeout_ms: 5000,
        priority: :high
      )

      hooks = CompactionHooks.list_hooks("test_session")
      assert length(hooks) == 1

      hook = hd(hooks)
      assert hook.timeout_ms == 5000
      assert hook.priority == :high
      assert is_binary(hook.id)
      assert Map.has_key?(hook, :registered_at)
    end
  end
end
