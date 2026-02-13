defmodule LemonChannels.Adapters.Telegram.Outbound do
  @moduledoc """
  Outbound message delivery for Telegram.

  Wraps the existing LemonGateway.Telegram.API for message delivery.
  """

  alias LemonChannels.OutboundPayload
  alias LemonGateway.Telegram.Formatter

  @doc """
  Deliver an outbound payload to Telegram.
  """
  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    chat_id = String.to_integer(payload.peer.id)
    {text, md_opts} = format_text(payload.content, telegram_use_markdown())
    opts = build_send_opts(payload, md_opts)
    {token, api_mod} = telegram_config()

    # Use existing Telegram API if available
    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.send_message(token, chat_id, text, opts, nil) do
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
    {formatted_text, md_opts} = format_text(text, telegram_use_markdown())
    {token, api_mod} = telegram_config()

    if Code.ensure_loaded?(api_mod) do
      with token when is_binary(token) and token != "" <- token do
        case api_mod.edit_message_text(token, chat_id, msg_id, formatted_text, md_opts) do
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
          {:ok, result} ->
            {:ok, result}

          # Telegram deleteMessage is effectively idempotent for our purposes. If the progress
          # message was already deleted (or never existed due to a race), Telegram returns 400
          # "message to delete not found". Treat as success so the Outbox won't retry.
          {:error, {:http_error, 400, body}} when is_binary(body) ->
            if telegram_delete_not_found?(body) do
              {:ok, :already_deleted}
            else
              {:error, {:http_error, 400, body}}
            end

          {:error, reason} ->
            {:error, reason}
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

  defp build_send_opts(payload, md_opts) do
    opts =
      %{}
      |> maybe_put(:reply_to_message_id, parse_optional_message_id(payload.reply_to))
      |> maybe_put(:message_thread_id, parse_optional_thread_id(payload.peer.thread_id))

    case md_opts do
      nil -> opts
      m when is_map(m) -> Map.merge(opts, m)
      _ -> opts
    end
  end

  defp parse_message_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_message_id(id) when is_integer(id), do: id
  defp parse_optional_message_id(nil), do: nil
  defp parse_optional_message_id(id), do: parse_message_id(id)

  defp parse_optional_thread_id(nil), do: nil
  defp parse_optional_thread_id(id) when is_binary(id), do: String.to_integer(id)
  defp parse_optional_thread_id(id) when is_integer(id), do: id

  defp format_text(text, true) do
    normalized = normalize_text(text)
    Formatter.prepare_for_telegram(normalized)
  end

  defp format_text(text, _use_markdown) do
    {normalize_text(text), nil}
  end

  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(nil), do: ""
  defp normalize_text(text), do: to_string(text)

  defp telegram_delete_not_found?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"description" => desc}} when is_binary(desc) ->
        String.contains?(String.downcase(desc), "message to delete not found")

      _ ->
        String.contains?(String.downcase(body), "message to delete not found")
    end
  end

  # Transport merges runtime overrides from `Application.get_env(:lemon_gateway, :telegram)`;
  # do the same here so tests can inject a mock api module without hitting the network.
  defp telegram_config do
    config = telegram_runtime_config()
    token = config[:bot_token] || config["bot_token"]
    api_mod = config[:api_mod] || config["api_mod"] || LemonGateway.Telegram.API
    {token, api_mod}
  end

  defp telegram_use_markdown do
    config = telegram_runtime_config()

    case fetch_config(config, :use_markdown) do
      {:ok, nil} -> true
      {:ok, v} -> v
      :error -> true
    end
  end

  defp telegram_runtime_config do
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

    Map.merge(base, overrides)
  end

  defp fetch_config(config, key) when is_map(config) and is_atom(key) do
    case Map.fetch(config, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Map.fetch(config, Atom.to_string(key))
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
