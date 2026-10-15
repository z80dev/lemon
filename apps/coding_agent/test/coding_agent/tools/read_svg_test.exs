defmodule CodingAgent.Tools.ReadSvgTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Read
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{ImageContent, TextContent}

  @moduletag :tmp_dir
  @svg ~s(<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"><rect width="2" height="2" fill="red"/></svg>)
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jDnoAAAAASUVORK5CYII="
       )

  test "SVG remains editable text by default", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.SVG")
    File.write!(path, @svg)

    assert %AgentToolResult{content: [%TextContent{text: text}], details: %{snapshot: tag}} =
             read(path, dir)

    assert is_binary(tag)
    assert text =~ @svg
  end

  test "SVGZ decodes to immutable text and supports selectors", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.svgz")
    File.write!(path, :zlib.gzip(@svg <> "\n<!-- second -->"))

    assert %AgentToolResult{content: [%TextContent{text: text}], details: %{immutable: true}} =
             read(path, dir)

    assert text =~ @svg

    assert %AgentToolResult{content: [%TextContent{text: "<!-- second -->"}]} =
             read(path <> ":2:raw", dir)
  end

  test "SVGZ decoding is bounded and malformed gzip errors", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.svgz")
    File.write!(path, :zlib.gzip(String.duplicate("a", 100_000)))
    assert {:error, error} = read(path, dir, format_max_member_bytes: 100)
    assert error =~ "size limit"
    File.write!(path, "invalid")
    assert {:error, error} = read(path, dir)
    assert error =~ "invalid gzip"
    compressed = :zlib.gzip(@svg)
    File.write!(path, binary_part(compressed, 0, byte_size(compressed) - 8))
    assert {:error, error} = read(path, dir)
    assert error =~ "invalid gzip"
  end

  test "img returns PNG bytes using an injected rasterizer executable for SVG and SVGZ", %{
    tmp_dir: dir
  } do
    executable = stub(dir, "printf '%s' '#{Base.encode64(@png)}' | /usr/bin/base64 -d")

    for extension <- ["svg", "svgz"] do
      path = Path.join(dir, "drawing." <> extension)
      File.write!(path, if(extension == "svgz", do: :zlib.gzip(@svg), else: @svg))

      assert %AgentToolResult{
               trust: :untrusted,
               content: [%ImageContent{data: data, mime_type: "image/png"}],
               details: details
             } = read(path <> ":img", dir, svg_rasterizer: executable)

      assert Base.decode64!(data) == @png
      assert details.path == path
    end
  end

  test "missing rasterizer gives installation guidance", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.svg")
    File.write!(path, @svg)
    assert {:error, error} = read(path <> ":img", dir, svg_rasterizer: nil)
    assert error =~ "rsvg-convert"
    assert error =~ "Install librsvg"
  end

  test "img rejects non-SVG files and incompatible selectors", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.png")
    File.write!(path, @png)
    assert {:error, error} = read(path <> ":img", dir)
    assert error =~ "only supported for SVG"
    assert {:error, _} = read(path <> ":img:raw", dir)
  end

  test "literal img filenames take precedence", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.svg:img")
    File.write!(path, "literal filename")
    assert %AgentToolResult{content: [%TextContent{text: text}]} = read(path, dir)
    assert text =~ "literal filename"
  end

  test "rasterization enforces output and time limits", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.svg")
    File.write!(path, @svg)
    executable = stub(dir, "printf 'xxxxxxxxxxxxxxxxxxxx'")

    assert {:error, error} =
             read(path <> ":img", dir, svg_rasterizer: executable, image_max_bytes: 10)

    assert error =~ "exceeds"
    executable = stub(dir, "exec /bin/sleep 2")

    assert {:error, error} =
             read(path <> ":img", dir, svg_rasterizer: executable, svg_timeout_ms: 10)

    assert error =~ "timed out"
  end

  @tag :rsvg_convert
  test "real rsvg-convert produces a PNG", %{tmp_dir: dir} do
    path = Path.join(dir, "drawing.svg")
    File.write!(path, @svg)

    assert %AgentToolResult{content: [%ImageContent{mime_type: "image/png"}]} =
             read(path <> ":img", dir)
  end

  defp read(path, dir, opts \\ []),
    do: Read.execute("svg", %{"path" => path}, nil, nil, dir, opts)

  defp stub(dir, body) do
    path = Path.join(dir, "rasterizer")
    File.write!(path, "#!/bin/sh\n" <> body <> "\n")
    File.chmod!(path, 0o700)
    path
  end
end
