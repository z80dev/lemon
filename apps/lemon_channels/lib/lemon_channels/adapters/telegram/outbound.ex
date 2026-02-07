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
    {token, api_mod} = telegram_config()

    # Use existing Telegram API if available
    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.send_message(token, chat_id, payload.content, opts, nil) do
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

  def deliver(
        %OutboundPayload{kind: :edit, content: %{message_id: message_id, text: text}} = payload
      ) do
    chat_id = String.to_integer(payload.peer.id)
    msg_id = parse_message_id(message_id)
    {token, api_mod} = telegram_config()

    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.edit_message_text(token, chat_id, msg_id, text, nil) do
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
    {token, api_mod} = telegram_config()

    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.delete_message(token, chat_id, msg_id) do
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

  # Transport merges runtime overrides from `Application.get_env(:lemon_gateway, :telegram)`;
  # do the same here so tests can inject a mock api module without hitting the network.
  defp telegram_config do
    base = LemonChannels.GatewayConfig.get(:telegram, %{}) || %{}

    overrides =
      case Application.get_env(:lemon_gateway, :telegram) do
        nil ->
          %{}

        m when is_map(m) ->
          m

        kw when is_list(kw) ->
          if Keyword.keyword?(kw) do
            Enum.into(kw, %{})
          else
            %{}
          end

        _ ->
          %{}
      end

    config = Map.merge(base, overrides)
    token = config[:bot_token] || config["bot_token"]
    api_mod = config[:api_mod] || config["api_mod"] || LemonGateway.Telegram.API
    {token, api_mod}
  end
end
