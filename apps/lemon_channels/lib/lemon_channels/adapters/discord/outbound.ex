defmodule LemonChannels.Adapters.Discord.Outbound do
  @moduledoc """
  Outbound message delivery for Discord.
  """

  require Logger

  alias LemonChannels.GatewayConfig
  alias LemonChannels.OutboundPayload
  alias Nostrum.Api.Message, as: NostrumMessage

  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    channel_id = peer_channel_id(payload)

    with {:ok, channel_id} <- channel_id,
         content when is_binary(content) <- to_string(payload.content),
         params <- text_params(content, payload),
         {:ok, result} <- message_api().create(channel_id, params) do
      {:ok, %{message_id: extract_message_id(result)}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:discord_send_failed, other}}
    end
  rescue
    error ->
      Logger.warning("discord outbound text delivery crashed: #{inspect(error)}")
      {:error, {:discord_send_crashed, error}}
  end

  def deliver(
        %OutboundPayload{kind: :edit, content: %{message_id: message_id, text: text}} = payload
      ) do
    components = extract_components(payload)

    edit_params =
      %{content: to_string(text)}
      |> maybe_put_components(components)

    with {:ok, channel_id} <- peer_channel_id(payload),
         {:ok, msg_id} <- normalize_id(message_id),
         {:ok, result} <- message_api().edit(channel_id, msg_id, edit_params) do
      {:ok, %{message_id: extract_message_id(result) || msg_id}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:discord_edit_failed, other}}
    end
  rescue
    error ->
      Logger.warning("discord outbound edit delivery crashed: #{inspect(error)}")
      {:error, {:discord_edit_crashed, error}}
  end

  def deliver(%OutboundPayload{kind: :delete, content: %{message_id: message_id}} = payload) do
    with {:ok, channel_id} <- peer_channel_id(payload),
         {:ok, msg_id} <- normalize_id(message_id),
         {:ok, _} <- message_api().delete(channel_id, msg_id) do
      {:ok, %{message_id: msg_id}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:discord_delete_failed, other}}
    end
  rescue
    error ->
      Logger.warning("discord outbound delete delivery crashed: #{inspect(error)}")
      {:error, {:discord_delete_crashed, error}}
  end

  def deliver(%OutboundPayload{kind: :reaction} = payload) do
    with {:ok, channel_id} <- peer_channel_id(payload),
         {:ok, msg_id} <- normalize_id(payload.content[:message_id]),
         emoji when is_binary(emoji) <- payload.content[:emoji] do
      create_reaction(channel_id, msg_id, emoji)
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:discord_reaction_failed, other}}
    end
  rescue
    error ->
      Logger.warning("discord outbound reaction delivery crashed: #{inspect(error)}")
      {:error, {:discord_reaction_crashed, error}}
  end

  def deliver(%OutboundPayload{kind: :file, content: content} = payload) do
    with {:ok, channel_id} <- peer_channel_id(payload),
         {:ok, params} <- file_params(content, payload),
         {:ok, result} <- message_api().create(channel_id, params) do
      {:ok, %{message_id: extract_message_id(result)}}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:discord_file_failed, other}}
    end
  rescue
    error ->
      Logger.warning("discord outbound file delivery crashed: #{inspect(error)}")
      {:error, {:discord_file_crashed, error}}
  end

  def deliver(%OutboundPayload{kind: kind}) do
    {:error, {:unsupported_kind, kind}}
  end

  # ============================================================================
  # Reactions
  # ============================================================================

  @doc "Add a reaction emoji to a message."
  @spec create_reaction(integer(), integer(), binary()) :: {:ok, term()} | {:error, term()}
  def create_reaction(channel_id, message_id, emoji)
      when is_integer(channel_id) and is_integer(message_id) and is_binary(emoji) do
    # URL-encode the emoji for the Discord API
    encoded = URI.encode(emoji)

    case message_api().react(channel_id, message_id, encoded) do
      {:ok} -> {:ok, %{message_id: message_id}}
      {:ok, _} -> {:ok, %{message_id: message_id}}
      :ok -> {:ok, %{message_id: message_id}}
      {:error, reason} -> {:error, {:discord_reaction_failed, reason}}
    end
  rescue
    error ->
      Logger.warning("discord create_reaction crashed: #{inspect(error)}")
      {:error, {:discord_reaction_crashed, error}}
  end

  @doc "Remove bot's own reaction from a message."
  @spec delete_own_reaction(integer(), integer(), binary()) :: :ok | {:error, term()}
  def delete_own_reaction(channel_id, message_id, emoji)
      when is_integer(channel_id) and is_integer(message_id) and is_binary(emoji) do
    encoded = URI.encode(emoji)

    case message_api().unreact(channel_id, message_id, encoded) do
      {:ok} -> :ok
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> :ok
  end

  @doc "Send a message with components (buttons, select menus)."
  @spec send_with_components(integer(), binary(), list(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def send_with_components(channel_id, content, components, opts \\ [])
      when is_integer(channel_id) and is_binary(content) do
    params =
      %{content: content, components: components}
      |> maybe_put_reply(opts)

    case message_api().create(channel_id, params) do
      {:ok, result} -> {:ok, %{message_id: extract_message_id(result)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      Logger.warning("discord send_with_components crashed: #{inspect(error)}")
      {:error, {:discord_send_crashed, error}}
  end

  @doc "Edit a message updating content and/or components."
  @spec edit_with_components(integer(), integer(), binary(), list()) ::
          {:ok, map()} | {:error, term()}
  def edit_with_components(channel_id, message_id, content, components)
      when is_integer(channel_id) and is_integer(message_id) do
    params =
      %{content: content, components: components}

    case message_api().edit(channel_id, message_id, params) do
      {:ok, result} -> {:ok, %{message_id: extract_message_id(result) || message_id}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error ->
      Logger.warning("discord edit_with_components crashed: #{inspect(error)}")
      {:error, {:discord_edit_crashed, error}}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp text_params(content, payload) do
    params = %{content: content}

    params =
      case normalize_id(payload.reply_to) do
        {:ok, reply_id} ->
          Map.put(params, :message_reference, %{message_id: reply_id})

        _ ->
          params
      end

    components = extract_components(payload)
    maybe_put_components(params, components)
  end

  defp extract_components(%OutboundPayload{meta: %{components: components}})
       when is_list(components),
       do: components

  defp extract_components(%OutboundPayload{meta: %{"components" => components}})
       when is_list(components),
       do: components

  defp extract_components(_), do: nil

  defp maybe_put_components(params, components) when is_list(components),
    do: Map.put(params, :components, components)

  defp maybe_put_components(params, _), do: params

  defp maybe_put_reply(params, opts) do
    case Keyword.get(opts, :reply_to) do
      nil ->
        params

      reply_id when is_integer(reply_id) ->
        Map.put(params, :message_reference, %{message_id: reply_id})

      _ ->
        params
    end
  end

  defp file_params(%{path: path} = content, payload) when is_binary(path) and path != "" do
    filename =
      if is_binary(content[:filename]) and content[:filename] != "",
        do: content[:filename],
        else: Path.basename(path)

    caption =
      case content[:caption] do
        text when is_binary(text) and text != "" -> text
        _ -> filename
      end

    case File.read(path) do
      {:ok, body} ->
        params =
          %{content: caption, files: [%{body: body, name: filename}]}
          |> maybe_put_reply_from_payload(payload)

        {:ok, params}

      {:error, reason} ->
        {:error, {:discord_file_read_failed, reason}}
    end
  end

  defp file_params(%{"path" => path} = content, payload) when is_binary(path) and path != "" do
    file_params(
      %{
        path: path,
        filename: content["filename"],
        caption: content["caption"]
      },
      payload
    )
  end

  defp file_params(other, _payload), do: {:error, {:discord_file_failed, other}}

  defp maybe_put_reply_from_payload(params, payload) do
    case normalize_id(payload.reply_to) do
      {:ok, reply_id} -> Map.put(params, :message_reference, %{message_id: reply_id})
      _ -> params
    end
  end

  defp peer_channel_id(%OutboundPayload{peer: %{thread_id: thread_id}})
       when is_binary(thread_id) and thread_id != "",
       do: normalize_id(thread_id)

  defp peer_channel_id(%OutboundPayload{peer: %{id: id}}), do: normalize_id(id)
  defp peer_channel_id(_), do: {:error, :invalid_peer}

  defp normalize_id(id) when is_integer(id), do: {:ok, id}

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, _} -> {:ok, value}
      :error -> {:error, :invalid_id}
    end
  end

  defp normalize_id(_), do: {:error, :invalid_id}

  defp message_api do
    case GatewayConfig.get(:discord, %{}) do
      %{api_mod: mod} -> normalize_api_mod(mod)
      %{"api_mod" => mod} -> normalize_api_mod(mod)
      _ -> NostrumMessage
    end
  end

  defp normalize_api_mod(mod) when is_atom(mod), do: mod

  defp normalize_api_mod(mod) when is_binary(mod) do
    try do
      String.to_existing_atom(mod)
    rescue
      ArgumentError -> NostrumMessage
    end
  end

  defp normalize_api_mod(_), do: NostrumMessage

  defp extract_message_id(%{id: id}) when is_integer(id), do: id

  defp extract_message_id(%{id: id}) when is_binary(id) do
    case normalize_id(id) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp extract_message_id(%{"id" => id}) when is_integer(id), do: id

  defp extract_message_id(%{"id" => id}) when is_binary(id) do
    case normalize_id(id) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp extract_message_id(_), do: nil
end
