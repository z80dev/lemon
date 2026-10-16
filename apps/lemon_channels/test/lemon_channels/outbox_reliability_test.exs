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
      send(payload.notify_pid, {:write_key, payload.notify_ref, payload.idempotency_key})
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
      Application.delete_env(:lemon_channels, Outbox)
      if Process.whereis(Registry), do: Registry.unregister(ControlledPlugin.id())
    end)

    %{account: "reliability-#{System.unique_integer([:positive])}"}
  end

  @tag capture_log: true
  test "with no retry budget a worker exception is terminal and the next write recovers", ctx do
    put_retry_budget(0)
    assert_failed_worker_releases_group(ctx, :raise_after_write, RuntimeError)
  end

  @tag capture_log: true
  test "an invalid adapter result crashes only its worker, not the outbox", ctx do
    put_retry_budget(0)
    assert_failed_worker_releases_group(ctx, :bad_contract, CaseClauseError)
  end

  test "with no retry budget failures are reported without replay", ctx do
    put_retry_budget(0)

    for reason <- [
          {:http_error, 400, "invalid recipient"},
          :outcome_unknown,
          {:outcome_unknown, :connection_lost},
          {:discord_send_crashed, RuntimeError.exception("lost acknowledgement")},
          {:discord_file_crashed, RuntimeError.exception("file send crashed")},
          {:discord_edit_crashed, RuntimeError.exception("edit crashed")},
          {:smtp, :timeout}
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

  test "with no retry budget ambiguous transport errors are reported as unknown", ctx do
    put_retry_budget(0)

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

  test "every unknown-outcome shape is retried at-least-once with the same key", ctx do
    reasons = [
      :outcome_unknown,
      {:outcome_unknown, :connection_lost},
      :timeout,
      {:closed, :socket},
      {:http_error, 503, ""},
      {:discord_send_crashed, RuntimeError.exception("lost acknowledgement")}
    ]

    # Independent peers, so every delivery group backs off concurrently.
    sends =
      for {reason, index} <- Enum.with_index(reasons) do
        key = "unknown-#{ctx.account}-#{index}"
        payload = keyed_payload(ctx.account, key, "peer-#{index}")
        assert {:ok, _} = Outbox.enqueue(payload)
        {payload.notify_ref, key, reason}
      end

    for {ref, key, reason} <- sends do
      assert_receive {:write_key, ^ref, ^key}, 1_000
      assert_receive {:write_attempt, ^ref, worker}, 1_000
      send(worker, {:finish, {:error, reason}})
    end

    # Intermediate unknown outcomes are not reported to the notifier.
    for {ref, _key, _reason} <- sends do
      refute_receive {:delivery_result, ^ref, _}, 0
    end

    for {ref, key, _reason} <- sends do
      assert_receive {:write_key, ^ref, ^key}, 2_500
      assert_receive {:write_attempt, ^ref, retry_worker}, 2_500
      send(retry_worker, {:finish, {:ok, :accepted}})
      assert_receive {:delivery_result, ^ref, {:ok, :accepted}}, 1_000
    end

    assert_group_drained(ctx.account)
  end

  @tag capture_log: true
  test "a worker exit is retried at-least-once with the same idempotency key", ctx do
    payload = keyed_payload(ctx.account, "worker-exit-#{ctx.account}")
    ref = payload.notify_ref
    key = payload.idempotency_key

    assert {:ok, _} = Outbox.enqueue(payload)
    assert_receive {:write_key, ^ref, ^key}, 1_000
    assert_receive {:write_attempt, ^ref, worker}, 1_000
    monitor = Process.monitor(worker)
    send(worker, :raise_after_write)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000

    refute_receive {:delivery_result, ^ref, _}, 0
    assert_receive {:write_key, ^ref, ^key}, 2_500
    assert_receive {:write_attempt, ^ref, retry_worker}, 2_500
    send(retry_worker, {:finish, {:ok, :accepted}})
    assert_receive {:delivery_result, ^ref, {:ok, :accepted}}, 1_000
    assert_group_drained(ctx.account)
  end

  test "unknown-outcome retries are bounded and unconfirmed keys stay unmarked", ctx do
    put_retry_budget(1)
    key = "bounded-#{ctx.account}"
    payload = keyed_payload(ctx.account, key)
    ref = payload.notify_ref
    reason = {:outcome_unknown, :connection_lost}

    assert {:ok, _} = Outbox.enqueue(payload)
    assert_receive {:write_attempt, ^ref, first}, 1_000
    send(first, {:finish, {:error, reason}})
    assert_receive {:write_attempt, ^ref, second}, 2_500
    send(second, {:finish, {:error, reason}})

    # One initial attempt plus one retry; the last failure is terminal.
    assert_receive {:delivery_result, ^ref, {:error, ^reason}}, 1_000
    assert_group_drained(ctx.account)
    refute_receive {:write_attempt, ^ref, _}, 0
    assert Dedupe.check(ControlledPlugin.id(), key) == :new
  end

  test "dedupe suppresses re-sends of a confirmed retried delivery", ctx do
    key = "confirmed-#{ctx.account}"
    payload = keyed_payload(ctx.account, key)
    ref = payload.notify_ref

    assert {:ok, _} = Outbox.enqueue(payload)
    assert_receive {:write_attempt, ^ref, first}, 1_000
    send(first, {:finish, {:error, {:outcome_unknown, :connection_lost}}})
    assert_receive {:write_attempt, ^ref, retry}, 2_500
    send(retry, {:finish, {:ok, :accepted}})
    assert_receive {:delivery_result, ^ref, {:ok, :accepted}}, 1_000

    again = keyed_payload(ctx.account, key)
    assert {:error, :duplicate} = Outbox.enqueue(again)
    refute_receive {:write_attempt, _, _}, 100
  end

  test "a pending retry is suppressed once its key is confirmed delivered", ctx do
    key = "confirmed-meanwhile-#{ctx.account}"
    payload = keyed_payload(ctx.account, key)
    ref = payload.notify_ref

    assert {:ok, _} = Outbox.enqueue(payload)
    assert_receive {:write_attempt, ^ref, worker}, 1_000
    send(worker, {:finish, {:error, {:outcome_unknown, :connection_lost}}})
    assert_group_idle(ctx.account)

    Dedupe.mark(ControlledPlugin.id(), key)

    assert_receive {:delivery_result, ^ref, {:error, :duplicate}}, 2_500
    refute_receive {:write_attempt, ^ref, _}, 0
    assert_group_drained(ctx.account)
  end

  test "definite rejections and unrecognized failures are never retried", ctx do
    sends =
      for {reason, index} <-
            Enum.with_index([
              {:http_error, 400, "invalid recipient"},
              {:smtp, {:rejected, 550}},
              {:invalid_recipient, "x"},
              :unexpected
            ]) do
        payload = keyed_payload(ctx.account, "rejected-#{ctx.account}-#{index}", "peer-#{index}")
        assert {:ok, _} = Outbox.enqueue(payload)
        {payload.notify_ref, reason}
      end

    for {ref, reason} <- sends do
      assert_receive {:write_attempt, ^ref, worker}, 1_000
      send(worker, {:finish, {:error, reason}})
      assert_receive {:delivery_result, ^ref, {:error, ^reason}}, 1_000
    end

    # The shortest retry backoff is one second.
    [{first_ref, _} | rest] = sends
    refute_receive {:write_attempt, ^first_ref, _}, 1_300
    for {ref, _} <- rest, do: refute_receive({:write_attempt, ^ref, _}, 0)
    assert_group_drained(ctx.account)
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

  # The failed delivery is queued for retry and nothing is in flight.
  defp assert_group_idle(account) do
    eventually(fn ->
      state = :sys.get_state(Outbox)
      assert Enum.any?(:queue.to_list(state.queue), &(&1.payload.account_id == account))

      refute Enum.any?(state.processing, fn {_ref, entry} ->
               entry.payload.account_id == account
             end)
    end)
  end

  defp eventually(fun, attempts \\ 50) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts > 0 do
        Process.sleep(20)
        eventually(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp put_retry_budget(max_attempts) do
    Application.put_env(:lemon_channels, Outbox, max_attempts: max_attempts)
  end

  defp keyed_payload(account, key, peer_id \\ "same-peer") do
    %{payload(account) | idempotency_key: key, peer: %{kind: :dm, id: peer_id, thread_id: nil}}
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
