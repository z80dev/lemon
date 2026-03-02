defmodule LemonChannels.ChannelStateTest do
  use ExUnit.Case, async: false

  alias LemonChannels.ChannelState
  alias LemonCore.ResumeToken
  alias LemonCore.SessionKey

  # Helper to build a Telegram session key for testing.
  defp telegram_session_key(opts \\ []) do
    SessionKey.channel_peer(%{
      agent_id: opts[:agent_id] || "test-agent",
      channel_id: "telegram",
      account_id: opts[:account_id] || "botx",
      peer_kind: opts[:peer_kind] || :group,
      peer_id: opts[:peer_id] || "12345",
      thread_id: opts[:thread_id]
    })
  end

  defp non_telegram_session_key do
    SessionKey.channel_peer(%{
      agent_id: "test-agent",
      channel_id: "discord",
      account_id: "default",
      peer_kind: :dm,
      peer_id: "99999"
    })
  end

  defp cleanup_store_keys(tables, keys) do
    for table <- tables, key <- keys do
      _ = LemonCore.Store.delete(table, key)
    end
  end

  # ── mark_pending_compaction/3 ────────────────────────────────────────

  describe "mark_pending_compaction/3" do
    test "writes a compaction marker for a Telegram session" do
      session_key = telegram_session_key(thread_id: "777")
      store_key = {"botx", 12_345, 777}

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key])
      end)

      assert :ok = ChannelState.mark_pending_compaction(session_key, :overflow)

      marker = LemonCore.Store.get(:telegram_pending_compaction, store_key)
      assert is_map(marker)
      assert marker.reason == "overflow"
      assert marker.session_key == session_key
      assert is_integer(marker.set_at_ms)
    end

    test "merges additional details into the compaction marker" do
      session_key = telegram_session_key(thread_id: "777")
      store_key = {"botx", 12_345, 777}

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key])
      end)

      details = %{input_tokens: 950, threshold_tokens: 900, context_window_tokens: 1000}
      assert :ok = ChannelState.mark_pending_compaction(session_key, :near_limit, details)

      marker = LemonCore.Store.get(:telegram_pending_compaction, store_key)
      assert marker.reason == "near_limit"
      assert marker.input_tokens == 950
      assert marker.threshold_tokens == 900
      assert marker.context_window_tokens == 1000
    end

    test "handles nil thread_id (DM sessions)" do
      session_key = telegram_session_key(peer_kind: :dm)
      store_key = {"botx", 12_345, nil}

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key])
      end)

      assert :ok = ChannelState.mark_pending_compaction(session_key, :overflow)

      marker = LemonCore.Store.get(:telegram_pending_compaction, store_key)
      assert is_map(marker)
      assert marker.reason == "overflow"
    end

    test "silently ignores non-Telegram session keys" do
      session_key = non_telegram_session_key()
      assert :ok = ChannelState.mark_pending_compaction(session_key, :overflow)
    end

    test "silently ignores nil session key" do
      assert :ok = ChannelState.mark_pending_compaction(nil, :overflow)
    end

    test "silently ignores empty string session key" do
      assert :ok = ChannelState.mark_pending_compaction("", :overflow)
    end

    test "filters nil values from details" do
      session_key = telegram_session_key(thread_id: "777")
      store_key = {"botx", 12_345, 777}

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key])
      end)

      details = %{input_tokens: 100, context_window_tokens: nil}
      assert :ok = ChannelState.mark_pending_compaction(session_key, :near_limit, details)

      marker = LemonCore.Store.get(:telegram_pending_compaction, store_key)
      assert marker.input_tokens == 100
      refute Map.has_key?(marker, :context_window_tokens)
    end
  end

  # ── get_pending_compaction/3 ─────────────────────────────────────────

  describe "get_pending_compaction/3" do
    test "returns the compaction marker when present" do
      store_key = {"botx", 12_345, 777}
      payload = %{reason: "overflow", session_key: "test", set_at_ms: 1000}
      _ = LemonCore.Store.put(:telegram_pending_compaction, store_key, payload)

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key])
      end)

      assert %{reason: "overflow"} = ChannelState.get_pending_compaction("botx", 12_345, 777)
    end

    test "returns nil when no marker exists" do
      assert nil == ChannelState.get_pending_compaction("botx", 99_999, nil)
    end
  end

  # ── delete_pending_compaction/3 ──────────────────────────────────────

  describe "delete_pending_compaction/3" do
    test "removes the compaction marker" do
      store_key = {"botx", 12_345, 777}
      _ = LemonCore.Store.put(:telegram_pending_compaction, store_key, %{reason: "overflow"})

      assert :ok = ChannelState.delete_pending_compaction("botx", 12_345, 777)
      assert nil == LemonCore.Store.get(:telegram_pending_compaction, store_key)
    end

    test "returns :ok when marker does not exist" do
      assert :ok = ChannelState.delete_pending_compaction("botx", 99_999, nil)
    end
  end

  # ── reset_resume_state/1 ────────────────────────────────────────────

  describe "reset_resume_state/1" do
    test "clears selected resume, msg_session, and msg_resume for a Telegram session" do
      session_key = telegram_session_key(thread_id: "777")
      account_id = "botx"
      chat_id = 12_345
      thread_id = 777

      selected_key = {account_id, chat_id, thread_id}
      index_key = {account_id, chat_id, thread_id, 9_001}
      gen_index_key = {account_id, chat_id, thread_id, 0, 9_002}
      stale_resume = %ResumeToken{engine: "codex", value: "thread_old"}

      _ = LemonCore.Store.put(:telegram_selected_resume, selected_key, stale_resume)
      _ = LemonCore.Store.put(:telegram_msg_session, index_key, session_key)
      _ = LemonCore.Store.put(:telegram_msg_session, gen_index_key, session_key)
      _ = LemonCore.Store.put(:telegram_msg_resume, index_key, stale_resume)
      _ = LemonCore.Store.put(:telegram_msg_resume, gen_index_key, stale_resume)

      on_exit(fn ->
        cleanup_store_keys(
          [:telegram_selected_resume, :telegram_msg_session, :telegram_msg_resume],
          [selected_key, index_key, gen_index_key]
        )
      end)

      assert :ok = ChannelState.reset_resume_state(session_key)

      assert nil == LemonCore.Store.get(:telegram_selected_resume, selected_key)
      assert nil == LemonCore.Store.get(:telegram_msg_session, index_key)
      assert nil == LemonCore.Store.get(:telegram_msg_session, gen_index_key)
      assert nil == LemonCore.Store.get(:telegram_msg_resume, index_key)
      assert nil == LemonCore.Store.get(:telegram_msg_resume, gen_index_key)
    end

    test "does not affect other thread keys" do
      session_key = telegram_session_key(thread_id: "777")
      other_index_key = {"botx", 12_345, 888, 0, 9_999}
      other_resume = %ResumeToken{engine: "codex", value: "other_thread"}

      _ = LemonCore.Store.put(:telegram_msg_session, other_index_key, "other_session")
      _ = LemonCore.Store.put(:telegram_msg_resume, other_index_key, other_resume)

      on_exit(fn ->
        cleanup_store_keys(
          [:telegram_msg_session, :telegram_msg_resume],
          [other_index_key]
        )
      end)

      assert :ok = ChannelState.reset_resume_state(session_key)

      # Other thread's keys should remain
      assert "other_session" == LemonCore.Store.get(:telegram_msg_session, other_index_key)
      assert other_resume == LemonCore.Store.get(:telegram_msg_resume, other_index_key)
    end

    test "silently ignores non-Telegram session keys" do
      session_key = non_telegram_session_key()
      assert :ok = ChannelState.reset_resume_state(session_key)
    end

    test "silently ignores nil" do
      assert :ok = ChannelState.reset_resume_state(nil)
    end
  end

  # ── put_resume/5 and get_resume/4 ──────────────────────────────────

  describe "put_resume/5 and get_resume/4" do
    test "stores and retrieves a resume token by message ID" do
      resume = %ResumeToken{engine: "codex", value: "thread_abc"}
      store_key = {"botx", 12_345, 777, 101}

      on_exit(fn ->
        cleanup_store_keys([:telegram_msg_resume], [store_key])
      end)

      assert :ok = ChannelState.put_resume("botx", 12_345, 777, 101, resume)
      assert %ResumeToken{engine: "codex", value: "thread_abc"} =
               ChannelState.get_resume("botx", 12_345, 777, 101)
    end

    test "returns nil when no resume token exists" do
      assert nil == ChannelState.get_resume("botx", 99_999, nil, 9_999)
    end

    test "handles nil thread_id" do
      resume = %ResumeToken{engine: "codex", value: "dm_thread"}
      store_key = {"botx", 12_345, nil, 200}

      on_exit(fn ->
        cleanup_store_keys([:telegram_msg_resume], [store_key])
      end)

      assert :ok = ChannelState.put_resume("botx", 12_345, nil, 200, resume)
      assert %ResumeToken{value: "dm_thread"} = ChannelState.get_resume("botx", 12_345, nil, 200)
    end
  end

  # ── put_resume_with_generation/6 and get_resume_with_generation/5 ──

  describe "put_resume_with_generation/6 and get_resume_with_generation/5" do
    test "stores and retrieves with generation key" do
      resume = %ResumeToken{engine: "codex", value: "gen_thread"}
      store_key = {"botx", 12_345, 777, 1, 101}

      on_exit(fn ->
        cleanup_store_keys([:telegram_msg_resume], [store_key])
      end)

      assert :ok = ChannelState.put_resume_with_generation("botx", 12_345, 777, 1, 101, resume)
      assert %ResumeToken{value: "gen_thread"} =
               ChannelState.get_resume_with_generation("botx", 12_345, 777, 1, 101)
    end

    test "falls back to legacy key when generation is 0" do
      resume = %ResumeToken{engine: "codex", value: "legacy_thread"}
      legacy_key = {"botx", 12_345, 777, 101}

      on_exit(fn ->
        cleanup_store_keys([:telegram_msg_resume], [legacy_key])
      end)

      # Write using the legacy (no-generation) key format
      _ = LemonCore.Store.put(:telegram_msg_resume, legacy_key, resume)

      assert %ResumeToken{value: "legacy_thread"} =
               ChannelState.get_resume_with_generation("botx", 12_345, 777, 0, 101)
    end

    test "returns nil when no resume exists for non-zero generation" do
      assert nil == ChannelState.get_resume_with_generation("botx", 99_999, nil, 2, 101)
    end
  end

  # ── Selected Resume ─────────────────────────────────────────────────

  describe "put_selected_resume/4, get_selected_resume/3, delete_selected_resume/3" do
    test "stores, retrieves, and deletes a selected resume token" do
      resume = %ResumeToken{engine: "codex", value: "selected_thread"}
      store_key = {"botx", 12_345, 777}

      on_exit(fn ->
        cleanup_store_keys([:telegram_selected_resume], [store_key])
      end)

      assert :ok = ChannelState.put_selected_resume("botx", 12_345, 777, resume)
      assert %ResumeToken{value: "selected_thread"} =
               ChannelState.get_selected_resume("botx", 12_345, 777)

      assert :ok = ChannelState.delete_selected_resume("botx", 12_345, 777)
      assert nil == ChannelState.get_selected_resume("botx", 12_345, 777)
    end

    test "handles nil thread_id" do
      resume = %ResumeToken{engine: "codex", value: "dm_selected"}
      store_key = {"botx", 12_345, nil}

      on_exit(fn ->
        cleanup_store_keys([:telegram_selected_resume], [store_key])
      end)

      assert :ok = ChannelState.put_selected_resume("botx", 12_345, nil, resume)
      assert %ResumeToken{value: "dm_selected"} =
               ChannelState.get_selected_resume("botx", 12_345, nil)
    end

    test "returns nil when no selected resume exists" do
      assert nil == ChannelState.get_selected_resume("botx", 99_999, nil)
    end
  end

  # ── Message Session Index ───────────────────────────────────────────

  describe "put_msg_session/6 and get_msg_session/5" do
    test "stores and retrieves a session key by message ID with generation" do
      store_key = {"botx", 12_345, 777, 0, 101}

      on_exit(fn ->
        cleanup_store_keys([:telegram_msg_session], [store_key])
      end)

      assert :ok = ChannelState.put_msg_session("botx", 12_345, 777, 0, 101, "my_session_key")
      assert "my_session_key" = ChannelState.get_msg_session("botx", 12_345, 777, 0, 101)
    end

    test "falls back to legacy key when generation is 0" do
      legacy_key = {"botx", 12_345, 777, 101}

      on_exit(fn ->
        cleanup_store_keys([:telegram_msg_session], [legacy_key])
      end)

      _ = LemonCore.Store.put(:telegram_msg_session, legacy_key, "legacy_session")

      assert "legacy_session" = ChannelState.get_msg_session("botx", 12_345, 777, 0, 101)
    end

    test "returns nil when no session exists" do
      assert nil == ChannelState.get_msg_session("botx", 99_999, nil, 0, 9_999)
    end

    test "returns nil for non-zero generation with no match and no legacy key" do
      assert nil == ChannelState.get_msg_session("botx", 99_999, nil, 2, 9_999)
    end
  end

  # ── Known Targets ───────────────────────────────────────────────────

  describe "list_known_targets/0" do
    test "returns empty list when no targets exist" do
      # This test relies on isolation; if other tests add targets they
      # are cleaned up. A fresh store should be empty for this table.
      targets = ChannelState.list_known_targets()
      assert is_list(targets)
    end

    test "returns stored known targets" do
      key = {"botx", -1_001_234, nil}
      entry = %{
        channel_id: "telegram",
        account_id: "botx",
        peer_kind: :group,
        peer_id: "-1001234",
        chat_id: -1_001_234,
        chat_type: "supergroup",
        chat_title: "Test Group"
      }

      on_exit(fn ->
        cleanup_store_keys([:telegram_known_targets], [key])
      end)

      _ = LemonCore.Store.put(:telegram_known_targets, key, entry)
      targets = ChannelState.list_known_targets()

      assert Enum.any?(targets, fn {k, _v} -> k == key end)
    end
  end

  describe "get_known_target/3" do
    test "returns the target entry when present" do
      key = {"botx", -1_005_678, nil}
      entry = %{
        channel_id: "telegram",
        account_id: "botx",
        peer_kind: :group,
        peer_id: "-1005678",
        chat_id: -1_005_678,
        chat_type: "supergroup"
      }

      on_exit(fn ->
        cleanup_store_keys([:telegram_known_targets], [key])
      end)

      _ = LemonCore.Store.put(:telegram_known_targets, key, entry)
      assert %{chat_type: "supergroup"} = ChannelState.get_known_target("botx", -1_005_678, nil)
    end

    test "returns nil when no target exists" do
      assert nil == ChannelState.get_known_target("botx", -9_999_999, nil)
    end
  end

  describe "put_known_target/4" do
    test "stores a known target entry" do
      key = {"botx", -1_009_999, nil}
      entry = %{
        channel_id: "telegram",
        account_id: "botx",
        peer_kind: :group,
        peer_id: "-1009999",
        chat_id: -1_009_999,
        chat_type: "group"
      }

      on_exit(fn ->
        cleanup_store_keys([:telegram_known_targets], [key])
      end)

      assert :ok = ChannelState.put_known_target("botx", -1_009_999, nil, entry)
      stored = LemonCore.Store.get(:telegram_known_targets, key)
      assert stored.chat_type == "group"
    end
  end

  # ── Integration: mark_pending_compaction + reset_resume_state ───────

  describe "integration: compaction workflow" do
    test "mark_pending_compaction then reset_resume_state clears both compaction and resume state" do
      session_key = telegram_session_key(thread_id: "777")
      account_id = "botx"
      chat_id = 12_345
      thread_id = 777

      pending_key = {account_id, chat_id, thread_id}
      selected_key = {account_id, chat_id, thread_id}
      index_key = {account_id, chat_id, thread_id, 0, 9_001}
      stale_resume = %ResumeToken{engine: "codex", value: "stale"}

      _ = LemonCore.Store.put(:telegram_selected_resume, selected_key, stale_resume)
      _ = LemonCore.Store.put(:telegram_msg_session, index_key, session_key)
      _ = LemonCore.Store.put(:telegram_msg_resume, index_key, stale_resume)

      on_exit(fn ->
        cleanup_store_keys(
          [
            :telegram_pending_compaction,
            :telegram_selected_resume,
            :telegram_msg_session,
            :telegram_msg_resume
          ],
          [pending_key, selected_key, index_key]
        )
      end)

      # Mark compaction
      assert :ok = ChannelState.mark_pending_compaction(session_key, :overflow)
      assert %{reason: "overflow"} = ChannelState.get_pending_compaction(account_id, chat_id, thread_id)

      # Reset resume state
      assert :ok = ChannelState.reset_resume_state(session_key)

      assert nil == LemonCore.Store.get(:telegram_selected_resume, selected_key)
      assert nil == LemonCore.Store.get(:telegram_msg_session, index_key)
      assert nil == LemonCore.Store.get(:telegram_msg_resume, index_key)

      # Compaction marker should still be present (reset_resume_state does not clear it)
      assert %{reason: "overflow"} = ChannelState.get_pending_compaction(account_id, chat_id, thread_id)
    end
  end

  # ── Edge cases ──────────────────────────────────────────────────────

  describe "edge cases" do
    test "multiple calls to mark_pending_compaction overwrite previous marker" do
      session_key = telegram_session_key(thread_id: "777")
      store_key = {"botx", 12_345, 777}

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key])
      end)

      assert :ok = ChannelState.mark_pending_compaction(session_key, :overflow)
      assert :ok = ChannelState.mark_pending_compaction(session_key, :near_limit, %{input_tokens: 500})

      marker = ChannelState.get_pending_compaction("botx", 12_345, 777)
      assert marker.reason == "near_limit"
      assert marker.input_tokens == 500
    end

    test "different account_ids are isolated" do
      session_key_a = telegram_session_key(account_id: "bot_a", thread_id: "777")
      session_key_b = telegram_session_key(account_id: "bot_b", thread_id: "777")
      store_key_a = {"bot_a", 12_345, 777}
      store_key_b = {"bot_b", 12_345, 777}

      on_exit(fn ->
        cleanup_store_keys([:telegram_pending_compaction], [store_key_a, store_key_b])
      end)

      assert :ok = ChannelState.mark_pending_compaction(session_key_a, :overflow)
      assert :ok = ChannelState.mark_pending_compaction(session_key_b, :near_limit)

      assert %{reason: "overflow"} = ChannelState.get_pending_compaction("bot_a", 12_345, 777)
      assert %{reason: "near_limit"} = ChannelState.get_pending_compaction("bot_b", 12_345, 777)
    end
  end
end
