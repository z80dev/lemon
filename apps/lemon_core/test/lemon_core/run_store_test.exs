defmodule LemonCore.RunStoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.RunStore
  alias LemonCore.Store

  defp unique_token, do: System.unique_integer([:positive, :monotonic])
  defp run_id(token, name), do: "run_#{token}_#{name}"
  defp session_key(token), do: "agent:run_store_test_#{token}:main"

  def handle_telemetry(event_name, measurements, metadata, pid) do
    send(pid, {:telemetry_event, event_name, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = "run-store-test-#{unique_token()}"
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

  describe "append_event/2" do
    test "delegates to Store.append_run_event/2" do
      token = unique_token()
      rid = run_id(token, :append)

      # Seed a run record so append has something to update
      :ok = Store.put(:runs, rid, %{events: [], summary: nil, started_at: 1_000})

      :ok = RunStore.append_event(rid, %{step: 1})

      # Use a synchronous call as mailbox barrier
      run = Store.get_run(rid)
      assert %{step: 1} in run.events
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :append_run_event, :start],
        [:lemon_core, :store, :append_run_event, :stop]
      ])

      token = unique_token()
      rid = run_id(token, :telem_append)

      :ok = Store.put(:runs, rid, %{events: [], summary: nil, started_at: 1_000})
      :ok = RunStore.append_event(rid, %{step: 1})

      assert_receive {:telemetry_event, [:lemon_core, :store, :append_run_event, :start],
                       %{system_time: _}, %{table: :runs, run_id: ^rid}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :append_run_event, :stop],
                       %{duration: duration}, %{table: :runs, run_id: ^rid}}

      assert is_integer(duration)
      assert duration >= 0
    end
  end

  describe "finalize/2" do
    test "delegates to Store.finalize_run/2" do
      token = unique_token()
      rid = run_id(token, :finalize)
      sk = session_key(token)

      :ok = Store.put(:runs, rid, %{events: [%{step: 1}], summary: nil, started_at: 1_000})
      :ok = RunStore.finalize(rid, %{session_key: sk})

      # Use get_run_history as barrier — finalize_run is async
      history = Store.get_run_history(sk, limit: 10)
      assert length(history) >= 1
      assert Enum.any?(history, fn {id, _data} -> id == rid end)
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :finalize_run, :start],
        [:lemon_core, :store, :finalize_run, :stop]
      ])

      token = unique_token()
      rid = run_id(token, :telem_finalize)
      sk = session_key(token)

      :ok = Store.put(:runs, rid, %{events: [], summary: nil, started_at: 1_000})
      :ok = RunStore.finalize(rid, %{session_key: sk})

      assert_receive {:telemetry_event, [:lemon_core, :store, :finalize_run, :start],
                       %{system_time: _}, %{table: :runs, run_id: ^rid}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :finalize_run, :stop],
                       %{duration: _}, %{table: :runs, run_id: ^rid}}
    end
  end

  describe "get/1" do
    test "returns run record from Store" do
      token = unique_token()
      rid = run_id(token, :get)
      record = %{events: [%{step: 1}], summary: nil, started_at: 1_000}

      :ok = Store.put(:runs, rid, record)

      result = RunStore.get(rid)
      assert result.events == [%{step: 1}]
      assert result.started_at == 1_000
    end

    test "returns nil for missing run" do
      token = unique_token()
      rid = run_id(token, :missing)

      assert RunStore.get(rid) == nil
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :get_run, :start],
        [:lemon_core, :store, :get_run, :stop]
      ])

      token = unique_token()
      rid = run_id(token, :telem_get)

      RunStore.get(rid)

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_run, :start],
                       %{system_time: _}, %{table: :runs, run_id: ^rid}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_run, :stop],
                       %{duration: _}, %{table: :runs, run_id: ^rid}}
    end
  end

  describe "get_history/2" do
    test "returns run history ordered newest first" do
      token = unique_token()
      sk = session_key(token)

      oldest = run_id(token, :oldest)
      newest = run_id(token, :newest)

      :ok = Store.put(:runs, oldest, %{events: [%{step: 1}], summary: nil, started_at: 1_000})
      :ok = Store.put(:runs, newest, %{events: [%{step: 2}], summary: nil, started_at: 2_000})

      :ok = Store.finalize_run(oldest, %{session_key: sk})
      :ok = Store.finalize_run(newest, %{session_key: sk})

      history = RunStore.get_history(sk, limit: 10)

      assert Enum.map(history, &elem(&1, 0)) == [newest, oldest]
    end

    test "respects limit option" do
      token = unique_token()
      sk = session_key(token)

      r1 = run_id(token, :r1)
      r2 = run_id(token, :r2)

      :ok = Store.put(:runs, r1, %{events: [], summary: nil, started_at: 1_000})
      :ok = Store.put(:runs, r2, %{events: [], summary: nil, started_at: 2_000})

      :ok = Store.finalize_run(r1, %{session_key: sk})
      :ok = Store.finalize_run(r2, %{session_key: sk})

      history = RunStore.get_history(sk, limit: 1)
      assert length(history) == 1
    end

    test "returns empty list for unknown session" do
      token = unique_token()
      sk = session_key(token)

      assert RunStore.get_history(sk) == []
    end

    test "emits start/stop telemetry" do
      attach_telemetry([
        [:lemon_core, :store, :get_run_history, :start],
        [:lemon_core, :store, :get_run_history, :stop]
      ])

      token = unique_token()
      sk = session_key(token)

      RunStore.get_history(sk)

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_run_history, :start],
                       %{system_time: _}, %{table: :run_history, session_key: ^sk}}

      assert_receive {:telemetry_event, [:lemon_core, :store, :get_run_history, :stop],
                       %{duration: _}, %{table: :run_history, session_key: ^sk}}
    end
  end
end
