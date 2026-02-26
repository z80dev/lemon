defmodule LemonChannels.Adapters.Discord.Outbound do
  @moduledoc """
  Outbound message delivery for Discord.
  """

  require Logger

  alias LemonChannels.OutboundPayload
  alias Nostrum.Api.Message

  @spec deliver(OutboundPayload.t()) :: {:ok, term()} | {:error, term()}
  def deliver(%OutboundPayload{kind: :text} = payload) do
    channel_id = peer_channel_id(payload)

    with {:ok, channel_id} <- channel_id,
         content when is_binary(content) <- to_string(payload.content),
         params <- text_params(content, payload),
         {:ok, result} <- Message.create(channel_id, params) do
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
    with {:ok, channel_id} <- peer_channel_id(payload),
         {:ok, msg_id} <- normalize_id(message_id),
         {:ok, result} <- Message.edit(channel_id, msg_id, %{content: to_string(text)}) do
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
         {:ok, _} <- Message.delete(channel_id, msg_id) do
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

  def deliver(%OutboundPayload{kind: :file, content: content} = payload) do
    with {:ok, channel_id} <- peer_channel_id(payload),
         text <- file_notice_text(content),
         {:ok, result} <- Message.create(channel_id, text_params(text, payload)) do
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

  defp text_params(content, payload) do
    params = %{content: content}

    case normalize_id(payload.reply_to) do
      {:ok, reply_id} ->
        Map.put(params, :message_reference, %{message_id: reply_id})

      _ ->
        params
    end
  end

  defp file_notice_text(%{path: path, filename: filename}) do
    filename =
      if is_binary(filename) and filename != "", do: filename, else: Path.basename(path || "")

    "Generated file: #{filename}\n#{to_string(path || "")}" |> String.trim()
  end

  defp file_notice_text(%{files: files}) when is_list(files) do
    lines =
      files
      |> Enum.map(fn file ->
        name =
          file[:filename] || file["filename"] ||
            Path.basename(to_string(file[:path] || file["path"] || ""))

        path = file[:path] || file["path"] || ""
        "- #{name}: #{path}"
      end)

    ["Generated files:", Enum.join(lines, "\n")]
    |> Enum.join("\n")
    |> String.trim()
  end

  defp file_notice_text(other), do: "Generated artifact: #{inspect(other, limit: 20)}"

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
