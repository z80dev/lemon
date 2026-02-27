defmodule LemonCore.StoreTest do
  use ExUnit.Case, async: false

  alias LemonCore.Store

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(_state, _table, _key, _value), do: {:error, :sqlite_busy}

    @impl true
    def get(_state, _table, _key), do: {:error, :sqlite_busy}

    @impl true
    def delete(_state, _table, _key), do: {:error, :sqlite_busy}

    @impl true
    def list(_state, _table), do: {:error, :sqlite_busy}
  end

  defmodule BlobTooBigBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts) do
      tid = :ets.new(:store_blob_too_big_backend, [:set, :public])
      :ets.insert(tid, {:run_history_put_count, 0})
      {:ok, %{tid: tid}}
    end

    @impl true
    def put(%{tid: tid} = state, table, key, value) do
      case table do
        :run_history ->
          [{:run_history_put_count, count}] = :ets.lookup(tid, :run_history_put_count)
          :ets.insert(tid, {:run_history_put_count, count + 1})

          if count == 0 do
            {:error, {:sqlite_bind_failed, :blob_too_big}}
          else
            :ets.insert(tid, {{table, key}, value})
            {:ok, state}
          end

        _ ->
          :ets.insert(tid, {{table, key}, value})
          {:ok, state}
      end
    end

    @impl true
    def get(%{tid: tid} = state, table, key) do
      value =
        case :ets.lookup(tid, {table, key}) do
          [{{^table, ^key}, found}] -> found
          _ -> nil
        end

      {:ok, value, state}
    end

    @impl true
    def delete(%{tid: tid} = state, table, key) do
      :ets.delete(tid, {table, key})
      {:ok, state}
    end

    @impl true
    def list(%{tid: tid} = state, table) do
      items =
        tid
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {{^table, key}, value} -> [{key, value}]
          _ -> []
        end)

      {:ok, items, state}
    end
  end

  defp unique_token do
    System.unique_integer([:positive, :monotonic])
  end

  defp scope(token, name), do: {:store_test, token, name}
  defp run_id(token, name), do: "run_#{token}_#{name}"
  defp session_key(token), do: "agent:store_test_#{token}:main"

  defp introspection_event(token, name, ts_ms, attrs \\ %{}) do
    Map.merge(
      %{
        event_id: "evt_#{token}_#{name}",
        event_type: :tool_completed,
        ts_ms: ts_ms,
        run_id: run_id(token, :introspection),
        session_key: session_key(token),
        agent_id: "agent_#{token}",
        parent_run_id: nil,
        engine: "codex",
        provenance: :direct,
        payload: %{tool_name: "exec", is_error: false}
      },
      attrs
    )
  end

  defp swap_store_backend(backend, backend_state) do
    original_state = :sys.get_state(Store)

    :sys.replace_state(Store, fn state ->
      %{state | backend: backend, backend_state: backend_state}
    end)

    original_state
  end

  describe "chat state TTL semantics" do
    test "put_chat_state persists expires_at using configured TTL" do
      token = unique_token()
      chat_scope = scope(token, :ttl)
      ttl_ms = :sys.get_state(Store).chat_state_ttl_ms

      before_put = System.system_time(:millisecond)
      :ok = Store.put_chat_state(chat_scope, %{phase: :active})
      stored = Store.get(:chat, chat_scope)
      after_put = System.system_time(:millisecond)

      assert %{phase: :active, expires_at: expires_at} = stored
      assert expires_at >= before_put + ttl_ms
      assert expires_at <= after_put + ttl_ms
      assert %{phase: :active} = Store.get_chat_state(chat_scope)
    end

    test "get_chat_state lazily evicts expired state" do
      token = unique_token()
      chat_scope = scope(token, :lazy_expiry)

      :ok =
        Store.put(:chat, chat_scope, %{
          phase: :stale,
          expires_at: System.system_time(:millisecond) - 1
        })

      assert Store.get_chat_state(chat_scope) == nil
      assert Store.get(:chat, chat_scope) == nil
    end

    test "periodic sweep removes expired entries and keeps live entries" do
      token = unique_token()
      expired_scope = scope(token, :sweep_expired)
      live_scope = scope(token, :sweep_live)
      now = System.system_time(:millisecond)

      :ok = Store.put(:chat, expired_scope, %{phase: :expired, expires_at: now - 1})
      :ok = Store.put(:chat, live_scope, %{phase: :live, expires_at: now + 60_000})

      send(Store, :sweep_expired_chat_states)

      # `get/2` is a call, so it acts as a barrier after the sweep message.
      assert Store.get(:chat, expired_scope) == nil
      assert %{phase: :live} = Store.get(:chat, live_scope)
    end
  end

  describe "run history ordering/backfill" do
    test "get_run_history orders finalized runs by newest started_at first" do
      token = unique_token()
      session_key = session_key(token)

      oldest = run_id(token, :oldest)
      middle = run_id(token, :middle)
      newest = run_id(token, :newest)

      :ok = Store.put(:runs, oldest, %{events: [%{step: 1}], summary: nil, started_at: 1_000})
      :ok = Store.put(:runs, middle, %{events: [%{step: 2}], summary: nil, started_at: 2_000})
      :ok = Store.put(:runs, newest, %{events: [%{step: 3}], summary: nil, started_at: 3_000})

      :ok = Store.finalize_run(oldest, %{session_key: session_key})
      :ok = Store.finalize_run(middle, %{session_key: session_key})
      :ok = Store.finalize_run(newest, %{session_key: session_key})

      history = Store.get_run_history(session_key, limit: 10)

      assert Enum.map(history, &elem(&1, 0)) == [newest, middle, oldest]
      assert Enum.map(history, fn {_run_id, data} -> data.started_at end) == [3_000, 2_000, 1_000]
    end

    test "applies ordering/limit consistently for canonical run_history rows" do
      token = unique_token()
      session_key = session_key(token)

      older_run = run_id(token, :older)
      newer_run = run_id(token, :newer)

      :ok =
        Store.put(
          :run_history,
          {session_key, 2_000, older_run},
          %{
            events: [%{kind: :older}],
            summary: %{session_key: session_key},
            session_key: session_key,
            run_id: older_run,
            started_at: 2_000
          }
        )

      :ok =
        Store.put(
          :run_history,
          {session_key, 3_000, newer_run},
          %{
            events: [%{kind: :newer}],
            summary: %{session_key: session_key},
            session_key: session_key,
            run_id: newer_run,
            started_at: 3_000
          }
        )

      session_history = Store.get_run_history(session_key, limit: 10)
      assert Enum.map(session_history, &elem(&1, 0)) == [newer_run, older_run]

      session_limited = Store.get_run_history(session_key, limit: 1)
      assert Enum.map(session_limited, &elem(&1, 0)) == [newer_run]
    end
  end

  describe "progress mapping put/get/delete" do
    test "stores, overwrites, isolates by scope, and deletes mappings" do
      token = unique_token()
      scope_a = scope(token, :progress_a)
      scope_b = scope(token, :progress_b)
      progress_msg_id = 42_001

      assert Store.get_run_by_progress(scope_a, progress_msg_id) == nil

      :ok = Store.put_progress_mapping(scope_a, progress_msg_id, "run_a_v1")
      :ok = Store.put_progress_mapping(scope_b, progress_msg_id, "run_b_v1")

      assert Store.get_run_by_progress(scope_a, progress_msg_id) == "run_a_v1"
      assert Store.get_run_by_progress(scope_b, progress_msg_id) == "run_b_v1"

      :ok = Store.put_progress_mapping(scope_a, progress_msg_id, "run_a_v2")
      # Use a synchronous call as a mailbox barrier so async casts are applied in order.
      assert Store.get(:progress, {scope_a, progress_msg_id}) == "run_a_v2"
      assert Store.get_run_by_progress(scope_a, progress_msg_id) == "run_a_v2"

      :ok = Store.delete_progress_mapping(scope_a, progress_msg_id)

      assert Store.get_run_by_progress(scope_a, progress_msg_id) == nil
      assert Store.get(:progress, {scope_a, progress_msg_id}) == nil
      assert Store.get_run_by_progress(scope_b, progress_msg_id) == "run_b_v1"
    end
  end

  describe "policy wrapper API" do
    test "agent policy wrappers preserve table/key compatibility" do
      token = unique_token()
      agent_id = "agent_#{token}"
      policy = %{approvals: %{"bash" => :always}}

      :ok = Store.put_agent_policy(agent_id, policy)

      assert Store.get_agent_policy(agent_id) == policy
      assert Store.get(:agent_policies, agent_id) == policy
      assert {agent_id, policy} in Store.list_agent_policies()

      :ok = Store.delete_agent_policy(agent_id)
      assert Store.get_agent_policy(agent_id) == nil
      assert Store.get(:agent_policies, agent_id) == nil
    end

    test "channel policy wrappers preserve table/key compatibility" do
      token = unique_token()
      channel_id = "channel_#{token}"
      policy = %{blocked_tools: ["exec_raw"]}

      :ok = Store.put_channel_policy(channel_id, policy)

      assert Store.get_channel_policy(channel_id) == policy
      assert Store.get(:channel_policies, channel_id) == policy
      assert {channel_id, policy} in Store.list_channel_policies()

      :ok = Store.delete_channel_policy(channel_id)
      assert Store.get_channel_policy(channel_id) == nil
      assert Store.get(:channel_policies, channel_id) == nil
    end

    test "session policy wrappers preserve table/key compatibility" do
      token = unique_token()
      key = session_key(token)
      policy = %{thinking_level: "high"}

      :ok = Store.put_session_policy(key, policy)

      assert Store.get_session_policy(key) == policy
      assert Store.get(:session_policies, key) == policy
      assert {key, policy} in Store.list_session_policies()

      :ok = Store.delete_session_policy(key)
      assert Store.get_session_policy(key) == nil
      assert Store.get(:session_policies, key) == nil
    end

    test "runtime policy wrappers preserve :global key compatibility" do
      policy = %{sandbox: true}

      :ok = Store.put_runtime_policy(policy)

      assert Store.get_runtime_policy() == policy
      assert Store.get(:runtime_policy, :global) == policy
      assert {:global, policy} in Store.list_runtime_policies()

      :ok = Store.delete_runtime_policy()
      assert Store.get_runtime_policy() == nil
      assert Store.get(:runtime_policy, :global) == nil
    end
  end

  describe "introspection event storage contract" do
    test "append/list stores canonical events newest-first with filters and limit" do
      token = unique_token()
      run_id = run_id(token, :introspection)
      session_key = session_key(token)
      base_ts = System.system_time(:millisecond)

      older =
        introspection_event(token, :older, base_ts - 2_000, %{
          event_type: :run_started,
          payload: %{phase: :start}
        })

      middle =
        introspection_event(token, :middle, base_ts - 1_000, %{
          event_type: :tool_started,
          payload: %{tool_name: "bash"}
        })

      newest =
        introspection_event(token, :newest, base_ts, %{
          event_type: :tool_completed,
          payload: %{tool_name: "bash", is_error: false}
        })

      assert :ok = Store.append_introspection_event(older)
      assert :ok = Store.append_introspection_event(middle)
      assert :ok = Store.append_introspection_event(newest)

      all_events = Store.list_introspection_events(limit: 10)
      matching = Enum.filter(all_events, &(&1.run_id == run_id))

      assert Enum.map(matching, & &1.event_id) == [
               newest.event_id,
               middle.event_id,
               older.event_id
             ]

      limited =
        Store.list_introspection_events(
          run_id: run_id,
          session_key: session_key,
          limit: 2
        )

      assert Enum.map(limited, & &1.event_id) == [newest.event_id, middle.event_id]
      assert Enum.all?(limited, &(&1.session_key == session_key))

      typed = Store.list_introspection_events(run_id: run_id, event_type: :tool_started)
      assert Enum.map(typed, & &1.event_id) == [middle.event_id]

      ranged =
        Store.list_introspection_events(
          run_id: run_id,
          since_ms: base_ts - 1_500,
          until_ms: base_ts - 500
        )

      assert Enum.map(ranged, & &1.event_id) == [middle.event_id]
    end

    test "append_introspection_event rejects invalid canonical events" do
      token = unique_token()
      event = introspection_event(token, :invalid, System.system_time(:millisecond))

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(Map.delete(event, :event_id))

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(%{event | provenance: :unknown})

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(%{event | payload: "not-a-map"})
    end

    test "sweep removes introspection events older than retention" do
      token = unique_token()
      now = System.system_time(:millisecond)
      old_event = introspection_event(token, :old, now - 10_000)
      live_event = introspection_event(token, :live, now)

      assert :ok = Store.append_introspection_event(old_event)
      assert :ok = Store.append_introspection_event(live_event)

      :sys.replace_state(Store, fn state ->
        %{state | introspection_retention_ms: 2_000}
      end)

      send(Store, :sweep_expired_chat_states)

      filtered =
        Store.list_introspection_events(run_id: old_event.run_id, limit: 10)
        |> Enum.map(& &1.event_id)

      assert live_event.event_id in filtered
      refute old_event.event_id in filtered
    end
  end

  describe "backend error handling" do
    test "sessions index reads are served from read cache even when backend becomes busy" do
      token = unique_token()
      key = session_key(token)
      entry = %{agent_id: "agent_#{token}", updated_at_ms: System.system_time(:millisecond)}

      assert :ok = Store.put(:sessions_index, key, entry)
      assert Store.get(:sessions_index, key) == entry
      assert {key, entry} in Store.list(:sessions_index)

      original_state = swap_store_backend(BusyBackend, %{})
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      assert Store.get(:sessions_index, key) == entry
      assert {key, entry} in Store.list(:sessions_index)
    end

    test "generic put returns error and store remains alive on sqlite busy" do
      original_state = swap_store_backend(BusyBackend, %{})
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      assert {:error, :sqlite_busy} =
               Store.put(:cron_runs, "run_busy_#{unique_token()}", %{status: :pending})

      assert Process.alive?(Process.whereis(Store))
    end

    test "finalize_run retries run_history write with compact payload on blob-too-big errors" do
      {:ok, backend_state} = BlobTooBigBackend.init([])
      original_state = swap_store_backend(BlobTooBigBackend, backend_state)
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      token = unique_token()
      key = session_key(token)
      rid = run_id(token, :blob_retry)
      long_text = String.duplicate("x", 25_000)

      assert :ok =
               Store.put(:runs, rid, %{
                 events: [%{type: :prompt, text: long_text}],
                 summary: nil,
                 started_at: 1_000
               })

      assert :ok =
               Store.finalize_run(rid, %{
                 session_key: key,
                 prompt: long_text,
                 completed: %{ok: true, answer: long_text}
               })

      history = Store.get_run_history(key, limit: 5)
      assert [{^rid, data}] = history
      assert data.events == []

      summary = data.summary || %{}
      completed = summary[:completed] || summary["completed"] || %{}
      answer = completed[:answer] || completed["answer"] || ""
      prompt = summary[:prompt] || summary["prompt"] || ""

      assert is_binary(answer)
      assert is_binary(prompt)
      assert String.contains?(answer, "[truncated")
      assert String.contains?(prompt, "[truncated")

      store_state = :sys.get_state(Store)

      [{:run_history_put_count, 2}] =
        :ets.lookup(store_state.backend_state.tid, :run_history_put_count)
    end
  end

  describe "GenServer bottleneck fixes: append_introspection_event" do
    test "append_introspection_event is asynchronous (cast)" do
      token = unique_token()
      event = introspection_event(token, :async, System.system_time(:millisecond))

      # cast returns :ok immediately without blocking
      assert :ok = Store.append_introspection_event(event)

      # Poll until the event is persisted (proves it was async, not a call)
      Enum.reduce_while(1..20, nil, fn _, _ ->
        Process.sleep(50)
        events = Store.list_introspection_events(run_id: event.run_id, limit: 10)

        if Enum.any?(events, &(&1.event_id == event.event_id)) do
          {:halt, :found}
        else
          {:cont, nil}
        end
      end)

      events = Store.list_introspection_events(run_id: event.run_id, limit: 10)
      assert Enum.any?(events, &(&1.event_id == event.event_id))
    end

    test "append_introspection_event validates event_id client-side" do
      token = unique_token()
      event = introspection_event(token, :no_id, System.system_time(:millisecond))
      bad_event = Map.delete(event, :event_id)

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(bad_event)
    end

    test "append_introspection_event validates ts_ms client-side" do
      token = unique_token()
      event = introspection_event(token, :bad_ts, System.system_time(:millisecond))

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(%{event | ts_ms: -1})
    end

    test "append_introspection_event validates event_type client-side" do
      token = unique_token()
      event = introspection_event(token, :bad_type, System.system_time(:millisecond))

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(%{event | event_type: nil})
    end

    test "append_introspection_event validates provenance client-side" do
      token = unique_token()
      event = introspection_event(token, :bad_prov, System.system_time(:millisecond))

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(%{event | provenance: :unknown})
    end

    test "append_introspection_event validates payload client-side" do
      token = unique_token()
      event = introspection_event(token, :bad_payload, System.system_time(:millisecond))

      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event(%{event | payload: "not-a-map"})
    end

    test "append_introspection_event rejects non-map input" do
      assert {:error, :invalid_introspection_event} =
               Store.append_introspection_event("not a map")
    end
  end
end
