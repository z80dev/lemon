defmodule LemonChannels.Adapters.Discord.FileOperations do
  @moduledoc """
  File upload/download operations for the Discord transport.

  Handles `/file put`, `/file get`, and auto-put for bare attachment uploads.
  Reuses shared path-validation and write helpers from the Telegram FileOperations
  module where possible, adapting the download/upload paths for Discord's API.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.FileOperations, as: TelegramFileOps
  alias LemonChannels.BindingResolver
  alias LemonCore.ChatScope

  @default_max_upload_bytes 25 * 1024 * 1024
  @default_max_download_bytes 25 * 1024 * 1024

  # ---------------------------------------------------------------------------
  # /file put  (slash command interaction)
  # ---------------------------------------------------------------------------

  @doc """
  Handle the `/file put` slash command interaction.

  Downloads the resolved attachment from its URL, validates the destination
  path, and writes the file to disk.

  Returns a reply string for the interaction response.
  """
  def handle_file_put(state, interaction, attachment, dest_path, force) do
    cfg = files_cfg(state)

    with :ok <- ensure_files_enabled(cfg),
         {:ok, root} <- resolve_project_root(state, interaction),
         {:ok, url, filename} <- extract_attachment_url(attachment),
         dest_rel <- resolve_put_dest(cfg, dest_path, filename),
         {:ok, dest_abs} <- TelegramFileOps.resolve_dest_abs(root, dest_rel),
         :ok <- TelegramFileOps.ensure_not_denied(root, dest_rel, cfg),
         {:ok, bytes} <- download_attachment_bytes(url),
         :ok <- TelegramFileOps.enforce_bytes_limit(bytes, cfg, :max_upload_bytes, @default_max_upload_bytes),
         {:ok, final_rel, _final_abs} <- TelegramFileOps.write_document(dest_rel, dest_abs, bytes, force: force) do
      {:ok, "Saved: #{final_rel}"}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "Upload failed."}
    end
  rescue
    _ -> {:error, "Upload failed."}
  end

  # ---------------------------------------------------------------------------
  # /file get  (slash command interaction)
  # ---------------------------------------------------------------------------

  @doc """
  Handle the `/file get` slash command interaction.

  Reads a file from disk and sends it to the Discord channel as an attachment.

  Returns `{:ok, msg}` or `{:error, msg}`.
  """
  def handle_file_get(state, interaction, file_path) do
    cfg = files_cfg(state)

    channel_id = interaction_channel_id(interaction)

    with :ok <- ensure_files_enabled(cfg),
         {:ok, root} <- resolve_project_root(state, interaction),
         {:ok, rel} <- validate_get_path(file_path),
         {:ok, abs} <- TelegramFileOps.resolve_dest_abs(root, rel),
         :ok <- TelegramFileOps.ensure_not_denied(root, rel, cfg),
         {:ok, kind, send_path, filename} <- TelegramFileOps.prepare_file_get(abs),
         :ok <- TelegramFileOps.enforce_path_size(send_path, cfg, :max_download_bytes, @default_max_download_bytes),
         :ok <- send_file_to_channel(channel_id, send_path, filename) do
      if kind == :zip, do: File.rm(send_path)
      {:ok, "Sent: #{filename}"}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
      _ -> {:error, "Download failed."}
    end
  rescue
    _ -> {:error, "Download failed."}
  end

  # ---------------------------------------------------------------------------
  # Auto-put for regular message attachments
  # ---------------------------------------------------------------------------

  @doc """
  Process auto-put for attachments on a regular (non-slash-command) message.

  Returns a list of `{:ok, rel_path}` or `{:error, reason}` tuples, one per
  attachment processed.
  """
  def handle_attachment_auto_put(state, inbound) do
    cfg = files_cfg(state)
    attachments = (inbound.meta[:attachments] || [])

    channel_id = inbound.meta[:channel_id]

    with true <- should_auto_put?(cfg),
         true <- length(attachments) > 0,
         {:ok, root} <- resolve_project_root_from_inbound(inbound) do
      uploads_dir = cfg_get(cfg, :uploads_dir, "incoming")

      results =
        Enum.map(attachments, fn att ->
          url = att_field(att, :url)
          filename = att_field(att, :filename) || auto_put_filename(att)
          rel = Path.join(uploads_dir, filename)

          with {:ok, dest_abs} <- TelegramFileOps.resolve_dest_abs(root, rel),
               :ok <- TelegramFileOps.ensure_not_denied(root, rel, cfg),
               {:ok, bytes} <- download_attachment_bytes(url),
               :ok <- TelegramFileOps.enforce_bytes_limit(bytes, cfg, :max_upload_bytes, @default_max_upload_bytes),
               {:ok, final_rel, _} <- TelegramFileOps.write_document(rel, dest_abs, bytes, force: false) do
            {:ok, final_rel}
          else
            {:error, msg} -> {:error, msg}
            _ -> {:error, "upload failed"}
          end
        end)

      # Send summary to channel
      ok_paths = for {:ok, p} <- results, do: p
      err_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

      msg =
        cond do
          ok_paths == [] ->
            "Upload failed."

          err_count == 0 ->
            "Uploaded #{length(ok_paths)} file(s):\n" <> Enum.map_join(ok_paths, "\n", &"- #{&1}")

          true ->
            "Uploaded #{length(ok_paths)} file(s) (#{err_count} failed):\n" <>
              Enum.map_join(ok_paths, "\n", &"- #{&1}")
        end

      if is_integer(channel_id) do
        _ = send_channel_message(channel_id, msg)
      end

      results
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns true when the inbound message has attachments and auto-put is
  enabled in the files config.
  """
  def should_auto_put?(state, inbound) when is_map(state) do
    cfg = files_cfg(state)
    attachments = (inbound.meta[:attachments] || [])
    should_auto_put?(cfg) and length(attachments) > 0
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Attachment download
  # ---------------------------------------------------------------------------

  @doc """
  Download attachment bytes from a Discord CDN URL.
  """
  def download_attachment_bytes(url) when is_binary(url) and url != "" do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      _ -> {:error, "Failed to download attachment."}
    end
  rescue
    _ -> {:error, "Failed to download attachment."}
  end

  def download_attachment_bytes(_), do: {:error, "No attachment URL provided."}

  # ---------------------------------------------------------------------------
  # File sending
  # ---------------------------------------------------------------------------

  @doc false
  def send_file_to_channel(channel_id, path, filename) when is_integer(channel_id) do
    case Nostrum.Api.Message.create(channel_id, %{content: filename, files: [path]}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, "Failed to send file: #{inspect(reason)}"}
    end
  rescue
    _ -> {:error, "Failed to send file."}
  end

  def send_file_to_channel(_, _, _), do: {:error, "Invalid channel ID."}

  # ---------------------------------------------------------------------------
  # Resolved attachment extraction (for slash command interactions)
  # ---------------------------------------------------------------------------

  @doc """
  Extract the resolved attachment struct from a `/file put` interaction.

  Discord option type 11 (ATTACHMENT) stores the snowflake ID as the option
  value. The actual attachment data lives in `interaction.data.resolved.attachments`
  keyed by that snowflake.
  """
  def extract_resolved_attachment(interaction, subcommand, option_name) do
    attachment_id = nested_option_value(interaction, subcommand, option_name)
    resolved = interaction |> map_get(:data) |> map_get(:resolved) |> map_get(:attachments)

    if is_map(resolved) do
      id = parse_id(attachment_id)

      cond do
        is_integer(id) and is_map_key(resolved, id) -> Map.get(resolved, id)
        is_binary(attachment_id) and is_map_key(resolved, attachment_id) -> Map.get(resolved, attachment_id)
        # Try the first attachment if we can't match by ID
        map_size(resolved) == 1 -> resolved |> Map.values() |> List.first()
        true -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp files_cfg(state) do
    cfg = state[:files] || %{}
    if is_map(cfg), do: cfg, else: %{}
  rescue
    _ -> %{}
  end

  defp ensure_files_enabled(cfg) do
    if truthy(cfg_get(cfg, :enabled)) do
      :ok
    else
      {:error, "File transfer is disabled. Enable it under [gateway.discord.files]."}
    end
  end

  defp should_auto_put?(cfg) do
    truthy(cfg_get(cfg, :enabled)) and truthy(cfg_get(cfg, :auto_put))
  end

  defp resolve_project_root(_state, interaction) do
    channel_id = interaction_channel_id(interaction)
    thread_id = interaction_thread_id(interaction)
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    root = BindingResolver.resolve_cwd(scope)
    TelegramFileOps.ensure_project_root(root)
  rescue
    _ -> TelegramFileOps.ensure_project_root(nil)
  end

  defp resolve_project_root_from_inbound(inbound) do
    channel_id = inbound.meta[:channel_id]
    thread_id = inbound.meta[:thread_id]
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    root = BindingResolver.resolve_cwd(scope)
    TelegramFileOps.ensure_project_root(root)
  rescue
    _ -> TelegramFileOps.ensure_project_root(nil)
  end

  defp resolve_put_dest(cfg, dest_path, filename) do
    cond do
      is_binary(dest_path) and String.trim(dest_path) != "" ->
        dest = String.trim(dest_path)

        if String.ends_with?(dest, "/") do
          Path.join(dest, filename)
        else
          dest
        end

      true ->
        uploads_dir = cfg_get(cfg, :uploads_dir, "incoming")
        Path.join(uploads_dir, filename)
    end
  end

  defp validate_get_path(path) when is_binary(path) and path != "" do
    {:ok, String.trim(path)}
  end

  defp validate_get_path(_), do: {:error, "Usage: /file get <path>"}

  defp extract_attachment_url(attachment) when is_map(attachment) do
    url = att_field(attachment, :url) || att_field(attachment, :proxy_url)
    filename = att_field(attachment, :filename) || "upload_#{System.system_time(:second)}.bin"

    if is_binary(url) and url != "" do
      {:ok, url, filename}
    else
      {:error, "Attachment has no downloadable URL."}
    end
  end

  defp extract_attachment_url(_), do: {:error, "No attachment provided."}

  defp auto_put_filename(att) do
    name = att_field(att, :filename)

    if is_binary(name) and name != "" do
      name
    else
      "upload_#{System.system_time(:second)}_#{:rand.uniform(9999)}.bin"
    end
  end

  defp att_field(att, key) when is_map(att) do
    Map.get(att, key) || Map.get(att, Atom.to_string(key))
  end

  defp att_field(_, _), do: nil

  defp interaction_channel_id(interaction) do
    interaction |> map_get(:channel_id) |> parse_id()
  end

  defp interaction_thread_id(interaction) do
    interaction
    |> map_get(:channel)
    |> map_get(:thread_metadata)
    |> case do
      %{} -> interaction |> map_get(:channel_id) |> parse_id()
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp send_channel_message(channel_id, text) when is_integer(channel_id) and is_binary(text) do
    Nostrum.Api.Message.create(channel_id, %{content: text})
  rescue
    _ -> :ok
  end

  defp nested_option_value(interaction, subcommand, option_name) do
    options =
      interaction
      |> map_get(:data)
      |> map_get(:options)
      |> List.wrap()

    sub_options =
      Enum.find_value(options, [], fn option ->
        if map_get(option, :name) == subcommand, do: map_get(option, :options) || [], else: nil
      end)

    sub_options
    |> List.wrap()
    |> Enum.find_value(fn option ->
      if map_get(option, :name) == option_name, do: map_get(option, :value), else: nil
    end)
    |> normalize_blank()
  rescue
    _ -> nil
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> id
      :error -> nil
    end
  end

  defp parse_id(_), do: nil

  defp normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank(_), do: nil

  defp cfg_get(cfg, key, default \\ nil) when is_atom(key) do
    cfg[key] || cfg[Atom.to_string(key)] || default
  end

  defp truthy(v), do: v in [true, "true", 1, "1"]
end
