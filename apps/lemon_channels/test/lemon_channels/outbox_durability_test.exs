defmodule LemonChannels.OutboxDurabilityTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{OutboundPayload, Outbox, Registry}
  alias LemonChannels.Outbox.{Dedupe, QueueStore}
  alias LemonCore.Store

  @store :outbox_durability_test_store
  @outbox :outbox_durability_test_queue
  @workers :outbox_durability_test_workers

  defmodule Adapter do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-durability-regression"
    @impl true
    def meta, do: %{label: "Durability regression", capabilities: %{chunk_limit: 64}, docs: nil}
    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
    @impl true
    def normalize_inbound(_raw), do: {:error, :unsupported}
    @impl true
    def gateway_methods, do: []

    @impl true
    def deliver(payload) do
      send(payload.meta.test_pid, {:attempt, payload.meta.label, payload.idempotency_key, self()})

      if Map.has_key?(payload.meta, :chunk_index) do
        send(
          payload.meta.test_pid,
          {:chunk_attempt, payload.meta.chunk_index, payload.idempotency_key, self()}
        )
      end

      receive do
        {:finish, result} -> result
        {:raise, message} -> raise message
      end
    end
  end

  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend
    alias LemonCore.Store.SqliteBackend

    @impl true
    def init(opts) do
      with {:ok, backend} <-
             SqliteBackend.init(path: Keyword.fetch!(opts, :path), ephemeral_tables: []) do
        {:ok,
         %{
           backend: backend,
           faults: Keyword.fetch!(opts, :faults),
           observer: Keyword.fetch!(opts, :observer)
         }}
      end
    end

    @impl true
    def put(state, table, key, value) do
      with :ok <- gate(state, :put),
           {:ok, backend} <- SqliteBackend.put(state.backend, table, key, value) do
        {:ok, %{state | backend: backend}}
      end
    end

    @impl true
    def put_new(state, table, key, value) do
      case SqliteBackend.put_new(state.backend, table, key, value) do
        {:ok, backend} -> {:ok, %{state | backend: backend}}
        {:exists, backend} -> {:exists, %{state | backend: backend}}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def get(state, table, key) do
      with {:ok, value, backend} <- SqliteBackend.get(state.backend, table, key) do
        {:ok, value, %{state | backend: backend}}
      end
    end

    @impl true
    def delete(state, table, key) do
      with {:ok, backend} <- SqliteBackend.delete(state.backend, table, key) do
        {:ok, %{state | backend: backend}}
      end
    end

    @impl true
    def list(state, table) do
      with {:ok, values, backend} <- SqliteBackend.list(state.backend, table) do
        {:ok, values, %{state | backend: backend}}
      end
    end

    @impl true
    def sync(state) do
      with :ok <- gate(state, :sync),
           {:ok, backend} <- SqliteBackend.sync(state.backend) do
        {:ok, %{state | backend: backend}}
      end
    end

    @impl true
    def close(state), do: SqliteBackend.close(state.backend)

    defp gate(state, operation) do
      case :ets.lookup(state.faults, operation) do
        [{^operation, :fail}] ->
          {:error, :injected_failure}

        [{^operation, :block}] ->
          token = make_ref()
          send(state.observer, {:storage_blocked, operation, self(), token})

          receive do
            {:continue_storage, ^token} -> :ok
          end

        [] ->
          :ok
      end
    end
  end

  setup context do
    path = Path.join(context.tmp_dir, "outbox.sqlite3")
    faults = :ets.new(:outbox_durability_faults, [:public, :set])

    store_opts = [
      name: @store,
      backend: FaultBackend,
      backend_opts: [path: path, faults: faults, observer: self()]
    ]

    start_store(store_opts)
    start_supervised!(LemonCore.TaskSupervisor.child_spec(name: @workers, max_children: 2))
    :ok = Registry.register(Adapter)
    previous_keys = :ets.match_object(:lemon_channels_outbox_dedupe, {{Adapter.id(), :_}, :_})

    on_exit(fn ->
      Registry.unregister(Adapter.id())
      :ets.match_delete(:lemon_channels_outbox_dedupe, {{Adapter.id(), :_}, :_})
      :ets.insert(:lemon_channels_outbox_dedupe, previous_keys)
    end)

    %{
      store_opts: store_opts,
      faults: faults,
      account: "durability-#{System.unique_integer([:positive])}"
    }
  end

  @tag :tmp_dir
  test "acknowledged items survive queue and Store crashes with their original keys and FIFO",
       ctx do
    outbox = start_outbox()
    first = payload(ctx, "first", "same-peer")
    second = payload(ctx, "second", "same-peer")
    first_key = first.idempotency_key
    second_key = second.idempotency_key

    assert {:ok, _} = Outbox.enqueue(outbox, first)
    assert_receive {:attempt, "first", ^first_key, first_worker}
    assert {:ok, _} = Outbox.enqueue(outbox, second)
    refute_receive {:attempt, "second", _, _}, 0
    assert {:ok, pending} = Store.fetch_all(@store, QueueStore.pending_table())
    assert length(pending) == 2

    worker_monitor = Process.monitor(first_worker)
    crash(outbox)
    assert_receive {:DOWN, ^worker_monitor, :process, ^first_worker, _}
    crash(Process.whereis(@store))
    start_store(ctx.store_opts)
    restarted = start_outbox()

    assert_receive {:attempt, "first", ^first_key, replay_worker}
    refute_receive {:attempt, "second", _, _}, 0
    send(replay_worker, {:finish, {:ok, :first}})
    first_ref = first.notify_ref
    assert_receive {:durable_result, ^first_ref, {:ok, :first}}
    assert_receive {:attempt, "second", ^second_key, second_worker}
    send(second_worker, {:finish, {:ok, :second}})
    second_ref = second.notify_ref
    assert_receive {:durable_result, ^second_ref, {:ok, :second}}
    assert {:ok, []} = Store.fetch_all(@store, QueueStore.pending_table())

    # Remove only this test's volatile keys: the second boot must restore the
    # content-free durable receipts rather than pass on an old ETS marker.
    crash(restarted)
    :ets.delete(:lemon_channels_outbox_dedupe, {Adapter.id(), first_key})
    :ets.delete(:lemon_channels_outbox_dedupe, {Adapter.id(), second_key})
    crash(Process.whereis(@store))
    start_store(ctx.store_opts)
    restored = start_outbox()
    assert {:error, :duplicate} = Outbox.enqueue(restored, first)
    assert {:error, :duplicate} = Outbox.enqueue(restored, second)
    refute_receive {:attempt, _, _, _}, 0
  end

  @tag :tmp_dir
  test "enqueue cannot acknowledge or start delivery before the durability barrier", ctx do
    outbox = start_outbox()
    :ets.insert(ctx.faults, {:sync, :block})
    parent = self()
    item = payload(ctx, "barrier", "peer")
    caller = Task.async(fn -> send(parent, {:enqueue_reply, Outbox.enqueue(outbox, item)}) end)
    assert_receive {:storage_blocked, :sync, store, token}
    refute_receive {:enqueue_reply, _}, 0
    refute_receive {:attempt, _, _, _}, 0
    :ets.delete(ctx.faults, :sync)
    send(store, {:continue_storage, token})
    assert_receive {:enqueue_reply, {:ok, _}}
    Task.await(caller)
    assert_receive {:attempt, "barrier", _, worker}
    send(worker, {:finish, {:ok, :accepted}})
    ref = item.notify_ref
    assert_receive {:durable_result, ^ref, {:ok, :accepted}}
  end

  @tag :tmp_dir
  test "failed durable puts report unknown admission and retain bounded capacity", ctx do
    outbox = start_outbox(max_queue_size: 2)
    :ets.insert(ctx.faults, {:put, :fail})
    first = payload(ctx, "put-failure", "one")

    assert {:error, {:outcome_unknown, :outbox_persistence_failed}} =
             Outbox.enqueue(outbox, first)

    assert Outbox.stats(outbox).pending_count == 1
    refute_receive {:attempt, _, _, _}, 0

    second = payload(ctx, "queued-behind-failure", "two")
    request = :gen_server.send_request(outbox, {:enqueue, second})
    # This synchronous inspection is an explicit mailbox barrier: the second
    # admission has reserved its slot behind the first failed storage operation.
    assert Outbox.stats(outbox).queue_depth == 2
    assert {:error, :queue_full} = Outbox.enqueue(outbox, payload(ctx, "full", "three"))
    :ets.delete(ctx.faults, :put)
    send(outbox, :retry_storage)
    assert {:reply, {:ok, _}} = :gen_server.receive_response(request, 2_000)

    for label <- ["put-failure", "queued-behind-failure"] do
      assert_receive {:attempt, ^label, _, worker}
      send(worker, {:finish, {:ok, :accepted}})
    end

    for ref <- [first.notify_ref, second.notify_ref] do
      assert_receive {:durable_result, ^ref, {:ok, :accepted}}
    end
  end

  @tag :tmp_dir
  test "a failed barrier itself returns unknown rather than an acknowledged enqueue", ctx do
    outbox = start_outbox()
    :ets.insert(ctx.faults, {:sync, :fail})
    item = payload(ctx, "sync-failure", "peer")
    assert {:error, {:outcome_unknown, :outbox_persistence_failed}} = Outbox.enqueue(outbox, item)
    refute_receive {:attempt, _, _, _}, 0
    :ets.delete(ctx.faults, :sync)
    send(outbox, :retry_storage)
    key = item.idempotency_key
    assert_receive {:attempt, "sync-failure", ^key, worker}
    send(worker, {:finish, {:ok, :accepted}})
    ref = item.notify_ref
    assert_receive {:durable_result, ^ref, {:ok, :accepted}}
  end

  @tag :tmp_dir
  test "recovery expires old pending content and caps content-free confirmed receipts", ctx do
    outbox = start_outbox(max_dedupe_entries: 2)

    for index <- 1..3 do
      item = payload(ctx, "confirmed-#{index}", "peer-#{index}")
      assert {:ok, _} = Outbox.enqueue(outbox, item)
      assert_receive {:attempt, _, _, worker}
      send(worker, {:finish, {:ok, :accepted}})
      ref = item.notify_ref
      assert_receive {:durable_result, ^ref, {:ok, :accepted}}
    end

    assert {:ok, receipts} = Store.fetch_all(@store, QueueStore.receipts_table())
    assert length(receipts) == 2

    assert Enum.all?(receipts, fn {_id, receipt} ->
             Enum.sort(Map.keys(receipt)) == [:channel_id, :expires_at_ms, :key, :sequence]
           end)

    item = payload(ctx, "expires", "peer")
    assert {:ok, _} = Outbox.enqueue(outbox, item)
    assert_receive {:attempt, "expires", _, worker}
    monitor = Process.monitor(worker)
    crash(outbox)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert {:ok, [{id, entry}]} = Store.fetch_all(@store, QueueStore.pending_table())
    assert :ok = Store.put(@store, QueueStore.pending_table(), id, %{entry | expires_at_ms: 0})
    [{receipt_id, receipt} | _] = receipts

    assert :ok =
             Store.put(@store, QueueStore.receipts_table(), receipt_id, %{
               receipt
               | expires_at_ms: 0
             })

    assert :ok = Store.sync(@store)
    restored = start_outbox(max_dedupe_entries: 2)
    assert Outbox.stats(restored).queue_depth == 0
    assert {:ok, []} = Store.fetch_all(@store, QueueStore.pending_table())
    assert {:ok, remaining_receipts} = Store.fetch_all(@store, QueueStore.receipts_table())
    assert length(remaining_receipts) == 1
    refute_receive {:attempt, "expires", _, _}, 0
  end

  @tag :tmp_dir
  test "delivery concurrency is capped by both queue admission and Task.Supervisor", ctx do
    outbox = start_outbox()
    items = for index <- 1..5, do: payload(ctx, "concurrent-#{index}", "peer-#{index}")

    for item <- items, do: assert({:ok, _} = Outbox.enqueue(outbox, item))
    assert_receive {:attempt, first, _, worker1}
    assert_receive {:attempt, second, _, worker2}
    assert first != second
    assert Outbox.stats(outbox).processing_count == 2
    assert %{active: 2} = Supervisor.count_children(@workers)

    assert {:error, :task_capacity_reached} =
             LemonCore.TaskSupervisor.start_child(@workers, fn -> :unexpected end)

    refute_receive {:attempt, _, _, _}, 0
    send(worker1, {:finish, {:ok, :accepted}})
    assert_receive {:attempt, _, _, worker3}
    assert %{active: 2} = Supervisor.count_children(@workers)
    send(worker2, {:finish, {:ok, :accepted}})
    assert_receive {:attempt, _, _, worker4}
    send(worker3, {:finish, {:ok, :accepted}})
    assert_receive {:attempt, _, _, worker5}
    send(worker4, {:finish, {:ok, :accepted}})
    send(worker5, {:finish, {:ok, :accepted}})

    for item <- items do
      ref = item.notify_ref
      assert_receive {:durable_result, ^ref, {:ok, :accepted}}
    end
  end

  @tag :tmp_dir
  test "enqueue caller and queue owner make no GenServer.call, even with lookup owners suspended",
       ctx do
    outbox = start_outbox()
    item = payload(ctx, "trace", "peer")
    parent = self()

    caller =
      spawn(fn ->
        receive do
          :go -> send(parent, {:traced_enqueue, Outbox.enqueue(outbox, item)})
        end
      end)

    owners = [Registry, LemonChannels.Outbox.RateLimiter, Dedupe]
    patterns = for arity <- [2, 3], do: {GenServer, :call, arity}
    previous = Enum.map(patterns, fn mfa -> {mfa, :erlang.trace_info(mfa, :match_spec)} end)

    try do
      Enum.each(owners, &:sys.suspend/1)
      Enum.each(patterns, &:erlang.trace_pattern(&1, true, [:local]))
      :erlang.trace(caller, true, [:call, {:tracer, self()}])
      :erlang.trace(outbox, true, [:call, {:tracer, self()}])
      send(caller, :go)
      assert_receive {:traced_enqueue, {:ok, _}}
      assert_receive {:attempt, "trace", _, worker}
      send(worker, {:finish, {:ok, :accepted}})
      ref = item.notify_ref
      assert_receive {:durable_result, ^ref, {:ok, :accepted}}
      marker = :erlang.trace_delivered(:all)
      assert_receive {:trace_delivered, :all, ^marker}
      refute_receive {:trace, _, :call, {GenServer, :call, _}}, 0
    after
      if Process.alive?(caller), do: :erlang.trace(caller, false, [:call])
      :erlang.trace(outbox, false, [:call])

      Enum.each(previous, fn {mfa, {:match_spec, pattern}} ->
        :erlang.trace_pattern(mfa, pattern, [:local])
      end)

      Enum.each(owners, &:sys.resume/1)
    end
  end

  @tag :tmp_dir
  test "adapter exception diagnostics never include message content or exception text", ctx do
    import ExUnit.CaptureLog
    outbox = start_outbox(max_attempts: 0)
    item = %{payload(ctx, "private", "peer") | content: "private-body-marker"}
    test_pid = self()
    handler = "outbox-private-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:lemon, :channels, :deliver, :exception],
      fn _, _, meta, _ ->
        send(test_pid, {:exception_metadata, meta})
      end,
      nil
    )

    try do
      log =
        capture_log(fn ->
          assert {:ok, _} = Outbox.enqueue(outbox, item)
          assert_receive {:attempt, "private", _, worker}
          send(worker, {:raise, "private-body-marker"})
          assert_receive {:exception_metadata, metadata}
          refute inspect(metadata) =~ "private-body-marker"
          refute Map.has_key?(metadata, :reason)
          refute Map.has_key?(metadata, :stacktrace)
          ref = item.notify_ref
          assert_receive {:durable_result, ^ref, {:error, {:worker_exit, {%RuntimeError{}, []}}}}
        end)

      refute log =~ "private-body-marker"
    after
      :telemetry.detach(handler)
    end
  end

  @tag :tmp_dir
  test "a durable retry cannot be overtaken by a later group member after restart", ctx do
    outbox = start_outbox()
    test_pid = self()
    handler = "outbox-retry-#{System.unique_integer([:positive])}"
    retry_barrier = make_ref()

    :telemetry.attach(
      handler,
      [:lemon, :channels, :outbox, :queue],
      fn _, _measurements, metadata, _ ->
        if metadata[:event] == :retry_scheduled and metadata[:channel_id] == Adapter.id() do
          send(test_pid, {:retry_durable, metadata.delay_ms})

          # Crash at the durable transition, never after an old worker dispatch.
          receive do
            {:release_retry, ^retry_barrier} -> :ok
          end
        end
      end,
      nil
    )

    try do
      first = payload(ctx, "retry-head", "same-peer")
      second = payload(ctx, "retry-tail", "same-peer")
      assert {:ok, _} = Outbox.enqueue(outbox, first)
      assert_receive {:attempt, "retry-head", _, worker}, 1_000
      assert {:ok, _} = Outbox.enqueue(outbox, second)
      failed_at_ms = System.system_time(:millisecond)
      send(worker, {:finish, {:error, {:outcome_unknown, :lost_ack}}})
      assert_receive {:retry_durable, 1_000}, 1_000
      assert {:ok, records} = Store.fetch_all(@store, QueueStore.pending_table())

      {_id, retry} =
        Enum.find(records, fn {_id, entry} ->
          entry.payload.idempotency_key == first.idempotency_key
        end)

      assert retry.attempts == 1
      assert retry.available_at_ms >= failed_at_ms + 1_000

      crash(outbox)
      restarted = start_outbox()
      refute_receive {:attempt, "retry-tail", _, _}, 0
      key = first.idempotency_key
      assert_receive {:attempt, "retry-head", ^key, replay}, 2_500
      refute_receive {:attempt, "retry-tail", _, _}, 0
      send(replay, {:finish, {:ok, :head}})
      assert_receive {:attempt, "retry-tail", _, tail}, 1_000
      send(tail, {:finish, {:ok, :tail}})

      for ref <- [first.notify_ref, second.notify_ref] do
        assert_receive {:durable_result, ^ref, {:ok, _}}, 1_000
      end

      assert Outbox.stats(restarted).queue_depth == 0
    after
      send(outbox, {:release_retry, retry_barrier})
      :telemetry.detach(handler)
    end
  end

  @tag :tmp_dir
  test "keyless chunks retain nil adapter keys and recover their private identities in order",
       ctx do
    outbox = start_outbox()

    item = %{
      payload(ctx, "chunks", "same-peer")
      | content: String.duplicate("x", 130),
        idempotency_key: nil
    }

    assert {:ok, _} = Outbox.enqueue(outbox, item)
    assert_receive {:attempt, "chunks", nil, worker}, 1_000
    assert_receive {:chunk_attempt, 0, nil, ^worker}, 1_000
    assert {:ok, records} = Store.fetch_all(@store, QueueStore.pending_table())
    chunks = records |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.chunk_index)
    assert length(chunks) == 3
    assert Enum.all?(chunks, &is_nil(&1.payload.idempotency_key))
    keys = Enum.map(chunks, &QueueStore.delivery_key/1)
    assert Enum.all?(keys, &is_binary/1)
    assert length(Enum.uniq(keys)) == 3
    monitor = Process.monitor(worker)
    crash(outbox)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    _ = start_outbox()
    assert {:ok, recovered} = Store.fetch_all(@store, QueueStore.pending_table())
    recovered = recovered |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.chunk_index)
    assert Enum.map(recovered, &QueueStore.delivery_key/1) == keys
    assert Enum.all?(recovered, &is_nil(&1.payload.idempotency_key))

    for index <- 0..2 do
      assert_receive {:chunk_attempt, ^index, nil, replay}, 1_000
      if index == 2, do: :ets.insert(ctx.faults, {:sync, :block})
      send(replay, {:finish, {:ok, :chunk}})
    end

    assert_receive {:storage_blocked, :sync, store, token}, 1_000
    :ets.delete(ctx.faults, :sync)
    send(store, {:continue_storage, token})
    assert {:ok, []} = Store.fetch_all(@store, QueueStore.pending_table())
  end

  @tag :tmp_dir
  test "a keyless pending record with a durable receipt is suppressed after restart", ctx do
    outbox = start_outbox()
    item = %{payload(ctx, "keyless-confirmed", "peer") | idempotency_key: nil}
    assert {:ok, _} = Outbox.enqueue(outbox, item)
    assert_receive {:attempt, "keyless-confirmed", nil, worker}, 1_000
    assert {:ok, [{_id, entry}]} = Store.fetch_all(@store, QueueStore.pending_table())

    # Inject the crash window between persisting confirmation and deleting the
    # pending record. Its internal identity must work without changing nil in
    # the original adapter payload.
    {table, id, receipt} = entry |> QueueStore.receipt() |> QueueStore.receipt_put()
    assert :ok = Store.put(@store, table, id, receipt)
    assert :ok = Store.sync(@store)
    monitor = Process.monitor(worker)
    crash(outbox)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    _ = start_outbox()
    ref = item.notify_ref
    assert_receive {:durable_result, ^ref, {:error, :duplicate}}, 1_000
    refute_receive {:attempt, "keyless-confirmed", _, _}, 0
    assert {:ok, []} = Store.fetch_all(@store, QueueStore.pending_table())
  end

  @tag :tmp_dir
  test "expired queued content is removed without a delivery attempt at runtime", ctx do
    outbox = start_outbox()
    head = payload(ctx, "expiry-head", "same-peer")
    tail = payload(ctx, "expiry-tail", "same-peer")
    assert {:ok, _} = Outbox.enqueue(outbox, head)
    assert_receive {:attempt, "expiry-head", _, worker}, 1_000
    assert {:ok, _} = Outbox.enqueue(outbox, tail)

    [expired] =
      :sys.replace_state(outbox, fn state ->
        [entry] = :queue.to_list(state.queue)
        %{state | queue: :queue.from_list([%{entry | expires_at_ms: 0}])}
      end).queue
      |> :queue.to_list()

    assert :ok =
             Store.put(
               @store,
               QueueStore.pending_table(),
               expired.durable_id,
               Map.drop(expired, [:recovered, :worker_pid])
             )

    assert :ok = Store.sync(@store)
    send(worker, {:finish, {:ok, :head}})
    tail_ref = tail.notify_ref
    assert_receive {:durable_result, ^tail_ref, {:error, :expired}}, 1_000
    refute_receive {:attempt, "expiry-tail", _, _}, 0
    assert {:ok, []} = Store.fetch_all(@store, QueueStore.pending_table())
  end

  defp start_store(opts) do
    start_supervised!(Supervisor.child_spec({Store, opts}, id: @store, restart: :temporary))
  end

  defp start_outbox(opts \\ []) do
    opts =
      Keyword.merge(
        [name: @outbox, store: @store, worker_supervisor: @workers, max_concurrency: 2],
        opts
      )

    start_supervised!(Supervisor.child_spec({Outbox, opts}, id: @outbox, restart: :temporary))
  end

  defp crash(pid) do
    id = if Process.whereis(@outbox) == pid, do: @outbox, else: @store
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    _ = stop_supervised(id)
  end

  defp payload(ctx, label, peer) do
    %OutboundPayload{
      channel_id: Adapter.id(),
      account_id: ctx.account,
      peer: %{kind: :dm, id: peer, thread_id: nil},
      kind: :text,
      content: "message",
      idempotency_key: "#{ctx.account}:#{label}",
      notify_pid: self(),
      notify_ref: make_ref(),
      meta: %{test_pid: self(), label: label, notify_tag: :durable_result}
    }
  end
end
