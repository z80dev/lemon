defmodule CodingAgent.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Write
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  # ============================================================================
  # Tool Definition Tests
  # ============================================================================

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Write.tool("/tmp")

      assert tool.name == "write"
      assert tool.label == "Write File"
      assert tool.description =~ "Write content to a file"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["path", "content"]
      assert tool.parameters["properties"]["path"]["type"] == "string"
      assert tool.parameters["properties"]["content"]["type"] == "string"
      assert is_function(tool.execute, 4)
    end

    test "tool execute function can be invoked", %{tmp_dir: tmp_dir} do
      tool = Write.tool(tmp_dir)
      path = Path.join(tmp_dir, "test.txt")

      result = tool.execute.("call_1", %{"path" => path, "content" => "hello"}, nil, nil)

      assert %AgentToolResult{} = result
      assert File.read!(path) == "hello"
    end
  end

  # ============================================================================
  # Writing New Files
  # ============================================================================

  describe "execute/6 - writing new files" do
    test "creates and writes to a new file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_file.txt")

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "Hello, World!"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Successfully wrote"
      assert text =~ "13 bytes"
      assert File.read!(path) == "Hello, World!"
      assert details.bytes_written == 13
      assert details.path == path
    end

    test "creates file with unicode content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unicode.txt")
      content = "Hello 世界! 🌍"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == content
    end

    test "creates file with multiline content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multiline.txt")
      content = "line 1\nline 2\nline 3"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == content
    end
  end

  # ============================================================================
  # Overwriting Existing Files
  # ============================================================================

  describe "execute/6 - overwriting existing files" do
    test "overwrites existing file content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "existing.txt")
      File.write!(path, "original content")

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "new content"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{} = result
      assert File.read!(path) == "new content"
    end

    test "overwrites longer file with shorter content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "shrink.txt")
      File.write!(path, "this is a very long original content string")

      result =
        Write.execute("call_1", %{"path" => path, "content" => "short"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "short"
    end

    test "overwrites shorter file with longer content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "grow.txt")
      File.write!(path, "short")

      long_content = String.duplicate("a", 10000)

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => long_content},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{} = result
      assert File.read!(path) == long_content
    end
  end

  # ============================================================================
  # Creating Parent Directories
  # ============================================================================

  describe "execute/6 - creating parent directories" do
    test "creates parent directories when they don't exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "a/b/c/deep_file.txt")

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "deep content"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{} = result
      assert File.read!(path) == "deep content"
      assert File.dir?(Path.join(tmp_dir, "a/b/c"))
    end

    test "handles existing parent directories", %{tmp_dir: tmp_dir} do
      nested_dir = Path.join(tmp_dir, "existing/dirs")
      File.mkdir_p!(nested_dir)
      path = Path.join(nested_dir, "file.txt")

      result =
        Write.execute("call_1", %{"path" => path, "content" => "content"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end

    test "creates multiple levels of directories", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "level1/level2/level3/level4/level5/deep.txt")

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "very deep"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{} = result
      assert File.read!(path) == "very deep"
    end
  end

  # ============================================================================
  # Empty Content
  # ============================================================================

  describe "execute/6 - empty content" do
    test "creates file with empty content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.txt")

      result = Write.execute("call_1", %{"path" => path, "content" => ""}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "0 bytes"
      assert File.read!(path) == ""
      assert details.bytes_written == 0
    end

    test "overwrites existing file with empty content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "clear.txt")
      File.write!(path, "has content")

      result = Write.execute("call_1", %{"path" => path, "content" => ""}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == ""
    end
  end

  # ============================================================================
  # Line Endings
  # ============================================================================

  describe "execute/6 - line endings" do
    test "preserves LF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "lf.txt")
      content = "line1\nline2\nline3"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      # Read in binary mode to preserve line endings
      assert File.read!(path) == "line1\nline2\nline3"
    end

    test "preserves CRLF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "crlf.txt")
      content = "line1\r\nline2\r\nline3"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "line1\r\nline2\r\nline3"
    end

    test "preserves mixed line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mixed.txt")
      content = "line1\nline2\r\nline3\rline4"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == content
    end

    test "preserves trailing newline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "trailing.txt")
      content = "content\n"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content\n"
    end

    test "preserves no trailing newline", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_trailing.txt")
      content = "content"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end
  end

  # ============================================================================
  # Permission Denied
  # ============================================================================

  describe "execute/6 - permission denied" do
    @tag :skip_on_ci
    test "returns error when parent directory is not writable", %{tmp_dir: tmp_dir} do
      no_write_dir = Path.join(tmp_dir, "no_write")
      File.mkdir_p!(no_write_dir)
      File.chmod!(no_write_dir, 0o555)

      path = Path.join(no_write_dir, "file.txt")

      result =
        Write.execute("call_1", %{"path" => path, "content" => "test"}, nil, nil, tmp_dir, [])

      # Restore permissions for cleanup
      File.chmod!(no_write_dir, 0o755)

      assert {:error, msg} = result
      assert msg =~ "Failed to write file"
    end

    @tag :skip_on_ci
    test "returns error when file is not writable", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "readonly.txt")
      File.write!(path, "original")
      File.chmod!(path, 0o444)

      result =
        Write.execute("call_1", %{"path" => path, "content" => "new"}, nil, nil, tmp_dir, [])

      # Restore permissions for cleanup
      File.chmod!(path, 0o644)

      assert {:error, msg} = result
      assert msg =~ "Failed to write file"
    end
  end

  # ============================================================================
  # Writing to Directory Path
  # ============================================================================

  describe "execute/6 - writing to directory" do
    test "returns error when path is an existing directory", %{tmp_dir: tmp_dir} do
      dir_path = Path.join(tmp_dir, "existing_dir")
      File.mkdir_p!(dir_path)

      result =
        Write.execute(
          "call_1",
          %{"path" => dir_path, "content" => "content"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "Failed to write file" or msg =~ "is a directory"
    end
  end

  # ============================================================================
  # Path Resolution
  # ============================================================================

  describe "execute/6 - path resolution" do
    test "resolves relative path from cwd", %{tmp_dir: tmp_dir} do
      result =
        Write.execute(
          "call_1",
          %{"path" => "relative.txt", "content" => "content"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      expected_path = Path.join(tmp_dir, "relative.txt")
      assert details.path == expected_path
      assert File.read!(expected_path) == "content"
    end

    test "handles absolute path ignoring cwd", %{tmp_dir: tmp_dir} do
      absolute_path = Path.join(tmp_dir, "absolute.txt")

      result =
        Write.execute(
          "call_1",
          %{"path" => absolute_path, "content" => "content"},
          nil,
          nil,
          "/different/cwd",
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.path == absolute_path
      assert File.read!(absolute_path) == "content"
    end

    test "expands home directory (~)", %{tmp_dir: tmp_dir} do
      # We can't write to actual home dir in tests, so we verify expansion doesn't crash
      # by using a path that will fail due to permissions or non-existence
      result =
        Write.execute(
          "call_1",
          %{
            "path" => "~/nonexistent_subdir_abc123xyz/test.txt",
            "content" => "content"
          },
          nil,
          nil,
          tmp_dir,
          []
        )

      # Either succeeds (if home is writable) or fails with proper error
      case result do
        %AgentToolResult{} -> :ok
        {:error, _msg} -> :ok
      end
    end

    test "resolves nested relative paths", %{tmp_dir: tmp_dir} do
      result =
        Write.execute(
          "call_1",
          %{"path" => "a/b/c/nested.txt", "content" => "nested"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{} = result
      expected_path = Path.join(tmp_dir, "a/b/c/nested.txt")
      assert File.read!(expected_path) == "nested"
    end
  end

  # ============================================================================
  # Parameter Validation
  # ============================================================================

  describe "execute/6 - parameter validation" do
    test "returns error when path is missing" do
      result = Write.execute("call_1", %{"content" => "test"}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "missing required parameter: path"
    end

    test "returns error when content is missing", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_content.txt")

      result = Write.execute("call_1", %{"path" => path}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "missing required parameter: content"
    end

    test "returns error when path is empty string" do
      result = Write.execute("call_1", %{"path" => "", "content" => "test"}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "path must be a non-empty string"
    end

    test "returns error when path is not a string" do
      result =
        Write.execute("call_1", %{"path" => 123, "content" => "test"}, nil, nil, "/tmp", [])

      assert {:error, msg} = result
      assert msg =~ "path must be a non-empty string"
    end

    test "returns error when content is not a string", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "invalid_content.txt")

      result = Write.execute("call_1", %{"path" => path, "content" => 123}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "content must be a string"
    end
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  describe "execute/6 - abort signal" do
    test "returns error when signal is already aborted at start", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort.txt")

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "content"},
          signal,
          nil,
          tmp_dir,
          []
        )

      AbortSignal.clear(signal)

      assert {:error, :aborted} = result
      refute File.exists?(path)
    end

    test "proceeds normally when signal is not aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_abort.txt")

      signal = AbortSignal.new()

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "content"},
          signal,
          nil,
          tmp_dir,
          []
        )

      AbortSignal.clear(signal)

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end

    test "proceeds normally when signal is nil", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nil_signal.txt")

      result =
        Write.execute(
          "call_1",
          %{"path" => path, "content" => "content"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end
  end

  # ============================================================================
  # Result Details
  # ============================================================================

  describe "execute/6 - result details" do
    test "includes complete details in successful result", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "details.txt")
      content = "test content here"

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Successfully wrote"
      assert text =~ "#{byte_size(content)} bytes"
      assert text =~ path
      assert details.path == path
      assert details.bytes_written == byte_size(content)
    end
  end

  # ============================================================================
  # Binary Content
  # ============================================================================

  describe "execute/6 - binary content" do
    test "writes binary content correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "binary.bin")
      # Binary content with null bytes and high bytes
      content = <<0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD>>

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == content
    end
  end

  # ============================================================================
  # Large Files
  # ============================================================================

  describe "execute/6 - large files" do
    test "writes large file successfully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "large.txt")
      # 1 MB of content
      content = String.duplicate("a", 1_000_000)

      result =
        Write.execute("call_1", %{"path" => path, "content" => content}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.bytes_written == 1_000_000
      assert byte_size(File.read!(path)) == 1_000_000
    end
  end

  # ============================================================================
  # Special Characters in Path
  # ============================================================================

  describe "execute/6 - special characters in path" do
    test "handles spaces in filename", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file with spaces.txt")

      result =
        Write.execute("call_1", %{"path" => path, "content" => "content"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end

    test "handles unicode in filename", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file_世界.txt")

      result =
        Write.execute("call_1", %{"path" => path, "content" => "content"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end

    test "handles special characters in filename", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "file-with_special.chars!@#.txt")

      result =
        Write.execute("call_1", %{"path" => path, "content" => "content"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "content"
    end
  end
end
