defmodule LemonChannels.Adapters.Telegram.Transport.FileOperations do
  @moduledoc """
  File upload/download operations for the Telegram transport.

  Handles `/file put`, `/file get`, auto-put for bare document uploads,
  and media-group file batching. Functions here perform I/O (Telegram API
  calls, filesystem writes) but do not directly mutate GenServer state.
  """

  alias LemonChannels.BindingResolver
  alias LemonChannels.Cwd
  alias LemonCore.ChatScope
  alias LemonChannels.Adapters.Telegram.Transport.Commands

  @media_types [:document, :photo, :video, :animation, :video_note]

  @mime_to_ext %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp",
    "video/mp4" => ".mp4",
    "video/quicktime" => ".mov",
    "video/webm" => ".webm",
    "video/x-matroska" => ".mkv"
  }

  @default_ext %{
    photo: ".jpg",
    video: ".mp4",
    animation: ".mp4",
    video_note: ".mp4"
  }

  # ---------------------------------------------------------------------------
  # Generic media extraction helpers
  # ---------------------------------------------------------------------------

  @doc """
  Extract the first present media attachment from the inbound message.
  Returns `{media_type, media_map}` or `nil`.
  """
  def extract_media(inbound) do
    meta = inbound.meta || %{}

    Enum.find_value(@media_types, fn type ->
      media = meta[type] || meta[Atom.to_string(type)]

      if is_map(media) and map_size(media) > 0 do
        {type, media}
      end
    end)
  rescue
    _ -> nil
  end

  @doc """
  Returns true when the inbound message has any downloadable media attachment.
  """
  def has_media?(inbound) do
    extract_media(inbound) != nil
  rescue
    _ -> false
  end

  @doc """
  Extract the file_id from whichever media type is present.
  """
  def extract_file_id(inbound) do
    case extract_media(inbound) do
      {_type, media} -> media[:file_id] || media["file_id"]
      nil -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Generate a filename for the media. Uses the Telegram-provided filename when
  available, otherwise generates `{type}_{YYYYMMDD_HHMMSS}{ext}`.
  """
  def media_filename(media_type, media) do
    telegram_name = media[:file_name] || media["file_name"]

    if is_binary(telegram_name) and telegram_name != "" do
      telegram_name
    else
      ext = ext_from_mime(media_type, media[:mime_type] || media["mime_type"])
      type_prefix = type_to_prefix(media_type)
      timestamp = format_timestamp()
      "#{type_prefix}_#{timestamp}#{ext}"
    end
  rescue
    _ -> "upload_#{System.system_time(:second)}.bin"
  end

  defp ext_from_mime(_type, mime) when is_binary(mime) and mime != "" do
    Map.get(@mime_to_ext, mime, Map.get(@default_ext, :video, ".bin"))
  end

  defp ext_from_mime(type, _mime), do: Map.get(@default_ext, type, ".bin")

  defp type_to_prefix(:video_note), do: "videonote"
  defp type_to_prefix(type), do: Atom.to_string(type)

  defp format_timestamp do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()
    uniq = rem(System.unique_integer([:positive, :monotonic]), 10000)

    :io_lib.format("~4..0B~2..0B~2..0B_~2..0B~2..0B~2..0B_~4..0B", [y, mo, d, h, mi, s, uniq])
    |> IO.iodata_to_binary()
  end

  # ---------------------------------------------------------------------------
  # Auto-put / media-group file operations
  # ---------------------------------------------------------------------------

  @doc """
  Process a media group of document uploads via auto-put behavior.

  Downloads each document and writes it to the configured uploads directory.
  Sends a summary system message.
  """
  def handle_auto_put_media_group(state, items, chat_id, thread_id, user_msg_id) do
    cfg = files_cfg(state)

    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, List.first(items), chat_id),
         {:ok, root} <- files_project_root(List.first(items), chat_id, thread_id) do
      uploads_dir = cfg_get(cfg, :uploads_dir, "incoming")

      results =
        Enum.map(items, fn inbound ->
          {media_type, media} =
            case extract_media(inbound) do
              {t, m} -> {t, m}
              nil -> {:document, %{}}
            end

          filename = media_filename(media_type, media)
          rel = Path.join(uploads_dir, filename)

          with {:ok, abs} <- resolve_dest_abs(root, rel),
               :ok <- ensure_not_denied(root, rel, cfg),
               {:ok, bytes} <- download_media_bytes(state, inbound),
               :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
               {:ok, final_rel, _} <- write_document(rel, abs, bytes, force: false) do
            {:ok, final_rel}
          else
            {:error, msg} -> {:error, msg}
            _ -> {:error, "upload failed"}
          end
        end)

      ok_paths = for {:ok, p} <- results, do: p
      err_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

      msg =
        cond do
          ok_paths == [] ->
            "Upload failed."

          err_count == 0 ->
            "Uploaded #{length(ok_paths)} files:\n" <> Enum.map_join(ok_paths, "\n", &"- #{&1}")

          true ->
            "Uploaded #{length(ok_paths)} files (#{err_count} failed):\n" <>
              Enum.map_join(ok_paths, "\n", &"- #{&1}")
        end

      _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
      :ok
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        :ok

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File uploads are restricted."
          )

        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Process a media group where one item carries a `/file put` caption.
  """
  def handle_file_put_media_group(
        state,
        file_put_inbound,
        items,
        chat_id,
        thread_id,
        user_msg_id
      ) do
    cfg = files_cfg(state)

    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
    root = BindingResolver.resolve_cwd(scope)

    args = Commands.telegram_command_args(file_put_inbound.message.text || "", "file") || ""
    parts = String.split(String.trim(args || ""), ~r/\s+/, trim: true)

    rest =
      case parts do
        ["put" | tail] -> tail
        _ -> []
      end

    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, file_put_inbound, chat_id),
         {:ok, root} <- ensure_project_root(root),
         {:ok, force, dest_rel} <- parse_file_put_args(cfg, file_put_inbound, rest),
         :ok <- validate_multi_file_dest(items, dest_rel) do
      results = upload_media_group_items(state, items, root, dest_rel, cfg, force)
      msg = format_upload_results(results)
      _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
      :ok
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        :ok

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File uploads are restricted."
          )

        :ok

      _ ->
        :ok
    end
  end

  def validate_multi_file_dest(items, dest_rel) do
    if length(items) > 1 and not String.ends_with?(dest_rel, "/") do
      {:error,
       "For multiple files, use a directory path ending with '/'. Example: /file put incoming/"}
    else
      :ok
    end
  end

  def upload_media_group_items(state, items, root, dest_rel, cfg, force) do
    Enum.map(items, fn inbound ->
      {media_type, media} =
        case extract_media(inbound) do
          {t, m} -> {t, m}
          nil -> {:document, %{}}
        end

      filename = media_filename(media_type, media)

      rel =
        if String.ends_with?(dest_rel, "/") do
          Path.join(dest_rel, filename)
        else
          dest_rel
        end

      with {:ok, abs} <- resolve_dest_abs(root, rel),
           :ok <- ensure_not_denied(root, rel, cfg),
           {:ok, bytes} <- download_media_bytes(state, inbound),
           :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
           {:ok, final_rel, _} <- write_document(rel, abs, bytes, force: force) do
        {:ok, final_rel}
      else
        {:error, msg} -> {:error, msg}
        _ -> {:error, "upload failed"}
      end
    end)
  end

  def format_upload_results(results) do
    ok_paths = for {:ok, p} <- results, do: p
    err_count = Enum.count(results, fn r -> match?({:error, _}, r) end)

    cond do
      ok_paths == [] ->
        "Upload failed."

      err_count == 0 ->
        "Saved #{length(ok_paths)} files:\n" <> Enum.map_join(ok_paths, "\n", &"- #{&1}")

      true ->
        "Saved #{length(ok_paths)} files (#{err_count} failed):\n" <>
          Enum.map_join(ok_paths, "\n", &"- #{&1}")
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-put detection
  # ---------------------------------------------------------------------------

  @doc """
  Returns true when the inbound has any media attachment that should be
  auto-saved according to the files configuration.
  """
  def should_auto_put_media?(state, inbound) do
    cfg = files_cfg(state)

    enabled? = truthy(cfg_get(cfg, :enabled))
    auto_put? = truthy(cfg_get(cfg, :auto_put))

    enabled? and auto_put? and has_media?(inbound) and
      not Commands.command_message_for_bot?(inbound.message.text || "", state.bot_username)
  rescue
    _ -> false
  end

  @doc false
  def should_auto_put_document?(state, inbound),
    do: should_auto_put_media?(state, inbound)

  @doc """
  Handle a single bare media upload via auto-put.

  Returns `{:ok, final_rel}` or `{:error, reason}`.
  """
  def handle_media_auto_put(state, inbound) do
    cfg = files_cfg(state)
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)

    with true <- is_integer(chat_id),
         :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, inbound, chat_id),
         {:ok, root} <- files_project_root(inbound, chat_id, thread_id),
         {:ok, dest_rel} <- auto_put_destination(cfg, inbound),
         {:ok, dest_abs} <- resolve_dest_abs(root, dest_rel),
         :ok <- ensure_not_denied(root, dest_rel, cfg),
         {:ok, bytes} <- download_media_bytes(state, inbound),
         :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
         {:ok, final_rel, _final_abs} <- write_document(dest_rel, dest_abs, bytes, force: false) do
      _ = send_system_message(state, chat_id, thread_id, user_msg_id, "Uploaded: #{final_rel}")

      {:ok, final_rel}
    else
      {:error, msg} when is_binary(msg) ->
        _ =
          is_integer(chat_id) && send_system_message(state, chat_id, thread_id, user_msg_id, msg)

        {:error, msg}

      false ->
        _ =
          is_integer(chat_id) &&
            send_system_message(
              state,
              chat_id,
              thread_id,
              user_msg_id,
              "File uploads are restricted."
            )

        {:error, :restricted}

      _ ->
        {:error, :unknown}
    end
  rescue
    _ -> {:error, :crash}
  end

  @doc false
  def handle_document_auto_put(state, inbound),
    do: handle_media_auto_put(state, inbound)

  # ---------------------------------------------------------------------------
  # /file command handlers
  # ---------------------------------------------------------------------------

  @doc """
  Handle the `/file` command dispatch (put / get / usage).

  Returns the updated state.
  """
  def handle_file_command(state, inbound) do
    cfg = files_cfg(state)
    {chat_id, thread_id, user_msg_id} = extract_message_ids(inbound)
    args = Commands.telegram_command_args(inbound.message.text, "file") || ""

    if not is_integer(chat_id) do
      state
    else
      scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}
      root = BindingResolver.resolve_cwd(scope)

      parts = String.split(String.trim(args || ""), ~r/\s+/, trim: true)

      case parts do
        [] ->
          _ = send_system_message(state, chat_id, thread_id, user_msg_id, file_usage())
          state

        ["put" | rest] ->
          handle_file_put(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest)

        ["get" | rest] ->
          handle_file_get(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest)

        _ ->
          _ = send_system_message(state, chat_id, thread_id, user_msg_id, file_usage())
          state
      end
    end
  rescue
    _ -> state
  end

  def handle_file_put(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest) do
    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, inbound, chat_id),
         {:ok, root} <- ensure_project_root(root),
         {:ok, force, dest_rel} <- parse_file_put_args(cfg, inbound, rest),
         {:ok, dest_abs} <- resolve_dest_abs(root, dest_rel),
         :ok <- ensure_not_denied(root, dest_rel, cfg),
         {:ok, bytes} <- download_media_bytes(state, inbound),
         :ok <- enforce_bytes_limit(bytes, cfg, :max_upload_bytes, 20 * 1024 * 1024),
         {:ok, final_rel, _final_abs} <- write_document(dest_rel, dest_abs, bytes, force: force) do
      _ = send_system_message(state, chat_id, thread_id, user_msg_id, "Saved: #{final_rel}")
      state
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        state

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File uploads are restricted."
          )

        state

      _ ->
        state
    end
  end

  def handle_file_get(state, inbound, cfg, chat_id, thread_id, user_msg_id, root, rest) do
    with :ok <- ensure_files_enabled(cfg),
         true <- files_sender_allowed?(state, inbound, chat_id),
         {:ok, root} <- ensure_project_root(root),
         {:ok, rel} <- parse_file_get_args(rest),
         {:ok, abs} <- resolve_dest_abs(root, rel),
         :ok <- ensure_not_denied(root, rel, cfg),
         {:ok, kind, send_path, filename} <- prepare_file_get(abs),
         :ok <- enforce_path_size(send_path, cfg, :max_download_bytes, 50 * 1024 * 1024),
         :ok <- send_document_reply(state, chat_id, thread_id, user_msg_id, send_path, filename) do
      if kind == :zip do
        _ = File.rm(send_path)
      end

      state
    else
      {:error, msg} when is_binary(msg) ->
        _ = send_system_message(state, chat_id, thread_id, user_msg_id, msg)
        state

      false ->
        _ =
          send_system_message(
            state,
            chat_id,
            thread_id,
            user_msg_id,
            "File downloads are restricted."
          )

        state

      _ ->
        state
    end
  rescue
    _ -> state
  end

  # ---------------------------------------------------------------------------
  # File-related helpers (also used by media-group processing)
  # ---------------------------------------------------------------------------

  def files_cfg(state) do
    cfg = state.files || %{}
    if is_map(cfg), do: cfg, else: %{}
  end

  def ensure_files_enabled(cfg) do
    if truthy(cfg_get(cfg, :enabled)) do
      :ok
    else
      {:error, "File transfer is disabled. Enable it under [gateway.telegram.files]."}
    end
  end

  def files_sender_allowed?(state, inbound, chat_id) do
    cfg = files_cfg(state)
    allowed = cfg_get(cfg, :allowed_user_ids, [])
    allowed = if is_list(allowed), do: allowed, else: []

    sender_id = parse_int(inbound.sender && inbound.sender.id)

    cond do
      is_integer(sender_id) and Enum.any?(allowed, fn x -> parse_int(x) == sender_id end) ->
        true

      inbound.peer.kind in [:group, :channel] ->
        if allowed == [] do
          sender_admin?(state, chat_id, sender_id)
        else
          false
        end

      true ->
        true
    end
  rescue
    _ -> false
  end

  def files_project_root(_inbound, chat_id, thread_id) do
    scope = %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: thread_id}

    root = BindingResolver.resolve_cwd(scope)
    ensure_project_root(root)
  rescue
    _ -> ensure_project_root(nil)
  end

  def ensure_project_root(root) when is_binary(root) and byte_size(root) > 0,
    do: {:ok, Path.expand(root)}

  def ensure_project_root(_) do
    case Cwd.default_cwd() do
      cwd when is_binary(cwd) and byte_size(cwd) > 0 -> {:ok, Path.expand(cwd)}
      _ -> {:error, "No accessible working directory configured."}
    end
  end

  def auto_put_destination(cfg, inbound) do
    uploads_dir = cfg_get(cfg, :uploads_dir, "incoming")

    {media_type, media} =
      case extract_media(inbound) do
        {t, m} -> {t, m}
        nil -> {:document, %{}}
      end

    filename = media_filename(media_type, media)
    {:ok, Path.join(uploads_dir, filename)}
  end

  def parse_file_put_args(cfg, inbound, rest) do
    rest = rest || []

    {force, rest} =
      case rest do
        ["--force" | tail] -> {true, tail}
        tail -> {false, tail}
      end

    dest =
      case rest do
        [path | _] when is_binary(path) and path != "" ->
          path

        _ ->
          uploads_dir = cfg_get(cfg, :uploads_dir, "incoming")

          {media_type, media} =
            case extract_media(inbound) do
              {t, m} -> {t, m}
              nil -> {:document, %{}}
            end

          filename = media_filename(media_type, media)
          Path.join(uploads_dir, filename)
      end

    if is_binary(dest) and String.trim(dest) != "" do
      {:ok, force, String.trim(dest)}
    else
      {:error, file_usage()}
    end
  end

  def parse_file_get_args(rest) do
    case rest do
      [path | _] when is_binary(path) and path != "" -> {:ok, String.trim(path)}
      _ -> {:error, file_usage()}
    end
  end

  def resolve_dest_abs(root, rel) do
    rel = String.trim(rel || "")

    cond do
      rel == "" ->
        {:error, file_usage()}

      Path.type(rel) == :absolute ->
        {:error, "Path must be relative to the active working directory root."}

      String.contains?(rel, "\\0") ->
        {:error, "Invalid path."}

      true ->
        root = Path.expand(root)
        abs = Path.expand(rel, root)

        if within_root?(root, abs) do
          {:ok, abs}
        else
          {:error, "Path escapes the active working directory root."}
        end
    end
  rescue
    _ -> {:error, "Invalid path."}
  end

  def within_root?(root, abs) when is_binary(root) and is_binary(abs) do
    root = Path.expand(root)
    abs = Path.expand(abs)
    abs == root or Path.relative_to(abs, root) != abs
  end

  def ensure_not_denied(root, rel, cfg) do
    globs = cfg_get(cfg, :deny_globs, [])
    globs = if is_list(globs), do: globs, else: []

    if denied_by_globs?(root, rel, globs) do
      {:error, "Access denied for that path."}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def download_media_bytes(state, inbound) do
    file_id = extract_file_id(inbound)

    cond do
      not is_binary(file_id) or file_id == "" ->
        {:error, "Attach a Telegram file and use:\n/file put [--force] <path>"}

      true ->
        with {:ok, %{"ok" => true, "result" => %{"file_path" => file_path}}} <-
               state.api_mod.get_file(state.token, file_id),
             {:ok, bytes} <- state.api_mod.download_file(state.token, file_path) do
          {:ok, bytes}
        else
          _ -> {:error, "Failed to download the file from Telegram."}
        end
    end
  rescue
    _ -> {:error, "Failed to download the file from Telegram."}
  end

  @doc false
  def download_document_bytes(state, inbound),
    do: download_media_bytes(state, inbound)

  def enforce_bytes_limit(bytes, cfg, key, default_max) when is_binary(bytes) do
    max = parse_int(cfg[key] || cfg[to_string(key)]) || default_max

    if is_integer(max) and max > 0 and byte_size(bytes) > max do
      {:error, "File is too large."}
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def write_document(rel, abs, bytes, opts) do
    force = Keyword.get(opts, :force, false)
    abs = Path.expand(abs)
    rel = String.trim(rel || "")

    dir = Path.dirname(abs)
    File.mkdir_p!(dir)

    cond do
      not force and File.exists?(abs) ->
        {:error, "File already exists. Use /file put --force <path> to overwrite."}

      true ->
        tmp = abs <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
        File.write!(tmp, bytes)
        File.rename!(tmp, abs)
        {:ok, rel, abs}
    end
  rescue
    _ -> {:error, "Failed to write file."}
  end

  def prepare_file_get(abs) do
    cond do
      File.regular?(abs) ->
        {:ok, :file, abs, Path.basename(abs)}

      File.dir?(abs) ->
        tmp =
          Path.join(
            System.tmp_dir!(),
            "lemon-telegram-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}.zip"
          )

        case zip_dir(abs, tmp) do
          :ok -> {:ok, :zip, tmp, Path.basename(abs) <> ".zip"}
          {:error, _} -> {:error, "Failed to zip directory."}
        end

      true ->
        {:error, "Not found."}
    end
  rescue
    _ -> {:error, "Not found."}
  end

  def enforce_path_size(path, cfg, key, default_max) do
    max = parse_int(cfg[key] || cfg[to_string(key)]) || default_max

    if is_integer(max) and max > 0 do
      size =
        case File.stat(path) do
          {:ok, %File.Stat{size: s}} -> s
          _ -> 0
        end

      if is_integer(size) and size > max, do: {:error, "File is too large."}, else: :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  def send_document_reply(state, chat_id, thread_id, reply_to_id, path, filename) do
    if function_exported?(state.api_mod, :send_document, 4) do
      opts =
        %{}
        |> maybe_put("reply_to_message_id", reply_to_id)
        |> maybe_put("message_thread_id", thread_id)
        |> maybe_put("caption", filename)

      case state.api_mod.send_document(state.token, chat_id, {:path, path}, opts) do
        {:ok, _} -> :ok
        _ -> {:error, "Failed to send file."}
      end
    else
      {:error, "This Telegram API module does not support sendDocument."}
    end
  rescue
    _ -> {:error, "Failed to send file."}
  end

  def file_usage do
    "Usage:\n/file put [--force] <path>\n/file get <path>"
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp truthy(v), do: v in [true, "true", 1, "1"]

  defp denied_by_globs?(_root, _rel, []), do: false

  defp denied_by_globs?(root, rel, globs) do
    root = Path.expand(root)
    abs = Path.expand(rel, root)

    Enum.any?(globs, fn glob ->
      matches = Path.wildcard(Path.join(root, glob), match_dot: true)
      Enum.any?(matches, fn m -> Path.expand(m) == abs end)
    end)
  end

  defp zip_dir(dir, zip_path) do
    files =
      Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))

    _ =
      :zip.create(
        to_charlist(zip_path),
        Enum.map(files, &to_charlist/1),
        cwd: to_charlist(dir)
      )

    :ok
  rescue
    _ -> {:error, :zip_failed}
  end

  defp sender_admin?(state, chat_id, sender_id) do
    if function_exported?(state.api_mod, :get_chat_member, 3) do
      case state.api_mod.get_chat_member(state.token, chat_id, sender_id) do
        {:ok, %{"ok" => true, "result" => %{"status" => status}}}
        when status in ["administrator", "creator"] ->
          true

        _ ->
          false
      end
    else
      false
    end
  rescue
    _ -> false
  end

  defp send_system_message(state, chat_id, thread_id, reply_to_message_id, text)
       when is_integer(chat_id) and is_binary(text) do
    delivery_opts =
      []
      |> maybe_put_kw(:account_id, state.account_id || "default")
      |> maybe_put_kw(:thread_id, thread_id)
      |> maybe_put_kw(:reply_to_message_id, reply_to_message_id)

    case LemonChannels.Telegram.Delivery.enqueue_send(chat_id, text, delivery_opts) do
      :ok ->
        :ok

      {:error, _reason} ->
        opts =
          %{}
          |> maybe_put("reply_to_message_id", reply_to_message_id)
          |> maybe_put("message_thread_id", thread_id)

        _ = state.api_mod.send_message(state.token, chat_id, text, opts, nil)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_message_ids(inbound) do
    chat_id = inbound.meta[:chat_id] || parse_int(inbound.peer.id)
    thread_id = parse_int(inbound.peer.thread_id)
    user_msg_id = inbound.meta[:user_msg_id] || parse_int(inbound.message.id)
    {chat_id, thread_id, user_msg_id}
  end

  defp cfg_get(cfg, key, default \\ nil) when is_atom(key) do
    cfg[key] || cfg[Atom.to_string(key)] || default
  end

  defp parse_int(nil), do: nil
  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_kw(opts, _key, nil) when is_list(opts), do: opts
  defp maybe_put_kw(opts, key, value) when is_list(opts), do: [{key, value} | opts]
end
