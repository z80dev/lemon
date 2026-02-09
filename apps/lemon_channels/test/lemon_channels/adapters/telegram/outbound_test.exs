defmodule LemonChannels.Adapters.Telegram.OutboundTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Outbound
  alias LemonChannels.OutboundPayload

  defmodule MockApiNotFound do
    def delete_message(_token, _chat_id, _message_id) do
      body =
        Jason.encode!(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: message to delete not found"
        })

      {:error, {:http_error, 400, body}}
    end
  end

  defmodule MockApiOther400 do
    def delete_message(_token, _chat_id, _message_id) do
      body =
        Jason.encode!(%{
          "ok" => false,
          "error_code" => 400,
          "description" => "Bad Request: chat not found"
        })

      {:error, {:http_error, 400, body}}
    end
  end

  setup do
    old = Application.get_env(:lemon_gateway, :telegram)

    on_exit(fn ->
      if old == nil do
        Application.delete_env(:lemon_gateway, :telegram)
      else
        Application.put_env(:lemon_gateway, :telegram, old)
      end
    end)

    :ok
  end

  test "delete: 400 message to delete not found is treated as success" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiNotFound})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :delete,
        content: %{message_id: "456"}
      }

    assert {:ok, :already_deleted} = Outbound.deliver(payload)
  end

  test "delete: other 400s are returned as errors" do
    Application.put_env(:lemon_gateway, :telegram, %{bot_token: "token", api_mod: MockApiOther400})

    payload =
      %OutboundPayload{
        channel_id: "telegram",
        account_id: "acct",
        peer: %{kind: :dm, id: "123", thread_id: nil},
        kind: :delete,
        content: %{message_id: 456}
      }

    assert {:error, {:http_error, 400, _body}} = Outbound.deliver(payload)
  end
end

