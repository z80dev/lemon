defmodule LemonChannels.Telegram.DeliveryTest do
  use ExUnit.Case, async: false

  alias LemonChannels.OutboundPayload
  alias LemonChannels.Telegram.Delivery

  defmodule LegacyApiMock do
    def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil) do
      notify({:legacy_send_message, chat_id, text, reply_to_or_opts, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      notify({:legacy_edit_message_text, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true, "result" => %{"message_id" => message_id}}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}

    defp notify(message) do
      pid = :persistent_term.get({__MODULE__, :notify_pid}, nil)
      if is_pid(pid), do: send(pid, message)
    end
  end

  defmodule TestTelegramPlugin do
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
      if is_pid(pid), do: send(pid, {:fallback_delivered, payload})
      {:ok, :ok}
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_channels)
    stop_legacy_outbox()

    :persistent_term.put({LegacyApiMock, :notify_pid}, self())

    on_exit(fn ->
      stop_legacy_outbox()
      :persistent_term.erase({LegacyApiMock, :notify_pid})
    end)

    :ok
  end

  test "enqueue_edit/4 uses legacy outbox and default notify semantics when available" do
    _pid = start_legacy_outbox()
    ref = make_ref()

    assert :ok ==
             Delivery.enqueue_edit(123, 456, "legacy edit",
               notify_pid: self(),
               notify_ref: ref
             )

    assert_receive {:legacy_edit_message_text, 123, 456, "legacy edit", _opts}, 500
    assert_receive {:outbox_delivered, ^ref, {:ok, _result}}, 500
  end

  test "enqueue_send/3 uses legacy outbox when available" do
    _pid = start_legacy_outbox()

    assert :ok ==
             Delivery.enqueue_send(321, "legacy send",
               reply_to_message_id: "88",
               thread_id: 99
             )

    assert_receive {:legacy_send_message, 321, "legacy send", opts, nil}, 500
    assert opts[:reply_to_message_id] == 88
    assert opts[:message_thread_id] == 99
  end

  test "enqueue_edit/4 falls back to LemonChannels.Outbox with notify callbacks" do
    ref = make_ref()
    tag = :delivery_test_notify

    assert :ok ==
             Delivery.enqueue_edit(555, 777, "fallback edit",
               notify_pid: self(),
               notify_ref: ref,
               notify_tag: tag
             )

    assert_receive {^tag, ^ref, result}, 2000
    assert match?({:ok, _}, result) or match?({:error, _}, result)
    refute_receive {:legacy_edit_message_text, _chat_id, _message_id, _text, _opts}, 100
  end

  test "enqueue_legacy_fallback/5 returns notify_ref when legacy outbox is available" do
    _pid = start_legacy_outbox()
    ref = make_ref()

    assert {:ok, ^ref} =
             Delivery.enqueue_legacy_fallback(
               {123, :run, :send},
               1,
               {:send, 123, %{text: "legacy helper send"}},
               fallback_payload("legacy helper send"),
               notify: {self(), ref, :outbox_delivered}
             )

    assert_receive {:legacy_send_message, 123, "legacy helper send", _opts, nil}, 500
    assert_receive {:outbox_delivered, ^ref, {:ok, _result}}, 500
  end

  test "enqueue_legacy_fallback/5 falls back to channels outbox and keeps idempotency key" do
    use_test_telegram_plugin()

    ref = make_ref()
    idempotency_key = "fallback-key-#{System.unique_integer([:positive])}"

    assert {:ok, _enqueue_ref} =
             Delivery.enqueue_legacy_fallback(
               {:fallback, :run, :send},
               1,
               {:send, 123, %{text: "fallback helper send"}},
               fallback_payload("fallback helper send", idempotency_key: idempotency_key),
               notify: {self(), ref, :delivery_test_notify}
             )

    assert_receive {:fallback_delivered,
                    %OutboundPayload{
                      idempotency_key: ^idempotency_key,
                      notify_pid: notify_pid,
                      notify_ref: ^ref,
                      meta: meta
                    }},
                   1000

    assert notify_pid == self()
    assert meta[:notify_tag] == :delivery_test_notify
    assert_receive {:delivery_test_notify, ^ref, {:ok, _result}}, 1000
    refute_receive {:legacy_send_message, _chat_id, _text, _opts, _parse_mode}, 100
  end

  defp start_legacy_outbox do
    start_supervised!({
      LemonGateway.Telegram.Outbox,
      [bot_token: "test-token", api_mod: LegacyApiMock, edit_throttle_ms: 0, use_markdown: false]
    })
  end

  defp use_test_telegram_plugin do
    :persistent_term.put({TestTelegramPlugin, :notify_pid}, self())

    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")
    :ok = LemonChannels.Registry.register(TestTelegramPlugin)

    on_exit(fn ->
      :persistent_term.erase({TestTelegramPlugin, :notify_pid})

      if is_pid(Process.whereis(LemonChannels.Registry)) do
        _ = LemonChannels.Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = LemonChannels.Registry.register(existing)
        end
      end
    end)
  end

  defp fallback_payload(content, opts \\ []) do
    %OutboundPayload{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: "123", thread_id: nil},
      kind: :text,
      content: content,
      idempotency_key: opts[:idempotency_key]
    }
  end

  defp stop_legacy_outbox do
    case Process.whereis(LemonGateway.Telegram.Outbox) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid, :normal, 1000)
    end
  catch
    :exit, _ -> :ok
  end
end
