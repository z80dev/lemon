defmodule Elixir.LemonChannels.Telegram.DeliveryTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias Elixir.LemonChannels.OutboundPayload
  alias Elixir.LemonChannels.Telegram.Delivery

  defmodule Elixir.LemonChannels.Telegram.DeliveryTest.TestTelegramPlugin do
    def id, do: "telegram"

    def meta do
      %{
        name: "Test Telegram",
        capabilities: %{
          edit_support: true,
          chunk_limit: 4096
        }
      }
    end

    def deliver(payload) do
      pid = :persistent_term.get({__MODULE__, :notify_pid}, nil)
      if is_pid(pid), do: send(pid, {:delivered, payload})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    :persistent_term.put({Elixir.LemonChannels.Telegram.DeliveryTest.TestTelegramPlugin, :notify_pid}, self())

    existing = Elixir.LemonChannels.Registry.get_plugin("telegram")
    _ = Elixir.LemonChannels.Registry.unregister("telegram")
    :ok = Elixir.LemonChannels.Registry.register(Elixir.LemonChannels.Telegram.DeliveryTest.TestTelegramPlugin)

    on_exit(fn ->
      :persistent_term.erase({Elixir.LemonChannels.Telegram.DeliveryTest.TestTelegramPlugin, :notify_pid})

      if is_pid(Process.whereis(Elixir.LemonChannels.Registry)) do
        _ = Elixir.LemonChannels.Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = Elixir.LemonChannels.Registry.register(existing)
        end
      end
    end)

    :ok
  end

  test "enqueue_edit/4 publishes edit payload and notify callback" do
    ref = make_ref()

    assert :ok ==
             Delivery.enqueue_edit(123, 456, "edited text",
               notify_pid: self(),
               notify_ref: ref,
               notify_tag: :delivery_test_notify
             )

    assert_receive {:delivered,
                    %OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      peer: %{id: "123"},
                      content: %{message_id: "456", text: "edited text"},
                      meta: %{notify_tag: :delivery_test_notify}
                    }},
                   1_000

    assert_receive {:delivery_test_notify, ^ref, {:ok, _result}}, 1_000
  end

  test "enqueue_send/3 includes reply_to and thread metadata" do
    assert :ok ==
             Delivery.enqueue_send(321, "hello",
               reply_to_message_id: "88",
               thread_id: 99
             )

    assert_receive {:delivered,
                    %OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      content: "hello",
                      reply_to: "88",
                      peer: %{id: "321", thread_id: "99"}
                    }},
                   1_000
  end

  test "enqueue_fallback/5 preserves idempotency and notify tag" do
    ref = make_ref()
    idempotency_key = "fallback-key-#{System.unique_integer([:positive])}"

    assert {:ok, _enqueue_ref} =
             Delivery.enqueue_fallback(
               {:fallback, :run, :send},
               1,
               {:send, 123, %{text: "fallback helper send"}},
               fallback_payload("fallback helper send", idempotency_key: idempotency_key),
               notify: {self(), ref, :delivery_test_notify}
             )

    assert_receive {:delivered,
                    %OutboundPayload{
                      idempotency_key: ^idempotency_key,
                      notify_pid: notify_pid,
                      notify_ref: ^ref,
                      meta: %{notify_tag: :delivery_test_notify}
                    }},
                   1_000

    assert notify_pid == self()
    assert_receive {:delivery_test_notify, ^ref, {:ok, _result}}, 1_000
  end

  defp fallback_payload(content, opts) do
    %OutboundPayload{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "123", thread_id: nil},
      kind: :text,
      content: content,
      idempotency_key: opts[:idempotency_key]
    }
  end
end
