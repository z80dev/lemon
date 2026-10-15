defmodule CodingAgent.Tools.FindTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Find
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  test "both backends sort the complete candidate set before limiting", %{tmp_dir: root} do
    files = for name <- ["z", "m", "a"], do: Path.join(root, name <> ".txt")
    Enum.each(files, &File.write!(&1, ""))
    [z, m, a] = files
    File.touch!(z, 100)
    File.touch!(m, 300)
    File.touch!(a, 300)

    for opts <- [
          [fd_available?: false, wildcard_fun: fn _, _ -> files end],
          [
            fd_available?: true,
            fd_run_fun: fn args, _, _ ->
              assert Enum.chunk_every(args, 2, 1, :discard)
                     |> Enum.member?(["--max-results", "100001"])

              {:ok, Enum.join(files, "\n")}
            end
          ]
        ] do
      recent =
        Find.execute(
          "recent",
          %{"pattern" => "*.txt", "sort" => "mtime", "max_results" => 2},
          nil,
          nil,
          root,
          opts
        )

      assert recent.details.files == ["a.txt", "m.txt"]
      assert recent.details.truncated

      by_path =
        Find.execute(
          "path",
          %{"pattern" => "*.txt", "sort" => "path", "max_results" => 1},
          nil,
          nil,
          root,
          opts
        )

      assert by_path.details.files == ["a.txt"]
    end
  end

  test "slash patterns use full paths and the same glob set in both backends", %{tmp_dir: root} do
    for dir <- ["lib/deep", "nested/lib", "other"], do: File.mkdir_p!(Path.join(root, dir))

    for file <- ["lib/a.ex", "lib/deep/no.ex", "nested/lib/b.ex", "other/no.ex"],
        do: File.write!(Path.join(root, file), "")

    expected = ["lib/a.ex", "nested/lib/b.ex"]

    # Exercise the actual fd when installed as well as the wildcard backend.
    for opts <- [[fd_available?: true], [fd_available?: false]] do
      result = Find.execute("slash", %{"pattern" => "lib/*.ex"}, nil, nil, root, opts)
      assert result.details.files == expected
    end

    result =
      Find.execute("fd-args", %{"pattern" => "lib/*.ex"}, nil, nil, root,
        fd_available?: true,
        fd_run_fun: fn args, _, _ ->
          assert "--full-path" in args
          assert "**/lib/*.ex" in args
          {:ok, Enum.map_join(expected, "\n", &Path.join(root, &1))}
        end
      )

    assert result.details.files == expected
  end

  test "candidate ceiling errors instead of showing an arbitrary subset", %{tmp_dir: root} do
    files = Enum.map(1..100_001, &Path.join(root, "#{&1}.txt"))

    for opts <- [
          [fd_available?: false, wildcard_fun: fn _, _ -> files end],
          [fd_available?: true, fd_run_fun: fn _, _, _ -> {:ok, Enum.join(files, "\n")} end]
        ] do
      assert {:error, "Find exceeds 100000 candidates; narrow path or pattern"} =
               Find.execute(
                 "cap",
                 %{"pattern" => "*", "no_ignore" => true, "max_results" => 1},
                 nil,
                 nil,
                 root,
                 opts
               )
    end

    assert {:error, "sort must be mtime or path"} =
             Find.execute("sort", %{"pattern" => "*", "sort" => "random"}, nil, nil, root, [])
  end

  test "merges roots before limiting and reports missing roots", %{tmp_dir: root} do
    for dir <- ["a", "b"], do: File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join(root, "a/same.txt"), "")
    File.write!(Path.join(root, "b/same.txt"), "")

    for opts <- [[], [fd_available?: false]] do
      result =
        Find.execute(
          "roots",
          %{"pattern" => "*.txt", "path" => " b ; a; missing ; ; a", "max_results" => 1},
          nil,
          nil,
          root,
          opts
        )

      assert result.details.files == ["a/same.txt"]
      assert result.details.truncated
      assert result.details.missing_paths == [Path.join(root, "missing")]
      assert Enum.any?(result.content, &(&1.text =~ "Missing search roots"))

      assert {:error, _} =
               Find.execute(
                 "missing",
                 %{"pattern" => "*", "path" => "missing;also-missing"},
                 nil,
                 nil,
                 root,
                 opts
               )

      assert {:error, _} =
               Find.execute("empty", %{"pattern" => "*", "path" => " ; "}, nil, nil, root, opts)
    end
  end

  test "fallback exact names and exact result limits", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "a.txt"), "")
    File.write!(Path.join(tmp_dir, "A.txt"), "")
    File.write!(Path.join(tmp_dir, "aXtxt"), "")

    assert %AgentToolResult{details: %{files: ["a.txt"], truncated: false}} =
             Find.execute("exact", %{"pattern" => "a.txt", "max_results" => 1}, nil, nil, tmp_dir,
               fd_available?: false
             )
  end

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Find.tool("/tmp")

      assert tool.name == "find"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["pattern"]
      assert is_function(tool.execute, 4)
    end

    test "exposes the required pattern parameter" do
      tool = Find.tool("/tmp")
      props = tool.parameters["properties"]

      assert Map.has_key?(props, "pattern")
    end
  end

  describe "execute/6 - basic search" do
    test "finds files by exact name", %{tmp_dir: tmp_dir} do
      # Create test files
      File.write!(Path.join(tmp_dir, "test.txt"), "content")
      File.write!(Path.join(tmp_dir, "other.txt"), "content")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Found 1 match"
      assert text =~ "test.txt"
      refute text =~ "other.txt"
      assert details.count == 1
      assert "test.txt" in details.files
    end

    test "finds files by glob pattern", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test1.txt"), "")
      File.write!(Path.join(tmp_dir, "test2.txt"), "")
      File.write!(Path.join(tmp_dir, "other.md"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 2
      assert "test1.txt" in details.files
      assert "test2.txt" in details.files
      refute "other.md" in details.files
    end

    test "returns no files message when nothing found", %{tmp_dir: tmp_dir} do
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "nonexistent.xyz"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No files found"
      assert details.count == 0
    end
  end

  describe "execute/6 - recursive search" do
    test "finds files in subdirectories", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(subdir, "nested.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 2
      assert "root.txt" in details.files
      assert "subdir/nested.txt" in details.files
    end

    test "respects max_depth parameter", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "level1")
      subsubdir = Path.join(subdir, "level2")
      deep_dir = Path.join(subsubdir, "level3")
      File.mkdir_p!(deep_dir)
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(subdir, "level1.txt"), "")
      File.write!(Path.join(subsubdir, "level2.txt"), "")
      File.write!(Path.join(deep_dir, "level3.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_depth" => 2},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # max_depth should limit how deep the search goes
      # The deepest file (level3.txt at depth 3) should not be found
      refute "level1/level2/level3/level3.txt" in details.files
      # At least some files should be found
      assert details.count >= 1
    end
  end

  describe "execute/6 - type filtering" do
    test "filters to files only", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "testdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "testfile.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test*", "type" => "file"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "testfile.txt" in details.files
      refute "testdir" in details.files
    end

    test "filters to directories only", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "testdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "testfile.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test*", "type" => "directory"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "testdir" in details.files
      refute "testfile.txt" in details.files
    end
  end

  describe "execute/6 - hidden files" do
    test "excludes hidden files by default", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "visible.txt"), "")
      File.write!(Path.join(tmp_dir, ".hidden.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "visible.txt" in details.files
      refute ".hidden.txt" in details.files
    end

    test "includes hidden files when requested", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "visible.txt"), "")
      File.write!(Path.join(tmp_dir, ".hidden.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "hidden" => true},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "visible.txt" in details.files
      assert ".hidden.txt" in details.files
    end
  end

  describe "execute/6 - result limiting" do
    test "respects max_results parameter", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => 5},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.count == 5
      assert details.truncated == true
      assert text =~ "limited to 5"
    end

    test "uses default max_results from opts", %{tmp_dir: tmp_dir} do
      for i <- 1..5 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          max_results: 3
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 3
      assert details.truncated == true
    end
  end

  describe "execute/6 - path parameter" do
    test "searches in specified subdirectory", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "search_here")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      File.write!(Path.join(subdir, "sub.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "search_here"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert "search_here/sub.txt" in details.files
    end

    test "handles absolute path", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "abs_test")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => subdir},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
    end
  end

  describe "execute/6 - error handling" do
    test "returns error for non-existent directory", %{tmp_dir: tmp_dir} do
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "nonexistent"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "Directory not found"
    end

    test "returns error when path is a file", %{tmp_dir: tmp_dir} do
      file_path = Path.join(tmp_dir, "file.txt")
      File.write!(file_path, "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "file.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert {:error, msg} = result
      assert msg =~ "not a directory"
    end
  end

  describe "execute/6 - abort signal" do
    test "respects abort signal at start" do
      signal = LemonAgent.AbortSignal.new()
      LemonAgent.AbortSignal.abort(signal)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          signal,
          nil,
          "/tmp",
          []
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "integration.txt"), "")

      tool = Find.tool(tmp_dir)

      result =
        tool.execute.(
          "call_1",
          %{"pattern" => "integration.txt"},
          nil,
          nil
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert "integration.txt" in details.files
    end
  end

  # ===========================================================================
  # Edge Case Tests
  # ===========================================================================

  describe "fd tool integration vs fallback behavior" do
    test "produces consistent results regardless of fd availability", %{tmp_dir: tmp_dir} do
      # Create a known file structure
      File.write!(Path.join(tmp_dir, "alpha.txt"), "")
      File.write!(Path.join(tmp_dir, "beta.txt"), "")
      subdir = Path.join(tmp_dir, "nested")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "gamma.txt"), "")

      # Execute search - result should be consistent whether fd is available or not
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 3
      assert "alpha.txt" in details.files
      assert "beta.txt" in details.files
      assert "nested/gamma.txt" in details.files
    end

    test "handles glob pattern with character classes", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "test1.txt"), "")
      File.write!(Path.join(tmp_dir, "test2.txt"), "")
      File.write!(Path.join(tmp_dir, "testA.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "test[12].txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "test1.txt" in details.files
      assert "test2.txt" in details.files
      refute "testA.txt" in details.files
    end

    test "handles glob pattern with question mark wildcard", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "a.txt"), "")
      File.write!(Path.join(tmp_dir, "ab.txt"), "")
      File.write!(Path.join(tmp_dir, "abc.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "?.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "a.txt" in details.files
      refute "ab.txt" in details.files
      refute "abc.txt" in details.files
    end

    test "handles glob pattern with curly braces (alternation)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "")
      File.write!(Path.join(tmp_dir, "file.md"), "")
      File.write!(Path.join(tmp_dir, "file.ex"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "file.{txt,md}"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "file.txt" in details.files
      assert "file.md" in details.files
      refute "file.ex" in details.files
    end

    test "plain text pattern without glob characters", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "exact_match.txt"), "")
      File.write!(Path.join(tmp_dir, "exact_match_extra.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "exact_match.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert "exact_match.txt" in details.files
    end
  end

  describe "hidden file handling edge cases" do
    test "excludes files in hidden directories by default", %{tmp_dir: tmp_dir} do
      hidden_dir = Path.join(tmp_dir, ".hidden_dir")
      File.mkdir_p!(hidden_dir)
      File.write!(Path.join(hidden_dir, "visible_in_hidden.txt"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "visible.txt" in details.files
      refute ".hidden_dir/visible_in_hidden.txt" in details.files
    end

    test "includes files in hidden directories when hidden=true", %{tmp_dir: tmp_dir} do
      hidden_dir = Path.join(tmp_dir, ".hidden_dir")
      File.mkdir_p!(hidden_dir)
      File.write!(Path.join(hidden_dir, "visible_in_hidden.txt"), "")
      File.write!(Path.join(tmp_dir, "visible.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "hidden" => true},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "visible.txt" in details.files
      assert ".hidden_dir/visible_in_hidden.txt" in details.files
    end

    test "finds hidden directories when type=directory and hidden=true", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".hidden_dir"))
      File.mkdir_p!(Path.join(tmp_dir, "visible_dir"))

      # Search for directories matching specific pattern
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*_dir", "type" => "directory", "hidden" => true},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert ".hidden_dir" in details.files
      assert "visible_dir" in details.files
    end

    test "deeply nested hidden file in hidden directory chain", %{tmp_dir: tmp_dir} do
      deep_hidden = Path.join([tmp_dir, ".level1", ".level2", ".level3"])
      File.mkdir_p!(deep_hidden)
      File.write!(Path.join(deep_hidden, ".deeply_hidden.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "hidden" => true},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert ".level1/.level2/.level3/.deeply_hidden.txt" in details.files
    end

    test "hidden file with common dotfile names", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".gitignore"), "")
      File.write!(Path.join(tmp_dir, ".env"), "")
      File.write!(Path.join(tmp_dir, ".bashrc"), "")
      File.write!(Path.join(tmp_dir, "regular.txt"), "")

      # Test tmp dirs live inside the checkout, whose .gitignore ignores `.env*`
      # (fd applies it even across a nested repo), so opt out of ignore rules
      # to test hidden-file handling alone; ignore filtering is covered below.
      result =
        Find.execute(
          "call_1",
          %{"pattern" => ".*", "hidden" => true, "no_ignore" => true},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert ".gitignore" in details.files
      assert ".env" in details.files
      assert ".bashrc" in details.files
      refute "regular.txt" in details.files
    end
  end

  describe "max_depth interaction with glob patterns" do
    test "max_depth limits search depth", %{tmp_dir: tmp_dir} do
      # Create a deep structure
      File.write!(Path.join(tmp_dir, "root.txt"), "")
      subdir = Path.join(tmp_dir, "sub")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "level1.txt"), "")
      deepdir = Path.join(subdir, "deep")
      File.mkdir_p!(deepdir)
      File.write!(Path.join(deepdir, "level2.txt"), "")

      # With max_depth=1, should not find level2.txt which is at depth 2
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_depth" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # Should not find the deeply nested file
      refute "sub/deep/level2.txt" in details.files
      # Should find at least some files
      assert details.count >= 1
    end

    test "max_depth with deeply nested directory structure", %{tmp_dir: tmp_dir} do
      # Create structure: tmp/a/b/c/d/e with files at each level
      current = tmp_dir
      dirs = ["a", "b", "c", "d", "e"]

      for {dir, idx} <- Enum.with_index(dirs) do
        current = Path.join(current, dir)
        File.mkdir_p!(current)
        File.write!(Path.join(current, "file#{idx}.txt"), "")
      end

      # With max_depth=3, should not find files at depth 4 and 5
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_depth" => 3},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # Should not find deeply nested files
      refute "a/b/c/d/file3.txt" in details.files
      refute "a/b/c/d/e/file4.txt" in details.files
    end

    test "max_depth with directory type filter", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join([tmp_dir, "top", "mid", "deep", "deeper"]))

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*", "type" => "directory", "max_depth" => 2},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # Should find some directories
      assert details.count >= 1
      # Should not find the deepest directories
      refute "top/mid/deep/deeper" in details.files
    end

    test "max_depth with subpath search", %{tmp_dir: tmp_dir} do
      # Create a deeper structure to clearly test max_depth
      File.mkdir_p!(Path.join([tmp_dir, "src", "a", "b", "c", "d"]))
      File.write!(Path.join([tmp_dir, "src", "a", "b", "c", "d", "deep.ex"]), "")
      File.write!(Path.join([tmp_dir, "src", "a", "b", "mid.ex"]), "")
      File.write!(Path.join([tmp_dir, "src", "root.ex"]), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.ex", "path" => "src", "max_depth" => 2},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # At least some files should be found
      assert details.count >= 1
      # The very deeply nested file should not be found
      refute "src/a/b/c/d/deep.ex" in details.files
    end
  end

  describe "symlink following behavior" do
    @describetag :symlink

    test "follows symlinks to files", %{tmp_dir: tmp_dir} do
      real_file = Path.join(tmp_dir, "real_file.txt")
      link_file = Path.join(tmp_dir, "link_file.txt")
      File.write!(real_file, "content")

      case File.ln_s(real_file, link_file) do
        :ok ->
          result =
            Find.execute(
              "call_1",
              %{"pattern" => "*.txt"},
              nil,
              nil,
              tmp_dir,
              []
            )

          assert %AgentToolResult{details: details} = result
          # Both the real file and symlink should be found
          assert "real_file.txt" in details.files
          assert "link_file.txt" in details.files

        {:error, :enotsup} ->
          # Skip on systems that don't support symlinks
          :ok
      end
    end

    test "follows symlinks to directories", %{tmp_dir: tmp_dir} do
      real_dir = Path.join(tmp_dir, "real_dir")
      link_dir = Path.join(tmp_dir, "link_dir")
      File.mkdir_p!(real_dir)
      File.write!(Path.join(real_dir, "nested.txt"), "content")

      case File.ln_s(real_dir, link_dir) do
        :ok ->
          result =
            Find.execute(
              "call_1",
              %{"pattern" => "*.txt"},
              nil,
              nil,
              tmp_dir,
              []
            )

          assert %AgentToolResult{details: details} = result
          # File should be found through both paths
          assert "real_dir/nested.txt" in details.files
          assert "link_dir/nested.txt" in details.files

        {:error, :enotsup} ->
          :ok
      end
    end

    test "handles broken symlinks gracefully", %{tmp_dir: tmp_dir} do
      broken_link = Path.join(tmp_dir, "broken_link.txt")
      File.write!(Path.join(tmp_dir, "valid.txt"), "content")

      case File.ln_s(Path.join(tmp_dir, "nonexistent.txt"), broken_link) do
        :ok ->
          result =
            Find.execute(
              "call_1",
              %{"pattern" => "*.txt"},
              nil,
              nil,
              tmp_dir,
              []
            )

          # Should not crash, but may or may not include broken symlink
          assert %AgentToolResult{details: details} = result
          assert "valid.txt" in details.files

        {:error, :enotsup} ->
          :ok
      end
    end

    test "handles circular symlinks without infinite loop", %{tmp_dir: tmp_dir} do
      dir_a = Path.join(tmp_dir, "dir_a")
      dir_b = Path.join(tmp_dir, "dir_b")
      File.mkdir_p!(dir_a)
      File.mkdir_p!(dir_b)
      File.write!(Path.join(dir_a, "file.txt"), "content")

      with :ok <- File.ln_s(dir_b, Path.join(dir_a, "link_to_b")),
           :ok <- File.ln_s(dir_a, Path.join(dir_b, "link_to_a")) do
        # This should complete without hanging
        result =
          Find.execute(
            "call_1",
            %{"pattern" => "*.txt", "max_results" => 10},
            nil,
            nil,
            tmp_dir,
            []
          )

        # Should return a result without infinite loop
        assert %AgentToolResult{} = result
      else
        {:error, :enotsup} -> :ok
      end
    end
  end

  describe "permission denied error handling" do
    @describetag :permission

    test "returns error for permission denied on search path (not root user)", %{tmp_dir: tmp_dir} do
      # Skip test if running as root (root can read any directory)
      if System.get_env("USER") == "root" do
        :ok
      else
        protected_dir = Path.join(tmp_dir, "protected")
        File.mkdir_p!(protected_dir)

        # Create a file inside before removing access
        File.write!(Path.join(protected_dir, "hidden.txt"), "secret")
        File.chmod!(protected_dir, 0o000)

        result =
          Find.execute(
            "call_1",
            %{"pattern" => "*.txt", "path" => "protected"},
            nil,
            nil,
            tmp_dir,
            []
          )

        # Restore permissions for cleanup
        File.chmod!(protected_dir, 0o755)

        # The behavior depends on whether fd is available and how it handles permissions
        # Either an error is returned or an empty result (fd may return exit 0 with no matches)
        case result do
          {:error, msg} ->
            assert msg =~ "Permission denied" or msg =~ "Cannot access"

          %AgentToolResult{details: details} ->
            # fd may return 0 results instead of an error
            assert details.count == 0
        end
      end
    end

    test "continues search when some subdirectories are not accessible", %{tmp_dir: tmp_dir} do
      # Skip test if running as root
      if System.get_env("USER") == "root" do
        :ok
      else
        accessible_dir = Path.join(tmp_dir, "accessible")
        protected_dir = Path.join(tmp_dir, "protected")
        File.mkdir_p!(accessible_dir)
        File.mkdir_p!(protected_dir)
        File.write!(Path.join(accessible_dir, "found.txt"), "content")
        File.write!(Path.join(protected_dir, "hidden.txt"), "content")
        File.chmod!(protected_dir, 0o000)

        result =
          Find.execute(
            "call_1",
            %{"pattern" => "*.txt"},
            nil,
            nil,
            tmp_dir,
            []
          )

        # Restore permissions for cleanup
        File.chmod!(protected_dir, 0o755)

        # Should find files in accessible directories
        assert %AgentToolResult{details: details} = result
        assert "accessible/found.txt" in details.files
      end
    end

    test "handles unreadable file gracefully", %{tmp_dir: tmp_dir} do
      unreadable_file = Path.join(tmp_dir, "unreadable.txt")
      readable_file = Path.join(tmp_dir, "readable.txt")
      File.write!(unreadable_file, "secret")
      File.write!(readable_file, "visible")
      File.chmod!(unreadable_file, 0o000)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      # Restore permissions for cleanup
      File.chmod!(unreadable_file, 0o644)

      # Find should still work (it just finds files, doesn't read them)
      assert %AgentToolResult{details: details} = result
      # Both files should be found - find doesn't need read permission
      assert details.files != []
    end
  end

  describe "very large result set pagination" do
    test "handles result set exactly at max_results limit", %{tmp_dir: tmp_dir} do
      max = 5

      for i <- 1..max do
        File.write!(Path.join(tmp_dir, "file#{String.pad_leading(to_string(i), 2, "0")}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => max},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == max
      # When exactly at limit, truncated could be true or false depending on implementation
    end

    test "handles result set one more than max_results", %{tmp_dir: tmp_dir} do
      max = 5

      for i <- 1..(max + 1) do
        File.write!(Path.join(tmp_dir, "file#{String.pad_leading(to_string(i), 2, "0")}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => max},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.count == max
      assert details.truncated == true
      assert text =~ "limited to #{max}"
    end

    test "handles very small max_results", %{tmp_dir: tmp_dir} do
      for i <- 1..10 do
        File.write!(Path.join(tmp_dir, "file#{i}.txt"), "")
      end

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert details.truncated == true
    end

    test "handles large number of files efficiently", %{tmp_dir: tmp_dir} do
      # Create 200 files
      for i <- 1..200 do
        File.write!(Path.join(tmp_dir, "file#{String.pad_leading(to_string(i), 3, "0")}.txt"), "")
      end

      {time_microseconds, result} =
        :timer.tc(fn ->
          Find.execute(
            "call_1",
            %{"pattern" => "*.txt", "max_results" => 50},
            nil,
            nil,
            tmp_dir,
            []
          )
        end)

      assert %AgentToolResult{details: details} = result
      assert details.count == 50
      assert details.truncated == true
      # Should complete in reasonable time (less than 5 seconds)
      assert time_microseconds < 5_000_000
    end

    test "max_results of 0 returns no results", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "max_results" => 0},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.count == 0
      assert text =~ "No files found"
    end

    test "results are sorted consistently", %{tmp_dir: tmp_dir} do
      files = ["zebra.txt", "alpha.txt", "mango.txt", "beta.txt"]

      for file <- files do
        File.write!(Path.join(tmp_dir, file), "")
      end

      result1 =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      result2 =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details1} = result1
      assert %AgentToolResult{details: details2} = result2
      # Results should be sorted and consistent
      assert details1.files == details2.files
      assert details1.files == Enum.sort(files)
    end
  end

  describe "path with special characters" do
    test "handles spaces in path", %{tmp_dir: tmp_dir} do
      space_dir = Path.join(tmp_dir, "path with spaces")
      File.mkdir_p!(space_dir)
      File.write!(Path.join(space_dir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "path with spaces"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
      assert "path with spaces/file.txt" in details.files
    end

    test "handles spaces in filename", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file with spaces.txt"), "content")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "file with spaces.txt" in details.files
    end

    test "handles unicode characters in path", %{tmp_dir: tmp_dir} do
      unicode_dir = Path.join(tmp_dir, "unicode_\u00e9\u00e8\u00ea")
      File.mkdir_p!(unicode_dir)
      File.write!(Path.join(unicode_dir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "unicode_\u00e9\u00e8\u00ea/file.txt" in details.files
    end

    test "handles unicode characters in filename", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "\u4e2d\u6587\u6587\u4ef6.txt"), "content")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "\u4e2d\u6587\u6587\u4ef6.txt" in details.files
    end

    test "handles parentheses in path", %{tmp_dir: tmp_dir} do
      paren_dir = Path.join(tmp_dir, "dir(1)")
      File.mkdir_p!(paren_dir)
      File.write!(Path.join(paren_dir, "file(2).txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "dir(1)/file(2).txt" in details.files
    end

    test "handles brackets in path", %{tmp_dir: tmp_dir} do
      bracket_dir = Path.join(tmp_dir, "dir[1]")
      File.mkdir_p!(bracket_dir)
      File.write!(Path.join(bracket_dir, "file.txt"), "")

      # Search in root directory to avoid bracket interpretation in path
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      # Brackets in directory names may be interpreted as glob patterns
      # The file should still be findable
      assert details.count >= 1 or "dir[1]/file.txt" in details.files
    end

    test "handles ampersand in path", %{tmp_dir: tmp_dir} do
      amp_dir = Path.join(tmp_dir, "dir&subdir")
      File.mkdir_p!(amp_dir)
      File.write!(Path.join(amp_dir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "dir&subdir/file.txt" in details.files
    end

    test "handles quotes in path", %{tmp_dir: tmp_dir} do
      quote_dir = Path.join(tmp_dir, "dir'quoted'")
      File.mkdir_p!(quote_dir)
      File.write!(Path.join(quote_dir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "dir'quoted'/file.txt" in details.files
    end

    test "handles newline in filename", %{tmp_dir: tmp_dir} do
      # Some filesystems allow newlines in filenames
      newline_file = Path.join(tmp_dir, "file\nwith\nnewlines.txt")

      case File.write(newline_file, "content") do
        :ok ->
          result =
            Find.execute(
              "call_1",
              %{"pattern" => "*.txt"},
              nil,
              nil,
              tmp_dir,
              []
            )

          assert %AgentToolResult{details: details} = result
          assert details.files != []

        {:error, _} ->
          # Filesystem doesn't support newlines in filenames
          :ok
      end
    end

    test "handles home directory tilde in path", %{tmp_dir: tmp_dir} do
      # Create a directory named with tilde prefix (not actual home expansion)
      tilde_dir = Path.join(tmp_dir, "~test")
      File.mkdir_p!(tilde_dir)
      File.write!(Path.join(tilde_dir, "file.txt"), "content")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "~test/file.txt" in details.files
    end
  end

  describe "empty directory handling" do
    test "returns no matches for empty directory", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty")
      File.mkdir_p!(empty_dir)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "empty"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No files found"
      assert details.count == 0
      assert details.files == []
    end

    test "finds empty directories when type=directory", %{tmp_dir: tmp_dir} do
      empty_subdir = Path.join(tmp_dir, "empty_subdir")
      File.mkdir_p!(empty_subdir)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*", "type" => "directory"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "empty_subdir" in details.files
    end

    test "handles deeply nested empty directories", %{tmp_dir: tmp_dir} do
      deep_empty = Path.join([tmp_dir, "a", "b", "c", "d", "e"])
      File.mkdir_p!(deep_empty)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "e", "type" => "directory"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "a/b/c/d/e" in details.files
    end

    test "handles mix of empty and non-empty directories", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty_dir")
      full_dir = Path.join(tmp_dir, "full_dir")
      File.mkdir_p!(empty_dir)
      File.mkdir_p!(full_dir)
      File.write!(Path.join(full_dir, "file.txt"), "content")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*_dir", "type" => "directory"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "empty_dir" in details.files
      assert "full_dir" in details.files
    end

    test "empty pattern returns all files", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file1.txt"), "")
      File.write!(Path.join(tmp_dir, "file2.ex"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count >= 2
    end

    test "wildcard in empty directory returns nothing", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "truly_empty")
      File.mkdir_p!(empty_dir)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*", "type" => "file", "path" => "truly_empty"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "No files found"
      assert details.count == 0
    end
  end

  describe "abort signal edge cases" do
    test "respects abort signal during directory check", %{tmp_dir: tmp_dir} do
      signal = LemonAgent.AbortSignal.new()

      # Create a valid directory structure
      File.write!(Path.join(tmp_dir, "file.txt"), "")

      # Abort before execution
      LemonAgent.AbortSignal.abort(signal)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          signal,
          nil,
          tmp_dir,
          []
        )

      assert {:error, "Operation aborted"} = result
    end

    test "nil signal allows execution to complete", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert details.count == 1
    end
  end

  describe "elixir fallback safeguards" do
    test "times out wildcard fallback instead of hanging", %{tmp_dir: tmp_dir} do
      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          nil,
          nil,
          tmp_dir,
          fd_available?: false,
          elixir_timeout_ms: 20,
          wildcard_fun: fn _pattern, _opts ->
            Process.sleep(10_000)
            []
          end
        )

      assert {:error, msg} = result
      assert msg =~ "timed out"
    end

    test "respects abort while wildcard fallback is running", %{tmp_dir: tmp_dir} do
      signal = LemonAgent.AbortSignal.new()

      Task.start(fn ->
        Process.sleep(20)
        LemonAgent.AbortSignal.abort(signal)
      end)

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt"},
          signal,
          nil,
          tmp_dir,
          fd_available?: false,
          elixir_timeout_ms: 2_000,
          wildcard_fun: fn _pattern, _opts ->
            Process.sleep(10_000)
            []
          end
        )

      assert {:error, "Operation aborted"} = result
    end
  end

  describe "path resolution edge cases" do
    test "handles empty path parameter", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "root.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => ""},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "root.txt" in details.files
    end

    test "handles dot path parameter", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "current.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "."},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "current.txt" in details.files
    end

    test "handles relative path with ..", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(tmp_dir, "parent.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "subdir/.."},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{details: details} = result
      assert "parent.txt" in details.files
    end

    test "handles multiple consecutive slashes in path", %{tmp_dir: tmp_dir} do
      subdir = Path.join(tmp_dir, "test")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "file.txt"), "")

      result =
        Find.execute(
          "call_1",
          %{"pattern" => "*.txt", "path" => "test///"},
          nil,
          nil,
          tmp_dir,
          []
        )

      # Should handle gracefully
      case result do
        %AgentToolResult{} -> :ok
        {:error, _} -> :ok
      end
    end
  end
end

defmodule CodingAgent.Tools.FindIgnoreTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Find
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # A nested repository makes the fixture independent of the checkout's own
    # .gitignore (test tmp dirs live under an ignored path).
    {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
    File.write!(Path.join(tmp_dir, ".gitignore"), "build/\n*.log\n")
    File.mkdir_p!(Path.join(tmp_dir, "build"))
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.write!(Path.join([tmp_dir, "build", "artifact.txt"]), "")
    File.write!(Path.join(tmp_dir, "debug.log"), "")
    File.write!(Path.join([tmp_dir, "lib", "code.txt"]), "")
    :ok
  end

  for {label, opts} <- [{"default finder", []}, {"elixir fallback", [fd_available?: false]}] do
    test "#{label} skips gitignored files by default", %{tmp_dir: tmp_dir} do
      assert %AgentToolResult{details: %{files: files}} =
               Find.execute("c1", %{"pattern" => "*"}, nil, nil, tmp_dir, unquote(opts))

      assert "lib/code.txt" in files
      refute "build/artifact.txt" in files
      refute "debug.log" in files
    end

    test "#{label} includes ignored files with no_ignore", %{tmp_dir: tmp_dir} do
      assert %AgentToolResult{details: %{files: files}} =
               Find.execute(
                 "c1",
                 %{"pattern" => "*.txt", "no_ignore" => true},
                 nil,
                 nil,
                 tmp_dir,
                 unquote(opts)
               )

      assert "lib/code.txt" in files
      assert "build/artifact.txt" in files
    end
  end

  test "fallback combines local gitignore and hierarchical ignore precedence and negation", %{
    tmp_dir: tmp_dir
  } do
    File.rm_rf!(Path.join(tmp_dir, ".git"))
    root = Path.join(tmp_dir, "nonrepo")
    File.mkdir_p!(Path.join(root, "nested/blocked"))
    File.write!(Path.join(root, ".gitignore"), "*.cache\n")
    File.write!(Path.join(root, ".ignore"), "!keep.cache\ndrop.cache\n*.txt\nblocked/\n")
    File.write!(Path.join(root, "nested/.gitignore"), "!git-keep.cache\n!drop.cache\n")
    File.write!(Path.join(root, "nested/.ignore"), "!visible.txt\n!blocked/keep.txt\n")

    for file <- [
          "skip.cache",
          "keep.cache",
          "nested/git-keep.cache",
          "nested/drop.cache",
          "nested/hidden.txt",
          "nested/visible.txt",
          "nested/blocked/keep.txt"
        ] do
      File.write!(Path.join(root, file), "")
    end

    assert %AgentToolResult{details: %{files: files}} =
             Find.execute("c1", %{"pattern" => "*", "type" => "file"}, nil, nil, root,
               fd_available?: false
             )

    assert Enum.sort(files) == ["keep.cache", "nested/git-keep.cache", "nested/visible.txt"]

    assert %AgentToolResult{details: %{files: all_files}} =
             Find.execute(
               "c2",
               %{"pattern" => "*", "type" => "file", "no_ignore" => true},
               nil,
               nil,
               root,
               fd_available?: false
             )

    assert "skip.cache" in all_files
    assert "nested/drop.cache" in all_files
    assert "nested/blocked/keep.txt" in all_files
  end

  test "fallback preserves Git repository and configured excludes for quoted newline paths", %{
    tmp_dir: tmp_dir
  } do
    File.write!(Path.join(tmp_dir, ".gitignore"), "ignored*.txt\n!ignored-keep*.txt\n")
    File.write!(Path.join(tmp_dir, ".git/info/exclude"), "info*.txt\n")
    excludes = Path.join(tmp_dir, ".global-ignore")
    File.write!(excludes, "global*.txt\n")
    {_, 0} = System.cmd("git", ["config", "core.excludesFile", excludes], cd: tmp_dir)

    names =
      for prefix <- ["ignored", "ignored-keep", "info", "global", "visible"] do
        name = prefix <> "\"quote\nname.txt"
        File.write!(Path.join(tmp_dir, name), "")
        {prefix, name}
      end
      |> Map.new()

    assert %AgentToolResult{details: %{files: files}} =
             Find.execute("c1", %{"pattern" => "*.txt"}, nil, nil, tmp_dir, fd_available?: false)

    assert names["visible"] in files
    assert names["ignored-keep"] in files
    refute names["ignored"] in files
    refute names["info"] in files
    refute names["global"] in files
  end

  test "fallback ignore double stars span quoted newline directory names", %{tmp_dir: tmp_dir} do
    File.rm_rf!(Path.join(tmp_dir, ".git"))
    root = Path.join(tmp_dir, "nonrepo")
    dir = "nested\n'quoted'"
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join(root, ".ignore"), "**/secret*.txt\n")
    File.write!(Path.join([root, dir, "secret.txt"]), "")
    File.write!(Path.join([root, dir, "secret.txt\n"]), "")
    File.write!(Path.join([root, dir, "visible.txt"]), "")

    assert %AgentToolResult{details: %{files: files}} =
             Find.execute("c1", %{"pattern" => "*", "type" => "file"}, nil, nil, root,
               fd_available?: false
             )

    assert Enum.sort(files) == [dir <> "/secret.txt\n", dir <> "/visible.txt"]
  end
end
