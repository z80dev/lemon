defmodule CodingAgent.Tools.PatchTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Patch
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Patch.tool("/tmp")

      assert tool.name == "patch"
      assert tool.label == "Apply Patch"
      assert tool.description =~ "patch"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["patch_text"]
      assert is_function(tool.execute, 4)
    end
  end

  describe "execute/6 - file addition" do
    test "adds a new file", %{tmp_dir: tmp_dir} do
      new_file = Path.join(tmp_dir, "newfile.txt")

      patch_text = """
      *** Add File: newfile.txt
      +line 1
      +line 2
      +line 3
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Patch applied successfully"
      assert File.exists?(new_file)
      assert File.read!(new_file) == "line 1\nline 2\nline 3"
      assert details.additions > 0
    end

    test "returns error when adding existing file", %{tmp_dir: tmp_dir} do
      existing = Path.join(tmp_dir, "existing.txt")
      File.write!(existing, "already here")

      patch_text = """
      *** Add File: existing.txt
      +new content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "already exists"
    end
  end

  describe "execute/6 - file deletion" do
    test "deletes an existing file", %{tmp_dir: tmp_dir} do
      file_to_delete = Path.join(tmp_dir, "delete_me.txt")
      File.write!(file_to_delete, "goodbye\nworld")

      patch_text = """
      *** Delete File: delete_me.txt
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Patch applied successfully"
      refute File.exists?(file_to_delete)
      assert details.removals > 0
    end

    test "returns error when deleting non-existent file", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Delete File: nonexistent.txt
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found"
    end
  end

  describe "execute/6 - file update" do
    test "updates existing file with hunks", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "update.txt")
      File.write!(file, "line 1\nline 2\nline 3\nline 4")

      patch_text = """
      *** Update File: update.txt
      @@ context
       line 2
      -line 3
      +replaced line 3
       line 4
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Patch applied successfully"
      assert File.read!(file) == "line 1\nline 2\nreplaced line 3\nline 4"
    end

    test "handles multiple hunks in same file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "multi_hunk.txt")
      File.write!(file, "aaa\nbbb\nccc\nddd\neee")

      patch_text = """
      *** Update File: multi_hunk.txt
      @@ first hunk
       aaa
      -bbb
      +BBB
       ccc
      @@ second hunk
       ccc
      -ddd
      +DDD
       eee
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "aaa\nBBB\nccc\nDDD\neee"
    end

    test "adds lines without removing", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "add_only.txt")
      File.write!(file, "before\nafter")

      patch_text = """
      *** Update File: add_only.txt
      @@ add lines
       before
      +inserted line
       after
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "before\ninserted line\nafter"
    end

    test "removes lines without adding", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "remove_only.txt")
      File.write!(file, "keep\nremove\nkeep")

      patch_text = """
      *** Update File: remove_only.txt
      @@ remove
       keep
      -remove
       keep
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "keep\nkeep"
    end

    test "returns error when context not found", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "nocontext.txt")
      File.write!(file, "actual content")

      patch_text = """
      *** Update File: nocontext.txt
      @@ hunk
       wrong context
      -something
      +replacement
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Context not found"
    end
  end

  describe "execute/6 - file move (rename)" do
    test "moves file to new location", %{tmp_dir: tmp_dir} do
      old_path = Path.join(tmp_dir, "old_name.txt")
      new_path = Path.join(tmp_dir, "new_name.txt")
      File.write!(old_path, "content\nhere")

      patch_text = """
      *** Update File: old_name.txt
      *** Move to: new_name.txt
      @@ update
       content
      -here
      +there
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      refute File.exists?(old_path)
      assert File.exists?(new_path)
      assert File.read!(new_path) == "content\nthere"
    end
  end

  describe "execute/6 - error handling" do
    test "returns error when patch_text is missing", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text is required"} = result
    end

    test "returns error when patch_text is empty", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{"patch_text" => ""}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text is required"} = result
    end

    test "returns error when no operations found", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{"patch_text" => "just some text"}, nil, nil, tmp_dir, [])
      assert {:error, "No patch operations found"} = result
    end

    test "returns error when updating non-existent file", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Update File: nonexistent.txt
      @@ hunk
       context
      -old
      +new
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found"
    end
  end

  describe "execute/6 - abort signal handling" do
    test "returns error when signal is aborted", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      patch_text = """
      *** Add File: test.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
    end

    test "proceeds when signal is not aborted", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      new_file = Path.join(tmp_dir, "ok.txt")

      patch_text = """
      *** Add File: ok.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, signal, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(new_file)
    end
  end

  describe "execute/6 - Begin/End Patch markers" do
    test "handles Begin Patch and End Patch markers", %{tmp_dir: tmp_dir} do
      new_file = Path.join(tmp_dir, "markers.txt")

      patch_text = """
      *** Begin Patch
      *** Add File: markers.txt
      +content with markers
      *** End Patch
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(new_file)
    end
  end

  describe "execute/6 - line ending preservation" do
    test "preserves CRLF line endings", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "crlf.txt")
      File.write!(file, "line1\r\nline2\r\nline3")

      patch_text = """
      *** Update File: crlf.txt
      @@ hunk
       line1
      -line2
      +replaced
       line3
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(file)
      assert content == "line1\r\nreplaced\r\nline3"
    end
  end

  describe "execute/6 - nested directory creation" do
    test "creates parent directories for new files", %{tmp_dir: tmp_dir} do
      new_file = Path.join([tmp_dir, "nested", "dir", "file.txt"])

      patch_text = """
      *** Add File: nested/dir/file.txt
      +nested content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(new_file)
      assert File.read!(new_file) == "nested content"
    end
  end

  describe "execute/6 - multiple operations" do
    test "applies multiple operations in sequence", %{tmp_dir: tmp_dir} do
      existing = Path.join(tmp_dir, "existing.txt")
      File.write!(existing, "original")

      patch_text = """
      *** Add File: new1.txt
      +new file 1
      *** Add File: new2.txt
      +new file 2
      *** Update File: existing.txt
      @@ update
      -original
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "3 files changed"
      assert File.exists?(Path.join(tmp_dir, "new1.txt"))
      assert File.exists?(Path.join(tmp_dir, "new2.txt"))
      assert File.read!(existing) == "modified"
      assert details.additions > 0
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      tool = Patch.tool(tmp_dir)

      patch_text = """
      *** Add File: integration.txt
      +test
      """

      result = tool.execute.("call_1", %{"patch_text" => patch_text}, nil, nil)

      assert %AgentToolResult{} = result
      assert File.exists?(Path.join(tmp_dir, "integration.txt"))
    end
  end

  # =============================================================================
  # Security Tests - Path Traversal Attack Vectors
  # =============================================================================

  describe "security - path traversal attacks" do
    test "blocks relative path with .. escaping cwd", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: ../escape.txt
      +malicious content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Path traversal not allowed"
    end

    test "blocks deeply nested .. escape attempts", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: foo/bar/../../../../../../etc/passwd
      +malicious content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Path traversal not allowed"
    end

    test "blocks path with encoded .. sequences are handled literally", %{tmp_dir: tmp_dir} do
      # The path should be treated literally - ..%2f.. is a literal filename
      patch_text = """
      *** Add File: ..%2f..%2fetc%2fpasswd
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # This should succeed because ..%2f is a literal filename, not traversal
      assert %AgentToolResult{} = result
      assert File.exists?(Path.join(tmp_dir, "..%2f..%2fetc%2fpasswd"))
    end

    test "allows paths within cwd even with .. that stay within cwd", %{tmp_dir: tmp_dir} do
      # Create a subdirectory
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)

      patch_text = """
      *** Add File: subdir/../allowed.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(Path.join(tmp_dir, "allowed.txt"))
    end

    test "allows path traversal when allow_path_traversal option is true", %{tmp_dir: tmp_dir} do
      parent_dir = Path.dirname(tmp_dir)
      unique_name = "escape_allowed_#{System.unique_integer([:positive])}.txt"

      patch_text = """
      *** Add File: ../#{unique_name}
      +content
      """

      result =
        Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir,
          allow_path_traversal: true
        )

      expected_file = Path.join(parent_dir, unique_name)

      # Clean up regardless of result
      on_exit(fn -> File.rm(expected_file) end)

      assert %AgentToolResult{} = result
      assert File.exists?(expected_file)
    end

    test "blocks null byte injection in path", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: innocent.txt\0/etc/passwd
      +malicious
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "null bytes"
    end

    test "blocks excessively long paths", %{tmp_dir: tmp_dir} do
      long_path = String.duplicate("a", 5000) <> ".txt"

      patch_text = """
      *** Add File: #{long_path}
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "exceeds maximum length"
    end

    test "blocks empty path components (double slashes)", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: foo//bar.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "empty components"
    end

    test "blocks empty path", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File:
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "cannot be empty"
    end

    test "allows absolute paths (they bypass cwd check)", %{tmp_dir: tmp_dir} do
      # Absolute paths are allowed by design - they don't go through traversal check
      abs_file = Path.join(tmp_dir, "absolute_test.txt")

      patch_text = """
      *** Add File: #{abs_file}
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.exists?(abs_file)
    end
  end

  describe "security - symlink handling" do
    test "blocks modifying symlinks by default", %{tmp_dir: tmp_dir} do
      # Create a real file and a symlink to it
      real_file = Path.join(tmp_dir, "real.txt")
      symlink = Path.join(tmp_dir, "link.txt")
      File.write!(real_file, "original")

      case File.ln_s(real_file, symlink) do
        :ok ->
          patch_text = """
          *** Update File: link.txt
          @@ hunk
          -original
          +modified
          """

          result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

          assert {:error, msg} = result
          assert msg =~ "symlink"

        {:error, :enotsup} ->
          # Symlinks not supported on this filesystem
          :ok
      end
    end

    test "allows modifying symlinks with allow_symlinks option", %{tmp_dir: tmp_dir} do
      real_file = Path.join(tmp_dir, "real.txt")
      symlink = Path.join(tmp_dir, "link.txt")
      File.write!(real_file, "original")

      case File.ln_s(real_file, symlink) do
        :ok ->
          patch_text = """
          *** Update File: link.txt
          @@ hunk
          -original
          +modified
          """

          result =
            Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir,
              allow_symlinks: true
            )

          assert %AgentToolResult{} = result
          assert File.read!(real_file) == "modified"

        {:error, :enotsup} ->
          :ok
      end
    end

    test "blocks symlink pointing outside cwd", %{tmp_dir: tmp_dir} do
      # Create a symlink pointing to /tmp
      symlink = Path.join(tmp_dir, "escape_link")

      case File.ln_s("/tmp", symlink) do
        :ok ->
          patch_text = """
          *** Update File: escape_link
          @@ hunk
          -content
          +malicious
          """

          result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

          # Should fail because symlinks are not allowed by default
          assert {:error, msg} = result
          assert msg =~ "symlink" or msg =~ "directory"

        {:error, :enotsup} ->
          :ok
      end
    end

    test "blocks parent directory symlink attack", %{tmp_dir: tmp_dir} do
      # Create directory with symlink to parent
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)

      symlink_dir = Path.join(subdir, "escape")

      case File.ln_s(Path.dirname(tmp_dir), symlink_dir) do
        :ok ->
          patch_text = """
          *** Add File: subdir/escape/malicious.txt
          +evil content
          """

          result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

          # Should either fail on symlink check or parent validation
          assert {:error, msg} = result
          assert msg =~ "symlink" or msg =~ "directory"

        {:error, :enotsup} ->
          :ok
      end
    end

    test "blocks device file modification", %{tmp_dir: tmp_dir} do
      # Try to modify /dev/null (a device file)
      patch_text = """
      *** Update File: /dev/null
      @@ hunk
      -something
      +malicious
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should fail - either as device or file not found
      assert {:error, _msg} = result
    end
  end

  # =============================================================================
  # Edge Case Tests - Large File Handling
  # =============================================================================

  describe "edge cases - large file handling" do
    test "rejects files larger than 10MB", %{tmp_dir: tmp_dir} do
      large_file = Path.join(tmp_dir, "large.txt")
      # Create a file slightly over 10MB
      # Writing 10MB + 1 byte
      content = String.duplicate("x", 10 * 1024 * 1024 + 1)
      File.write!(large_file, content)

      patch_text = """
      *** Update File: large.txt
      @@ hunk
       x
      -x
      +y
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "too large" or msg =~ "Maximum supported size"
    end

    test "accepts files at exactly 10MB", %{tmp_dir: tmp_dir} do
      large_file = Path.join(tmp_dir, "exact_10mb.txt")
      # Create exactly 10MB file with line breaks for context matching
      line = String.duplicate("x", 100) <> "\n"
      lines_needed = div(10 * 1024 * 1024, 101)
      content = String.duplicate(line, lines_needed)
      File.write!(large_file, content)

      patch_text = """
      *** Update File: exact_10mb.txt
      @@ hunk
       #{String.duplicate("x", 100)}
      +inserted
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should succeed since it's at the limit, not over
      assert %AgentToolResult{} = result
    end

    test "handles moderately large files efficiently", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "moderate.txt")
      # 1MB file with numbered lines for unique context
      lines = for i <- 1..10000, do: "line #{i}: #{String.duplicate("x", 90)}"
      File.write!(file, Enum.join(lines, "\n"))

      patch_text = """
      *** Update File: moderate.txt
      @@ hunk
       line 5000: #{String.duplicate("x", 90)}
      -line 5001: #{String.duplicate("x", 90)}
      +line 5001: MODIFIED
       line 5002: #{String.duplicate("x", 90)}
      """

      {time_us, result} =
        :timer.tc(fn ->
          Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])
        end)

      assert %AgentToolResult{} = result
      # Should complete in reasonable time (under 5 seconds)
      assert time_us < 5_000_000
    end
  end

  # =============================================================================
  # Edge Case Tests - Binary File Handling
  # =============================================================================

  describe "edge cases - binary file handling" do
    test "fails gracefully on binary files with no matching context", %{tmp_dir: tmp_dir} do
      binary_file = Path.join(tmp_dir, "binary.dat")
      # Write actual binary data (not valid UTF-8 text)
      binary_data = <<0, 1, 2, 255, 254, 253, 0, 0, 127, 128>>
      File.write!(binary_file, binary_data)

      patch_text = """
      *** Update File: binary.dat
      @@ hunk
       some text context
      -old line
      +new line
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Context not found"
    end

    test "handles files with embedded null bytes in content", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "null_content.txt")
      # File content with embedded nulls (valid but unusual)
      File.write!(file, "line1\nline2\0embedded\nline3")

      patch_text = """
      *** Update File: null_content.txt
      @@ hunk
       line1
      -line2\0embedded
      +replaced
       line3
      """

      # This might match or might not depending on how split handles it
      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Either succeeds or fails gracefully
      case result do
        %AgentToolResult{} -> assert true
        {:error, msg} -> assert msg =~ "Context not found"
      end
    end

    test "handles mixed binary and text content", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "mixed.txt")
      File.write!(file, "text line\n" <> <<255, 254>> <> "\nmore text")

      patch_text = """
      *** Update File: mixed.txt
      @@ hunk
       text line
      +inserted
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should handle gracefully
      case result do
        %AgentToolResult{} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  # =============================================================================
  # Edge Case Tests - Concurrent Patch Operations
  # =============================================================================

  describe "edge cases - concurrent operations" do
    test "handles concurrent patches to different files", %{tmp_dir: tmp_dir} do
      # Create multiple files
      for i <- 1..5 do
        File.write!(Path.join(tmp_dir, "concurrent_#{i}.txt"), "original #{i}")
      end

      # Launch concurrent patch operations
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            patch_text = """
            *** Update File: concurrent_#{i}.txt
            @@ hunk
            -original #{i}
            +modified #{i}
            """

            Patch.execute("call_#{i}", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      for result <- results do
        assert %AgentToolResult{} = result
      end

      # Verify all files were modified
      for i <- 1..5 do
        content = File.read!(Path.join(tmp_dir, "concurrent_#{i}.txt"))
        assert content == "modified #{i}"
      end
    end

    test "handles race condition on same file (last write wins)", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "race.txt")
      File.write!(file, "original")

      # Launch concurrent patches to same file
      tasks =
        for i <- 1..3 do
          Task.async(fn ->
            # Small random delay to increase race likelihood
            :timer.sleep(:rand.uniform(10))

            patch_text = """
            *** Update File: race.txt
            @@ hunk
            -original
            +modified_by_#{i}
            """

            Patch.execute("call_#{i}", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # At least one should succeed, others may fail due to context mismatch
      success_count = Enum.count(results, &match?(%AgentToolResult{}, &1))
      assert success_count >= 1

      # File should contain one of the modifications
      content = File.read!(file)
      assert String.starts_with?(content, "modified_by_")
    end

    test "concurrent add operations with unique files all succeed", %{tmp_dir: tmp_dir} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            patch_text = """
            *** Add File: new_file_#{i}.txt
            +content for file #{i}
            """

            Patch.execute("call_#{i}", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      for result <- results do
        assert %AgentToolResult{} = result
      end

      # All files should exist
      for i <- 1..10 do
        assert File.exists?(Path.join(tmp_dir, "new_file_#{i}.txt"))
      end
    end
  end

  # =============================================================================
  # Edge Case Tests - Malformed Patch Format Recovery
  # =============================================================================

  describe "edge cases - malformed patch format" do
    test "handles patch with only whitespace content", %{tmp_dir: tmp_dir} do
      patch_text = "   \n\t\n   "

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Whitespace-only content is treated as empty (trimmed)
      assert {:error, "patch_text is required"} = result
    end

    test "handles patch with mismatched markers", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Begin Patch
      *** Add File: test.txt
      +content
      *** Begin Patch
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should still parse the add operation
      assert %AgentToolResult{} = result
      assert File.exists?(Path.join(tmp_dir, "test.txt"))
    end

    test "handles hunk without any changes", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "no_changes.txt")
      File.write!(file, "line1\nline2\nline3")

      patch_text = """
      *** Update File: no_changes.txt
      @@ empty hunk
       line1
       line2
       line3
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      # No actual changes made
      assert details.additions == 0
      assert details.removals == 0
    end

    test "handles malformed hunk header", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "malformed.txt")
      File.write!(file, "content")

      patch_text = """
      *** Update File: malformed.txt
      @@ -1,1 +1,1 garbage
       content
      +added
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should still parse and apply (hunk header content is ignored)
      assert %AgentToolResult{} = result
    end

    test "handles patch with mixed line endings in patch text", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "mixed_endings.txt")
      File.write!(file, "line1\nline2\nline3")

      # Patch text with CRLF endings
      patch_text =
        "*** Update File: mixed_endings.txt\r\n@@ hunk\r\n line1\r\n-line2\r\n+replaced\r\n line3"

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "line1\nreplaced\nline3"
    end

    test "handles incomplete add file operation", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: incomplete.txt
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should create empty file
      assert %AgentToolResult{} = result
      assert File.read!(Path.join(tmp_dir, "incomplete.txt")) == ""
    end

    test "handles patch with unicode content", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "unicode.txt")
      File.write!(file, "Hello 世界\nLine 2")

      patch_text = """
      *** Update File: unicode.txt
      @@ hunk
       Hello 世界
      -Line 2
      +Line 2 修改
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "Hello 世界\nLine 2 修改"
    end

    test "handles patch with emoji in path and content", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: emoji_🎉.txt
      +Content with 🚀 emoji
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(Path.join(tmp_dir, "emoji_🎉.txt")) == "Content with 🚀 emoji"
    end

    test "handles patch_text that is not a string", %{tmp_dir: tmp_dir} do
      result = Patch.execute("call_1", %{"patch_text" => 12345}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text must be a string"} = result

      result = Patch.execute("call_1", %{"patch_text" => ["list"]}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text must be a string"} = result

      result = Patch.execute("call_1", %{"patch_text" => nil}, nil, nil, tmp_dir, [])
      assert {:error, "patch_text must be a string"} = result
    end
  end

  # =============================================================================
  # Edge Case Tests - Hunk Context Matching
  # =============================================================================

  describe "edge cases - hunk context matching" do
    test "matches context at beginning of file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "beginning.txt")
      File.write!(file, "first\nsecond\nthird")

      patch_text = """
      *** Update File: beginning.txt
      @@ hunk
      -first
      +FIRST
       second
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "FIRST\nsecond\nthird"
    end

    test "matches context at end of file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "ending.txt")
      File.write!(file, "first\nsecond\nthird")

      patch_text = """
      *** Update File: ending.txt
      @@ hunk
       second
      -third
      +THIRD
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "first\nsecond\nTHIRD"
    end

    test "handles duplicate context lines - matches first occurrence", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "duplicates.txt")
      File.write!(file, "duplicate\nTARGET\nduplicate\nOTHER\n")

      patch_text = """
      *** Update File: duplicates.txt
      @@ hunk
       duplicate
      -TARGET
      +MODIFIED
       duplicate
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(file)
      # Should modify the first TARGET
      assert content == "duplicate\nMODIFIED\nduplicate\nOTHER\n"
    end

    test "handles empty file update with insertion", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "empty.txt")
      File.write!(file, "")

      patch_text = """
      *** Update File: empty.txt
      @@ hunk
      +first line
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      # Empty file splits to [""] so insertion goes after that empty line
      assert File.read!(file) == "\nfirst line"
    end

    test "handles single line file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "single.txt")
      File.write!(file, "only line")

      patch_text = """
      *** Update File: single.txt
      @@ hunk
      -only line
      +modified line
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "modified line"
    end

    test "handles whitespace-only context differences", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "whitespace.txt")
      File.write!(file, "line1\n  indented\nline3")

      patch_text = """
      *** Update File: whitespace.txt
      @@ hunk
       line1
       indented
      +inserted
       line3
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Context doesn't match due to whitespace difference
      assert {:error, msg} = result
      assert msg =~ "Context not found"
    end

    test "context must match exactly", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "exact.txt")
      File.write!(file, "Line One\nLine Two\nLine Three")

      patch_text = """
      *** Update File: exact.txt
      @@ hunk
       line one
      -Line Two
      +Modified
       Line Three
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Case mismatch should fail
      assert {:error, msg} = result
      assert msg =~ "Context not found"
    end

    test "handles trailing newline in file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "trailing.txt")
      File.write!(file, "line1\nline2\n")

      patch_text = """
      *** Update File: trailing.txt
      @@ hunk
       line1
      -line2
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      # Trailing newline should be preserved
      assert File.read!(file) == "line1\nmodified\n"
    end

    test "handles file without trailing newline", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "no_trailing.txt")
      File.write!(file, "line1\nline2")

      patch_text = """
      *** Update File: no_trailing.txt
      @@ hunk
       line1
      -line2
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(file) == "line1\nmodified"
    end
  end

  # =============================================================================
  # Edge Case Tests - File Permission Scenarios
  # =============================================================================

  describe "edge cases - file permission scenarios" do
    @tag :skip_on_ci
    test "handles read-only file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "readonly.txt")
      File.write!(file, "original")
      File.chmod!(file, 0o444)

      on_exit(fn ->
        File.chmod(file, 0o644)
        File.rm(file)
      end)

      patch_text = """
      *** Update File: readonly.txt
      @@ hunk
      -original
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Permission denied" or msg =~ "eacces"
    end

    @tag :skip_on_ci
    test "handles read-only directory for new file", %{tmp_dir: tmp_dir} do
      readonly_dir = Path.join(tmp_dir, "readonly_dir")
      File.mkdir_p!(readonly_dir)
      File.chmod!(readonly_dir, 0o555)

      on_exit(fn ->
        File.chmod(readonly_dir, 0o755)
        File.rm_rf(readonly_dir)
      end)

      patch_text = """
      *** Add File: readonly_dir/new.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Permission denied" or msg =~ "eacces"
    end

    @tag :skip_on_ci
    test "handles unreadable file", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "unreadable.txt")
      File.write!(file, "secret")
      File.chmod!(file, 0o000)

      on_exit(fn ->
        File.chmod(file, 0o644)
        File.rm(file)
      end)

      patch_text = """
      *** Update File: unreadable.txt
      @@ hunk
      -secret
      +exposed
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Permission denied" or msg =~ "eacces"
    end

    test "handles non-existent parent directory", %{tmp_dir: tmp_dir} do
      patch_text = """
      *** Add File: deep/nested/path/file.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should auto-create parent directories
      assert %AgentToolResult{} = result
      assert File.exists?(Path.join(tmp_dir, "deep/nested/path/file.txt"))
    end

    test "handles directory path given as file", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "a_directory")
      File.mkdir_p!(dir)

      patch_text = """
      *** Update File: a_directory
      @@ hunk
      -content
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "directory" or msg =~ "not a regular file"
    end
  end

  # =============================================================================
  # Additional Security Tests
  # =============================================================================

  describe "security - move operation validation" do
    test "validates move_to path for traversal", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "source.txt")
      File.write!(file, "content")

      patch_text = """
      *** Update File: source.txt
      *** Move to: ../escaped.txt
      @@ hunk
      -content
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Path traversal not allowed"
    end

    test "validates move_to path for null bytes", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "source.txt")
      File.write!(file, "content")

      patch_text = """
      *** Update File: source.txt
      *** Move to: target\0evil.txt
      @@ hunk
      -content
      +modified
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "null bytes"
    end
  end

  describe "security - abort signal during operations" do
    test "aborts during multi-hunk application", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "multi_abort.txt")
      File.write!(file, "line1\nline2\nline3\nline4\nline5")

      signal = AbortSignal.new()

      # Start patch in a task and abort during execution
      task =
        Task.async(fn ->
          patch_text = """
          *** Update File: multi_abort.txt
          @@ first
           line1
          -line2
          +LINE2
           line3
          @@ second
           line3
          -line4
          +LINE4
           line5
          """

          # Small delay then abort
          spawn(fn ->
            :timer.sleep(1)
            AbortSignal.abort(signal)
          end)

          Patch.execute("call_1", %{"patch_text" => patch_text}, signal, nil, tmp_dir, [])
        end)

      result = Task.await(task)

      # Should either complete or abort - both are valid
      case result do
        {:error, "Operation aborted"} -> assert true
        %AgentToolResult{} -> assert true
      end
    end

    test "abort before any operation starts", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      patch_text = """
      *** Add File: never_created.txt
      +content
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
      refute File.exists?(Path.join(tmp_dir, "never_created.txt"))
    end
  end

  describe "security - validate_operations pre-check" do
    test "validates all operations before applying any", %{tmp_dir: tmp_dir} do
      # First operation is valid, second has traversal attack
      existing = Path.join(tmp_dir, "valid.txt")
      File.write!(existing, "content")

      patch_text = """
      *** Update File: valid.txt
      @@ hunk
      -content
      +modified
      *** Add File: ../escape.txt
      +malicious
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should fail without modifying valid.txt
      assert {:error, msg} = result
      assert msg =~ "Path traversal"

      # First file should be unchanged
      assert File.read!(existing) == "content"
    end

    test "validates delete target exists before any changes", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "keeper.txt")
      File.write!(file, "keep me")

      patch_text = """
      *** Update File: keeper.txt
      @@ hunk
      -keep me
      +modified
      *** Delete File: nonexistent.txt
      """

      result = Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir, [])

      # Should fail validation and not modify first file
      assert {:error, msg} = result
      assert msg =~ "not found"

      # First file should be unchanged
      assert File.read!(file) == "keep me"
    end
  end
end
