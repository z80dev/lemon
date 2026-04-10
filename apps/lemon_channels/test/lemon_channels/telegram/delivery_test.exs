defmodule LemonChannels.Telegram.DeliveryTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias Elixir.LemonChannels.OutboundPayload
  alias Elixir.LemonChannels.Telegram.Delivery

  defmodule DeliveryTestTelegramPlugin do
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
    :persistent_term.put({DeliveryTestTelegramPlugin, :notify_pid}, self())

    existing = Elixir.LemonChannels.Registry.get_plugin("telegram")
    _ = Elixir.LemonChannels.Registry.unregister("telegram")
    :ok = Elixir.LemonChannels.Registry.register(DeliveryTestTelegramPlugin)

    on_exit(fn ->
      :persistent_term.erase({DeliveryTestTelegramPlugin, :notify_pid})

      if is_pid(Process.whereis(Elixir.LemonChannels.Registry)) do
        _ = Elixir.LemonChannels.Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = Elixir.LemonChannels.Registry.register(existing)
        end
      end
    end)

    :ok
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

  test "enqueue_send/3 preserves reply markup in payload metadata" do
    reply_markup = %{"keyboard" => [[%{"text" => "pick me"}]], "resize_keyboard" => true}

    assert :ok ==
             Delivery.enqueue_send(654, "choose",
               reply_markup: reply_markup,
               reply_to_message_id: 12,
               thread_id: 34
             )

    assert_receive {:delivered,
                    %OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      content: "choose",
                      reply_to: "12",
                      peer: %{id: "654", thread_id: "34"},
                      meta: %{reply_markup: ^reply_markup}
                    }},
                   1_000
  end
end
