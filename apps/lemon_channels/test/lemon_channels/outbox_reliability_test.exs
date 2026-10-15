defmodule LemonChannels.OutboxReliabilityTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{OutboundPayload, Outbox, Registry}
  alias LemonChannels.Outbox.{Dedupe, RateLimiter}

  defmodule ControlledPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-reliability"
    @impl true
    def meta, do: %{label: "Reliability", capabilities: %{chunk_limit: 4096}, docs: nil}
    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}
    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}
    @impl true
    def gateway_methods, do: []

    @impl true
    def deliver(payload) do
      send(payload.notify_pid, {:write_attempt, payload.notify_ref, self()})

      receive do
        :raise_after_write -> raise "platform write completed before adapter failed"
        :bad_contract -> :unexpected_adapter_result
        {:finish, result} -> result
      end
    end
  end

  setup do
    for module <- [Registry, RateLimiter, Dedupe, Outbox] do
      if is_nil(Process.whereis(module)), do: start_supervised!(module)
    end

    Registry.register(ControlledPlugin)

    on_exit(fn ->
      if Process.whereis(Registry), do: Registry.unregister(ControlledPlugin.id())
    end)

    %{account: "reliability-#{System.unique_integer([:positive])}"}
  end

  @tag capture_log: true
  test "a worker exception is not replayed and the next write in its group recovers", ctx do
    assert_failed_worker_releases_group(ctx, :raise_after_write, RuntimeError)
  end

  @tag capture_log: true
  test "an invalid adapter result crashes only its worker, not the outbox", ctx do
    assert_failed_worker_releases_group(ctx, :bad_contract, CaseClauseError)
  end

  test "explicit API rejection and unknown outcomes notify failure without replay", ctx do
    for reason <- [
          {:http_error, 400, "invalid recipient"},
          :outcome_unknown,
          {:outcome_unknown, :connection_lost},
          {:discord_send_crashed, RuntimeError.exception("lost acknowledgement")}
        ] do
      payload = payload(ctx.account)
      ref = payload.notify_ref
      assert {:ok, _} = Outbox.enqueue(payload)
      assert_receive {:write_attempt, ^ref, worker}, 1_000
      send(worker, {:finish, {:error, reason}})
      assert_receive {:delivery_result, ^ref, {:error, ^reason}}, 1_000
      assert_group_drained(ctx.account)
      refute_receive {:write_attempt, ^ref, _}, 0
    end
  end

  test "unclassified failures are terminal and ambiguous transport errors are unknown", ctx do
    for reason <- [:timeout, {:closed, :socket}, {:http_error, 503, ""}, :unexpected_failure] do
      payload = payload(ctx.account)
      ref = payload.notify_ref
      expected = LemonChannels.DeliveryError.classify(reason)
      assert {:ok, _} = Outbox.enqueue(payload)
      assert_receive {:write_attempt, ^ref, worker}, 1000
      send(worker, {:finish, {:error, reason}})
      assert_receive {:delivery_result, ^ref, {:error, ^expected}}, 1000
      assert_group_drained(ctx.account)
      refute_receive {:write_attempt, ^ref, _}, 0
    end
  end

  @tag timeout: 10_000
  test "enqueue timeout reports unknown admission without resending", ctx do
    outbox = Process.whereis(Outbox)
    payload = payload(ctx.account)
    :ok = :sys.suspend(outbox)

    try do
      assert {:error, {:outcome_unknown, :enqueue_timeout}} = Outbox.enqueue(payload)
    after
      :sys.resume(outbox)
    end

    ref = payload.notify_ref
    assert_receive {:write_attempt, ^ref, worker}, 1000
    send(worker, {:finish, {:ok, :accepted}})
    assert_receive {:delivery_result, ^ref, {:ok, :accepted}}, 1000
    assert_group_drained(ctx.account)
    refute_receive {:write_attempt, ^ref, _}, 0
  end

  defp assert_failed_worker_releases_group(ctx, failure, exception_module) do
    outbox = Process.whereis(Outbox)
    first = payload(ctx.account)
    next = payload(ctx.account)
    first_ref = first.notify_ref
    next_ref = next.notify_ref

    assert {:ok, _} = Outbox.enqueue(first)
    assert_receive {:write_attempt, ^first_ref, first_worker}, 1_000
    assert {:ok, _} = Outbox.enqueue(next)

    # Both writes share a delivery group. The later one cannot overtake the
    # blocked first write, but an independent conversation can still proceed.
    independent = %{payload(ctx.account) | peer: %{kind: :dm, id: "another-peer"}}
    independent_ref = independent.notify_ref
    assert {:ok, _} = Outbox.enqueue(independent)
    assert_receive {:write_attempt, ^independent_ref, independent_worker}, 1_000
    refute_receive {:write_attempt, ^next_ref, _}, 0
    send(independent_worker, {:finish, {:ok, :independent_message}})
    assert_receive {:delivery_result, ^independent_ref, {:ok, :independent_message}}, 1_000

    monitor = Process.monitor(first_worker)
    send(first_worker, failure)
    assert_receive {:DOWN, ^monitor, :process, ^first_worker, _}, 1_000

    assert_receive {:delivery_result, ^first_ref,
                    {:error, {:worker_exit, {%{__struct__: ^exception_module}, _stack}}}},
                   1_000

    assert_receive {:write_attempt, ^next_ref, next_worker}, 1_000
    send(next_worker, {:finish, {:ok, :next_message}})
    assert_receive {:delivery_result, ^next_ref, {:ok, :next_message}}, 1_000

    assert Process.whereis(Outbox) == outbox
    assert_group_drained(ctx.account)
    refute_receive {:write_attempt, ^first_ref, _}, 0
  end

  defp assert_group_drained(account) do
    state = :sys.get_state(Outbox)
    refute Enum.any?(:queue.to_list(state.queue), &(&1.payload.account_id == account))

    refute Enum.any?(state.processing, fn {_ref, entry} -> entry.payload.account_id == account end)
  end

  defp payload(account) do
    %OutboundPayload{
      channel_id: ControlledPlugin.id(),
      account_id: account,
      peer: %{kind: :dm, id: "same-peer", thread_id: nil},
      kind: :text,
      content: "one external write",
      notify_pid: self(),
      notify_ref: make_ref(),
      meta: %{notify_tag: :delivery_result}
    }
  end
end
