defmodule CodingAgent.Tools.ReadImage do
  @moduledoc """
  Native model-image previews using the real macOS `sips` backend.

  Inspects actual pixel dimensions and proportionally downsizes previews to
  `:image_max_dimension` (1568) and `:image_max_bytes` (4 MiB). JPEG stays JPEG;
  other supported formats use PNG when a conversion is needed. Original small
  images retain their bytes. Generated previews live in a unique temporary
  directory removed after the result is encoded; the source is never overwritten.
  Animated images that need conversion may become a first-frame preview, which
  is explicitly reported both to the model and in result metadata. If no backend exists, images up to
  20 MiB return `:not_supported` for the caller's real native-image fallback;
  oversized images return actionable guidance. Never pretends to resize.
  `backend/0` allows callers to check preview availability.
  """

  alias CodingAgent.Tools.{ReadFormats, ReadFormatCommand}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{ImageContent, TextContent}
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  @types %{
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".png" => "image/png",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  def supported?(path), do: Map.has_key?(@types, String.downcase(Path.extname(path)))

  # Only absolute operator PATH entries outside the session project (and its
  # ancestor `.lemon` trees, including symlink targets) may supply `sips`.
  def backend(cwd) do
    case ReadFormatCommand.system_executable("sips", cwd) do
      nil ->
        {:error,
         "Bounded image previews require macOS sips. Install a supported image backend or resize externally to at most 1568 pixels and 4 MiB before reading."}

      executable ->
        {:ok, %{name: :sips, executable: executable}}
    end
  end

  def read(path, _params, signal, cwd, opts) do
    with :ok <- check_abort(signal),
         :ok <- ReadFormats.check_input(path, opts),
         {:ok, stat} <- File.stat(path) do
      case backend(cwd) do
        {:ok, backend} ->
          read_with_backend(path, stat, backend.executable, signal, opts)

        {:error, _} when stat.size <= 20 * 1024 * 1024 ->
          :not_supported

        {:error, message} ->
          {:error, "Image exceeds the 20 MiB original-image limit. " <> message}
      end
    end
  end

  defp read_with_backend(path, stat, executable, signal, opts) do
    with {:ok, dimensions} <- dimensions(executable, path, signal) do
      max_dimension = Keyword.get(opts, :image_max_dimension, 1568)
      max_bytes = Keyword.get(opts, :image_max_bytes, 4 * 1024 * 1024)
      resize? = max(dimensions.width, dimensions.height) > max_dimension or stat.size > max_bytes

      if resize? do
        preview(path, dimensions, stat.size, executable, signal, max_dimension, max_bytes)
      else
        with {:ok, bytes} <- File.read(path), :ok <- check_abort(signal) do
          result(
            path,
            bytes,
            @types[String.downcase(Path.extname(path))],
            dimensions,
            dimensions,
            false,
            stat.size
          )
        end
      end
    end
  end

  defp preview(path, original, original_size, executable, signal, max_dimension, max_bytes) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "lemon-read-image-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    with :ok <- File.mkdir(directory),
         :ok <- File.chmod(directory, 0o700) do
      try do
        jpeg? = String.downcase(Path.extname(path)) in [".jpg", ".jpeg"]
        format = if jpeg?, do: "jpeg", else: "png"
        target = Path.join(directory, "preview." <> if(jpeg?, do: "jpg", else: "png"))
        initial = min(max_dimension, max(original.width, original.height))

        with {:ok, bytes, dimensions} <-
               resize(executable, path, target, format, initial, max_bytes, signal) do
          result(
            path,
            bytes,
            if(jpeg?, do: "image/jpeg", else: "image/png"),
            original,
            dimensions,
            true,
            original_size
          )
        end
      after
        File.rm_rf(directory)
      end
    else
      {:error, reason} -> {:error, "Cannot create image preview workspace: #{reason}"}
    end
  end

  defp resize(executable, source, target, format, dimension, max_bytes, signal) do
    args = ["-s", "format", format, "-Z", Integer.to_string(dimension), source, "--out", target]

    with {:ok, _} <- ReadFormatCommand.run(executable, args, signal, max_bytes: 64 * 1024),
         {:ok, bytes} <- File.read(target),
         {:ok, dimensions} <- dimensions(executable, target, signal) do
      if byte_size(bytes) <= max_bytes do
        {:ok, bytes, dimensions}
      else
        next =
          min(dimension - 1, trunc(dimension * :math.sqrt(max_bytes / byte_size(bytes)) * 0.9))

        if next < 1 do
          {:error,
           "Image preview cannot fit the #{max_bytes}-byte image budget. Increase :image_max_bytes."}
        else
          resize(executable, source, target, format, next, max_bytes, signal)
        end
      end
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "Cannot read generated image preview: #{reason}"}

      {:error, reason} ->
        {:error,
         "Image preview failed: #{reason}. Resize or convert the source with a supported image backend."}
    end
  end

  defp dimensions(executable, path, signal) do
    with {:ok, output} <-
           ReadFormatCommand.run(
             executable,
             ["-g", "pixelWidth", "-g", "pixelHeight", path],
             signal,
             max_bytes: 64 * 1024
           ) do
      width = property(output, "pixelWidth")
      height = property(output, "pixelHeight")

      if width && height && width > 0 && height > 0 do
        {:ok, %{width: width, height: height}}
      else
        {:error,
         "Image backend cannot decode pixel dimensions for #{path}. Convert to PNG or JPEG externally."}
      end
    end
  end

  defp property(output, key) do
    case Regex.scan(Regex.compile!("^\\s+" <> key <> ":\\s+(\\d+)\\s*$", "m"), output,
           capture: :all_but_first
         )
         |> List.last() do
      [value] -> String.to_integer(value)
      _ -> nil
    end
  end

  defp result(path, bytes, mime, original, dimensions, resized, original_size) do
    description =
      "Image #{original.width}×#{original.height}; model preview #{dimensions.width}×#{dimensions.height}, #{byte_size(bytes)} bytes." <>
        if(resized,
          do:
            " Proportionally resized preview; animated sources may show only the first frame. Original: #{path}",
          else: ""
        )

    {:ok,
     %AgentToolResult{
       content: [
         %TextContent{text: description},
         %ImageContent{data: Base.encode64(bytes), mime_type: mime}
       ],
       details: %{
         format: :image,
         path: path,
         source_path: path,
         full_source: path,
         original_width: original.width,
         original_height: original.height,
         width: dimensions.width,
         height: dimensions.height,
         original_size: original_size,
         size: byte_size(bytes),
         mime_type: mime,
         resized: resized,
         backend: :sips,
         description: description,
         animation: if(resized, do: :possibly_first_frame, else: :original)
       }
     }}
  end
end
