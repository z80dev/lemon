defmodule CodingAgent.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Read
  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.AbortSignal
  alias LemonAi.Types.{TextContent, ImageContent}

  @moduletag :tmp_dir

  # ============================================================================
  # Basic Text File Reading
  # ============================================================================

  describe "execute/6 - reading text files" do
    test "reads text through ACP client filesystem bridge", %{tmp_dir: tmp_dir} do
      run_id = unique_run_id("read")
      path = Path.join(tmp_dir, "client-buffer.txt")
      :ok = LemonCore.ACPClientBridge.register(run_id)

      task =
        Task.async(fn ->
          Read.execute(
            "call_1",
            %{"path" => path, "offset" => 2, "limit" => 1},
            nil,
            nil,
            tmp_dir,
            run_id: run_id,
            acp_client_fs_read_text_file: true
          )
        end)

      params =
        reply_acp_request("fs/read_text_file", %{
          "result" => %{"content" => "line two"}
        })

      assert params["path"] == path
      assert params["line"] == 2
      assert params["limit"] == 1

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
               Task.await(task)

      assert text =~ "2: line two"
      refute text =~ "line one"
      assert details.acp_client == true
    end

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
      assert text =~ "\n1: "
    end

    test "reads file with only newlines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "newlines.txt")
      File.write!(path, "\n\n\n")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "1: "
      assert text =~ "2: "
      assert text =~ "3: "
      refute text =~ "4: "
    end

    test "reads file with unicode content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unicode.txt")
      File.write!(path, "Hello 世界! 🌍")

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Hello 世界! 🌍"
    end

    test "caps a giant first line and keeps UTF-8 previews valid", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "long-line.txt")
      File.write!(path, String.duplicate("🌍", 100_000) <> "\nsecond")
      result = Read.execute("long", %{"path" => path}, nil, nil, tmp_dir, max_bytes: 101)
      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert String.valid?(text)
      assert byte_size(text |> String.split("\n") |> Enum.at(1)) <= 101
      assert details.total_lines == 2
      assert details.truncation.reason == "long_line"
      assert text =~ path

      assert %AgentToolResult{content: [%TextContent{text: next_text}]} =
               Read.execute("next", %{"path" => path, "offset" => 2}, nil, nil, tmp_dir, [])

      assert next_text =~ "\n2: second"
    end

    test "validates UTF-8 across chunk boundaries and retains the full-file digest", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "chunk-boundary.txt")
      content = String.duplicate("x", 65_535) <> "🌍\nsecond"
      File.write!(path, content)
      assert {:ok, window} = CodingAgent.Tools.ReadText.read(path, 1, 1, 10, 100, nil)
      assert window.lines == ["second"]
      assert window.digest == :erlang.md5(content)
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

    test "rejects non-positive offsets", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "negative.txt")
      File.write!(path, "line1\nline2\nline3")

      result1 = Read.execute("call_1", %{"path" => path, "offset" => 0}, nil, nil, tmp_dir, [])
      result2 = Read.execute("call_1", %{"path" => path, "offset" => -5}, nil, nil, tmp_dir, [])

      assert {:error, "offset must be a positive integer" <> _} = result1
      assert {:error, "offset must be a positive integer" <> _} = result2
    end

    test "offset beyond file length reports its bounds", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "beyond.txt")
      File.write!(path, "line1\nline2")

      result = Read.execute("call_1", %{"path" => path, "offset" => 100}, nil, nil, tmp_dir, [])

      assert {:error, message} = result
      assert message =~ "offset=100"
      assert message =~ "2 lines"
    end

    test "rejects non-positive limits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "zero_limit.txt")
      File.write!(path, "line1\nline2\nline3")

      result1 = Read.execute("call_1", %{"path" => path, "limit" => 0}, nil, nil, tmp_dir, [])

      assert {:error, "limit must be a positive integer" <> _} = result1
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
      lines = text |> String.split("\n") |> Enum.drop(1)
      assert Enum.at(lines, 0) == "1: a"
      assert Enum.at(lines, 1) == "2: b"
      assert Enum.at(lines, 2) == "3: c"
    end

    test "line numbers continue from offset", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "offset_format.txt")
      File.write!(path, "a\nb\nc\nd\ne")

      result = Read.execute("call_1", %{"path" => path, "offset" => 3}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      lines = text |> String.split("\n") |> Enum.drop(1)
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
    test "returns real native PNG bytes with case-insensitive extension", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "IMAGE.PNG")

      png_data =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jDnoAAAAASUVORK5CYII="
        )

      File.write!(path, png_data)

      assert %AgentToolResult{content: content, details: details} =
               Read.execute("image", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %ImageContent{} = image = Enum.find(content, &match?(%ImageContent{}, &1))
      assert image.mime_type == "image/png"
      assert Base.decode64!(image.data) == png_data
      assert details.size == byte_size(png_data)
      assert details.media_path == path
    end
  end

  describe "execute/6 - display-only media paths" do
    test "whole model reads and :raw expose the absolute source without changing content", %{
      tmp_dir: cwd
    } do
      for name <- ~w(scene.obj scene.GLB.GZ scene.3ds.gz image.svg) do
        path = Path.join(cwd, name)
        File.write!(path, "first\nsecond\nthird\n")

        assert %AgentToolResult{details: %{media_path: ^path}, content: content} =
                 Read.execute("whole", %{"path" => name}, nil, nil, cwd, [])

        assert Enum.any?(content, &match?(%TextContent{}, &1))

        assert %AgentToolResult{
                 details: %{media_path: ^path},
                 content: [%TextContent{text: text}]
               } =
                 Read.execute("raw", %{"path" => name <> ":raw"}, nil, nil, cwd, [])

        assert text == "first\nsecond\nthird"
      end
    end

    test "explicit source windows never advertise the whole media file", %{tmp_dir: cwd} do
      path = Path.join(cwd, "drawing.svg")
      File.write!(path, "first\nsecond\nthird\n")

      for selection <- [
            %{"offset" => 1},
            %{"limit" => 3},
            %{"page" => 1},
            %{"page_limit" => 1},
            %{"cell" => 1},
            %{"cell_limit" => 1},
            %{"path" => "drawing.svg:1"},
            %{"path" => "drawing.svg:1-2:raw"},
            %{"path" => "drawing.svg:1,3"},
            %{"path" => "drawing.svg:-1"}
          ] do
        params = Map.merge(%{"path" => "drawing.svg"}, selection)

        assert %AgentToolResult{details: details} =
                 Read.execute("partial", params, nil, nil, cwd, [])

        refute Map.has_key?(details, :media_path), inspect(selection)
      end
    end

    test "sidecars, unsupported gzip types, dotfiles and directories are not media", %{
      tmp_dir: cwd
    } do
      for name <- ~w(notes.txt scene.mtl image.png.gz scene.usdz.gz .png) do
        File.write!(Path.join(cwd, name), "ordinary text")

        assert %AgentToolResult{details: details} =
                 Read.execute("plain", %{"path" => name}, nil, nil, cwd, [])

        refute Map.has_key?(details, :media_path), name
      end

      File.mkdir!(Path.join(cwd, "folder.svg"))

      assert %AgentToolResult{details: details} =
               Read.execute("dir", %{"path" => "folder.svg"}, nil, nil, cwd, [])

      refute Map.has_key?(details, :media_path)
    end

    test "failed media reads retain their errors instead of a display receipt", %{tmp_dir: cwd} do
      assert {:error, _} =
               Read.execute("missing", %{"path" => "missing.png"}, nil, nil, cwd, [])

      File.write!(Path.join(cwd, "broken.glb"), <<0, 255>>)

      assert {:error, _} =
               Read.execute("binary", %{"path" => "broken.glb"}, nil, nil, cwd, [])
    end
  end

  # ============================================================================
  # Binary File Detection
  # ============================================================================

  describe "execute/6 - binary files" do
    test "binary file without image extension is refused", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "binary.bin")
      # Binary data with null bytes
      binary_data = <<0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE>>
      File.write!(path, binary_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert {:error, message} = result
      assert message =~ "binary"
      assert message =~ "bash"
    end
  end

  # ============================================================================
  # Invalid UTF-8 Handling
  # ============================================================================

  describe "execute/6 - invalid UTF-8" do
    test "handles file with invalid UTF-8 sequences", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid_utf8.txt")
      # Invalid UTF-8 sequence (continuation byte without start)
      content = "hello " <> <<0x80, 0x81>> <> " world"
      File.write!(path, content)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert {:error, message} = result
      assert message =~ "invalid UTF-8"
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
    test "lists directory entries through the read tool", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(dir_path)
      File.write!(Path.join(dir_path, "entry.txt"), "content")

      result = Read.execute("call_1", %{"path" => dir_path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "entry.txt"
      assert details.is_directory
      assert result.trust == :untrusted
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

      png_data =
        Base.decode64!(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jDnoAAAAASUVORK5CYII="
        )

      File.write!(path, png_data)

      result = Read.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.path == path
      assert details.size == byte_size(png_data)
      assert details.mime_type == "image/png"
    end
  end

  defp unique_run_id(prefix), do: "run_acp_#{prefix}_#{System.unique_integer([:positive])}"

  defp reply_acp_request(method, response) do
    receive do
      {:acp_client_request, %{method: ^method, params: params, reply_to: reply_to, ref: ref}} ->
        send(reply_to, {:acp_client_response, ref, response})
        params
    after
      1_000 -> flunk("timed out waiting for #{method}")
    end
  end
end
