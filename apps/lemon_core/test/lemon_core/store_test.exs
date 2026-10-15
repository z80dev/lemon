defmodule LemonCore.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonCore.Store
  alias LemonCore.Testing.AsyncHelpers

  setup do
    assert {:ok, _} = Application.ensure_all_started(:lemon_core)
    :ok
  end

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def put(_state, _table, _key, _value), do: {:error, :sqlite_busy}

    @impl true
    def put_new(_state, _table, _key, _value), do: {:error, :sqlite_busy}

    @impl true
    def get(_state, _table, _key), do: {:error, :sqlite_busy}

    @impl true
    def delete(_state, _table, _key), do: {:error, :sqlite_busy}

    @impl true
    def list(%{list_response: response}, _table), do: response
    def list(_state, _table), do: {:error, :sqlite_busy}
  end

  defmodule RecentFailureBackend do
    @behaviour LemonCore.Store.Backend

    defdelegate init(opts), to: BusyBackend
    defdelegate put(state, table, key, value), to: BusyBackend
    defdelegate put_new(state, table, key, value), to: BusyBackend
    defdelegate get(state, table, key), to: BusyBackend
    defdelegate delete(state, table, key), to: BusyBackend
    defdelegate list(state, table), to: BusyBackend

    def list_recent(%{list_response: response}, :introspection_log, _limit), do: response
  end

  defmodule SecondDeleteFailureBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{data: %{}, delete_count: 0}}

    @impl true
    def put(state, table, key, value),
      do: {:ok, put_in(state, [:data, {table, key}], value)}

    @impl true
    def put_new(state, table, key, value) do
      if Map.has_key?(state.data, {table, key}),
        do: {:exists, state},
        else: put(state, table, key, value)
    end

    @impl true
    def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(%{delete_count: 1}, _table, _key), do: {:error, :injected_second_delete}

    def delete(state, table, key) do
      {:ok,
       %{state | data: Map.delete(state.data, {table, key}), delete_count: state.delete_count + 1}}
    end

    @impl true
    def list(state, table) do
      entries =
        for {{^table, key}, value} <- state.data,
            do: {key, value}

      {:ok, entries, state}
    end
  end

  defmodule DiagnosticLeakBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{mode: :error, secret: "unset"}}

    @impl true
    def put(_state, _table, _key, _value), do: {:error, :read_only}

    @impl true
    def put_new(_state, _table, _key, _value), do: {:error, :read_only}

    @impl true
    def get(%{mode: :error, secret: secret}, _table, key) do
      {:error, {:decode_failed, %{context: %{key: key}, detail: secret}}}
    end

    def get(%{mode: :unexpected, secret: secret}, _table, key) do
      {:unexpected, %{context: %{key: key}, detail: secret}}
    end

    def get(%{mode: {:error_term, reason}}, _table, _key), do: {:error, reason}

    def get(%{mode: :ok} = state, table, key),
      do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(_state, _table, _key), do: {:error, :read_only}

    @impl true
    def list(state, _table), do: {:ok, [], state}

    @impl true
    def compare_and_delete_many(%{mode: {:compare_unexpected, response}}, _entries),
      do: response
  end

  defmodule FallbackUnexpectedBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{data: %{}, mode: :ok, secret: "unset"}}

    @impl true
    def put(state, table, key, value),
      do: {:ok, put_in(state, [:data, {table, key}], value)}

    @impl true
    def put_new(state, table, key, value) do
      if Map.has_key?(state.data, {table, key}),
        do: {:exists, state},
        else: put(state, table, key, value)
    end

    @impl true
    def get(%{mode: :unexpected_get, secret: secret}, _table, key),
      do: {:unexpected_get, %{key: key, secret: secret}}

    def get(state, table, key), do: {:ok, Map.get(state.data, {table, key}), state}

    @impl true
    def delete(%{mode: :unexpected_delete, secret: secret}, _table, key),
      do: {:unexpected_delete, %{key: key, secret: secret}}

    def delete(state, table, key),
      do: {:ok, %{state | data: Map.delete(state.data, {table, key})}}

    @impl true
    def list(state, table) do
      entries = for {{^table, key}, value} <- state.data, do: {key, value}
      {:ok, entries, state}
    end
  end

  defp unique_token do
    System.system_time(:microsecond) + System.unique_integer([:positive, :monotonic])
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

  describe "expiring entries" do
    test "periodic sweep removes expired entries and keeps live entries" do
      token = unique_token()
      expired_scope = scope(token, :sweep_expired)
      live_scope = scope(token, :sweep_live)
      now = System.system_time(:millisecond)

      :ok = Store.put(:chat, expired_scope, %{phase: :expired, expires_at: now - 1})
      :ok = Store.put(:chat, live_scope, %{phase: :live, expires_at: now + 60_000})

      send(Store, :sweep_expired)
      # `:chat` reads are served from the mirror, so a call is the barrier.
      :ok = Store.ping()

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

    test "applies ordering/limit consistently via RunHistoryStore" do
      token = unique_token()
      session_key = "agent:rhs_ordering_#{token}:main"

      older_run = run_id(token, :older)
      newer_run = run_id(token, :newer)

      LemonCore.RunHistoryStore.put(session_key, 2_000, older_run, %{
        events: [%{kind: :older}],
        summary: %{session_key: session_key},
        session_key: session_key,
        run_id: older_run,
        started_at: 2_000
      })

      LemonCore.RunHistoryStore.put(session_key, 3_000, newer_run, %{
        events: [%{kind: :newer}],
        summary: %{session_key: session_key},
        session_key: session_key,
        run_id: newer_run,
        started_at: 3_000
      })

      # Use a synchronous call as a barrier to ensure async casts are applied
      _ = LemonCore.RunHistoryStore.get(session_key, limit: 1)

      session_history = Store.get_run_history(session_key, limit: 10)
      assert Enum.map(session_history, &elem(&1, 0)) == [newer_run, older_run]

      session_limited = Store.get_run_history(session_key, limit: 1)
      assert Enum.map(session_limited, &elem(&1, 0)) == [newer_run]
    end
  end

  describe "introspection event storage contract" do
    test "the introspection CLI refuses an unavailable history" do
      original_state = swap_store_backend(BusyBackend, %{})

      try do
        assert_raise Mix.Error, "Introspection events are unavailable", fn ->
          Mix.Tasks.Lemon.Introspection.run([])
        end
      after
        :sys.replace_state(Store, fn _ -> original_state end)
      end
    end

    test "listing and counting preserve backend errors through both query paths" do
      original_state = :sys.get_state(Store)
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      for backend <- [BusyBackend, RecentFailureBackend],
          opts <- [[], [run_id: "introspection-backend-failure"]] do
        swap_store_backend(backend, %{list_response: {:error, :sqlite_busy}})

        assert Store.list_introspection_events(opts) == {:error, :sqlite_busy}
        assert LemonCore.Introspection.list(opts) == {:error, :sqlite_busy}
        assert LemonCore.IntrospectionStore.count(opts) == {:error, :sqlite_busy}
      end
    end

    test "unexpected backend responses are errors, not an empty event history" do
      original_state = :sys.get_state(Store)
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      for backend <- [BusyBackend, RecentFailureBackend],
          opts <- [[], [event_type: :run_completed]] do
        swap_store_backend(backend, %{list_response: :unexpected})

        assert Store.list_introspection_events(opts) ==
                 {:error, {:unexpected_backend_response, :unexpected}}
      end
    end

    test "failed Store calls do not look like an empty event history" do
      assert Store.list_introspection_events(:missing_introspection_store, []) ==
               {:error, :store_unavailable}

      assert Store.list_introspection_events(self(), []) == {:error, :store_unavailable}
    end

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

      matching = Store.list_introspection_events(run_id: run_id, limit: 10)

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

      send(Store, :sweep_expired)

      filtered =
        Store.list_introspection_events(run_id: old_event.run_id, limit: 10)
        |> Enum.map(& &1.event_id)

      assert live_event.event_id in filtered
      refute old_event.event_id in filtered
    end
  end

  describe "backend error handling" do
    test "fetch distinguishes confirmed absence from backend failure" do
      key = "fetch_#{unique_token()}"
      assert {:ok, nil} = Store.fetch(:router_run_admissions, key)
      assert {:ok, nil} = Store.fetch_run(key)

      original_state = swap_store_backend(BusyBackend, %{})
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      assert {:error, :store_unavailable} = Store.fetch(:router_run_admissions, key)
      assert {:error, :store_unavailable} = Store.fetch_run(key)
    end

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

    test "generic put_new claims a key without overwriting the first value" do
      token = unique_token()
      key = "claim_#{token}"

      assert :ok = Store.put_new(:cron_runs, key, %{owner: :first})
      assert {:error, :exists} = Store.put_new(:cron_runs, key, %{owner: :second})
      assert Store.get(:cron_runs, key) == %{owner: :first}
    end

    test "generic put_new allows exactly one concurrent claimant" do
      token = unique_token()
      key = "concurrent_claim_#{token}"
      parent = self()

      tasks =
        for index <- 1..12 do
          Task.async(fn ->
            result = Store.put_new(:cron_runs, key, %{owner: index})
            send(parent, {:put_new_result, result})
            result
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 2_000))

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :exists})) == 11
      assert %{owner: owner} = Store.get(:cron_runs, key)
      assert owner in 1..12
    end

    test "generic take allows exactly one concurrent consumer" do
      key = "take_#{unique_token()}"
      assert :ok = Store.put(:node_challenges, key, %{node_id: "node-1"})

      results =
        1..12
        |> Enum.map(fn _ -> Task.async(fn -> Store.take(:node_challenges, key) end) end)
        |> Enum.map(&Task.await(&1, 2_000))

      assert Enum.count(results, &(&1 == %{node_id: "node-1"})) == 1
      assert Enum.count(results, &is_nil/1) == 11
      assert Store.get(:node_challenges, key) == nil
    end

    test "generic compare_and_swap serializes concurrent replacements" do
      key = "cas_#{unique_token()}"
      assert :ok = Store.put(:session_token_heads, key, %{generation: 1})

      results =
        2..13
        |> Enum.map(fn generation ->
          Task.async(fn ->
            Store.compare_and_swap(
              :session_token_heads,
              key,
              %{generation: 1},
              %{generation: generation}
            )
          end)
        end)
        |> Enum.map(&Task.await(&1, 2_000))

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :mismatch})) == 11
      assert %{generation: generation} = Store.get(:session_token_heads, key)
      assert generation in 2..13
    end

    test "generic compare_and_delete preserves a value changed after a cleanup snapshot" do
      key = "compare_delete_#{unique_token()}"
      claimed = %{state: "claimed", expires_at_ms: 0}
      submitting = %{state: "submitting"}

      assert :ok = Store.put(:session_token_heads, key, claimed)
      snapshot = Store.get(:session_token_heads, key)

      assert :ok = Store.compare_and_swap(:session_token_heads, key, claimed, submitting)

      assert {:error, :mismatch} =
               Store.compare_and_delete(:session_token_heads, key, snapshot)

      assert Store.get(:session_token_heads, key) == submitting
      assert :ok = Store.compare_and_delete(:session_token_heads, key, submitting)
      assert Store.get(:session_token_heads, key) == nil
    end

    test "generic compare_and_delete_many validates every snapshot before deleting any" do
      suffix = unique_token()
      first_key = "compare_delete_many_first_#{suffix}"
      second_key = "compare_delete_many_second_#{suffix}"
      original = %{generation: 1}
      renewed = %{generation: 2}

      assert :ok = Store.put(:session_token_heads, first_key, original)
      assert :ok = Store.put(:session_token_heads, second_key, original)
      assert :ok = Store.compare_and_swap(:session_token_heads, second_key, original, renewed)

      assert {:error, :mismatch} =
               Store.compare_and_delete_many([
                 {:session_token_heads, first_key, original},
                 {:session_token_heads, second_key, original}
               ])

      assert Store.get(:session_token_heads, first_key) == original
      assert Store.get(:session_token_heads, second_key) == renewed

      assert :ok =
               Store.compare_and_delete_many([
                 {:session_token_heads, first_key, original},
                 {:session_token_heads, second_key, renewed}
               ])

      assert Store.get(:session_token_heads, first_key) == nil
      assert Store.get(:session_token_heads, second_key) == nil
    end

    test "generic compare_and_delete_many propagates a later backend delete failure" do
      response = %{kind: :expired_response}
      primary_fence = %{kind: :execution_fence}

      backend_state = %{
        data: %{
          {:responses, :response} => response,
          {:primary, :fence} => primary_fence
        },
        delete_count: 0
      }

      original_state = swap_store_backend(SecondDeleteFailureBackend, backend_state)
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      assert {:error, :injected_second_delete} =
               Store.compare_and_delete_many([
                 {:responses, :response, response},
                 {:primary, :fence, primary_fence}
               ])

      assert Store.get(:responses, :response) == nil
      assert Store.get(:primary, :fence) == primary_fence
    end

    test "fetch_all distinguishes a backend list failure from an empty table" do
      original_state = swap_store_backend(BusyBackend, %{})
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      assert Store.list(:webhook_idempotency) == []
      assert Store.fetch_all(:webhook_idempotency) == {:error, :store_unavailable}
    end

    test "fetch_all distinguishes a stopped store from an empty table" do
      missing_store = :missing_store_for_fetch_all

      assert Store.list(missing_store, :webhook_idempotency) == []
      assert Store.fetch_all(missing_store, :webhook_idempotency) == {:error, :store_unavailable}
    end

    test "idempotency diagnostics sanitize embedded raw keys and backend payloads" do
      secret = "backend-diagnostic-secret-#{unique_token()}"
      raw_key = {"integration", secret}
      original_state = swap_store_backend(DiagnosticLeakBackend, %{mode: :error, secret: secret})
      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      error_log =
        capture_log(fn ->
          assert Store.fetch(:webhook_idempotency, raw_key) == {:error, :store_unavailable}
        end)

      refute error_log =~ secret

      :sys.replace_state(Store, fn state ->
        %{state | backend_state: %{mode: :unexpected, secret: secret}}
      end)

      unexpected_log =
        capture_log(fn ->
          assert Store.fetch(:webhook_idempotency_responses, raw_key) ==
                   {:error, :store_unavailable}
        end)

      refute unexpected_log =~ secret
    end

    test "idempotency diagnostic sanitizer is total and preserves the Store process" do
      secret = "total-sanitizer-secret-#{unique_token()}"
      key = {"integration", secret}
      fence = %{state: "accepted"}
      store_pid = Process.whereis(Store)

      original_state =
        swap_store_backend(DiagnosticLeakBackend, %{
          mode: {:error_term, [secret | :improper_tail]},
          data: %{{:webhook_idempotency, key} => fence}
        })

      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      improper_log =
        capture_log(fn ->
          assert Store.fetch(:webhook_idempotency, key) == {:error, :store_unavailable}
        end)

      refute improper_log =~ secret
      assert Process.whereis(Store) == store_pid
      assert Process.alive?(store_pid)

      deep_term = Enum.reduce(1..1_000, secret, fn _, nested -> {nested} end)

      :sys.replace_state(Store, fn state ->
        %{state | backend_state: %{state.backend_state | mode: {:error_term, deep_term}}}
      end)

      deep_log =
        capture_log(fn ->
          assert Store.fetch(:webhook_idempotency, key) == {:error, :store_unavailable}
        end)

      refute deep_log =~ secret
      assert Process.whereis(Store) == store_pid

      large_term = List.duplicate(secret, 10_000)

      :sys.replace_state(Store, fn state ->
        %{state | backend_state: %{state.backend_state | mode: {:error_term, large_term}}}
      end)

      large_log =
        capture_log(fn ->
          assert Store.fetch(:webhook_idempotency, key) == {:error, :store_unavailable}
        end)

      refute large_log =~ secret
      assert Process.whereis(Store) == store_pid

      :sys.replace_state(Store, fn state ->
        %{state | backend_state: %{state.backend_state | mode: :ok}}
      end)

      assert Store.get(:webhook_idempotency, key) == fence
    end

    test "unexpected multi-delete responses cannot expose sensitive entries" do
      secret = "multi-delete-secret-#{unique_token()}"
      key = {"integration", secret}
      fence = %{state: "accepted", secret: secret}
      response = {:unexpected, %{entries: [{:webhook_idempotency, key, fence}], secret: secret}}

      original_state =
        swap_store_backend(DiagnosticLeakBackend, %{
          mode: {:compare_unexpected, response},
          secret: secret
        })

      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)

      {result, log} =
        with_log(fn ->
          Store.compare_and_delete_many([
            {:webhook_idempotency_responses, {key, "receipt"}, fence},
            {:webhook_idempotency, key, fence}
          ])
        end)

      assert result == {:error, :unexpected_backend_response}
      refute log =~ secret
      refute inspect(result) =~ secret
      assert Process.alive?(Process.whereis(Store))
    end

    test "fallback multi-delete bounds unexpected get and delete responses" do
      secret = "fallback-response-secret-#{unique_token()}"
      key = {"integration", secret}
      response_key = {key, "receipt"}
      fence = %{state: "accepted", secret: secret}
      receipt = %{status: 200, secret: secret}

      data = %{
        {:webhook_idempotency, key} => fence,
        {:webhook_idempotency_responses, response_key} => receipt
      }

      original_state =
        swap_store_backend(FallbackUnexpectedBackend, %{
          data: data,
          mode: :unexpected_get,
          secret: secret
        })

      on_exit(fn -> :sys.replace_state(Store, fn _ -> original_state end) end)
      store_pid = Process.whereis(Store)

      entries = [
        {:webhook_idempotency_responses, response_key, receipt},
        {:webhook_idempotency, key, fence}
      ]

      {get_result, get_log} = with_log(fn -> Store.compare_and_delete_many(entries) end)
      assert get_result == {:error, :unexpected_backend_response}
      refute inspect(get_result) =~ secret
      refute get_log =~ secret
      assert Process.whereis(Store) == store_pid

      :sys.replace_state(Store, fn state ->
        %{state | backend_state: %{state.backend_state | mode: :unexpected_delete}}
      end)

      {delete_result, delete_log} = with_log(fn -> Store.compare_and_delete_many(entries) end)
      assert delete_result == {:error, :unexpected_backend_response}
      refute inspect(delete_result) =~ secret
      refute delete_log =~ secret
      assert Process.whereis(Store) == store_pid

      :sys.replace_state(Store, fn state ->
        %{state | backend_state: %{state.backend_state | mode: :ok}}
      end)

      assert Store.get(:webhook_idempotency_responses, response_key) == receipt
      assert Store.get(:webhook_idempotency, key) == fence
    end

    test "finalize_run writes history to RunHistoryStore" do
      token = unique_token()
      key = session_key(token)
      rid = run_id(token, :history_delegate)

      assert :ok =
               Store.put(:runs, rid, %{
                 events: [%{type: :prompt, text: "hello"}],
                 summary: nil,
                 started_at: 1_000
               })

      assert :ok =
               Store.finalize_run(rid, %{
                 session_key: key
               })

      # The history write to RunHistoryStore is asynchronous
      AsyncHelpers.assert_eventually(
        fn ->
          key
          |> Store.get_run_history(limit: 50)
          |> Enum.any?(fn {id, _} -> id == rid end)
        end,
        timeout: 5_000
      )

      history = Store.get_run_history(key, limit: 50)
      assert {^rid, data} = Enum.find(history, fn {id, _} -> id == rid end)
      assert data.session_key == key
    end
  end

  describe "GenServer bottleneck fixes: append_introspection_event" do
    test "append_introspection_event is asynchronous (cast)" do
      token = unique_token()
      event = introspection_event(token, :async, System.system_time(:millisecond))

      # cast returns :ok immediately without blocking
      assert :ok = Store.append_introspection_event(event)

      # Poll until the event is persisted (proves it was async, not a call)
      Enum.reduce_while(1..100, nil, fn _, _ ->
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
