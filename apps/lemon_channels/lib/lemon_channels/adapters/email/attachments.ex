defmodule LemonChannels.Adapters.Email.Attachments do
  @moduledoc """
  Persists inbound email attachments to disk and describes them for the agent.

  ## Shape of the work

  `prepare/1` runs on the request path and is deliberately cheap: it decides a
  target path, sanitizes the filename and applies the size cap, but writes
  nothing. It returns metadata plus a list of write thunks, and `schedule/1`
  runs those in a background task. The provider's webhook therefore gets its
  response back without waiting on file I/O, while the path in the metadata is
  already valid — the run that reads it is queued behind scheduling and
  engine startup, which is the buffer this relies on.

  ## What is refused

  An attachment over the cap is dropped with a warning rather than truncated.
  The cap defaults to three quarters of `LemonChannels.InboundHttp.max_body_bytes/0`
  rather than to a number of its own, because the two limits are not
  independent: an attachment arrives base64-encoded, taking about a third more
  space on the wire than decoded, so anything larger than that fraction of the
  body limit is unreachable — the request is rejected with a 413 before this
  code ever sees it. Deriving it means raising the body limit raises the
  attachment cap with it, and a cap that promises more than the listener will
  accept cannot be configured by accident. Override deliberately with:

      config :lemon_channels, LemonChannels.Adapters.Email, attachment_max_bytes: n

  Filenames are reduced to their basename with everything outside
  `[A-Za-z0-9._-]` replaced — an attachment name is attacker-controlled, and it
  is about to become a path. Written files are chmod 0600 on Unix, since they
  can contain anything someone chose to mail an agent.

  Attachments that are only a URL are passed through undownloaded: fetching a
  remote URL named by an unauthenticated sender is a request forgery this
  adapter should not make on its own.
  """

  require Logger

  alias LemonChannels.Adapters.Email.Config
  alias LemonChannels.InboundHttp

  @attachments_dir "lemon_channels_email_attachments"

  @type meta :: %{
          filename: binary(),
          content_type: binary() | nil,
          path: binary() | nil,
          url: binary() | nil,
          bytes: non_neg_integer() | nil
        }

  @doc """
  Splits raw attachments into metadata and deferred writes.

  Anything unrecognized, oversized or empty is dropped, so the returned lists
  can be shorter than the input.
  """
  @spec prepare(term()) :: {[meta()], [(-> any())]}
  def prepare(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&prepare_one/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.unzip()
    |> case do
      {metas, writes} -> {metas, Enum.reject(writes, &is_nil/1)}
    end
  end

  def prepare(_attachments), do: {[], []}

  @doc "Runs deferred writes off the request path. Always returns `:ok`."
  @spec schedule([(-> any())]) :: :ok
  def schedule([]), do: :ok

  def schedule(writes) when is_list(writes) do
    _ = Task.start(fn -> Enum.each(writes, & &1.()) end)
    :ok
  end

  def schedule(_writes), do: :ok

  @doc "One human-readable line per attachment, for the prompt the agent sees."
  @spec describe([meta()]) :: [binary()]
  def describe(metas) when is_list(metas) do
    Enum.map(metas, fn meta ->
      name = meta[:filename] || "attachment"
      type = meta[:content_type] || "application/octet-stream"
      location = meta[:path] || meta[:url] || "(unavailable)"
      size = if is_integer(meta[:bytes]), do: "#{meta[:bytes]} bytes", else: "size unknown"

      "- #{name} (#{type}, #{size}) at #{location}"
    end)
  end

  def describe(_metas), do: []

  defp prepare_one(%Plug.Upload{} = upload) do
    prepare_one(%{
      "upload" => upload,
      "filename" => upload.filename,
      "content_type" => upload.content_type
    })
  end

  defp prepare_one(attachment) when is_map(attachment) do
    upload = upload_in(attachment)

    filename =
      sanitize_filename(value(attachment, [:filename, :name, :file_name]) || upload_name(upload))

    content_type = Config.blank_to_nil(value(attachment, [:content_type, :mime_type, :type]))
    url = Config.blank_to_nil(value(attachment, [:url, :href]))
    data = decode(value(attachment, [:content, :data, :content_base64, :base64, :body]))

    cond do
      not is_nil(upload) ->
        prepare_upload(upload, filename, content_type, url)

      is_binary(data) and byte_size(data) > max_bytes() ->
        Logger.warning("email attachment dropped: #{filename} exceeds the size cap")
        nil

      is_binary(data) ->
        target = target_path(filename)

        {%{
           filename: filename,
           content_type: content_type,
           path: target,
           url: url,
           bytes: byte_size(data)
         }, fn -> write(target, data) end}

      is_binary(url) ->
        {%{filename: filename, content_type: content_type, path: nil, url: url, bytes: nil}, nil}

      true ->
        nil
    end
  end

  defp prepare_one(url) when is_binary(url) do
    case Config.blank_to_nil(url) do
      nil -> nil
      value -> prepare_one(%{"url" => value})
    end
  end

  defp prepare_one(_attachment), do: nil

  # A multipart POST arrives as a Plug.Upload already spooled to a temp file
  # that Plug deletes when the request process exits, so the bytes have to be
  # copied somewhere durable before the response goes out.
  defp prepare_upload(%Plug.Upload{path: path} = upload, filename, content_type, url)
       when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= 0 ->
        nil

      {:ok, %File.Stat{size: size}} ->
        if size > max_bytes() do
          Logger.warning("email attachment dropped: #{filename} exceeds the size cap")
          nil
        else
          target = target_path(filename)

          {%{
             filename: filename,
             content_type: content_type || Config.blank_to_nil(upload.content_type),
             path: target,
             url: url,
             bytes: size
           }, fn -> copy(path, target) end}
        end

      {:error, reason} ->
        Logger.warning("email attachment dropped: #{filename} unreadable (#{inspect(reason)})")
        nil
    end
  end

  defp prepare_upload(_upload, _filename, _content_type, _url), do: nil

  defp upload_in(attachment) do
    case value(attachment, [:upload, :file, :attachment]) do
      %Plug.Upload{} = upload -> upload
      _ -> nil
    end
  end

  defp upload_name(%Plug.Upload{filename: filename}), do: filename
  defp upload_name(_upload), do: nil

  defp value(attachment, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(attachment, key) do
        {:ok, value} -> value
        :error -> Map.get(attachment, Atom.to_string(key))
      end
    end)
  end

  # Providers send either raw bytes or base64, and do not reliably say which.
  defp decode(nil), do: nil

  defp decode(data) when is_binary(data) do
    trimmed = String.trim(data)

    cond do
      trimmed == "" -> nil
      likely_base64?(trimmed) -> decode_base64(trimmed) || data
      true -> data
    end
  end

  defp decode(_data), do: nil

  defp decode_base64(data) do
    if byte_size(data) <= max_bytes() * 4 do
      case Base.decode64(data, ignore: :whitespace) do
        {:ok, decoded} -> decoded
        :error -> nil
      end
    end
  end

  defp likely_base64?(value) do
    byte_size(value) > 20 and Regex.match?(~r/\A[A-Za-z0-9+\/=\r\n]+\z/, value)
  end

  defp copy(source, target) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.cp(source, target) do
      restrict(target)
    else
      {:error, reason} ->
        Logger.warning("email attachment copy failed: #{inspect(reason)}")
    end
  end

  defp write(target, data) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target, data) do
      restrict(target)
    else
      {:error, reason} ->
        Logger.warning("email attachment write failed: #{inspect(reason)}")
    end
  end

  defp restrict(target) do
    if match?({:unix, _}, :os.type()), do: File.chmod(target, 0o600), else: :ok
  end

  defp target_path(filename) do
    unique = "#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"

    System.tmp_dir!()
    |> Path.join(@attachments_dir)
    |> Path.join("#{unique}_#{filename}")
  end

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> case do
      "" -> "attachment.bin"
      value -> value
    end
  end

  defp sanitize_filename(_name), do: "attachment.bin"

  defp max_bytes do
    case Config.get() |> Config.first_defined([:attachment_max_bytes]) do
      value when is_integer(value) and value > 0 -> value
      _ -> div(InboundHttp.max_body_bytes() * 3, 4)
    end
  end
end
