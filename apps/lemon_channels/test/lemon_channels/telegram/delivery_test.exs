defmodule LemonChannels.Telegram.DeliveryTest do
  use ExUnit.Case, async: false

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

  defp start_legacy_outbox do
    start_supervised!({
      LemonGateway.Telegram.Outbox,
      [bot_token: "test-token", api_mod: LegacyApiMock, edit_throttle_ms: 0, use_markdown: false]
    })
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
