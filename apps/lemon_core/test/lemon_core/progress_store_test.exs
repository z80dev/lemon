defmodule LemonCore.ProgressStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProgressStore
  alias LemonCore.Store

  defp unique_token, do: System.unique_integer([:positive, :monotonic])
  defp scope(token, name), do: {:progress_store_test, token, name}
  defp session_key(token), do: "agent:progress_store_test_#{token}:main"

  def handle_telemetry(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = "progress-store-test-#{unique_token()}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "put_progress_mapping/3" do
    test "stores mapping through Store" do
      token = unique_token()
      scope = scope(token, :put)
      progress_msg_id = 42_001

      :ok = ProgressStore.put_progress_mapping(scope, progress_msg_id, "run_a")

      # Use generic get as barrier
      assert Store.get(:progress, {scope, progress_msg_id}) == "run_a"
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :put_progress_mapping, :start],
        [:lemon_core, :store, :put_progress_mapping, :stop]
      ])

      token = unique_token()
      scope = scope(token, :telem_put)
      progress_msg_id = 42_002

      ProgressStore.put_progress_mapping(scope, progress_msg_id, "run_a")

      assert_receive {:telemetry_event, [:lemon_core, :store, :put_progress_mapping, :start],
                       %{system_time: _},
                       %{table: :progress, scope: ^scope, progress_msg_id: ^progress_msg_id}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :put_progress_mapping, :stop],
                       %{duration: duration},
                       %{table: :progress, scope: ^scope, progress_msg_id: ^progress_msg_id}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "get_run_by_progress/2" do
    test "returns run ID from Store" do
      token = unique_token()
      scope = scope(token, :get)
      progress_msg_id = 42_003

      :ok = Store.put_progress_mapping(scope, progress_msg_id, "run_b")

      assert ProgressStore.get_run_by_progress(scope, progress_msg_id) == "run_b"
    end

    test "returns nil for missing mapping" do
      token = unique_token()
      scope = scope(token, :missing)

      assert ProgressStore.get_run_by_progress(scope, 99_999) == nil
    end

    test "isolates by scope" do
      token = unique_token()
      scope_a = scope(token, :iso_a)
      scope_b = scope(token, :iso_b)
      progress_msg_id = 42_004

      :ok = Store.put_progress_mapping(scope_a, progress_msg_id, "run_a")
      :ok = Store.put_progress_mapping(scope_b, progress_msg_id, "run_b")

      assert ProgressStore.get_run_by_progress(scope_a, progress_msg_id) == "run_a"
      assert ProgressStore.get_run_by_progress(scope_b, progress_msg_id) == "run_b"
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :get_run_by_progress, :start],
        [:lemon_core, :store, :get_run_by_progress, :stop]
      ])

      token = unique_token()
      scope = scope(token, :telem_get)
      progress_msg_id = 42_005

      ProgressStore.get_run_by_progress(scope, progress_msg_id)

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_run_by_progress, :start],
                       %{system_time: _},
                       %{table: :progress, scope: ^scope, progress_msg_id: ^progress_msg_id}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_run_by_progress, :stop],
                       %{duration: _},
                       %{table: :progress, scope: ^scope, progress_msg_id: ^progress_msg_id}}
    end
  end

  describe "delete_progress_mapping/2" do
    test "removes mapping through Store" do
      token = unique_token()
      scope = scope(token, :delete)
      progress_msg_id = 42_006

      :ok = Store.put_progress_mapping(scope, progress_msg_id, "run_c")
      assert Store.get_run_by_progress(scope, progress_msg_id) == "run_c"

      :ok = ProgressStore.delete_progress_mapping(scope, progress_msg_id)

      # Use generic get as barrier
      assert Store.get(:progress, {scope, progress_msg_id}) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :delete_progress_mapping, :start],
        [:lemon_core, :store, :delete_progress_mapping, :stop]
      ])

      token = unique_token()
      scope = scope(token, :telem_delete)
      progress_msg_id = 42_007

      ProgressStore.delete_progress_mapping(scope, progress_msg_id)

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_progress_mapping, :start],
                       %{system_time: _},
                       %{table: :progress, scope: ^scope, progress_msg_id: ^progress_msg_id}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_progress_mapping, :stop],
                       %{duration: _},
                       %{table: :progress, scope: ^scope, progress_msg_id: ^progress_msg_id}}
    end
  end

  describe "put_pending_compaction/2" do
    test "stores compaction marker through Store" do
      token = unique_token()
      key = session_key(token)

      assert :ok = ProgressStore.put_pending_compaction(key)

      assert Store.get(:pending_compaction, key) == true
    end

    test "supports custom marker values" do
      token = unique_token()
      key = session_key(token)

      assert :ok = ProgressStore.put_pending_compaction(key, %{reason: :size_limit})

      assert Store.get(:pending_compaction, key) == %{reason: :size_limit}
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :put_pending_compaction, :start],
        [:lemon_core, :store, :put_pending_compaction, :stop]
      ])

      token = unique_token()
      key = session_key(token)

      ProgressStore.put_pending_compaction(key)

      assert_receive {:telemetry_event, [:lemon_core, :store, :put_pending_compaction, :start],
                       %{system_time: _},
                       %{table: :pending_compaction, session_key: ^key}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :put_pending_compaction, :stop],
                       %{duration: _},
                       %{table: :pending_compaction, session_key: ^key}}
    end
  end

  describe "get_pending_compaction/1" do
    test "returns compaction marker from Store" do
      token = unique_token()
      key = session_key(token)

      :ok = Store.put(:pending_compaction, key, true)

      assert ProgressStore.get_pending_compaction(key) == true
    end

    test "returns nil for missing marker" do
      token = unique_token()
      key = session_key(token)

      assert ProgressStore.get_pending_compaction(key) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :get_pending_compaction, :start],
        [:lemon_core, :store, :get_pending_compaction, :stop]
      ])

      token = unique_token()
      key = session_key(token)

      ProgressStore.get_pending_compaction(key)

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_pending_compaction, :start],
                       %{system_time: _},
                       %{table: :pending_compaction, session_key: ^key}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_pending_compaction, :stop],
                       %{duration: _},
                       %{table: :pending_compaction, session_key: ^key}}
    end
  end

  describe "delete_pending_compaction/1" do
    test "removes compaction marker from Store" do
      token = unique_token()
      key = session_key(token)

      :ok = Store.put(:pending_compaction, key, true)
      assert Store.get(:pending_compaction, key) == true

      :ok = ProgressStore.delete_pending_compaction(key)
      assert Store.get(:pending_compaction, key) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :delete_pending_compaction, :start],
        [:lemon_core, :store, :delete_pending_compaction, :stop]
      ])

      token = unique_token()
      key = session_key(token)

      ProgressStore.delete_pending_compaction(key)

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_pending_compaction, :start],
                       %{system_time: _},
                       %{table: :pending_compaction, session_key: ^key}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :delete_pending_compaction, :stop],
                       %{duration: _},
                       %{table: :pending_compaction, session_key: ^key}}
    end
  end

  describe "full progress lifecycle" do
    test "put, get, overwrite, delete cycle works end-to-end" do
      token = unique_token()
      scope = scope(token, :lifecycle)
      progress_msg_id = 42_100

      # Initially empty
      assert ProgressStore.get_run_by_progress(scope, progress_msg_id) == nil

      # Put
      :ok = ProgressStore.put_progress_mapping(scope, progress_msg_id, "run_v1")
      assert ProgressStore.get_run_by_progress(scope, progress_msg_id) == "run_v1"

      # Overwrite
      :ok = ProgressStore.put_progress_mapping(scope, progress_msg_id, "run_v2")
      # Use generic get as barrier
      assert Store.get(:progress, {scope, progress_msg_id}) == "run_v2"
      assert ProgressStore.get_run_by_progress(scope, progress_msg_id) == "run_v2"

      # Delete
      :ok = ProgressStore.delete_progress_mapping(scope, progress_msg_id)
      assert ProgressStore.get_run_by_progress(scope, progress_msg_id) == nil
    end
  end
end
