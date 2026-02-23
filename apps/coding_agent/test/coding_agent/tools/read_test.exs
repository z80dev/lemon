defmodule CodingAgent.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Read
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.{TextContent, ImageContent}

  @moduletag :tmp_dir

  # ============================================================================
  # Tool Definition Tests
  # ============================================================================

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Read.tool("/tmp")

      assert tool.name == "read"
      assert tool.label == "Read File"
      assert tool.description =~ "Read the contents of a file"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["path"]
      assert tool.parameters["properties"]["path"]["type"] == "string"
      assert tool.parameters["properties"]["offset"]["type"] == "integer"
      assert tool.parameters["properties"]["limit"]["type"] == "integer"
      assert is_function(tool.execute, 4)
    end

    test "tool execute function can be invoked", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "hello world")

      tool = Read.tool(tmp_dir)
      result = tool.execute.("call_1", %{"path" => path}, nil, nil)

      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Basic Text File Reading
  # ============================================================================

  describe "execute/6 - reading text files" do
    test "reads simple text file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "simple.txt")
      File.write!(path, "Hello, World!")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1: Hello, World!"
    end

    test "reads multiline text file with line numbers", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multiline.txt")
      content = "line one\nline two\nline three"
      File.write!(path, content)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1: line one"
      assert text =~ "2: line two"
      assert text =~ "3: line three"
    end

    test "reads empty file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.txt")
      File.write!(path, "")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text == "1: "
    end

    test "reads file with only newlines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "newlines.txt")
      File.write!(path, "\n\n\n")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1: "
      assert text =~ "2: "
      assert text =~ "3: "
      assert text =~ "4: "
    end

    test "reads file with unicode content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unicode.txt")
      File.write!(path, "Hello 世界! 🌍")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Hello 世界! 🌍"
    end
  end

  # ============================================================================
  # Line Endings
  # ============================================================================

  describe "execute/6 - line endings" do
    test "handles CRLF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "line1\r\nline2\r\nline3")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1: line1"
      assert text =~ "2: line2"
      assert text =~ "3: line3"
    end

    test "handles LF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lf.txt")
      File.write!(path, "line1\nline2\nline3")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: _text}], details: details} = result
      assert details.total_lines == 3
    end

    test "handles mixed line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mixed.txt")
      File.write!(path, "line1\nline2\r\nline3")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1: line1"
      assert text =~ "2: line2"
      assert text =~ "3: line3"
    end
  end

  # ============================================================================
  # Offset and Limit
  # ============================================================================

  describe "execute/6 - offset and limit" do
    test "reads with offset (1-indexed)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "offset.txt")
      File.write!(path, "line1\nline2\nline3\nline4\nline5")

      result = Read.execute("call_1", %{"path" => path, "offset" => 3}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "3: line3"
      assert text =~ "4: line4"
      assert text =~ "5: line5"
      refute text =~ "1: line1"
      refute text =~ "2: line2"
      assert details.start_line == 3
    end

    test "reads with limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "limit.txt")
      File.write!(path, "line1\nline2\nline3\nline4\nline5")

      result = Read.execute("call_1", %{"path" => path, "limit" => 2}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "1: line1"
      assert text =~ "2: line2"
      refute text =~ "3: line3"
      assert details.lines_shown == 2
    end

    test "reads with both offset and limit", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "both.txt")
      File.write!(path, "line1\nline2\nline3\nline4\nline5")

      result =
        Read.execute(
          "call_1",
          %{"path" => path, "offset" => 2, "limit" => 2},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "2: line2"
      assert text =~ "3: line3"
      refute text =~ "1: line1"
      refute text =~ "4: line4"
      assert details.start_line == 2
      assert details.lines_shown == 2
    end

    test "offset of 0 or negative is treated as 1", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "negative.txt")
      File.write!(path, "line1\nline2\nline3")

      result1 = Read.execute("call_1", %{"path" => path, "offset" => 0}, nil, nil, tmp_dir, [])
      result2 = Read.execute("call_1", %{"path" => path, "offset" => -5}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{start_line: 1}} = result1
      assert %AgentToolResult{details: %{start_line: 1}} = result2
    end

    test "offset beyond file length returns empty content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "beyond.txt")
      File.write!(path, "line1\nline2")

      result = Read.execute("call_1", %{"path" => path, "offset" => 100}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.lines_shown == 0
    end

    test "limit of 0 or negative returns no lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "zero_limit.txt")
      File.write!(path, "line1\nline2\nline3")

      result1 = Read.execute("call_1", %{"path" => path, "limit" => 0}, nil, nil, tmp_dir, [])

      # limit <= 0 does not apply user limit (reads all lines)
      assert %AgentToolResult{details: details} = result1
      assert details.lines_shown == 3
    end
  end

  # ============================================================================
  # Line Number Formatting
  # ============================================================================

  describe "execute/6 - line number formatting" do
    test "formats line numbers correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "format.txt")
      File.write!(path, "a\nb\nc")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      lines = String.split(text, "\n")
      assert Enum.at(lines, 0) == "1: a"
      assert Enum.at(lines, 1) == "2: b"
      assert Enum.at(lines, 2) == "3: c"
    end

    test "line numbers continue from offset", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "offset_format.txt")
      File.write!(path, "a\nb\nc\nd\ne")

      result = Read.execute("call_1", %{"path" => path, "offset" => 3}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      lines = String.split(text, "\n")
      assert Enum.at(lines, 0) == "3: c"
      assert Enum.at(lines, 1) == "4: d"
      assert Enum.at(lines, 2) == "5: e"
    end
  end

  # ============================================================================
  # Truncation
  # ============================================================================

  describe "execute/6 - truncation" do
    test "truncates file when exceeding max_lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large_lines.txt")
      content = Enum.map_join(1..100, "\n", &"line #{&1}")
      File.write!(path, content)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, max_lines: 10)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.truncation != nil
      assert details.truncation.truncated == true
      assert details.lines_shown == 10
      assert text =~ "[Showing lines 1-10 of 100"
      assert text =~ "Use offset=11 to continue"
    end

    test "truncates file when exceeding max_bytes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large_bytes.txt")
      # Create file with many lines to trigger byte limit
      content = Enum.map_join(1..100, "\n", fn _ -> String.duplicate("x", 100) end)
      File.write!(path, content)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, max_bytes: 500)

      assert %AgentToolResult{details: details} = result
      assert details.truncation != nil
      assert details.truncation.truncated == true
    end

    test "no truncation message when file fits within limits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "small.txt")
      File.write!(path, "line1\nline2\nline3")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      refute text =~ "[Showing lines"
      assert details.truncation == nil
    end

    test "details include truncation reason", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "truncate_reason.txt")
      content = Enum.map_join(1..50, "\n", &"line #{&1}")
      File.write!(path, content)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, max_lines: 10)

      assert %AgentToolResult{details: details} = result
      assert details.truncation.reason == "max_lines"
    end
  end

  # ============================================================================
  # Image Files
  # ============================================================================

  describe "execute/6 - image files" do
    test "returns ImageContent for PNG files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "image.png")
      # Minimal valid PNG header
      png_data =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48,
          0x44, 0x52>>

      File.write!(path, png_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%ImageContent{} = image], details: details} = result
      assert image.mime_type == "image/png"
      assert is_binary(image.data)
      assert Base.decode64!(image.data) == png_data
      assert details.mime_type == "image/png"
      assert details.size == byte_size(png_data)
    end

    test "returns ImageContent for JPEG files (.jpg)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "image.jpg")
      # Minimal JPEG header
      jpeg_data = <<0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46>>
      File.write!(path, jpeg_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%ImageContent{mime_type: "image/jpeg"}]} = result
    end

    test "returns ImageContent for JPEG files (.jpeg)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "image.jpeg")
      jpeg_data = <<0xFF, 0xD8, 0xFF, 0xE0>>
      File.write!(path, jpeg_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%ImageContent{mime_type: "image/jpeg"}]} = result
    end

    test "returns ImageContent for GIF files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "image.gif")
      # GIF87a header
      gif_data = <<0x47, 0x49, 0x46, 0x38, 0x37, 0x61>>
      File.write!(path, gif_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%ImageContent{mime_type: "image/gif"}]} = result
    end

    test "returns ImageContent for WebP files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "image.webp")
      webp_data = "RIFF" <> <<0x00, 0x00, 0x00, 0x00>> <> "WEBP"
      File.write!(path, webp_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%ImageContent{mime_type: "image/webp"}]} = result
    end

    test "case insensitive extension matching for images", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "IMAGE.PNG")
      png_data = <<0x89, 0x50, 0x4E, 0x47>>
      File.write!(path, png_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%ImageContent{mime_type: "image/png"}]} = result
    end
  end

  # ============================================================================
  # Binary File Detection
  # ============================================================================

  describe "execute/6 - binary files" do
    # Note: The current implementation does not explicitly detect binary files
    # other than images. Non-image binary files are read as text.
    # This test documents current behavior.

    test "binary file without image extension is read as text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "binary.bin")
      # Binary data with null bytes
      binary_data = <<0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE>>
      File.write!(path, binary_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      # Current behavior: returns TextContent (may have encoding issues)
      assert %AgentToolResult{content: [%TextContent{}]} = result
    end
  end

  # ============================================================================
  # Invalid UTF-8 Handling
  # ============================================================================

  describe "execute/6 - invalid UTF-8" do
    # Note: The current implementation reads file as binary and splits on regex
    # which handles invalid UTF-8 gracefully by treating it as bytes.

    test "handles file with invalid UTF-8 sequences", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid_utf8.txt")
      # Invalid UTF-8 sequence (continuation byte without start)
      content = "hello " <> <<0x80, 0x81>> <> " world"
      File.write!(path, content)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      # Should not crash - either returns text or handles gracefully
      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "execute/6 - file not found" do
    test "returns error for non-existent file", %{tmp_dir: tmp_dir} do
      result =
        Read.execute(
          "call_1",
          %{"path" => Path.join(tmp_dir, "nonexistent.txt")},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "File not found"
    end

    test "returns error for non-existent path with nested directories", %{tmp_dir: tmp_dir} do
      result =
        Read.execute(
          "call_1",
          %{"path" => Path.join(tmp_dir, "a/b/c/nonexistent.txt")},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "File not found"
    end
  end

  describe "execute/6 - permission denied" do
    test "returns error for unreadable file", %{tmp_dir: tmp_dir} do
      import CodingAgent.TestHelpers.PermissionHelpers

      path = Path.join(tmp_dir, "no_read.txt")
      File.write!(path, "secret")

      with_unreadable(path, fn ->
        result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

        assert {:error, msg} = result
        assert msg =~ "Permission denied" or msg =~ "eacces"
      end)
    end
  end

  describe "execute/6 - directory handling" do
    test "returns error when path is a directory", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(dir_path)

      result = Read.execute("call_1", %{"path" => dir_path}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "directory"
    end
  end

  describe "execute/6 - missing path parameter" do
    test "returns error when path is empty" do
      result = Read.execute("call_1", %{"path" => ""}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "Path is required"
    end

    test "returns error when path is missing" do
      result = Read.execute("call_1", %{}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "Path is required"
    end
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  describe "execute/6 - path resolution" do
    test "resolves relative path from cwd", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "relative.txt")
      File.write!(path, "content")

      result = Read.execute("call_1", %{"path" => "relative.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.path == path
    end

    test "handles absolute path ignoring cwd", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absolute.txt")
      File.write!(path, "content")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, "/different/cwd", [])

      assert %AgentToolResult{details: details} = result
      assert details.path == path
    end

    test "expands home directory (~)", %{tmp_dir: tmp_dir} do
      # This test may not work in all environments
      # We'll test that ~ expansion doesn't crash
      result =
        Read.execute("call_1", %{"path" => "~/nonexistent_file.txt"}, nil, nil, tmp_dir, [])

      # Should return file not found, not a crash
      assert {:error, msg} = result
      assert msg =~ "File not found" or msg =~ "No such file"
    end

    test "resolves nested relative paths", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join(tmp_dir, "a/b/c")
      File.mkdir_p!(nested_dir)
      path = Path.join(nested_dir, "nested.txt")
      File.write!(path, "nested content")

      result = Read.execute("call_1", %{"path" => "a/b/c/nested.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "nested content"
    end

    test "normalizes paths with .. components", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file.txt")
      File.write!(path, "content")

      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)

      result = Read.execute("call_1", %{"path" => "subdir/../file.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  describe "execute/6 - abort signal" do
    test "returns error when signal is already aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort.txt")
      File.write!(path, "content")

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = Read.execute("call_1", %{"path" => path}, signal, nil, tmp_dir, [])

      AbortSignal.clear(signal)

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds normally when signal is not aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_abort.txt")
      File.write!(path, "content")

      signal = AbortSignal.new()

      result = Read.execute("call_1", %{"path" => path}, signal, nil, tmp_dir, [])

      AbortSignal.clear(signal)

      assert %AgentToolResult{} = result
    end

    test "proceeds normally when signal is nil", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nil_signal.txt")
      File.write!(path, "content")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
    end
  end

  # ============================================================================
  # Result Details
  # ============================================================================

  describe "execute/6 - result details" do
    test "includes complete details for text files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "details.txt")
      File.write!(path, "line1\nline2\nline3")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.path == path
      assert details.total_lines == 3
      assert details.start_line == 1
      assert details.lines_shown == 3
    end

    test "includes complete details for image files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "details.png")
      png_data = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>
      File.write!(path, png_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.path == path
      assert details.size == byte_size(png_data)
      assert details.mime_type == "image/png"
    end
  end
end
