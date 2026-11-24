defmodule LemonChannels.Adapters.Discord.FileOperations do
  @moduledoc """
  File upload/download operations for the Discord transport.

  Handles `/file put`, `/file get`, and auto-put for bare attachment uploads.
  Path containment, deny rules, archives and writes are the shared
  `LemonCore.FileAccess` rules used by Telegram. A non-empty
  `allowed_user_ids` decides who may transfer files; without one, slash
  commands need a guild member with Administrator or Manage Server and
  auto-put is off.
  """

  require Logger

  alias LemonChannels.Adapters.Telegram.Transport.FileOperations, as: TelegramFileOps
  alias LemonChannels.BindingResolver
  alias LemonChannels.CommandAuthority
  alias LemonChannels.ImageDownload
  alias LemonCore.{ChatScope, FileAccess}

  @default_max_upload_bytes 25 * 1024 * 1024
  @default_max_download_bytes 25 * 1024 * 1024
  @download_timeout_ms 60_000

  # ---------------------------------------------------------------------------
  # /file put  (slash command interaction)
  # ---------------------------------------------------------------------------

  @doc """
  Handle the `/file put` slash command interaction.

  Validates the destination, then downloads the resolved attachment from its
  URL and writes it. Returns `{:ok, msg}` or `{:error, msg}`.
  """
  def handle_file_put(state, interaction, attachment, dest_path, force) do
    cfg = files_cfg(state)

    with :ok <- ensure_files_enabled(cfg),
         :ok <- ensure_sender_allowed(cfg, interaction, "File uploads are restricted."),
         {:ok, root} <- resolve_project_root(state, interaction),
         {:ok, url, filename} <- extract_attachment_url(attachment),
         dest_rel = resolve_put_dest(cfg, dest_path, filename),
         {:ok, final_rel} <-
           FileAccess.put(
             root,
             dest_rel,
             cfg,
             fn -> download_attachment_bytes(url, upload_cap(cfg), net_opts(state)) end,
             force,
             @default_max_upload_bytes
           ) do
      {:ok, "Saved: #{final_rel}"}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
    end
  end

  # ---------------------------------------------------------------------------
  # /file get  (slash command interaction)
  # ---------------------------------------------------------------------------

  @doc """
  Handle the `/file get` slash command interaction.

  Sends a private copy of the file (or a zip of a directory's allowed files)
  to the Discord channel. Returns `{:ok, msg}` or `{:error, msg}`.
  """
  def handle_file_get(state, interaction, file_path) do
    cfg = files_cfg(state)

    channel_id = interaction_channel_id(interaction)

    with :ok <- ensure_files_enabled(cfg),
         :ok <- ensure_sender_allowed(cfg, interaction, "File downloads are restricted."),
         {:ok, root} <- resolve_project_root(state, interaction),
         {:ok, rel} <- validate_get_path(file_path),
         {:ok, filename, bytes} <- FileAccess.get(root, rel, cfg, @default_max_download_bytes),
         :ok <-
           FileAccess.with_temp_file(filename, bytes, fn path ->
             send_file_to_channel(channel_id, path, filename)
           end) do
      {:ok, "Sent: #{filename}"}
    else
      {:error, msg} when is_binary(msg) -> {:error, msg}
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-put for regular message attachments
  # ---------------------------------------------------------------------------

  @doc """
  Process auto-put for attachments on a regular (non-slash-command) message.

  Returns a list of `{:ok, rel_path}` or `{:error, reason}` tuples, one per
  attachment processed. Messages carry no permission data, so auto-put needs
  the sender in a non-empty `allowed_user_ids`.
  """
  def handle_attachment_auto_put(state, inbound) do
    cfg = files_cfg(state)
    attachments = inbound.meta[:attachments] || []

    channel_id = inbound.meta[:channel_id]

    with true <- should_auto_put?(cfg),
         true <- attachments != [],
         true <-
           FileAccess.sender_allowed?(
             cfg_get(cfg, :allowed_user_ids),
             inbound.meta[:user_id],
             fn -> false end
           ),
         {:ok, root} <- resolve_project_root_from_inbound(inbound) do
      uploads_dir = cfg_get(cfg, :uploads_dir, "incoming")

      results =
        Enum.map(attachments, fn att ->
          url = att_field(att, :url)
          filename = FileAccess.upload_name(att_field(att, :filename), auto_put_filename())
          rel = Path.join(uploads_dir, filename)

          FileAccess.put(
            root,
            rel,
            cfg,
            fn -> download_attachment_bytes(url, upload_cap(cfg), net_opts(state)) end,
            false,
            @default_max_upload_bytes
          )
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
  end

  @doc """
  Returns true when the inbound message has attachments and auto-put is
  enabled in the files config.
  """
  def should_auto_put?(state, inbound) when is_map(state) do
    cfg = files_cfg(state)
    attachments = inbound.meta[:attachments] || []
    should_auto_put?(cfg) and attachments != []
  end

  # ---------------------------------------------------------------------------
  # Attachment download
  # ---------------------------------------------------------------------------

  @doc """
  Download attachment bytes from a Discord CDN URL.

  Only `https://cdn.discordapp.com` and `https://media.discordapp.net` URLs
  are fetched, through `LemonCore.Net.HTTP`: the address is authorized and
  pinned, redirects are not followed, the body is cut off above `max_bytes`
  (the channel's upload limit) while it streams, and the download has a 60 s
  deadline. `net_opts` are extra fetcher options for tests (`:resolver`,
  `:send`).
  """
  def download_attachment_bytes(url, max_bytes \\ @default_max_upload_bytes, net_opts \\ [])

  def download_attachment_bytes(url, max_bytes, net_opts)
      when is_binary(url) and url != "" and is_integer(max_bytes) and max_bytes > 0 do
    opts =
      Keyword.merge(net_opts,
        timeout_ms: @download_timeout_ms,
        max_body_bytes: max_bytes,
        max_redirects: 0
      )

    result =
      if ImageDownload.discord_url?(url),
        do: LemonCore.Net.HTTP.request(:get, url, opts),
        else: {:error, :not_discord_cdn}

    case result do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:error, {:body_too_large, _}} ->
        {:error, "Attachment is too large for the upload limit."}

      result ->
        Logger.warning("Discord attachment download failed: #{inspect(download_failure(result))}")

        {:error,
         "Failed to download attachment. Check that the attachment is still available, then try again."}
    end
  end

  def download_attachment_bytes(_, _, _), do: {:error, "No attachment URL provided."}

  defp download_failure({:ok, %{status: status}}), do: {:http_status, status}
  defp download_failure({:error, reason}), do: reason

  # Transport state may carry `:attachment_net_opts` in tests only; nothing
  # but the resolver and transport stand-ins is taken from it.
  defp net_opts(state),
    do: state |> Map.get(:attachment_net_opts, []) |> Keyword.take([:resolver, :send])

  # The upload limit `FileAccess.put/6` enforces, so the download stops where
  # the write would be refused.
  defp upload_cap(cfg) do
    case cfg_get(cfg, :max_upload_bytes) do
      max when is_integer(max) and max > 0 ->
        max

      max when is_binary(max) ->
        case Integer.parse(String.trim(max)) do
          {value, ""} when value > 0 -> value
          _ -> @default_max_upload_bytes
        end

      _ ->
        @default_max_upload_bytes
    end
  end

  # ---------------------------------------------------------------------------
  # File sending
  # ---------------------------------------------------------------------------

  @doc false
  def send_file_to_channel(channel_id, path, filename) when is_integer(channel_id) do
    api =
      cfg_get(
        LemonCore.GatewayConfig.get(:discord, %{}) || %{},
        :api_mod,
        Nostrum.Api.Message
      )

    case api.create(channel_id, %{content: filename, files: [path]}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Discord file send failed: #{inspect(reason)}")

        {:error,
         "Failed to send file. Check the file size and that the bot can post in this channel, then try again."}
    end
  rescue
    error ->
      Logger.warning("Discord file send failed: #{inspect(error)}")

      {:error,
       "Failed to send file. Check that the file exists, its size, and that the bot can post in this channel, then try again."}
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
        is_integer(id) and is_map_key(resolved, id) ->
          Map.get(resolved, id)

        is_binary(attachment_id) and is_map_key(resolved, attachment_id) ->
          Map.get(resolved, attachment_id)

        # Try the first attachment if we can't match by ID
        map_size(resolved) == 1 ->
          resolved |> Map.values() |> List.first()

        true ->
          nil
      end
    else
      nil
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp files_cfg(state) do
    cfg = state[:files] || %{}
    if is_map(cfg), do: cfg, else: %{}
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
  end

  defp resolve_project_root_from_inbound(inbound) do
    channel_id = inbound.meta[:channel_id]
    thread_id = inbound.meta[:thread_id]
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    root = BindingResolver.resolve_cwd(scope)
    TelegramFileOps.ensure_project_root(root)
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
    filename = FileAccess.upload_name(att_field(attachment, :filename), auto_put_filename())

    if is_binary(url) and url != "" do
      {:ok, url, filename}
    else
      {:error, "Attachment has no downloadable URL."}
    end
  end

  defp extract_attachment_url(_), do: {:error, "No attachment provided."}

  defp auto_put_filename do
    "upload_#{System.system_time(:second)}_#{:rand.uniform(9999)}.bin"
  end

  defp ensure_sender_allowed(cfg, interaction, refusal) do
    sender_id =
      interaction |> map_get(:member) |> map_get(:user) |> map_get(:id) ||
        interaction |> map_get(:user) |> map_get(:id)

    if FileAccess.sender_allowed?(cfg_get(cfg, :allowed_user_ids), sender_id, fn ->
         CommandAuthority.discord_admin?(interaction)
       end),
       do: :ok,
       else: {:error, refusal}
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
  end

  defp send_channel_message(channel_id, text) when is_integer(channel_id) and is_binary(text) do
    Nostrum.Api.Message.create(channel_id, %{content: text})
  rescue
    error -> {:error, {:discord_send_crashed, error}}
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
