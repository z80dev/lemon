defmodule LemonCore.IdempotencyConcurrencyTest do
  # Swaps the default Store's backend, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias LemonCore.{Idempotency, Store}
  alias LemonCore.Store.EtsBackend

  # Fails or stalls every operation on the idempotency table, inside the real
  # Store process, while all other tables keep working.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    def set(fault), do: :persistent_term.put({__MODULE__, :fault}, fault)
    def clear, do: :persistent_term.erase({__MODULE__, :fault})

    defp faulted(:idempotency, fun) do
      case :persistent_term.get({__MODULE__, :fault}, nil) do
        :error ->
          {:error, :boom}

        {:stall, ms} ->
          Process.sleep(ms)
          fun.()

        nil ->
          fun.()
      end
    end

    defp faulted(_table, fun), do: fun.()

    defdelegate init(opts), to: EtsBackend
    defdelegate sync(state), to: EtsBackend
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend

    def get(s, t, k), do: faulted(t, fn -> EtsBackend.get(s, t, k) end)
    def put(s, t, k, v), do: faulted(t, fn -> EtsBackend.put(s, t, k, v) end)
    def put_new(s, t, k, v), do: faulted(t, fn -> EtsBackend.put_new(s, t, k, v) end)
    def delete(s, t, k), do: faulted(t, fn -> EtsBackend.delete(s, t, k) end)
    def list(s, t), do: faulted(t, fn -> EtsBackend.list(s, t) end)
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_core)
    %{backend: EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    on_exit(fn ->
      FaultBackend.clear()
      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})
    end)

    key = "idem-#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.delete(:idempotency, "concurrency:" <> key) end)
    %{key: key}
  end

  test "two concurrent execute/3 calls with one key invoke the function once", %{key: key} do
    test_pid = self()
    counter = :counters.new(1, [])

    fun = fn ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:started, self()})

      receive do
        :release -> :done
      after
        5_000 -> :timeout
      end
    end

    first = Task.async(fn -> Idempotency.execute("concurrency", key, fun) end)
    assert_receive {:started, first_runner}, 2_000

    second = Task.async(fn -> Idempotency.execute("concurrency", key, fun) end)
    second_result = Task.await(second, 6_000)
    send(first_runner, :release)
    first_result = Task.await(first, 6_000)

    assert :counters.get(counter, 1) == 1
    assert first_result == {:ok, :done}
    assert second_result == {:error, :in_progress}

    # Once completed, every later caller gets the recorded result.
    assert Idempotency.execute("concurrency", key, fun) == {:ok, :done}
    assert :counters.get(counter, 1) == 1
  end

  test "concurrent put_new/3 calls store exactly one result", %{key: key} do
    results =
      1..8
      |> Enum.map(fn n -> Task.async(fn -> Idempotency.put_new("concurrency", key, n) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == :exists)) == 7
  end

  test "a backend error is store_unavailable, never a miss that executes", %{key: key} do
    :ok = Idempotency.put("concurrency", key, :recorded)
    FaultBackend.set(:error)
    counter = :counters.new(1, [])

    assert Idempotency.get("concurrency", key) == {:error, :store_unavailable}

    assert Idempotency.execute("concurrency", key, fn -> :counters.add(counter, 1, 1) end) ==
             {:error, :store_unavailable}

    assert :counters.get(counter, 1) == 0
  end

  @tag timeout: 60_000
  test "a Store call timeout is store_unavailable and the function never runs", %{key: key} do
    FaultBackend.set({:stall, 5_500})
    counter = :counters.new(1, [])

    assert Idempotency.execute("concurrency", key, fn -> :counters.add(counter, 1, 1) end) ==
             {:error, :store_unavailable}

    assert :counters.get(counter, 1) == 0
  end

  describe "unresolved claims" do
    @day_ms 24 * 60 * 60 * 1000

    test "a pending claim older than the TTL is never taken over", %{key: key} do
      assert {:new, _claim} = Idempotency.begin("concurrency", key, %{"run_id" => "run-original"})
      age_entry(key, @day_ms + 60_000)

      assert {:pending, _claim} =
               Idempotency.begin("concurrency", key, %{"run_id" => "run-second"})

      assert Idempotency.get("concurrency", key) == {:error, :in_progress}
      assert Idempotency.put_new("concurrency", key, :replacement) == :exists
      assert stored_meta(key) == %{"run_id" => "run-original"}
    end

    test "an unknown outcome stays pending past the TTL and never re-executes", %{key: key} do
      counter = :counters.new(1, [])

      assert_raise RuntimeError, fn ->
        Idempotency.execute("concurrency", key, fn ->
          :counters.add(counter, 1, 1)
          raise "outcome unknown"
        end)
      end

      age_entry(key, 2 * @day_ms)

      assert Idempotency.execute("concurrency", key, fn -> :counters.add(counter, 1, 1) end) ==
               {:error, :in_progress}

      assert :counters.get(counter, 1) == 1
    end

    test "a failed completion write keeps the original claim pending", %{key: key} do
      assert {:new, claim} = Idempotency.begin("concurrency", key, %{"run_id" => "run-original"})

      FaultBackend.set(:error)
      assert {:error, _reason} = Idempotency.complete(claim, %{"run_id" => "run-original"})
      FaultBackend.clear()

      age_entry(key, @day_ms + 60_000)

      assert {:pending, _claim} =
               Idempotency.begin("concurrency", key, %{"run_id" => "run-second"})

      assert stored_meta(key) == %{"run_id" => "run-original"}
    end

    @tag :tmp_dir
    test "the retention sweep never deletes a pending claim", %{key: key, tmp_dir: tmp_dir} do
      assert {:new, _claim} = Idempotency.begin("concurrency", key, %{"run_id" => "run-original"})
      pending = age_entry(key, 3 * @day_ms)

      swept_done = %{
        "state" => "done",
        "result" => :old,
        "inserted_at_ms" => now_ms() - 3 * @day_ms
      }

      for {name, backend, opts} <- [
            {:"idem_sweep_ets_#{key}", EtsBackend, []},
            {:"idem_sweep_sqlite_#{key}", LemonCore.Store.SqliteBackend,
             [path: Path.join(tmp_dir, "store.sqlite3")]}
          ] do
        start_supervised!(
          Supervisor.child_spec(
            {Store, name: name, backend: backend, backend_opts: opts, cached_tables: []},
            id: name
          )
        )

        :ok = Store.put(name, :idempotency, "pending", pending)
        :ok = Store.put(name, :idempotency, "done", swept_done)

        send(Process.whereis(name), :sweep_expired)
        :ok = Store.ping(name)

        assert Store.fetch(name, :idempotency, "done") == {:ok, nil}, "#{backend} did not sweep"
        assert Store.fetch(name, :idempotency, "pending") == {:ok, pending}
      end
    end
  end

  defp now_ms, do: System.system_time(:millisecond)

  # Moves every timestamp of the stored entry into the past, so the test does
  # not depend on which field the entry uses.
  defp age_entry(key, ms) do
    store_key = "concurrency:" <> key
    {:ok, %{} = entry} = Store.fetch(:idempotency, store_key)

    aged =
      Map.new(entry, fn
        {field, at} when is_binary(field) and is_integer(at) ->
          if String.ends_with?(field, "_at_ms"), do: {field, at - ms}, else: {field, at}

        other ->
          other
      end)

    :ok = Store.put(:idempotency, store_key, aged)
    aged
  end

  defp stored_meta(key) do
    {:ok, %{"meta" => meta}} = Store.fetch(:idempotency, "concurrency:" <> key)
    meta
  end
end
