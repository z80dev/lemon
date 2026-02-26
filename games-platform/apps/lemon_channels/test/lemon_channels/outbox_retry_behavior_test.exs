defmodule LemonChannels.OutboxRetryBehaviorTest do
  use ExUnit.Case, async: false

  alias LemonChannels.{Outbox, OutboundPayload, Registry}
  alias LemonChannels.Outbox.{Dedupe, RateLimiter}

  defmodule RetryAfterPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-retry-after-channel"

    @impl true
    def meta do
      %{
        label: "Outbox RetryAfter Test Channel",
        capabilities: %{chunk_limit: 4096},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(payload) do
      counter_pid = payload.meta[:counter_pid]

      attempt =
        Agent.get_and_update(counter_pid, fn count ->
          next = count + 1
          {next, next}
        end)

      test_pid = payload.meta[:test_pid]

      if is_pid(test_pid) do
        send(test_pid, {:retry_after_attempt, attempt, System.monotonic_time(:millisecond)})
      end

      case attempt do
        1 ->
          body =
            ~s({"ok":false,"error_code":429,"description":"Too Many Requests: retry after 1.2","parameters":{"retry_after":1.2}})

          {:error, {:http_error, 429, body}}

        _ ->
          {:ok, %{"message_id" => 101}}
      end
    end

    @impl true
    def gateway_methods, do: []
  end

  defmodule Always429Plugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "outbox-always-429-channel"

    @impl true
    def meta do
      %{
        label: "Outbox Always429 Test Channel",
        capabilities: %{chunk_limit: 4096},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Agent, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_supported}

    @impl true
    def deliver(_payload) do
      body =
        ~s({"ok":false,"error_code":429,"description":"Too Many Requests: retry after 0.1","parameters":{"retry_after":0.1}})

      {:error, {:http_error, 429, body}}
    end

    @impl true
    def gateway_methods, do: []
  end

  setup do
    start_supervised_if_needed(Registry)
    start_supervised_if_needed(RateLimiter)
    start_supervised_if_needed(Dedupe)
    start_supervised_if_needed(Outbox)

    for plugin <- [RetryAfterPlugin, Always429Plugin] do
      case Registry.register(plugin) do
        :ok -> :ok
        {:error, :already_registered} -> :ok
      end
    end

    on_exit(fn ->
      _ = Registry.unregister(RetryAfterPlugin.id())
      _ = Registry.unregister(Always429Plugin.id())
      Application.delete_env(:lemon_channels, Outbox)
    end)

    :ok
  end

  defp start_supervised_if_needed(module) do
    case Process.whereis(module) do
      nil -> start_supervised!(module)
      _pid -> :ok
    end
  end

  test "honors retry_after delay and does not notify intermediate failures" do
    {:ok, counter_pid} = Agent.start_link(fn -> 0 end)
    notify_ref = make_ref()

    payload = %OutboundPayload{
      channel_id: RetryAfterPlugin.id(),
      kind: :text,
      content: "retry-after",
      account_id: "acct-#{System.unique_integer([:positive])}",
      peer: %{kind: :dm, id: "peer-1", thread_id: nil},
      notify_pid: self(),
      notify_ref: notify_ref,
      meta: %{test_pid: self(), counter_pid: counter_pid}
    }

    {:ok, _ref} = Outbox.enqueue(payload)

    assert_receive {:retry_after_attempt, 1, first_attempt_ms}, 500

    outbox_pid = Process.whereis(Outbox)

    for _ <- 1..20 do
      send(outbox_pid, :process_queue)
    end

    refute_receive {:retry_after_attempt, 2, _}, 900
    assert_receive {:retry_after_attempt, 2, second_attempt_ms}, 1500
    assert second_attempt_ms - first_attempt_ms >= 1100

    assert_receive {:outbox_delivered, ^notify_ref, {:ok, _delivery_ref}}, 1000
    refute_receive {:outbox_delivered, ^notify_ref, {:error, _}}, 100
  end

  test "exposes structured rate-limit failure reason to notifier" do
    Application.put_env(:lemon_channels, Outbox, max_attempts: 0)

    notify_ref = make_ref()

    payload = %OutboundPayload{
      channel_id: Always429Plugin.id(),
      kind: :text,
      content: "always-429",
      account_id: "acct-#{System.unique_integer([:positive])}",
      peer: %{kind: :dm, id: "peer-2", thread_id: nil},
      notify_pid: self(),
      notify_ref: notify_ref,
      meta: %{test_pid: self()}
    }

    {:ok, _ref} = Outbox.enqueue(payload)

    assert_receive {:outbox_delivered, ^notify_ref, {:error, {:rate_limited, details}}}, 1000
    assert details[:retry_after_ms] == 100
    assert match?({:http_error, 429, _}, details[:reason])
  end
end
