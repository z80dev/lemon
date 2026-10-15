defmodule CodingAgent.Tools.ReadSvg do
  @moduledoc false

  alias CodingAgent.Tools.{ReadFormatCommand, ReadFormats, ReadFormatText}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.ImageContent
  import LemonAgent.Tools.AbortHelpers, only: [check_abort: 1]

  def supported?(path), do: String.downcase(Path.extname(path)) in [".svg", ".svgz"]

  def text(path, params, signal, opts) do
    with {:ok, bytes} <- source(path, signal, opts) do
      ReadFormatText.result(bytes, path, params, signal, opts, %{format: :svg, immutable: true})
    end
  end

  def image(path, signal, cwd, opts) do
    if supported?(path) do
      with {:ok, executable} <- backend(cwd, opts),
           {:ok, bytes} <- source(path, signal, opts) do
        rasterize(path, bytes, executable, signal, opts)
      end
    else
      {:error, ":img is only supported for SVG/SVGZ paths; read raster images without :img"}
    end
  end

  defp backend(cwd, opts) do
    executable =
      if Keyword.has_key?(opts, :svg_rasterizer),
        do: ReadFormatCommand.operator_executable(opts[:svg_rasterizer], cwd),
        else: ReadFormatCommand.system_executable("rsvg-convert", cwd)

    if executable,
      do: {:ok, executable},
      else:
        {:error,
         "SVG :img requires rsvg-convert. Install librsvg (brew install librsvg or apt install librsvg2-bin)."}
  end

  defp source(path, signal, opts) do
    with :ok <- check_abort(signal),
         :ok <- ReadFormats.check_input(path, opts),
         {:ok, bytes} <- File.read(path) do
      if String.downcase(Path.extname(path)) == ".svgz",
        do: gunzip(bytes, signal, Keyword.get(opts, :format_max_member_bytes, 32 * 1024 * 1024)),
        else: {:ok, bytes}
    end
  end

  defp gunzip(bytes, signal, limit) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31)

      with {:ok, content} <- inflate(z, bytes, signal, limit, []) do
        :ok = :zlib.inflateEnd(z)
        {:ok, content}
      end
    rescue
      ErlangError -> {:error, "Cannot decode SVGZ: invalid gzip data"}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, bytes, signal, remaining, chunks) do
    with :ok <- check_abort(signal) do
      {status, output} = :zlib.safeInflate(z, bytes)
      size = IO.iodata_length(output)

      cond do
        size > remaining ->
          {:error,
           "Decoded SVGZ exceeds the rich-read member size limit (:format_max_member_bytes)"}

        status == :finished ->
          {:ok, IO.iodata_to_binary(Enum.reverse([output | chunks]))}

        size == 0 ->
          {:error, "Cannot decode SVGZ: incomplete gzip data"}

        true ->
          inflate(z, <<>>, signal, remaining - size, [output | chunks])
      end
    end
  end

  defp rasterize(path, bytes, executable, signal, opts) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "lemon-read-svg-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}"
      )

    with :ok <- File.mkdir(directory) do
      try do
        source = Path.join(directory, "source.svg")
        dimension = Integer.to_string(Keyword.get(opts, :image_max_dimension, 1568))

        with :ok <- File.chmod(directory, 0o700),
             :ok <- File.write(source, bytes),
             {:ok, png} <-
               ReadFormatCommand.run(
                 executable,
                 [
                   "--format=png",
                   "--keep-aspect-ratio",
                   "--width",
                   dimension,
                   "--height",
                   dimension,
                   source
                 ],
                 signal,
                 timeout_ms: Keyword.get(opts, :svg_timeout_ms, 30_000),
                 max_bytes: Keyword.get(opts, :image_max_bytes, 4 * 1024 * 1024)
               ),
             :ok <- validate_png(png) do
          {:ok,
           %AgentToolResult{
             content: [%ImageContent{data: Base.encode64(png), mime_type: "image/png"}],
             details: %{
               format: :image,
               path: path,
               source_path: path,
               full_source: path,
               mime_type: "image/png",
               size: byte_size(png),
               backend: :rsvg_convert,
               immutable: true
             }
           }}
        end
      after
        File.rm_rf(directory)
      end
    end
  end

  defp validate_png(<<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: :ok
  defp validate_png(_), do: {:error, "SVG rasterizer did not return PNG data"}
end
