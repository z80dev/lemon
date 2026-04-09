defmodule LemonChannels.PresentationStateTest do
  use ExUnit.Case, async: false

  alias LemonChannels.PresentationState
  alias LemonCore.DeliveryRoute

  @route %DeliveryRoute{
    channel_id: "telegram",
    account_id: "test",
    peer_kind: :dm,
    peer_id: "12345",
    thread_id: nil
  }

  setup do
    case Process.whereis(PresentationState) do
      nil ->
        {:ok, pid} = PresentationState.start_link([])

        on_exit(fn ->
          if Process.alive?(pid), do: GenServer.stop(pid)
        end)

      _ ->
        :ok
    end

    :ok
  end

  describe "get/3 with stale pending_create_ref" do
    test "evicts stale pending_create_ref after TTL" do
      run_id = "run_stale_#{System.unique_integer()}"
      ref = make_ref()

      # Register a pending create
      PresentationState.register_pending_create(
        @route,
        run_id,
        :answer,
        ref,
        1,
        12345
      )

      # Immediately, the ref should still be pending
      entry = PresentationState.get(@route, run_id, :answer)
      assert is_reference(entry.pending_create_ref)

      # Manually backdate the entry to simulate staleness
      # We can't directly set pending_create_at, but we can verify
      # the TTL mechanism by checking the entry after the call
      # The TTL is 30s, so we test the GC logic directly via the state
      state = :sys.get_state(PresentationState)

      key =
        {@route.channel_id, @route.account_id, @route.peer_kind, @route.peer_id, @route.thread_id,
         run_id, :answer}

      entry = Map.get(state.entries, key)
      assert is_reference(entry.pending_create_ref)

      # Backdate the pending_create_at to simulate 31 seconds ago
      stale_at = System.monotonic_time(:millisecond) - 31_000
      stale_entry = %{entry | pending_create_at: stale_at}

      :sys.replace_state(PresentationState, fn s ->
        put_in(s, [:entries, key], stale_entry)
      end)

      # Now calling get should trigger GC and clear the stale ref
      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.pending_create_ref)
      assert is_nil(entry.pending_create_at)

      # Verify the refs map was also cleaned
      state = :sys.get_state(PresentationState)
      refute Map.has_key?(state.refs, ref)
    end

    test "does not evict fresh pending_create_ref" do
      run_id = "run_fresh_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(
        @route,
        run_id,
        :answer,
        ref,
        1,
        12345
      )

      # The ref was just registered, so it should NOT be evicted
      entry = PresentationState.get(@route, run_id, :answer)
      assert is_reference(entry.pending_create_ref)
    end

    test "evicted stale entry allows new CREATE on next flush" do
      run_id = "run_evict_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(@route, run_id, :answer, ref, 1, 111)

      # Simulate staleness
      stale_at = System.monotonic_time(:millisecond) - 31_000

      key =
        {@route.channel_id, @route.account_id, @route.peer_kind, @route.peer_id, @route.thread_id,
         run_id, :answer}

      :sys.replace_state(PresentationState, fn s ->
        case Map.get(s.entries, key) do
          nil -> s
          entry -> put_in(s, [:entries, key], %{entry | pending_create_at: stale_at})
        end
      end)

      # Trigger GC via get
      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.platform_message_id)
      assert is_nil(entry.pending_create_ref)

      # Now a new register should work (simulating next flush's CREATE path)
      new_ref = make_ref()
      :ok = PresentationState.register_pending_create(@route, run_id, :answer, new_ref, 2, 222)

      entry = PresentationState.get(@route, run_id, :answer)
      assert entry.pending_create_ref == new_ref
    end
  end

  describe "notification handling" do
    test "sets platform_message_id from successful delivery" do
      run_id = "run_notify_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(@route, run_id, :answer, ref, 1, 111)

      # Simulate delivery notification
      send(
        PresentationState,
        {:presentation_delivery, ref, {:ok, %{"result" => %{"message_id" => 42}}}}
      )

      # Give the GenServer time to process
      Process.sleep(50)

      entry = PresentationState.get(@route, run_id, :answer)
      assert entry.platform_message_id == 42
      assert is_nil(entry.pending_create_ref)
    end

    test "clears pending_create_ref on delivery failure" do
      run_id = "run_fail_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(@route, run_id, :answer, ref, 1, 111)

      # Simulate failed delivery
      send(PresentationState, {:presentation_delivery, ref, {:error, :timeout}})

      Process.sleep(50)

      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.platform_message_id)
      assert is_nil(entry.pending_create_ref)
    end

    test "silently drops notification for unknown ref" do
      run_id = "run_unknown_#{System.unique_integer()}"
      unknown_ref = make_ref()

      # Send notification for a ref that was never registered
      send(
        PresentationState,
        {:presentation_delivery, unknown_ref, {:ok, %{"result" => %{"message_id" => 99}}}}
      )

      Process.sleep(50)

      # Should not crash, and no entry should exist
      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.platform_message_id)
      assert is_nil(entry.pending_create_ref)
    end

    test "clears pending_create_at on successful notification" do
      run_id = "run_clear_at_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(@route, run_id, :answer, ref, 1, 111)

      send(
        PresentationState,
        {:presentation_delivery, ref, {:ok, %{"result" => %{"message_id" => 77}}}}
      )

      Process.sleep(50)

      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.pending_create_at)
    end

    test "flushes staged followups when create notification arrives" do
      run_id = "run_create_followups_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(@route, run_id, :answer, ref, 1, 111)
      PresentationState.stage_followups(@route, run_id, :answer, ["tail"], %{reply_to: "42"})

      send(
        PresentationState,
        {:presentation_delivery, ref, {:ok, %{"result" => %{"message_id" => 42}}}}
      )

      Process.sleep(50)

      entry = PresentationState.get(@route, run_id, :answer)
      assert entry.platform_message_id == 42
      assert is_nil(entry.pending_create_ref)
      assert is_nil(entry.pending_followup_chunks)
    end
  end

  describe "deferred edit flush" do
    test "flushes deferred text when create notification arrives" do
      run_id = "run_defer_#{System.unique_integer()}"
      ref = make_ref()

      PresentationState.register_pending_create(@route, run_id, :answer, ref, 1, 111)

      # Defer a text edit while create is pending
      PresentationState.defer_text(@route, run_id, :answer, "Updated text", 2, 222, %{})

      # The edit should be pending
      entry = PresentationState.get(@route, run_id, :answer)
      assert entry.deferred_text == "Updated text"

      # Simulate create notification
      send(
        PresentationState,
        {:presentation_delivery, ref, {:ok, %{"result" => %{"message_id" => 55}}}}
      )

      Process.sleep(50)

      # Deferred text should have been flushed
      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.deferred_text)
      assert entry.last_seq == 2
      assert entry.last_text_hash == 222
    end

    test "clears pending_edit_ref when edit notification arrives" do
      run_id = "run_edit_clear_#{System.unique_integer()}"
      ref = make_ref()

      :ok = PresentationState.mark_sent(@route, run_id, :answer, 1, 111, 55)
      :ok = PresentationState.register_pending_edit(@route, run_id, :answer, ref, 2, 222, 55)

      send(PresentationState, {:presentation_delivery, ref, {:ok, %{"ok" => true}}})

      Process.sleep(50)

      entry = PresentationState.get(@route, run_id, :answer)
      assert is_nil(entry.pending_edit_ref)
      assert is_nil(entry.pending_edit_at)
      assert entry.platform_message_id == 55
    end

    test "ignores stale edit notifications when a newer edit is pending" do
      run_id = "run_edit_stale_#{System.unique_integer()}"
      stale_ref = make_ref()
      current_ref = make_ref()

      :ok = PresentationState.mark_sent(@route, run_id, :answer, 1, 111, 55)

      :ok =
        PresentationState.register_pending_edit(@route, run_id, :answer, stale_ref, 2, 222, 55)

      :ok =
        PresentationState.register_pending_edit(@route, run_id, :answer, current_ref, 3, 333, 55)

      :ok =
        PresentationState.stage_followups(@route, run_id, :answer, ["tail"], %{reply_to: "42"})

      send(PresentationState, {:presentation_delivery, stale_ref, {:ok, %{"ok" => true}}})

      Process.sleep(50)

      entry = PresentationState.get(@route, run_id, :answer)
      assert entry.pending_edit_ref == current_ref
      assert entry.pending_followup_chunks == ["tail"]
    end
  end
end
