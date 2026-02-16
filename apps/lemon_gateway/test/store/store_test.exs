defmodule LemonGateway.StoreTest do
  # async: false because Store is a named GenServer
  use ExUnit.Case, async: false

  alias LemonGateway.Store
  alias LemonGateway.Types.ChatScope

  setup do
    # Some other lemon_gateway tests stop the application for isolation. Ensure the
    # Store (and its supervisor tree) is running before each test here.
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  # Use a unique key prefix per test to avoid conflicts with other tests
  # This avoids having to restart the Store between tests

  describe "chat state" do
    test "put and get chat state" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      state = %{history: [], context: "test"}

      Store.put_chat_state(scope, state)

      # Give cast time to process
      Process.sleep(10)

      result = Store.get_chat_state(scope)
      # expires_at is automatically added by the Store
      assert result.history == state.history
      assert result.context == state.context
      assert is_integer(result.expires_at)
    end

    test "returns nil for missing scope" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      assert Store.get_chat_state(scope) == nil
    end

    test "delete_chat_state removes state" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      state = %{history: [], context: "test"}

      Store.put_chat_state(scope, state)
      Process.sleep(10)
      assert Store.get_chat_state(scope) != nil

      Store.delete_chat_state(scope)
      Process.sleep(10)
      assert Store.get_chat_state(scope) == nil
    end

    test "chat state expires_at is set to future timestamp" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      state = %{data: "test"}
      now = System.system_time(:millisecond)

      Store.put_chat_state(scope, state)
      Process.sleep(10)

      result = Store.get_chat_state(scope)
      # expires_at should be in the future (default TTL is 24 hours)
      assert result.expires_at > now
      # Should be roughly 24 hours from now (within a few seconds tolerance)
      expected_ttl_ms = 24 * 60 * 60 * 1000
      assert result.expires_at >= now + expected_ttl_ms - 5000
      assert result.expires_at <= now + expected_ttl_ms + 5000
    end
  end

  describe "run events" do
    test "append and get run" do
      run_id = make_ref()

      Store.append_run_event(run_id, %{type: :started})
      Store.append_run_event(run_id, %{type: :progress})

      Process.sleep(10)

      run = Store.get_run(run_id)
      assert length(run.events) == 2
      assert %{type: :progress} in run.events
      assert %{type: :started} in run.events
    end

    test "finalize run adds summary" do
      run_id = make_ref()
      scope = %ChatScope{transport: :test, chat_id: unique_id(), topic_id: nil}

      Store.append_run_event(run_id, %{type: :started})
      Store.finalize_run(run_id, %{ok: true, answer: "done", scope: scope})

      Process.sleep(10)

      run = Store.get_run(run_id)
      assert run.summary == %{ok: true, answer: "done", scope: scope}
    end
  end

  describe "progress mapping" do
    test "put, get, and delete progress mapping" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      progress_msg_id = unique_id()
      run_id = make_ref()

      Store.put_progress_mapping(scope, progress_msg_id, run_id)
      Process.sleep(10)

      assert Store.get_run_by_progress(scope, progress_msg_id) == run_id

      Store.delete_progress_mapping(scope, progress_msg_id)
      Process.sleep(10)

      assert Store.get_run_by_progress(scope, progress_msg_id) == nil
    end
  end

  describe "run history" do
    test "get_run_history returns finalized runs for scope" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}

      # Create multiple runs
      run1 = "run_#{System.unique_integer()}"
      run2 = "run_#{System.unique_integer()}"

      Store.append_run_event(run1, %{type: :started})
      Store.finalize_run(run1, %{ok: true, answer: "first", scope: scope})
      Process.sleep(20)

      Store.append_run_event(run2, %{type: :started})
      Store.finalize_run(run2, %{ok: true, answer: "second", scope: scope})
      Process.sleep(20)

      history = Store.get_run_history(scope)

      assert length(history) == 2

      # Most recent first
      [{_id1, data1}, {_id2, data2}] = history
      assert data1.summary.answer == "second"
      assert data2.summary.answer == "first"
    end

    test "get_run_history respects limit" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}

      # Create 5 runs
      for i <- 1..5 do
        run_id = "run_limit_#{unique_id()}_#{i}"
        Store.append_run_event(run_id, %{type: :started})
        Store.finalize_run(run_id, %{ok: true, answer: "run #{i}", scope: scope})
        Process.sleep(5)
      end

      Process.sleep(20)

      history = Store.get_run_history(scope, limit: 3)
      assert length(history) == 3
    end

    test "get_run_history filters by scope" do
      scope_a = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      scope_b = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}

      run_a = "run_a_#{unique_id()}"
      run_b = "run_b_#{unique_id()}"

      Store.append_run_event(run_a, %{type: :started})
      Store.finalize_run(run_a, %{ok: true, scope: scope_a})

      Store.append_run_event(run_b, %{type: :started})
      Store.finalize_run(run_b, %{ok: true, scope: scope_b})

      Process.sleep(20)

      history_a = Store.get_run_history(scope_a)
      history_b = Store.get_run_history(scope_b)

      assert length(history_a) == 1
      assert length(history_b) == 1

      [{id_a, _}] = history_a
      [{id_b, _}] = history_b

      assert id_a == run_a
      assert id_b == run_b
    end

    test "get_run_history returns empty list for no runs" do
      scope = %ChatScope{transport: :test, chat_id: unique_chat_id(), topic_id: nil}
      assert Store.get_run_history(scope) == []
    end
  end

  # Generate unique IDs to avoid test interference
  defp unique_id, do: System.unique_integer([:positive])

  # Avoid collisions with other test suites that may use small-ish fixed chat_id values.
  defp unique_chat_id, do: 1_000_000_000 + unique_id()
