defmodule LemonChannels.Adapters.Discord.Outbound do
  @moduledoc """
  Outbound message delivery for Discord.
  """

  require Logger

  alias LemonChannels.GatewayConfig
  alias LemonChannels.OutboundPayload
  alias Nostrum.Api.Message, as: NostrumMessage

  @max_content_chars 1_900
  @max_file_count 10

  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    channel_id = peer_channel_id(payload)

    with {:ok, channel_id} <- channel_id,
         content when is_binary(content) <- to_string(payload.content),
         [first | rest] <- content_chunks(content),
         params <- text_params(first, payload),
         {:ok, result} <- message_api().create(channel_id, params),
         {:ok, extra_ids} <- send_extra_chunks(channel_id, rest) do
      {:ok, %{message_id: extract_message_id(result), extra_message_ids: extra_ids}}
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
    [first | rest] = content_chunks(to_string(text))

    edit_params =
      %{content: first}
      |> put_safe_allowed_mentions()
      |> maybe_put_components(components)

    with {:ok, channel_id} <- peer_channel_id(payload),
         {:ok, msg_id} <- normalize_id(message_id),
         {:ok, result} <- message_api().edit(channel_id, msg_id, edit_params),
         {:ok, extra_ids} <- send_extra_chunks(channel_id, rest) do
      {:ok, %{message_id: extract_message_id(result) || msg_id, extra_message_ids: extra_ids}}
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
      |> put_safe_allowed_mentions()
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
      |> put_safe_allowed_mentions()

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
    params = %{content: content} |> put_safe_allowed_mentions()

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

  defp send_extra_chunks(_channel_id, []), do: {:ok, []}

  defp send_extra_chunks(channel_id, chunks) do
    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, ids} ->
      case message_api().create(channel_id, %{content: chunk} |> put_safe_allowed_mentions()) do
        {:ok, result} ->
          {:cont, {:ok, ids ++ [extract_message_id(result)]}}

        {:error, reason} ->
          {:halt, {:error, reason}}

        other ->
          {:halt, {:error, {:discord_chunk_send_failed, other}}}
      end
    end)
  end

  defp content_chunks(content) when is_binary(content) do
    do_content_chunks(content, [])
  end

  defp do_content_chunks("", []), do: [""]
  defp do_content_chunks("", acc), do: Enum.reverse(acc)

  defp do_content_chunks(content, acc) do
    {chunk, rest} = String.split_at(content, @max_content_chars)
    do_content_chunks(rest, [chunk | acc])
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

  defp put_safe_allowed_mentions(params) do
    Map.put(params, :allowed_mentions, :none)
  end

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
          |> put_safe_allowed_mentions()
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

  defp file_params(%{files: files} = content, payload) when is_list(files) do
    batch_file_params(files, content[:caption], payload)
  end

  defp file_params(%{"files" => files} = content, payload) when is_list(files) do
    batch_file_params(files, content["caption"], payload)
  end

  defp file_params(other, _payload), do: {:error, {:discord_file_failed, other}}

  defp batch_file_params(files, caption, payload) do
    with :ok <- validate_file_count(files),
         {:ok, normalized_files} <- normalize_batch_files(files),
         {:ok, uploaded_files} <- read_batch_files(normalized_files) do
      content = batch_caption(caption, normalized_files)

      params =
        %{content: content, files: uploaded_files}
        |> put_safe_allowed_mentions()
        |> maybe_put_reply_from_payload(payload)

      {:ok, params}
    end
  end

  defp validate_file_count([]), do: {:error, :discord_file_batch_empty}

  defp validate_file_count(files) when length(files) > @max_file_count,
    do: {:error, {:discord_file_batch_too_large, @max_file_count}}

  defp validate_file_count(_files), do: :ok

  defp normalize_batch_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case normalize_batch_file(file) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_batch_file(%{path: path} = file) when is_binary(path) and path != "" do
    filename =
      if is_binary(file[:filename]) and file[:filename] != "",
        do: file[:filename],
        else: Path.basename(path)

    {:ok, %{path: path, filename: filename}}
  end

  defp normalize_batch_file(%{"path" => path} = file) when is_binary(path) and path != "" do
    normalize_batch_file(%{path: path, filename: file["filename"]})
  end

  defp normalize_batch_file(other), do: {:error, {:discord_file_failed, other}}

  defp read_batch_files(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      case File.read(file.path) do
        {:ok, body} ->
          {:cont, {:ok, [%{body: body, name: file.filename} | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:discord_file_read_failed, reason}}}
      end
    end)
    |> case do
      {:ok, uploaded_files} -> {:ok, Enum.reverse(uploaded_files)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp batch_caption(caption, _files) when is_binary(caption) and caption != "", do: caption
  defp batch_caption(_caption, [_ | _] = files), do: "Uploaded #{length(files)} files"

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
