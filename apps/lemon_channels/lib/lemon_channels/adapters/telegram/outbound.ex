defmodule LemonChannels.Adapters.Telegram.Outbound do
  @moduledoc """
  Outbound message delivery for Telegram.

  Wraps the existing LemonGateway.Telegram.API for message delivery.
  """

  alias LemonChannels.OutboundPayload

  @doc """
  Deliver an outbound payload to Telegram.
  """
  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    chat_id = String.to_integer(payload.peer.id)
    opts = build_send_opts(payload)
    token = telegram_token()

    # Use existing Telegram API if available
    if Code.ensure_loaded?(LemonGateway.Telegram.API) do
      with token when is_binary(token) and token != "" <- token do
        case LemonGateway.Telegram.API.send_message(token, chat_id, payload.content, opts, nil) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      else
        _ -> {:error, :telegram_not_configured}
      end
    else
      {:error, :telegram_api_not_available}
    end
  end

  def deliver(%OutboundPayload{kind: :edit, content: %{message_id: message_id, text: text}} = payload) do
    chat_id = String.to_integer(payload.peer.id)
    msg_id = parse_message_id(message_id)
    token = telegram_token()

    if Code.ensure_loaded?(LemonGateway.Telegram.API) do
      with token when is_binary(token) and token != "" <- token do
        case LemonGateway.Telegram.API.edit_message_text(token, chat_id, msg_id, text, nil) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      else
        _ -> {:error, :telegram_not_configured}
      end
    else
      {:error, :telegram_api_not_available}
    end
  end

  def deliver(%OutboundPayload{kind: :delete, content: %{message_id: message_id}} = payload) do
    chat_id = String.to_integer(payload.peer.id)
    msg_id = parse_message_id(message_id)
    token = telegram_token()

    if Code.ensure_loaded?(LemonGateway.Telegram.API) do
      with token when is_binary(token) and token != "" <- token do
        case LemonGateway.Telegram.API.delete_message(token, chat_id, msg_id) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      else
        _ -> {:error, :telegram_not_configured}
      end
    else
      {:error, :telegram_api_not_available}
    end
  end

  def deliver(%OutboundPayload{kind: kind}) do
    {:error, {:unsupported_kind, kind}}
  end

  defp build_send_opts(payload) do
    opts = []

    opts =
      if payload.reply_to do
        [{:reply_to_message_id, parse_message_id(payload.reply_to)} | opts]
      else
        opts
      end

    opts =
      if payload.peer.thread_id do
        [{:message_thread_id, String.to_integer(payload.peer.thread_id)} | opts]
      else
        opts
      end

    opts
  end

  defp parse_message_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_message_id(id) when is_integer(id), do: id

  defp telegram_token do
    config = Application.get_env(:lemon_gateway, :telegram, %{})
    config[:bot_token] || config["bot_token"]
  end
end