end

defmodule LemonGateway.Store.BackendConfigTest do
  @moduledoc """
  Tests for backend configuration.
  These tests need to restart the Store, so they run separately.
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Store
  alias LemonGateway.Types.ChatScope

  setup do
    # Stop the application to get full control
    Application.stop(:lemon_gateway)
    Application.stop(:lemon_core)

    on_exit(fn ->
      # Clean up config
      Application.delete_env(:lemon_core, LemonCore.Store)
      Application.delete_env(:lemon_gateway, Store)
      # Restart application for other tests
      Application.ensure_all_started(:lemon_gateway)
    end)

    :ok
  end

  test "uses ETS backend by default" do
    Application.delete_env(:lemon_core, LemonCore.Store)
    Application.delete_env(:lemon_gateway, Store)
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 100_000, topic_id: nil}

    Store.put_chat_state(scope, %{test: true})
    Process.sleep(10)

    result = Store.get_chat_state(scope)
    assert result.test == true
    assert is_integer(result.expires_at)
  end

  test "can use JSONL backend when configured" do
    # Create temp directory
    tmp_dir = Path.join(System.tmp_dir!(), "store_test_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      # Stop the store before deleting the directory; late async writes (casts) can otherwise
      # crash LemonCore.Store after the test has already finished.
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_core)
      File.rm_rf!(tmp_dir)
    end)

    # Configure JSONL backend
    Application.put_env(:lemon_core, LemonCore.Store,
      backend: LemonCore.Store.JsonlBackend,
      backend_opts: [path: tmp_dir]
    )

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 200_000, topic_id: nil}
    Store.put_chat_state(scope, %{persistent: true})
    Process.sleep(10)

    result = Store.get_chat_state(scope)
    assert result.persistent == true
    assert is_integer(result.expires_at)

    # Verify file was created
    assert File.exists?(Path.join(tmp_dir, "chat.jsonl"))
  end

  test "can use SQLite backend when configured" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "store_sqlite_test_#{System.unique_integer([:positive])}")

    db_path = Path.join(tmp_dir, "store.sqlite3")

    on_exit(fn ->
      # Stop the store before deleting files to avoid late writes during teardown.
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_core)
      File.rm_rf!(tmp_dir)
    end)

    Application.put_env(:lemon_core, LemonCore.Store,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: [path: tmp_dir, ephemeral_tables: []]
    )

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 300_000, topic_id: nil}
    Store.put_chat_state(scope, %{persistent: true})
    Process.sleep(10)

    result = Store.get_chat_state(scope)
    assert result.persistent == true
    assert is_integer(result.expires_at)

    # Regression: repeated SQLite reads for the same key should not poison the
    # prepared statement cursor and crash the Store process.
    result_again = Store.get_chat_state(scope)
    assert result_again.persistent == true
    assert is_integer(result_again.expires_at)

    override_scope = %ChatScope{transport: :telegram, chat_id: 300_001, topic_id: nil}
    :ok = Store.put(:gateway_project_overrides, override_scope, "default")
    assert Store.get(:gateway_project_overrides, override_scope) == "default"
    assert Store.get(:gateway_project_overrides, override_scope) == "default"

    assert File.exists?(db_path)
  end
end
