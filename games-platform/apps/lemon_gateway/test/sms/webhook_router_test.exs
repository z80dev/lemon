defmodule LemonGateway.Sms.WebhookRouterTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.Inbox
  alias LemonGateway.Sms.WebhookRouter

  @table :sms_inbox

  setup do
    # Keep this test deterministic even if the developer environment has Twilio webhook
    # validation enabled.
    orig_validate = System.get_env("TWILIO_VALIDATE_WEBHOOK")
    System.put_env("TWILIO_VALIDATE_WEBHOOK", "0")

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    for {k, _v} <- LemonCore.Store.list(@table) do
      _ = LemonCore.Store.delete(@table, k)
    end

    on_exit(fn ->
      case orig_validate do
        nil -> System.delete_env("TWILIO_VALIDATE_WEBHOOK")
        v -> System.put_env("TWILIO_VALIDATE_WEBHOOK", v)
      end

      for {k, _v} <- LemonCore.Store.list(@table) do
        _ = LemonCore.Store.delete(@table, k)
      end
    end)

    :ok
  end

  test "POST /webhooks/twilio/sms stores message and returns empty TwiML" do
    sid = "SM#{System.unique_integer([:positive])}"

    conn =
      Plug.Test.conn(:post, "/webhooks/twilio/sms", %{
        "MessageSid" => sid,
        "From" => "+15551230100",
        "To" => "+15551239999",
        "Body" => "Your code is 999999"
      })
      |> WebhookRouter.call([])

    assert conn.status == 200
    assert conn.resp_body =~ "<Response"

    msgs = Inbox.list_messages(limit: 10, include_claimed: true)
    assert Enum.any?(msgs, fn msg -> msg["message_sid"] == sid end)
  end
end
